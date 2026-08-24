package agent

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/vmatveenko/nanopi-r5s/manager/internal/buildinfo"
	"github.com/vmatveenko/nanopi-r5s/manager/internal/model"
)

const updateUserAgent = "NanoPi-Manager/" + "self-update"

type githubRelease struct {
	TagName     string    `json:"tag_name"`
	Name        string    `json:"name"`
	Draft       bool      `json:"draft"`
	Prerelease  bool      `json:"prerelease"`
	PublishedAt time.Time `json:"published_at"`
	HTMLURL     string    `json:"html_url"`
	Assets      []struct {
		Name string `json:"name"`
		URL  string `json:"browser_download_url"`
	} `json:"assets"`
}

type updateMetadata struct {
	Version    string `json:"version"`
	InstallDir string `json:"installDir"`
	WebPort    int    `json:"webPort"`
	SocketPath string `json:"socketPath"`
}

func (s *Service) ManagerReleases(ctx context.Context, includePrerelease bool) (model.ReleaseStatus, error) {
	if s.cfg.DryRun {
		return model.ReleaseStatus{CurrentVersion: buildinfo.Version, Releases: []model.ReleaseInfo{}}, nil
	}
	releases, err := s.fetchReleases(ctx, includePrerelease)
	return model.ReleaseStatus{CurrentVersion: buildinfo.Version, Releases: releases}, err
}

func (s *Service) fetchReleases(ctx context.Context, includePrerelease bool) ([]model.ReleaseInfo, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(s.cfg.ReleaseAPIURL, "/")+"/releases?per_page=50", nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", updateUserAgent)
	response, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("GitHub releases returned HTTP %d", response.StatusCode)
	}
	var remote []githubRelease
	if err := json.NewDecoder(io.LimitReader(response.Body, 4<<20)).Decode(&remote); err != nil {
		return nil, err
	}
	archiveName := "nanopi-manager-linux-" + releaseArchitecture() + ".tar.gz"
	var result []model.ReleaseInfo
	for _, release := range remote {
		if release.Draft || release.TagName == "" || release.Prerelease && !includePrerelease {
			continue
		}
		item := model.ReleaseInfo{Version: release.TagName, Name: release.Name, Prerelease: release.Prerelease, PublishedAt: release.PublishedAt, ReleaseURL: release.HTMLURL}
		for _, asset := range release.Assets {
			switch asset.Name {
			case archiveName:
				item.ArchiveURL = asset.URL
			case "checksums.txt":
				item.ChecksumsURL = asset.URL
			}
		}
		if item.ArchiveURL != "" && item.ChecksumsURL != "" {
			result = append(result, item)
		}
	}
	sort.Slice(result, func(i, j int) bool { return result[i].PublishedAt.After(result[j].PublishedAt) })
	return result, nil
}

