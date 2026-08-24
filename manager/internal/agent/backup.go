package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/vmatveenko/nanopi-r5s/manager/internal/model"
)

type backupEntry struct {
	Path    string `json:"path"`
	Existed bool   `json:"existed"`
	Backup  string `json:"backup,omitempty"`
	Mode    uint32 `json:"mode,omitempty"`
}

type backupManifest struct {
	RevisionID string        `json:"revisionId"`
	CreatedAt  time.Time     `json:"createdAt"`
	Entries    []backupEntry `json:"entries"`
}

func (s *Service) createBackup(files []model.FileChange) (backupManifest, error) {
	revision := time.Now().UTC().Format("20060102T150405.000000000Z")
	dir := filepath.Join(s.cfg.StateDir, "backups", revision)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return backupManifest{}, err
	}
	manifest := backupManifest{RevisionID: revision, CreatedAt: time.Now().UTC()}
	for index, file := range files {
		target := s.cfg.Rooted(file.Path)
		entry := backupEntry{Path: file.Path}
		raw, err := os.ReadFile(target)
		if err == nil {
			entry.Existed = true
			if info, statErr := os.Stat(target); statErr == nil {
				entry.Mode = uint32(info.Mode().Perm())
			}
			entry.Backup = fmt.Sprintf("%03d.bin", index)
			if err := os.WriteFile(filepath.Join(dir, entry.Backup), raw, 0o600); err != nil {
				return backupManifest{}, err
			}
		} else if !errors.Is(err, os.ErrNotExist) {
			return backupManifest{}, err
		}
		manifest.Entries = append(manifest.Entries, entry)
	}
	if err := writeJSONAtomic(filepath.Join(dir, "manifest.json"), manifest, 0o600); err != nil {
		return backupManifest{}, err
	}
	return manifest, nil
}

func (s *Service) restoreRevision(ctx context.Context, revision string) error {
	if revision == "" || strings.ContainsAny(revision, `/\\`) {
		return errors.New("invalid revision identifier")
	}
	dir := filepath.Join(s.cfg.StateDir, "backups", revision)
	raw, err := os.ReadFile(filepath.Join(dir, "manifest.json"))
	if err != nil {
		return fmt.Errorf("read backup manifest: %w", err)
	}
	var manifest backupManifest
	if err := json.Unmarshal(raw, &manifest); err != nil {
		return err
	}
	for _, entry := range manifest.Entries {
		target := s.cfg.Rooted(entry.Path)
		if entry.Existed {
			content, err := os.ReadFile(filepath.Join(dir, entry.Backup))
			if err != nil {
				return err
			}
			mode := os.FileMode(entry.Mode)
			if mode == 0 {
				mode = 0o600
			}
			if err := writeFileAtomic(target, content, mode); err != nil {
				return err
			}
		} else if err := os.Remove(target); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	if s.cfg.DryRun {
		return nil
	}
	for _, command := range [][]string{
		{"systemctl", "daemon-reload"},
		{"sysctl", "--system"},
		{"systemctl", "restart", "nftables"},
		{"netplan", "apply"},
		{"systemctl", "restart", "isc-dhcp-server"},
	} {
		if _, err := s.runner.Run(ctx, command[0], command[1:]...); err != nil {
			return fmt.Errorf("restore %s: %w", command[0], err)
		}
	}
	return nil
}

func writeFileAtomic(path string, content []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".nanopi-manager-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if err := tmp.Chmod(mode); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(content); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpName, path)
}

func writeJSONAtomic(path string, value any, mode os.FileMode) error {
	raw, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	return writeFileAtomic(path, append(raw, '\n'), mode)
}
