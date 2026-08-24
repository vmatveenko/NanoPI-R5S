package store

import (
	"testing"

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