func (s *Service) ScheduleManagerUpdate(ctx context.Context, version string, confirmRisk bool) (model.UpdateResult, error) {
	version = strings.TrimSpace(version)
	if version == "" || strings.ContainsAny(version, `/\\`) || strings.Contains(version, "..") {
		return model.UpdateResult{}, errors.New("invalid release version")
	}
	if s.cfg.DryRun {
		return model.UpdateResult{Scheduled: true, Version: version, Message: "dry-run update scheduled"}, nil
	}
	releases, err := s.fetchReleases(ctx, true)
	if err != nil {
		return model.UpdateResult{}, err
	}
	var selected *model.ReleaseInfo
	for index := range releases {
		if releases[index].Version == version {
			selected = &releases[index]
			break
		}
	}
	if selected == nil {
		return model.UpdateResult{}, errors.New("selected release is unavailable for this architecture")
	}
	if (selected.Prerelease || isOlderVersion(version, buildinfo.Version)) && !confirmRisk {
		return model.UpdateResult{}, errors.New("prerelease or downgrade requires explicit confirmation")
	}
	archive, err := downloadBytes(ctx, selected.ArchiveURL, 100<<20)
	if err != nil {
		return model.UpdateResult{}, fmt.Errorf("download release archive: %w", err)
	}
	checksums, err := downloadBytes(ctx, selected.ChecksumsURL, 1<<20)
	if err != nil {
		return model.UpdateResult{}, fmt.Errorf("download checksums: %w", err)
	}
	archiveName := "nanopi-manager-linux-" + releaseArchitecture() + ".tar.gz"
	if err := verifyArchiveChecksum(archiveName, archive, string(checksums)); err != nil {
		return model.UpdateResult{}, err
	}
	dir := filepath.Join(s.cfg.StateDir, "updates", time.Now().UTC().Format("20060102T150405Z")+"-"+safeName(version))
	staged := filepath.Join(dir, "staged")
	backup := filepath.Join(dir, "backup")
	if err := os.MkdirAll(staged, 0o700); err != nil {
		return model.UpdateResult{}, err
	}
	if err := os.MkdirAll(backup, 0o700); err != nil {
		return model.UpdateResult{}, err
	}
	if err := extractManagerArchive(archive, staged); err != nil {
		return model.UpdateResult{}, err
	}
	installDir := s.cfg.Rooted(s.cfg.InstallDir)
	for _, name := range []string{"nanopi-manager-web", "nanopi-manager-agent"} {
		current, err := os.ReadFile(filepath.Join(installDir, name))
		if err != nil {
			return model.UpdateResult{}, fmt.Errorf("backup %s: %w", name, err)
		}
		if err := os.WriteFile(filepath.Join(backup, name), current, 0o700); err != nil {
			return model.UpdateResult{}, err
		}
	}
	helper := filepath.Join(dir, "update-helper")
	currentAgent, err := os.ReadFile(filepath.Join(installDir, "nanopi-manager-agent"))
	if err != nil {
		return model.UpdateResult{}, err
	}
	if err := os.WriteFile(helper, currentAgent, 0o700); err != nil {
		return model.UpdateResult{}, err
	}
	metadata := updateMetadata{Version: version, InstallDir: installDir, WebPort: s.configuredManagerPort(), SocketPath: s.cfg.SocketPath}
	if err := writeJSONAtomic(filepath.Join(dir, "metadata.json"), metadata, 0o600); err != nil {
		return model.UpdateResult{}, err
	}
	unit := "nanopi-manager-update-" + safeName(version) + "-" + strconv.FormatInt(time.Now().UnixNano(), 10)
	if _, err := s.runner.Run(ctx, "systemd-run", "--unit", unit, "--on-active", "2s", "--property", "Type=oneshot", helper, "--mode", "finish-update", "--update-dir", dir); err != nil {
		return model.UpdateResult{}, fmt.Errorf("schedule update: %w", err)
	}
	return model.UpdateResult{Scheduled: true, Version: version, Message: "update scheduled; services will restart"}, nil
}

func (s *Service) FinishManagerUpdate(ctx context.Context) error {
	dir, err := filepath.Abs(s.cfg.UpdateDir)
	if err != nil || s.cfg.UpdateDir == "" {
		return errors.New("invalid update directory")
	}
	updatesRoot, _ := filepath.Abs(filepath.Join(s.cfg.StateDir, "updates"))
	if rel, relErr := filepath.Rel(updatesRoot, dir); relErr != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(os.PathSeparator)) {
		return errors.New("update directory is outside state directory")
	}
	raw, err := os.ReadFile(filepath.Join(dir, "metadata.json"))
	if err != nil {
		return err
	}
	var metadata updateMetadata
	if err := json.Unmarshal(raw, &metadata); err != nil {
		return err
	}
	install := func(sourceDir string) error {
		for _, name := range []string{"nanopi-manager-web", "nanopi-manager-agent"} {
			content, err := os.ReadFile(filepath.Join(sourceDir, name))
			if err != nil {
				return err
			}
			if err := writeFileAtomic(filepath.Join(metadata.InstallDir, name), content, 0o755); err != nil {
				return err
			}
		}
		return nil
	}
	restart := func() error {
		if _, err := s.runner.Run(ctx, "systemctl", "restart", "nanopi-manager-agent.service"); err != nil {
			return err
		}
		_, err := s.runner.Run(ctx, "systemctl", "restart", "nanopi-manager-web.service")
		return err
	}
	if err := install(filepath.Join(dir, "staged")); err != nil {
		return err
	}
	if err := restart(); err == nil && waitForManager(ctx, metadata.WebPort, metadata.SocketPath) == nil {
		return writeJSONAtomic(filepath.Join(s.cfg.StateDir, "last-update.json"), map[string]any{"version": metadata.Version, "updatedAt": time.Now().UTC(), "rolledBack": false}, 0o600)
	}
	if restoreErr := install(filepath.Join(dir, "backup")); restoreErr != nil {
		return fmt.Errorf("update failed and backup restore failed: %w", restoreErr)
	}
	if restartErr := restart(); restartErr != nil {
		return fmt.Errorf("update failed; previous binaries restored but restart failed: %w", restartErr)
	}
	_ = writeJSONAtomic(filepath.Join(s.cfg.StateDir, "last-update.json"), map[string]any{"version": metadata.Version, "updatedAt": time.Now().UTC(), "rolledBack": true}, 0o600)
	return errors.New("updated services failed health check; previous version restored")
}

func downloadBytes(ctx context.Context, url string, limit int64) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", updateUserAgent)
	response, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d", response.StatusCode)
	}
	raw, err := io.ReadAll(io.LimitReader(response.Body, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(raw)) > limit {
		return nil, errors.New("download exceeds size limit")
	}
	return raw, nil
}

