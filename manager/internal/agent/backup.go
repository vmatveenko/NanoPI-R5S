package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/vmatveenko/nanopi-r5s/manager/internal/model"
)

type backupEntry struct {
	Path    string `json:"path"`
	Existed bool   `json:"existed"`
	Backup  string `json:"backup,omitempty"`
	Mode    uint32 `json:"mode,omitempty"`
}

type backupManifest struct {
	RevisionID string          `json:"revisionId"`
	CreatedAt  time.Time       `json:"createdAt"`
	Entries    []backupEntry   `json:"entries"`
	Services   []serviceBackup `json:"services,omitempty"`
}

type serviceBackup struct {
	Name    string `json:"name"`
	Active  bool   `json:"active"`
	Enabled bool   `json:"enabled"`
}

func (s *Service) createBackup(ctx context.Context, files []model.FileChange) (backupManifest, error) {
	revision := time.Now().UTC().Format("20060102T150405.000000000Z")
	dir := filepath.Join(s.cfg.StateDir, "backups", revision)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return backupManifest{}, err
	}
	manifest := backupManifest{RevisionID: revision, CreatedAt: time.Now().UTC()}
	if !s.cfg.DryRun {
		for _, name := range []string{"nftables.service", "isc-dhcp-server.service"} {
			active, _ := s.runner.Run(ctx, "systemctl", "is-active", name)
			enabled, _ := s.runner.Run(ctx, "systemctl", "is-enabled", name)
			manifest.Services = append(manifest.Services, serviceBackup{Name: name, Active: strings.TrimSpace(active) == "active", Enabled: strings.TrimSpace(enabled) == "enabled"})
		}
	}
	for index, file := range files {
		target := s.cfg.Rooted(file.Path)
		entry := backupEntry{Path: file.Path}
		raw, err := os.ReadFile(target)
		if err == nil {
			entry.Existed = true
			if info, statErr := os.Stat(target); statErr == nil {
				entry.Mode = uint32(info.Mode().Perm())
			}
			entry.Backup = fmt.Sprintf("%03d.bin", index)
			if err := os.WriteFile(filepath.Join(dir, entry.Backup), raw, 0o600); err != nil {
				return backupManifest{}, err
			}
		} else if !errors.Is(err, os.ErrNotExist) {
			return backupManifest{}, err
		}
		manifest.Entries = append(manifest.Entries, entry)
	}
	if err := writeJSONAtomic(filepath.Join(dir, "manifest.json"), manifest, 0o600); err != nil {
		return backupManifest{}, err
	}
	return manifest, nil
}

func (s *Service) restoreRevision(ctx context.Context, revision string) error {
	if revision == "" || strings.ContainsAny(revision, `/\\`) {
		return errors.New("invalid revision identifier")
	}
	dir := filepath.Join(s.cfg.StateDir, "backups", revision)
	raw, err := os.ReadFile(filepath.Join(dir, "manifest.json"))
	if err != nil {
		return fmt.Errorf("read backup manifest: %w", err)
	}
	var manifest backupManifest
	if err := json.Unmarshal(raw, &manifest); err != nil {
		return err
	}
	for _, entry := range manifest.Entries {
		target := s.cfg.Rooted(entry.Path)
		if entry.Existed {
			content, err := os.ReadFile(filepath.Join(dir, entry.Backup))
			if err != nil {
				return err
			}
			mode := os.FileMode(entry.Mode)
			if mode == 0 {
				mode = 0o600
			}
			if err := writeFileAtomic(target, content, mode); err != nil {
				return err
			}
		} else if err := os.Remove(target); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	if s.cfg.DryRun {
		return nil
	}
	for _, command := range [][]string{
		{"systemctl", "daemon-reload"},
		{"sysctl", "--system"},
		{"netplan", "apply"},
	} {
		if _, err := s.runner.Run(ctx, command[0], command[1:]...); err != nil {
			return fmt.Errorf("restore %s: %w", command[0], err)
		}
	}
	if len(manifest.Services) == 0 {
		for _, name := range []string{"nftables.service", "isc-dhcp-server.service"} {
			if _, err := s.runner.Run(ctx, "systemctl", "restart", name); err != nil {
				return fmt.Errorf("restore service %s: %w", name, err)
			}
		}
	} else {
		for _, service := range manifest.Services {
			enableAction := "disable"
			if service.Enabled {
				enableAction = "enable"
			}
			if _, err := s.runner.Run(ctx, "systemctl", enableAction, service.Name); err != nil {
				return fmt.Errorf("restore enablement %s: %w", service.Name, err)
			}
			runtimeAction := "stop"
			if service.Active {
				runtimeAction = "restart"
			}
			if _, err := s.runner.Run(ctx, "systemctl", runtimeAction, service.Name); err != nil {
				return fmt.Errorf("restore runtime %s: %w", service.Name, err)
			}
		}
	}
	for _, entry := range manifest.Entries {
		if entry.Path == "/etc/nanopi-manager/manager.env" {
			if err := s.scheduleWebRestart(ctx, revision); err != nil {
				return fmt.Errorf("schedule Manager restart after restore: %w", err)
			}
			break
		}
	}
	return nil
}

func writeFileAtomic(path string, content []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".nanopi-manager-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if err := tmp.Chmod(mode); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(content); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpName, path)
}

func writeJSONAtomic(path string, value any, mode os.FileMode) error {
	raw, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	return writeFileAtomic(path, append(raw, '\n'), mode)
}
