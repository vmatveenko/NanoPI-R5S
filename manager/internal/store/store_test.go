package store

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/vmatveenko/nanopi-r5s/manager/internal/model"
)

func TestPendingRouterConfigSurvivesReopenAndConfirms(t *testing.T) {
	dir := t.TempDir()
	state, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	cfg := model.DefaultRouterConfig()
	cfg.WANInterface = "eth0"
	cfg.LANInterfaces = []string{"eth1", "eth2"}
	cfg.ManagerWANSources = []string{"203.0.113.10"}
	if err := state.SavePendingRouterConfig("revision-1", cfg); err != nil {
		t.Fatal(err)
	}
	reopened, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := reopened.Snapshot().PendingRouterConfigs["revision-1"]; !ok {
		t.Fatal("pending configuration was not persisted")
	}
	confirmed, ok, err := reopened.ConfirmPendingRouterConfig("revision-1")
	if err != nil || !ok {
		t.Fatalf("confirm failed: ok=%v err=%v", ok, err)
	}
	if confirmed.WANInterface != "eth0" || reopened.Snapshot().RouterConfig == nil {
		t.Fatal("confirmed configuration was not saved")
	}
}

func TestOpenMigratesV2PanelAndManagerWANRule(t *testing.T) {
	dir := t.TempDir()
	raw := `{"version":2,"routerConfig":{"wanInterface":"eth0","wanMacMode":"current","lanInterfaces":["eth1"],"bridge":"br0","lanCidr":"192.168.10.1/24","dhcpStart":"192.168.10.10","dhcpEnd":"192.168.10.200","dns":["8.8.8.8"],"managerPort":8080,"managerWanAccess":true,"managerWanSources":["203.0.113.4"],"panelPort":3053}}`
	if err := os.WriteFile(filepath.Join(dir, "state.json"), []byte(raw), 0o600); err != nil {
		t.Fatal(err)
	}
	state, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	snapshot := state.Snapshot()
	if snapshot.Version != 3 || snapshot.XUIConfig.PanelPort != 3053 {
		t.Fatalf("state not migrated: %#v", snapshot)
	}
	if snapshot.RouterConfig == nil || !model.TCPPortOpen(snapshot.RouterConfig.WANPorts, 8080) {
		t.Fatalf("manager WAN access not migrated: %#v", snapshot.RouterConfig)
	}
	rule := snapshot.RouterConfig.WANPorts[model.TCPPortRuleIndex(snapshot.RouterConfig.WANPorts, 8080)]
	if len(rule.Sources) != 1 || rule.Sources[0] != "203.0.113.4" || snapshot.RouterConfig.PanelPort != 0 || snapshot.RouterConfig.ManagerWANAccess {
		t.Fatalf("legacy fields not normalized: %#v", snapshot.RouterConfig)
	}
}

func TestPendingConfirmationRequiresTokenAndExpires(t *testing.T) {
	state, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	cfg := model.DefaultRouterConfig()
	if err := state.SavePendingRouterApply("rev", cfg, "secret", time.Now().Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	if !state.ValidPendingConfirmation("rev", "secret", time.Now()) || state.ValidPendingConfirmation("rev", "wrong", time.Now()) {
		t.Fatal("confirmation token validation failed")
	}
	if state.ValidPendingConfirmation("rev", "secret", time.Now().Add(2*time.Minute)) {
		t.Fatal("expired token accepted")
	}
	if _, ok, err := state.ConfirmPendingRouterConfig("rev"); err != nil || !ok {
		t.Fatalf("confirm failed: ok=%v err=%v", ok, err)
	}
	if state.ValidPendingConfirmation("rev", "secret", time.Now()) {
		t.Fatal("confirmation token was not consumed")
	}
}
