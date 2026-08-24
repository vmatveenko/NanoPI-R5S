package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/vmatveenko/nanopi-r5s/manager/internal/model"
	"github.com/vmatveenko/nanopi-r5s/manager/internal/router"
)

// Pinned to the stable release whose API schema is covered by this adapter.
const xuiImage = "ghcr.io/mhsanaei/3x-ui:v3.6.0"

func (s *Service) DockerInstall(ctx context.Context) error {
	if s.cfg.DryRun {
		return nil
	}
	osInfo := readKeyValueFile("/etc/os-release")
	id := osInfo["ID"]
	if id != "ubuntu" && id != "debian" {
		return fmt.Errorf("Docker installer currently supports Ubuntu and Debian, got %q", id)
	}
	codename := osInfo["VERSION_CODENAME"]
	if codename == "" {
		codename = osInfo["UBUNTU_CODENAME"]
	}
	if codename == "" {
		return errors.New("cannot determine distribution codename")
	}
	if _, err := s.runner.Run(ctx, "apt-get", "update"); err != nil {
		return err
	}
	if _, err := s.runner.Run(ctx, "apt-get", "install", "-y", "ca-certificates", "curl", "gnupg"); err != nil {
		return err
	}
	if err := os.MkdirAll("/etc/apt/keyrings", 0o755); err != nil {
		return err
	}
	keyPath := "/etc/apt/keyrings/docker.asc"
	if _, err := s.runner.Run(ctx, "curl", "-fsSL", "https://download.docker.com/linux/"+id+"/gpg", "-o", keyPath); err != nil {
		return err
	}
	if err := os.Chmod(keyPath, 0o644); err != nil {
		return err
	}
	arch, err := s.runner.Run(ctx, "dpkg", "--print-architecture")
	if err != nil {
		return err
	}
	source := fmt.Sprintf("Types: deb\nURIs: https://download.docker.com/linux/%s\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: %s\n", id, codename, strings.TrimSpace(arch), keyPath)
	if err := writeFileAtomic("/etc/apt/sources.list.d/docker.sources", []byte(source), 0o644); err != nil {
		return err
	}
	if _, err := s.runner.Run(ctx, "apt-get", "update"); err != nil {
		return err
	}
	if _, err := s.runner.Run(ctx, "apt-get", "install", "-y", "docker-ce", "docker-ce-cli", "containerd.io", "docker-buildx-plugin", "docker-compose-plugin"); err != nil {
		return err
	}
	_, err = s.runner.Run(ctx, "systemctl", "enable", "--now", "docker")
	return err
}

func (s *Service) XUIAction(ctx context.Context, request model.XUIActionRequest, panelPort int) (string, error) {
	base := s.cfg.Rooted("/opt/nanopi-manager/3x-ui")
	compose := filepath.Join(base, "compose.yaml")
	if err := os.MkdirAll(filepath.Join(base, "db"), 0o700); err != nil {
		return "", err
	}
	if err := os.MkdirAll(filepath.Join(base, "cert"), 0o700); err != nil {
		return "", err
	}
	if err := writeFileAtomic(compose, []byte(renderXUICompose(panelPort)), 0o600); err != nil {
		return "", err
	}

	switch request.Action {
	case "install", "update":
		if dirHasEntries(filepath.Join(base, "db")) {
			if _, err := s.backupXUI(ctx, base, compose); err != nil {
				return "", fmt.Errorf("pre-update backup: %w", err)
			}
		}
		if _, err := s.runner.Run(ctx, "docker", "compose", "-f", compose, "pull"); err != nil {
			return "", err
		}
		_, err := s.runner.Run(ctx, "docker", "compose", "-f", compose, "up", "-d", "--remove-orphans")
		return "3x-ui is running", err
	case "start":
		_, err := s.runner.Run(ctx, "docker", "compose", "-f", compose, "up", "-d")
		return "3x-ui started", err
	case "stop":
		_, err := s.runner.Run(ctx, "docker", "compose", "-f", compose, "stop")
		return "3x-ui stopped", err
	case "remove":
		if dirHasEntries(filepath.Join(base, "db")) {
			if _, err := s.backupXUI(ctx, base, compose); err != nil {
				return "", fmt.Errorf("pre-remove backup: %w", err)
			}
		}
		_, err := s.runner.Run(ctx, "docker", "compose", "-f", compose, "down", "--remove-orphans")
		return "3x-ui container removed; data and backup are preserved", err
	case "restart":
		_, err := s.runner.Run(ctx, "docker", "compose", "-f", compose, "restart")
		return "3x-ui restarted", err
	case "backup":
		return s.backupXUI(ctx, base, compose)
	case "restore":
		return s.restoreXUI(ctx, base, request.BackupID, compose)
	default:
		return "", errors.New("unsupported 3x-ui action")
	}
}