func verifyArchiveChecksum(name string, archive []byte, checksums string) error {
	want := ""
	for _, line := range strings.Split(checksums, "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 2 && strings.TrimPrefix(fields[len(fields)-1], "*") == name {
			want = fields[0]
			break
		}
	}
	if len(want) != sha256.Size*2 {
		return errors.New("release checksum is missing or invalid")
	}
	if _, err := hex.DecodeString(want); err != nil {
		return errors.New("release checksum is invalid")
	}
	got := sha256.Sum256(archive)
	if !strings.EqualFold(want, hex.EncodeToString(got[:])) {
		return errors.New("release archive checksum mismatch")
	}
	return nil
}

func extractManagerArchive(archive []byte, destination string) error {
	gz, err := gzip.NewReader(bytes.NewReader(archive))
	if err != nil {
		return err
	}
	defer gz.Close()
	found := map[string]bool{}
	reader := tar.NewReader(gz)
	for {
		header, err := reader.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return err
		}
		if header.Typeflag != tar.TypeReg && header.Typeflag != tar.TypeRegA {
			continue
		}
		name := filepath.Base(filepath.Clean(header.Name))
		if name != "nanopi-manager-web" && name != "nanopi-manager-agent" {
			continue
		}
		if header.Size < 1 || header.Size > 100<<20 {
			return errors.New("release binary has invalid size")
		}
		content, err := io.ReadAll(io.LimitReader(reader, header.Size))
		if err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(destination, name), content, 0o700); err != nil {
			return err
		}
		found[name] = true
	}
	if !found["nanopi-manager-web"] || !found["nanopi-manager-agent"] {
		return errors.New("release archive does not contain both Manager binaries")
	}
	return nil
}

func waitForManager(ctx context.Context, port int, socketPath string) error {
	client := &http.Client{Timeout: 2 * time.Second}
	url := fmt.Sprintf("http://127.0.0.1:%d/api/bootstrap", port)
	agentClient := &http.Client{Transport: &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{Timeout: 2 * time.Second}).DialContext(ctx, "unix", socketPath)
	}}, Timeout: 2 * time.Second}
	for attempt := 0; attempt < 20; attempt++ {
		req, _ := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if response, err := client.Do(req); err == nil {
			response.Body.Close()
			if response.StatusCode == http.StatusOK {
				agentRequest, _ := http.NewRequestWithContext(ctx, http.MethodGet, "http://agent/v1/inventory", nil)
				if agentResponse, agentErr := agentClient.Do(agentRequest); agentErr == nil {
					agentResponse.Body.Close()
					if agentResponse.StatusCode == http.StatusOK {
						return nil
					}
				}
			}
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Second):
		}
	}
	return errors.New("Manager health check timed out")
}

func (s *Service) configuredManagerPort() int {
	raw, err := os.ReadFile(s.cfg.Rooted("/etc/nanopi-manager/manager.env"))
	if err == nil {
		for _, line := range strings.Split(string(raw), "\n") {
			if value, ok := strings.CutPrefix(strings.TrimSpace(line), "NANOPI_MANAGER_PORT="); ok {
				if port, parseErr := strconv.Atoi(value); parseErr == nil && port > 0 && port <= 65535 {
					return port
				}
			}
		}
	}
	return currentPort(s.cfg.ListenAddress)
}

func releaseArchitecture() string {
	if runtime.GOARCH == "arm64" {
		return "arm64"
	}
	return "amd64"
}

func safeName(value string) string {
	var b strings.Builder
	for _, r := range value {
		if r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-' || r == '_' || r == '.' {
			b.WriteRune(r)
		}
	}
	if b.Len() == 0 {
		return "release"
	}
	return b.String()
}

func isOlderVersion(candidate, current string) bool {
	parse := func(value string) ([]int, bool) {
		value = strings.TrimPrefix(strings.TrimSpace(value), "v")
		value = strings.SplitN(value, "-", 2)[0]
		parts := strings.Split(value, ".")
		if len(parts) < 2 {
			return nil, false
		}
		result := make([]int, len(parts))
		for i, part := range parts {
			n, err := strconv.Atoi(part)
			if err != nil {
				return nil, false
			}
			result[i] = n
		}
		return result, true
	}
	a, okA := parse(candidate)
	b, okB := parse(current)
	if !okA || !okB {
		return false
	}
	for len(a) < len(b) {
		a = append(a, 0)
	}
	for len(b) < len(a) {
		b = append(b, 0)
	}
	for i := range a {
		if a[i] != b[i] {
			return a[i] < b[i]
		}
	}
	return false
}
