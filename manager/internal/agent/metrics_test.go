package agent

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/vmatveenko/nanopi-r5s/manager/internal/config"
)

func TestMetricsFromFixture(t *testing.T) {
	root := t.TempDir()
	writeMetricFixture(t, root, "proc/uptime", "98765.43 1000.00\n")
	writeMetricFixture(t, root, "proc/loadavg", "0.42 0.31 0.20 1/128 42\n")
	writeMetricFixture(t, root, "proc/meminfo", "MemTotal:       4096000 kB\nMemAvailable:   1024000 kB\n")
	writeMetricFixture(t, root, "sys/class/thermal/thermal_zone0/type", "gpu-thermal\n")
	writeMetricFixture(t, root, "sys/class/thermal/thermal_zone0/temp", "39000\n")
	writeMetricFixture(t, root, "sys/class/thermal/thermal_zone1/type", "soc-thermal\n")
	writeMetricFixture(t, root, "sys/class/thermal/thermal_zone1/temp", "47250\n")
	writeMetricFixture(t, root, "sys/class/net/eth0/carrier", "1\n")
	writeMetricFixture(t, root, "sys/class/net/eth0/speed", "2500\n")
	writeMetricFixture(t, root, "sys/class/net/eth1/carrier", "0\n")
	writeMetricFixture(t, root, "sys/class/net/eth1/speed", "1000\n")

	service := NewService(config.Config{RootDir: root, DryRun: true}, fakeRunner{})
	metrics := service.Metrics()

	if metrics.UptimeSeconds != 98765 || metrics.Load1 != 0.42 || metrics.Load5 != 0.31 || metrics.Load15 != 0.20 {
		t.Fatalf("unexpected uptime/load metrics: %+v", metrics)
	}
	if metrics.MemoryTotalBytes != 4096000*1024 || metrics.MemoryUsedBytes != 3072000*1024 || metrics.MemoryUsedPercent != 75 {
		t.Fatalf("unexpected memory metrics: %+v", metrics)
	}
	if metrics.TemperatureC == nil || *metrics.TemperatureC != 47.25 {
		t.Fatalf("unexpected temperature: %+v", metrics.TemperatureC)
	}
	if len(metrics.Links) != 2 || metrics.Links[0].Name != "eth0" || !metrics.Links[0].Carrier || metrics.Links[0].SpeedMbps != 2500 {
		t.Fatalf("unexpected links: %+v", metrics.Links)
	}
}

func TestMetricsToleratesUnavailableSensors(t *testing.T) {
	service := NewService(config.Config{RootDir: t.TempDir(), DryRun: true}, fakeRunner{})
	metrics := service.Metrics()
	if metrics.UptimeSeconds != 0 || metrics.MemoryTotalBytes != 0 || metrics.TemperatureC != nil || len(metrics.Links) != 0 {
		t.Fatalf("expected empty partial metrics, got %+v", metrics)
	}
}

func writeMetricFixture(t *testing.T, root, name, content string) {
	t.Helper()
	path := filepath.Join(root, filepath.FromSlash(name))
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}
