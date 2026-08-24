package agent

import (
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/vmatveenko/nanopi-r5s/manager/internal/model"
)

func (s *Service) Metrics() model.SystemMetrics {
	metrics := model.SystemMetrics{CollectedAt: time.Now().UTC(), Links: []model.LinkMetric{}}
	metrics.UptimeSeconds = readUptime(s.cfg.Rooted("/proc/uptime"))
	metrics.Load1, metrics.Load5, metrics.Load15 = readLoad(s.cfg.Rooted("/proc/loadavg"))
	metrics.MemoryTotalBytes, metrics.MemoryUsedBytes = readMemory(s.cfg.Rooted("/proc/meminfo"))
	if metrics.MemoryTotalBytes > 0 {
		metrics.MemoryUsedPercent = float64(metrics.MemoryUsedBytes) / float64(metrics.MemoryTotalBytes) * 100
	}
	metrics.TemperatureC = readTemperature(s.cfg.Rooted("/sys/class/thermal"))
	metrics.Links = readLinks(s.cfg.Rooted("/sys/class/net"))
	return metrics
}

func readUptime(path string) int64 {
	fields := readFields(path)
	if len(fields) == 0 {
		return 0
	}
	value, _ := strconv.ParseFloat(fields[0], 64)
	return int64(value)
}

func readLoad(path string) (float64, float64, float64) {
	fields := readFields(path)
	if len(fields) < 3 {
		return 0, 0, 0
	}
	load1, _ := strconv.ParseFloat(fields[0], 64)
	load5, _ := strconv.ParseFloat(fields[1], 64)
	load15, _ := strconv.ParseFloat(fields[2], 64)
	return load1, load5, load15
}

func readMemory(path string) (uint64, uint64) {
	data, err := os.ReadFile(path)
	if err != nil {
		return 0, 0
	}
	var totalKB, availableKB uint64
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		value, err := strconv.ParseUint(fields[1], 10, 64)
		if err != nil {
			continue
		}
		switch strings.TrimSuffix(fields[0], ":") {
		case "MemTotal":
			totalKB = value
		case "MemAvailable":
			availableKB = value
		}
	}
	if availableKB > totalKB {
		availableKB = totalKB
	}
	return totalKB * 1024, (totalKB - availableKB) * 1024
}

func readTemperature(root string) *float64 {
	zones, _ := filepath.Glob(filepath.Join(root, "thermal_zone*"))
	sort.Strings(zones)
	type reading struct {
		preferred bool
		value     float64
	}
	readings := make([]reading, 0, len(zones))
	for _, zone := range zones {
		raw, err := os.ReadFile(filepath.Join(zone, "temp"))
		if err != nil {
			continue
		}
		value, err := strconv.ParseFloat(strings.TrimSpace(string(raw)), 64)
		if err != nil {
			continue
		}
		if value > 1000 {
			value /= 1000
		}
		typeRaw, _ := os.ReadFile(filepath.Join(zone, "type"))
		name := strings.ToLower(string(typeRaw))
		preferred := strings.Contains(name, "cpu") || strings.Contains(name, "soc") || strings.Contains(name, "package")
		readings = append(readings, reading{preferred: preferred, value: value})
	}
	for _, current := range readings {
		if current.preferred {
			value := current.value
			return &value
		}
	}
	if len(readings) == 0 {
		return nil
	}
	value := readings[0].value
	return &value
}

func readLinks(root string) []model.LinkMetric {
	entries, err := os.ReadDir(root)
	if err != nil {
		return []model.LinkMetric{}
	}
	links := make([]model.LinkMetric, 0, len(entries))
	for _, entry := range entries {
		if !entry.IsDir() && entry.Type()&os.ModeSymlink == 0 || entry.Name() == "lo" {
			continue
		}
		base := filepath.Join(root, entry.Name())
		carrier := strings.TrimSpace(readText(filepath.Join(base, "carrier"))) == "1"
		speed, _ := strconv.Atoi(strings.TrimSpace(readText(filepath.Join(base, "speed"))))
		if speed < 0 {
			speed = 0
		}
		links = append(links, model.LinkMetric{Name: entry.Name(), Carrier: carrier, SpeedMbps: speed})
	}
	sort.Slice(links, func(i, j int) bool { return links[i].Name < links[j].Name })
	return links
}

func readFields(path string) []string {
	return strings.Fields(readText(path))
}

func readText(path string) string {
	value, _ := os.ReadFile(path)
	return string(value)
}