func renderXUICompose(panelPort int) string {
	if panelPort < 1 || panelPort > 65535 {
		panelPort = model.DefaultPanelPort
	}
	return fmt.Sprintf(`services:
  3x-ui:
    image: %s
    container_name: 3x-ui
    network_mode: host
    restart: unless-stopped
    environment:
      XRAY_VMESS_AEAD_FORCED: "false"
      XUI_ENABLE_FAIL2BAN: "false"
      XUI_PORT: "%d"
    cap_add:
      - NET_ADMIN
      - NET_RAW
    devices:
      - /dev/net/tun:/dev/net/tun
    volumes:
      - ./db:/etc/x-ui
      - ./cert:/root/cert
`, xuiImage, panelPort)
}

func (s *Service) ApplyXUISettings(ctx context.Context, request model.XUISettingsApplyRequest) (model.XUISettingsResult, error) {
	if request.PanelPort < 1 || request.PanelPort > 65535 {
		return model.XUISettingsResult{}, errors.New("3x-ui panel port must be between 1 and 65535")
	}
	if request.PanelPort == request.Config.ManagerPort {
		return model.XUISettingsResult{}, errors.New("3x-ui panel port must differ from Manager port")
	}
	normalized := request.Config
	basePath := "/opt/nanopi-manager/3x-ui"
	base := s.cfg.Rooted(basePath)
	composePath := filepath.Join(base, "compose.yaml")
	if err := os.MkdirAll(filepath.Join(base, "db"), 0o700); err != nil {
		return model.XUISettingsResult{}, err
	}
	if err := os.MkdirAll(filepath.Join(base, "cert"), 0o700); err != nil {
		return model.XUISettingsResult{}, err
	}
	composeContent := renderXUICompose(request.PanelPort)
	files := []model.FileChange{{Path: basePath + "/compose.yaml", Content: composeContent, Mode: 0o600}}
	routerActive := s.RouterStatus().Active
	if routerActive {
		plan, err := s.Plan(request.Config)
		if err != nil {
			return model.XUISettingsResult{}, err
		}
		normalized = plan.Config
		files = append(files, model.FileChange{Path: "/etc/nftables.conf", Content: router.RenderNFTables(normalized), Mode: 0o600})
	}
	backup, err := s.createBackup(ctx, files)
	if err != nil {
		return model.XUISettingsResult{}, fmt.Errorf("backup 3x-ui settings: %w", err)
	}
	rollback := func(cause error) (model.XUISettingsResult, error) {
		if !s.cfg.DryRun {
			// Stop the just-applied compose before restoring its previous file. This
			// also removes a newly created container when no compose existed before.
			_, _ = s.runner.Run(context.Background(), "docker", "compose", "-f", composePath, "down", "--remove-orphans")
		}
		if _, restoreErr := s.restoreRevisionFiles(backup.RevisionID); restoreErr != nil {
			return model.XUISettingsResult{}, fmt.Errorf("%v; restore settings: %w", cause, restoreErr)
		}
		if !s.cfg.DryRun {
			if _, statErr := os.Stat(composePath); statErr == nil {
				_, _ = s.runner.Run(context.Background(), "docker", "compose", "-f", composePath, "up", "-d", "--remove-orphans")
			}
			if routerActive {
				_, _ = s.runner.Run(context.Background(), "systemctl", "restart", "nftables.service")
			}
		}
		return model.XUISettingsResult{}, cause
	}
	if err := writeFileAtomic(composePath, []byte(composeContent), 0o600); err != nil {
		return rollback(err)
	}
	if routerActive {
		if err := writeFileAtomic(s.cfg.Rooted("/etc/nftables.conf"), []byte(router.RenderNFTables(normalized)), 0o600); err != nil {
			return rollback(err)
		}
	}
	if !s.cfg.DryRun {
		if _, err := s.runner.Run(ctx, "docker", "compose", "-f", composePath, "config", "-q"); err != nil {
			return rollback(fmt.Errorf("validate 3x-ui compose: %w", err))
		}
		if routerActive {
			if _, err := s.runner.Run(ctx, "nft", "-c", "-f", s.cfg.Rooted("/etc/nftables.conf")); err != nil {
				return rollback(fmt.Errorf("validate firewall: %w", err))
			}
		}
		if _, err := s.runner.Run(ctx, "docker", "compose", "-f", composePath, "up", "-d", "--remove-orphans"); err != nil {
			return rollback(fmt.Errorf("apply 3x-ui settings: %w", err))
		}
		if routerActive {
			if _, err := s.runner.Run(ctx, "systemctl", "restart", "nftables.service"); err != nil {
				return rollback(fmt.Errorf("apply firewall: %w", err))
			}
		}
	}
	return model.XUISettingsResult{PanelPort: request.PanelPort, WANAccess: model.TCPPortOpen(normalized.WANPorts, request.PanelPort), Applied: true, Message: "3x-ui settings applied"}, nil
}

