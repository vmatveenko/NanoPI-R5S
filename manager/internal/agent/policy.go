package agent

import (
	"context"
	"strings"
)

func (s *Service) ReconcilePolicy(ctx context.Context) error {
	if s.cfg.DryRun {
		return nil
	}
	_, tunErr := s.runner.Run(ctx, "ip", "link", "show", "dev", "xray0")
	container, containerErr := s.runner.Run(ctx, "docker", "inspect", "-f", "{{.State.Running}}", "3x-ui")
	healthy := tunErr == nil && containerErr == nil && strings.TrimSpace(container) == "true"
	if !healthy {
		for {
			if _, err := s.runner.Run(ctx, "ip", "rule", "del", "priority", "10000"); err != nil {
				break
			}
		}
		return nil
	}
	if _, err := s.runner.Run(ctx, "ip", "route", "replace", "default", "dev", "xray0", "table", "100"); err != nil {
		return err
	}
	rules, _ := s.runner.Run(ctx, "ip", "rule", "show")
	if !strings.Contains(rules, "10000:") {
		if _, err := s.runner.Run(ctx, "ip", "rule", "add", "priority", "10000", "fwmark", "0x1", "lookup", "100"); err != nil {
			return err
		}
	}
	return nil
}
