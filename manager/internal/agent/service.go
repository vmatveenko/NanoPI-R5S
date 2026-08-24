package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/vmatveenko/nanopi-r5s/manager/internal/config"
	"github.com/vmatveenko/nanopi-r5s/manager/internal/model"
	"github.com/vmatveenko/nanopi-r5s/manager/internal/router"
)

const rollbackSeconds = 120

type Service struct {
	cfg    config.Config
	runner Runner
}

func NewService(cfg config.Config, runner Runner) *Service {
	return &Service{cfg: cfg, runner: runner}
}

func (s *Service) Inventory() (model.Inventory, error) {
	if s.cfg.DryRun && s.cfg.RootDir != "/" {
		return model.Inventory{Hostname: "dry-run", Architecture: "arm64", OS: "Ubuntu 24.04 (fixture)"}, nil
	}
	return router.InventoryFromSystem()
}

func (s *Service) Plan(cfg model.RouterConfig) (model.Plan, error) {
	inventory, err := s.Inventory()
	if err != nil && !s.cfg.DryRun {
		return model.Plan{}, err
	}
	plan, err := router.BuildPlan(cfg, inventory.Interfaces)
	if err != nil {
		return model.Plan{}, err
	}
	for index := range plan.Files {
		current, readErr := os.ReadFile(s.cfg.Rooted(plan.Files[index].Path))
		if errors.Is(readErr, os.ErrNotExist) {
			plan.Files[index].Changed = true
			plan.Files[index].Diff = renderSafeDiff(nil, []byte(plan.Files[index].Content))
			continue
		}
		if readErr != nil {
			plan.Warnings = append(plan.Warnings, "Cannot read current "+plan.Files[index].Path+": "+readErr.Error())
			continue
		}
		plan.Files[index].Changed = string(current) != plan.Files[index].Content
		if plan.Files[index].Changed {
			plan.Files[index].Diff = renderSafeDiff(current, []byte(plan.Files[index].Content))
		}
	}
	return plan, nil
}

func (s *Service) Apply(ctx context.Context, cfg model.RouterConfig) (model.ApplyResult, error) {
	previousManagerPort := s.configuredManagerPort()
	plan, err := s.Plan(cfg)
	if err != nil {
		return model.ApplyResult{}, err
	}
	backup, err := s.createBackup(ctx, plan.Files)
	if err != nil {
		return model.ApplyResult{}, fmt.Errorf("backup current configuration: %w", err)
	}
	for _, file := range plan.Files {
		if err := writeFileAtomic(s.cfg.Rooted(file.Path), []byte(file.Content), os.FileMode(file.Mode)); err != nil {
			_ = s.restoreRevision(ctx, backup.RevisionID)
			return model.ApplyResult{}, fmt.Errorf("write %s: %w", file.Path, err)
		}
	}
	if err := s.validateManagedConfiguration(ctx); err != nil {
		_ = s.restoreRevision(ctx, backup.RevisionID)
		return model.ApplyResult{}, err
	}
	if !s.cfg.DryRun {
		if err := s.scheduleRollback(ctx, backup.RevisionID); err != nil {
			_ = s.restoreRevision(ctx, backup.RevisionID)
			return model.ApplyResult{}, err
		}
	}
	if err := s.applyManagedConfiguration(ctx); err != nil {
		s.cancelRollback(ctx, backup.RevisionID)
		_ = s.restoreRevision(ctx, backup.RevisionID)
		return model.ApplyResult{}, err
	}
	baselineCreated := false
	if _, err := os.Stat(s.baselinePath()); errors.Is(err, os.ErrNotExist) {
		if err := writeJSONAtomic(s.baselinePath(), baselineState{RevisionID: backup.RevisionID, ManagerPort: previousManagerPort}, 0o600); err != nil {
			s.cancelRollback(ctx, backup.RevisionID)
			_ = s.restoreRevision(ctx, backup.RevisionID)
			return model.ApplyResult{}, err
		}
		baselineCreated = true
	}
	due := time.Now().UTC().Add(rollbackSeconds * time.Second)
	active := activeApply{RevisionID: backup.RevisionID, RollbackDueAt: due, BaselineCreated: baselineCreated, PreviousManagerPort: previousManagerPort}
	if err := writeJSONAtomic(filepath.Join(s.cfg.StateDir, "active-apply.json"), active, 0o600); err != nil {
		s.cancelRollback(ctx, backup.RevisionID)
		if baselineCreated {
			_ = os.Remove(s.baselinePath())
		}
		_ = s.restoreRevision(ctx, backup.RevisionID)
		return model.ApplyResult{}, err
	}
	restart := previousManagerPort != plan.Config.ManagerPort
	if restart && !s.cfg.DryRun {
		if err := s.scheduleWebRestart(ctx, backup.RevisionID); err != nil {
			s.cancelRollback(ctx, backup.RevisionID)
			_ = os.Remove(s.activeApplyPath())
			if baselineCreated {
				_ = os.Remove(s.baselinePath())
			}
			_ = s.restoreRevision(ctx, backup.RevisionID)
			return model.ApplyResult{}, fmt.Errorf("schedule Manager restart: %w", err)
		}
	}
	return model.ApplyResult{RevisionID: backup.RevisionID, RollbackDueAt: due, ConfirmationTTL: rollbackSeconds, ManagerPort: plan.Config.ManagerPort, ManagerRestart: restart}, nil
}

