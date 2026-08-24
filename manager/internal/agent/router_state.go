package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/vmatveenko/nanopi-r5s/manager/internal/model"
	"github.com/vmatveenko/nanopi-r5s/manager/internal/router"
)

type activeApply struct {
	RevisionID          string    `json:"revisionId"`
	RollbackDueAt       time.Time `json:"rollbackDueAt"`
	BaselineCreated     bool      `json:"baselineCreated,omitempty"`
	PreviousManagerPort int       `json:"previousManagerPort,omitempty"`
}

type baselineState struct {
	RevisionID  string `json:"revisionId"`
	ManagerPort int    `json:"managerPort,omitempty"`
}

func (s *Service) baselinePath() string {
	return filepath.Join(s.cfg.StateDir, "router-baseline.json")
}

func (s *Service) activeApplyPath() string {
	return filepath.Join(s.cfg.StateDir, "active-apply.json")
}

func (s *Service) readActiveApply() (activeApply, error) {
	raw, err := os.ReadFile(s.activeApplyPath())
	if err != nil {
		return activeApply{}, err
	}
	var value activeApply
	err = json.Unmarshal(raw, &value)
	return value, err
}

func (s *Service) readBaseline() (baselineState, error) {
	raw, err := os.ReadFile(s.baselinePath())
	if err != nil {
		return baselineState{}, err
	}
	var value baselineState
	err = json.Unmarshal(raw, &value)
	return value, err
}

func (s *Service) RouterStatus() model.RouterStatus {
	status := model.RouterStatus{State: "not_applied"}
	if baseline, err := s.readBaseline(); err == nil {
		status.Active = true
		status.State = "active"
		status.BaselineRevision = baseline.RevisionID
	}
	if active, err := s.readActiveApply(); err == nil {
		status.Pending = true
		status.State = "pending"
		status.PendingRevision = active.RevisionID
		status.RollbackDueAt = active.RollbackDueAt
	}
	return status
}

func (s *Service) DeactivateRouter(ctx context.Context) error {
	baseline, err := s.readBaseline()
	if errors.Is(err, os.ErrNotExist) {
		return errors.New("router mode is not active")
	}
	if err != nil {
		return err
	}
	if active, err := s.readActiveApply(); err == nil {
		if !s.cfg.DryRun {
			unit := rollbackUnit(active.RevisionID)
			_, _ = s.runner.Run(ctx, "systemctl", "stop", unit+".timer")
			_, _ = s.runner.Run(ctx, "systemctl", "stop", unit+".service")
		}
	}
	if err := s.restoreRevision(ctx, baseline.RevisionID); err != nil {
		return err
	}
	_ = os.Remove(s.activeApplyPath())
	return os.Remove(s.baselinePath())
}

func (s *Service) rollbackManagerPort(revision string) int {
	if active, err := s.readActiveApply(); err == nil && active.RevisionID == revision && active.PreviousManagerPort > 0 {
		return active.PreviousManagerPort
	}
	return model.DefaultManagerPort
}

func (s *Service) baselineManagerPort() int {
	if baseline, err := s.readBaseline(); err == nil && baseline.ManagerPort > 0 {
		return baseline.ManagerPort
	}
	return model.DefaultManagerPort
}

func (s *Service) ApplyFirewall(ctx context.Context, cfg model.RouterConfig) (model.FirewallApplyResult, error) {
	plan, err := s.Plan(cfg)
	if err != nil {
		return model.FirewallApplyResult{}, err
	}
	if !s.RouterStatus().Active {
		return model.FirewallApplyResult{Applied: false, Message: "saved; router mode is not active"}, nil
	}
	content := router.RenderNFTables(plan.Config)
	file := model.FileChange{Path: "/etc/nftables.conf", Content: content, Mode: 0o600, Changed: true}
	backup, err := s.createBackup(ctx, []model.FileChange{file})
	if err != nil {
		return model.FirewallApplyResult{}, err
	}
	if err := writeFileAtomic(s.cfg.Rooted(file.Path), []byte(content), 0o600); err != nil {
		return model.FirewallApplyResult{}, err
	}
	if !s.cfg.DryRun {
		if _, err := s.runner.Run(ctx, "nft", "-c", "-f", s.cfg.Rooted(file.Path)); err != nil {
			_ = s.restoreRevision(ctx, backup.RevisionID)
			return model.FirewallApplyResult{}, fmt.Errorf("firewall validation failed: %w", err)
		}
		if _, err := s.runner.Run(ctx, "systemctl", "restart", "nftables.service"); err != nil {
			_ = s.restoreRevision(ctx, backup.RevisionID)
			return model.FirewallApplyResult{}, fmt.Errorf("apply firewall: %w", err)
		}
	}
	return model.FirewallApplyResult{Applied: true, Message: "firewall applied"}, nil
}

func (s *Service) FirewallStatus(ctx context.Context, cfg model.RouterConfig) (model.FirewallStatus, error) {
	plan, err := s.Plan(cfg)
	if err != nil {
		return model.FirewallStatus{}, err
	}
	normalized := plan.Config
	status := model.FirewallStatus{
		RouterActive: s.RouterStatus().Active,
		Rules:        normalized.WANPorts,
		ManagerWAN:   normalized.ManagerWANAccess,
		ManagerPort:  normalized.ManagerPort,
		SystemRules:  []string{"loopback", "established/related", "ICMP", "LAN input", "WAN DHCP response", "LAN forwarding", "NAT masquerade"},
	}
	current, readErr := os.ReadFile(s.cfg.Rooted("/etc/nftables.conf"))
	status.InSync = readErr == nil && string(current) == router.RenderNFTables(normalized)
	if status.RouterActive && !s.cfg.DryRun {
		if output, runErr := s.runner.Run(ctx, "nft", "list", "table", "inet", "nanopi_filter"); runErr == nil {
			status.Detail = strings.TrimSpace(output)
		} else {
			status.Detail = runErr.Error()
		}
	}
	return status, nil
}

func currentPort(address string) int {
	_, port, err := net.SplitHostPort(address)
	if err != nil {
		return model.DefaultManagerPort
	}
	value, err := strconv.Atoi(port)
	if err != nil {
		return model.DefaultManagerPort
	}
	return value
}