func (s *Service) backupXUI(ctx context.Context, base, compose string) (string, error) {
	id := time.Now().UTC().Format("20060102T150405.000000000Z")
	dir := filepath.Join(s.cfg.StateDir, "xui-backups")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	target := filepath.Join(dir, id+".tar.gz")
	_, _ = s.runner.Run(ctx, "docker", "compose", "-f", compose, "stop")
	if _, err := s.runner.Run(ctx, "tar", "-czf", target, "-C", base, "db", "cert"); err != nil {
		_, _ = s.runner.Run(ctx, "docker", "compose", "-f", compose, "up", "-d")
		return "", err
	}
	if _, err := s.runner.Run(ctx, "docker", "compose", "-f", compose, "up", "-d"); err != nil {
		return "", err
	}
	return id, nil
}

func (s *Service) restoreXUI(ctx context.Context, base, id, compose string) (string, error) {
	if id == "" {
		entries, err := filepath.Glob(filepath.Join(s.cfg.StateDir, "xui-backups", "*.tar.gz"))
		if err != nil || len(entries) == 0 {
			return "", errors.New("no 3x-ui backup found")
		}
		sort.Strings(entries)
		id = strings.TrimSuffix(filepath.Base(entries[len(entries)-1]), ".tar.gz")
	}
	if strings.ContainsAny(id, `/\\`) || strings.Contains(id, "..") {
		return "", errors.New("invalid backup id")
	}
	source := filepath.Join(s.cfg.StateDir, "xui-backups", id+".tar.gz")
	if _, err := os.Stat(source); err != nil {
		return "", err
	}
	safetyID, err := s.backupXUI(ctx, base, compose)
	if err != nil {
		return "", fmt.Errorf("pre-restore backup: %w", err)
	}
	_, _ = s.runner.Run(ctx, "docker", "compose", "-f", compose, "stop")
	if _, err := s.runner.Run(ctx, "tar", "-xzf", source, "-C", base); err != nil {
		return "", err
	}
	if _, err := s.runner.Run(ctx, "docker", "compose", "-f", compose, "up", "-d"); err != nil {
		return "", err
	}
	return fmt.Sprintf("%s (pre-restore backup %s)", id, safetyID), nil
}

func dirHasEntries(path string) bool {
	entries, err := os.ReadDir(path)
	return err == nil && len(entries) > 0
}