func (s *Service) Confirm(ctx context.Context, revision string) error {
	if err := validateRevisionID(revision); err != nil {
		return err
	}
	if !s.cfg.DryRun {
		unit := rollbackUnit(revision)
		_, _ = s.runner.Run(ctx, "systemctl", "stop", unit+".timer")
		_, _ = s.runner.Run(ctx, "systemctl", "stop", unit+".service")
		_, _ = s.runner.Run(ctx, "systemctl", "reset-failed", unit+".service")
	}
	err := os.Remove(filepath.Join(s.cfg.StateDir, "active-apply.json"))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

func (s *Service) Rollback(ctx context.Context, revision string) error {
	if err := validateRevisionID(revision); err != nil {
		return err
	}
	if err := s.restoreRevision(ctx, revision); err != nil {
		return err
	}
	if active, err := s.readActiveApply(); err == nil && active.RevisionID == revision && active.BaselineCreated {
		_ = os.Remove(s.baselinePath())
	}
	_ = os.Remove(filepath.Join(s.cfg.StateDir, "active-apply.json"))
	return nil
}

func (s *Service) scheduleWebRestart(ctx context.Context, revision string) error {
	unit := "nanopi-manager-web-restart-" + strings.NewReplacer(":", "-", ".", "-").Replace(revision) + "-" + fmt.Sprintf("%d", time.Now().UnixNano())
	_, err := s.runner.Run(ctx, "systemd-run", "--unit", unit, "--on-active", "2s", "systemctl", "restart", "nanopi-manager-web.service")
	return err
}

func (s *Service) cancelRollback(ctx context.Context, revision string) {
	if s.cfg.DryRun {
		return
	}
	unit := rollbackUnit(revision)
	_, _ = s.runner.Run(ctx, "systemctl", "stop", unit+".timer")
	_, _ = s.runner.Run(ctx, "systemctl", "stop", unit+".service")
}

func (s *Service) validateManagedConfiguration(ctx context.Context) error {
	if s.cfg.DryRun {
		return nil
	}
	commands := [][]string{
		{"netplan", "generate"},
		{"dhcpd", "-t", "-cf", s.cfg.Rooted("/etc/dhcp/dhcpd.conf")},
		{"nft", "-c", "-f", s.cfg.Rooted("/etc/nftables.conf")},
	}
	for _, command := range commands {
		if _, err := s.runner.Run(ctx, command[0], command[1:]...); err != nil {
			return fmt.Errorf("configuration validation failed: %w", err)
		}
	}
	return nil
}

func (s *Service) applyManagedConfiguration(ctx context.Context) error {
	if s.cfg.DryRun {
		return nil
	}
	commands := [][]string{
		{"systemctl", "daemon-reload"},
		{"sysctl", "--system"},
		{"systemctl", "enable", "--now", "nftables"},
		{"netplan", "apply"},
		{"systemctl", "enable", "--now", "isc-dhcp-server"},
	}
	for _, command := range commands {
		if _, err := s.runner.Run(ctx, command[0], command[1:]...); err != nil {
			return fmt.Errorf("apply configuration: %w", err)
		}
	}
	return nil
}

func (s *Service) scheduleRollback(ctx context.Context, revision string) error {
	unit := rollbackUnit(revision)
	_, err := s.runner.Run(ctx, "systemd-run",
		"--unit", unit,
		"--on-active", fmt.Sprintf("%ds", rollbackSeconds),
		"--property", "Type=oneshot",
		s.cfg.AgentBinary, "--mode", "rollback", "--revision", revision,
	)
	if err != nil {
		return fmt.Errorf("schedule rollback: %w", err)
	}
	return nil
}

func validateRevisionID(revision string) error {
	if revision == "" || strings.ContainsAny(revision, `/\\`) || strings.Contains(revision, "..") {
		return errors.New("invalid revision identifier")
	}
	return nil
}

func rollbackUnit(revision string) string {
	return "nanopi-manager-rollback-" + strings.NewReplacer(":", "-", ".", "-").Replace(revision)
}

func decodeJSON(r *http.Request, dst any) error {
	decoder := json.NewDecoder(io.LimitReader(r.Body, 1<<20))
	decoder.DisallowUnknownFields()
	return decoder.Decode(dst)
}

func renderSafeDiff(before, after []byte) string {
	var b strings.Builder
	b.WriteString("--- current\n+++ desired\n")
	for _, line := range strings.Split(string(before), "\n") {
		if line != "" {
			b.WriteString("-" + redactLine(line) + "\n")
		}
	}
	for _, line := range strings.Split(string(after), "\n") {
		if line != "" {
			b.WriteString("+" + redactLine(line) + "\n")
		}
	}
	if b.Len() > 128*1024 {
		return b.String()[:128*1024] + "\n... diff truncated ...\n"
	}
	return b.String()
}

func redactLine(line string) string {
	lower := strings.ToLower(line)
	for _, marker := range []string{"password", "passwd", "secret", "token", "private-key", "psk"} {
		if strings.Contains(lower, marker) {
			return "[redacted sensitive line]"
		}
	}
	return line
}
