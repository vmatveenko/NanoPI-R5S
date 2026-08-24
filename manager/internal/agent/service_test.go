package agent

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/vmatveenko/nanopi-r5s/manager/internal/config"
	"github.com/vmatveenko/nanopi-r5s/manager/internal/model"
)

type fakeRunner struct{}

func (fakeRunner) Run(context.Context, string, ...string) (string, error) { return "", nil }

func TestDryRunApplyAndRollback(t *testing.T) {
	root := t.TempDir()
	state := filepath.Join(root, "state")
	cfg := config.Defaults()
	cfg.RootDir = root
	cfg.StateDir = state
	cfg.DryRun = true
	service := NewService(cfg, fakeRunner{})
	routerCfg := model.DefaultRouterConfig()
	routerCfg.WANInterface = "eth0"
	routerCfg.LANInterfaces = []string{"eth1", "eth2"}
	result, err := service.Apply(context.Background(), routerCfg)
	if err != nil {
		t.Fatal(err)
	}
	nft := cfg.Rooted("/etc/nftables.conf")
	if _, err := os.Stat(nft); err != nil {
		t.Fatalf("managed file not written: %v", err)
	}
	if err := service.Rollback(context.Background(), result.RevisionID); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(nft); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("new file not removed on rollback: %v", err)
	}
}

func TestDeactivateRestoresBaselineAfterConfirmation(t *testing.T) {
	root := t.TempDir()
	cfg := config.Defaults()
	cfg.RootDir = root
	cfg.StateDir = filepath.Join(root, "state")
	cfg.DryRun = true
	service := NewService(cfg, fakeRunner{})
	routerCfg := model.DefaultRouterConfig()
	routerCfg.WANInterface = "eth0"
	routerCfg.LANInterfaces = []string{"eth1", "eth2"}
	result, err := service.Apply(context.Background(), routerCfg)
	if err != nil {
		t.Fatal(err)
	}
	if err := service.Confirm(context.Background(), result.RevisionID); err != nil {
		t.Fatal(err)
	}
	if !service.RouterStatus().Active {
		t.Fatal("router mode is not active after confirmation")
	}
	if err := service.DeactivateRouter(context.Background()); err != nil {
		t.Fatal(err)
	}
	if service.RouterStatus().Active {
		t.Fatal("router mode remains active after deactivation")
	}
	if _, err := os.Stat(cfg.Rooted("/etc/nftables.conf")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("baseline was not restored: %v", err)
	}
}

func TestApplyXUISettingsUpdatesComposeAndActiveFirewall(t *testing.T) {
	root := t.TempDir()
	cfg := config.Defaults()
	cfg.RootDir = root
	cfg.StateDir = filepath.Join(root, "state")
	cfg.DryRun = true
	service := NewService(cfg, fakeRunner{})
	routerCfg := model.DefaultRouterConfig()
	routerCfg.WANInterface = "eth0"
	routerCfg.LANInterfaces = []string{"eth1", "eth2"}
	result, err := service.Apply(context.Background(), routerCfg)
	if err != nil {
		t.Fatal(err)
	}
	if err := service.Confirm(context.Background(), result.RevisionID); err != nil {
		t.Fatal(err)
	}
	next := routerCfg
	next.WANPorts = []model.PortRule{{Protocol: "tcp", Port: 3053, Description: "3x-ui panel"}}
	settings, err := service.ApplyXUISettings(context.Background(), model.XUISettingsApplyRequest{PreviousConfig: routerCfg, Config: next, PreviousPort: 2053, PanelPort: 3053})
	if err != nil {
		t.Fatal(err)
	}
	if !settings.Applied || !settings.WANAccess {
		t.Fatalf("unexpected settings result: %#v", settings)
	}
	compose, err := os.ReadFile(cfg.Rooted("/opt/nanopi-manager/3x-ui/compose.yaml"))
	if err != nil || !strings.Contains(string(compose), `XUI_PORT: "3053"`) {
		t.Fatalf("compose port not updated: %v %s", err, compose)
	}
	nft, err := os.ReadFile(cfg.Rooted("/etc/nftables.conf"))
	if err != nil || !strings.Contains(string(nft), "tcp dport 3053") {
		t.Fatalf("firewall port not updated: %v %s", err, nft)
	}
}

func TestFirewallStatusIsAvailableBeforeRouterSetup(t *testing.T) {
	cfg := config.Defaults()
	cfg.RootDir = t.TempDir()
	cfg.StateDir = filepath.Join(cfg.RootDir, "state")
	cfg.DryRun = true
	service := NewService(cfg, fakeRunner{})
	status, err := service.FirewallStatus(context.Background(), model.DefaultRouterConfig())
	if err != nil {
		t.Fatal(err)
	}
	if status.RouterActive || len(status.SystemRules) == 0 {
		t.Fatalf("unexpected pre-setup status: %#v", status)
	}
}

func TestLocalPanelURL(t *testing.T) {
	for _, good := range []string{"http://127.0.0.1:2053", "http://localhost:2053/base", "http://[::1]:2053"} {
		if _, err := validateLocalPanelURL(good); err != nil {
			t.Errorf("%s: %v", good, err)
		}
	}
	for _, bad := range []string{"https://127.0.0.1:2053", "http://example.com:2053", "http://127.0.0.1:2053/?token=x"} {
		if _, err := validateLocalPanelURL(bad); err == nil {
			t.Errorf("unsafe URL accepted: %s", bad)
		}
	}
}

func TestBootstrapTUNUsesBearerAndExpectedSchema(t *testing.T) {
	var added map[string]any
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer test-token" {
			t.Errorf("missing bearer token")
		}
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/panel/api/inbounds/list":
			_, _ = w.Write([]byte(`{"success":true,"obj":[]}`))
		case "/panel/api/inbounds/add":
			if err := json.NewDecoder(r.Body).Decode(&added); err != nil {
				t.Error(err)
			}
			_, _ = w.Write([]byte(`{"success":true}`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	cfg := config.Defaults()
	cfg.DryRun = true
	cfg.StateDir = t.TempDir()
	service := NewService(cfg, fakeRunner{})
	if _, err := service.BootstrapTUN(context.Background(), model.XUITUNRequest{PanelURL: server.URL, APIToken: "test-token", WAN: "eth0"}); err != nil {
		t.Fatal(err)
	}
	if added["protocol"] != "tun" || added["port"].(float64) != 0 {
		t.Fatalf("unexpected inbound: %#v", added)
	}
	settings := added["settings"].(map[string]any)
	if settings["name"] != "xray0" || settings["autoOutboundsInterface"] != "eth0" {
		t.Fatalf("unexpected settings: %#v", settings)
	}
}