func (s *Service) BootstrapTUN(ctx context.Context, request model.XUITUNRequest) (string, error) {
	panel, err := validateLocalPanelURL(request.PanelURL)
	if err != nil {
		return "", err
	}
	if request.APIToken == "" {
		return "", errors.New("3x-ui API token is required")
	}
	client := &http.Client{Timeout: 15 * time.Second}
	listURL := strings.TrimRight(panel.String(), "/") + "/panel/api/inbounds/list"
	var listEnvelope struct {
		Success bool `json:"success"`
		Obj     []struct {
			Protocol string `json:"protocol"`
			Settings any    `json:"settings"`
		} `json:"obj"`
		Msg string `json:"msg"`
	}
	if err := xuiJSON(ctx, client, http.MethodGet, listURL, request.APIToken, nil, &listEnvelope); err != nil {
		return "", err
	}
	for _, inbound := range listEnvelope.Obj {
		if inbound.Protocol == "tun" && settingsName(inbound.Settings) == model.DefaultTUNName {
			if err := s.ReconcilePolicy(ctx); err != nil {
				return "", err
			}
			return "xray0 already exists", nil
		}
	}
	wan := request.WAN
	if wan == "" {
		wan = "auto"
	}
	payload := map[string]any{
		"up": 0, "down": 0, "total": 0, "remark": "NanoPi LAN TUN", "enable": true,
		"expiryTime": 0, "listen": "", "port": 0, "protocol": "tun", "tag": "nanopi-tun-in",
		"settings": map[string]any{
			"name": model.DefaultTUNName, "mtu": 1500, "gateway": []string{model.DefaultTUNAddress},
			"dns": []string{}, "userLevel": 0, "autoSystemRoutingTable": []string{}, "autoOutboundsInterface": wan,
		},
		"streamSettings":    map[string]any{},
		"sniffing":          map[string]any{"enabled": true, "destOverride": []string{"http", "tls", "quic"}, "metadataOnly": false, "routeOnly": true, "ipsExcluded": []string{}, "domainsExcluded": []string{}},
		"shareAddrStrategy": "node", "shareAddr": "",
	}
	var result struct {
		Success bool   `json:"success"`
		Msg     string `json:"msg"`
	}
	addURL := strings.TrimRight(panel.String(), "/") + "/panel/api/inbounds/add"
	if err := xuiJSON(ctx, client, http.MethodPost, addURL, request.APIToken, payload, &result); err != nil {
		return "", err
	}
	if !result.Success {
		return "", fmt.Errorf("3x-ui rejected TUN: %s", result.Msg)
	}
	if err := s.ReconcilePolicy(ctx); err != nil {
		return "TUN created, but policy routing is not active", err
	}
	return "xray0 created", nil
}

func validateLocalPanelURL(raw string) (*url.URL, error) {
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Scheme != "http" {
		return nil, errors.New("panel URL must use http")
	}
	host := parsed.Hostname()
	if host != "127.0.0.1" && host != "localhost" && host != "::1" {
		return nil, errors.New("panel URL must point to localhost")
	}
	if parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
		return nil, errors.New("invalid panel URL")
	}
	return parsed, nil
}

func xuiJSON(ctx context.Context, client *http.Client, method, endpoint, token string, body any, result any) error {
	var reader io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			return err
		}
		reader = bytes.NewReader(raw)
	}
	req, err := http.NewRequestWithContext(ctx, method, endpoint, reader)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	response, err := client.Do(req)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		message, _ := io.ReadAll(io.LimitReader(response.Body, 4096))
		return fmt.Errorf("3x-ui returned HTTP %d: %s", response.StatusCode, strings.TrimSpace(string(message)))
	}
	return json.NewDecoder(io.LimitReader(response.Body, 1<<20)).Decode(result)
}

func settingsName(value any) string {
	if raw, ok := value.(string); ok {
		var parsed map[string]any
		if json.Unmarshal([]byte(raw), &parsed) == nil {
			value = parsed
		}
	}
	if object, ok := value.(map[string]any); ok {
		name, _ := object["name"].(string)
		return name
	}
	return ""
}

func readKeyValueFile(path string) map[string]string {
	result := map[string]string{}
	raw, err := os.ReadFile(path)
	if err != nil {
		return result
	}
	for _, line := range strings.Split(string(raw), "\n") {
		key, value, ok := strings.Cut(line, "=")
		if ok {
			result[key] = strings.Trim(strings.TrimSpace(value), "\"")
		}
	}
	return result
}
