package store

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/vmatveenko/nanopi-r5s/manager/internal/model"
)

var ErrNotInitialized = errors.New("administrator is not initialized")

type Admin struct {
	Username     string `json:"username"`
	PasswordSalt string `json:"passwordSalt"`
	PasswordHash string `json:"passwordHash"`
	Iterations   int    `json:"iterations"`
}

type State struct {
	Version      int                 `json:"version"`
	Admin        *Admin              `json:"admin,omitempty"`
	RouterConfig *model.RouterConfig `json:"routerConfig,omitempty"`
	UpdatedAt    time.Time           `json:"updatedAt"`
}

type Store struct {
	mu   sync.RWMutex
	path string
	data State
}

func Open(stateDir string) (*Store, error) {
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		return nil, fmt.Errorf("create state directory: %w", err)
	}
	s := &Store{path: filepath.Join(stateDir, "state.json"), data: State{Version: 1}}
	raw, err := os.ReadFile(s.path)
	if errors.Is(err, os.ErrNotExist) {
		return s, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read state: %w", err)
	}
	if err := json.Unmarshal(raw, &s.data); err != nil {
		return nil, fmt.Errorf("decode state: %w", err)
	}
	return s, nil
}

func (s *Store) Snapshot() State {
	s.mu.RLock()
	defer s.mu.RUnlock()
	copy := s.data
	if s.data.RouterConfig != nil {
		cfg := *s.data.RouterConfig
		copy.RouterConfig = &cfg
	}
	if s.data.Admin != nil {
		admin := *s.data.Admin
		copy.Admin = &admin
	}
	return copy
}

func (s *Store) InitializeAdmin(admin Admin) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.data.Admin != nil {
		return errors.New("administrator already exists")
	}
	s.data.Admin = &admin
	return s.saveLocked()
}

func (s *Store) SaveRouterConfig(cfg model.RouterConfig) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.data.RouterConfig = &cfg
	return s.saveLocked()
}

func (s *Store) saveLocked() error {
	s.data.Version = 1
	s.data.UpdatedAt = time.Now().UTC()
	raw, err := json.MarshalIndent(s.data, "", "  ")
	if err != nil {
		return err
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, append(raw, '\n'), 0o600); err != nil {
		return err
	}
	if err := os.Rename(tmp, s.path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}
