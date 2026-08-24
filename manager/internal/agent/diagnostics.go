package agent

import (
	"context"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/vmatveenko/nanopi-r5s/manager/internal/model"
)

func (s *Service) Diagnostics(ctx context.Context) model.Diagnostics {
	result := model.Diagnostics{GeneratedAt: time.Now().UTC()}
	result.Components = append(result.Components,
		s.commandExpected(ctx, "IPv4 forwarding", "1", "sysctl", "-n", "net.ipv4.ip_forward"),
		s.commandStatus(ctx, "nftables", "systemctl", "is-active", "nftables"),
		s.commandStatus(ctx, "DHCP", "systemctl", "is-active", "isc-dhcp-server"),
		s.commandStatus(ctx, "Docker", "systemctl", "is-active", "docker"),
		s.commandStatus(ctx, "3x-ui", "docker", "inspect", "-f", "{{.State.Status}}", "3x-ui"),
		s.commandStatus(ctx, "Xray TUN", "ip", "-brief", "address", "show", "dev", "xray0"),
		s.commandNonEmpty(ctx, "Policy route", "ip", "rule", "show", "priority", "10000"),
	)
	if _, err := os.Stat(s.cfg.Rooted("/etc/netplan/60-nanopi-manager.yaml")); err == nil {
		result.Components = append(result.Components, model.ComponentStatus{Name: "Managed router configuration", OK: true, Summary: "present"})
	} else {
		result.Components = append(result.Components, model.ComponentStatus{Name: "Managed router configuration", OK: false, Summary: "not applied"})
	}
	return result
}

func (s *Service) commandExpected(ctx context.Context, label, expected, command string, args ...string) model.ComponentStatus {
	status := s.commandStatus(ctx, label, command, args...)
	if status.OK && strings.TrimSpace(status.Summary) != expected {
		status.OK = false
		status.Detail = "expected " + expected
	}
	return status
}

func (s *Service) commandNonEmpty(ctx context.Context, label, command string, args ...string) model.ComponentStatus {
	status := s.commandStatus(ctx, label, command, args...)
	if status.OK && strings.TrimSpace(status.Summary) == "ok" {
		status.OK = false
		status.Summary = "not configured"
	}
	return status
}

func (s *Service) commandStatus(ctx context.Context, label, command string, args ...string) model.ComponentStatus {
	output, err := s.runner.Run(ctx, command, args...)
	trimmed := strings.TrimSpace(output)
	if err != nil {
		return model.ComponentStatus{Name: label, OK: false, Summary: "unavailable", Detail: err.Error()}
	}
	if trimmed == "" {
		trimmed = "ok"
	}
	if len(trimmed) > 500 {
		trimmed = trimmed[:500] + "…"
	}
	return model.ComponentStatus{Name: label, OK: true, Summary: fmt.Sprint(trimmed)}
}
