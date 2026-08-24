package store

import (
	"crypto/sha256"
	"crypto/subtle"
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
	Version              int                            `json:"version"`
	Admin                *Admin                         `json:"admin,omitempty"`
	RouterConfig         *model.RouterConfig            `json:"routerConfig,omitempty"`
	XUIConfig            model.XUIConfig                `json:"xuiConfig"`
	PendingRouterConfigs map[string]model.RouterConfig  `json:"pendingRouterConfigs,omitempty"`
	PendingConfirmations map[string]PendingConfirmation `json:"pendingConfirmations,omitempty"`
	UpdatedAt            time.Time                      `json:"updatedAt"`
}

type PendingConfirmation struct {
	TokenHash string    `json:"tokenHash"`
	ExpiresAt time.Time `json:"expiresAt"`
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
	s := &Store{path: filepath.Join(stateDir, "state.json"), data: State{Version: 3, XUIConfig: model.DefaultXUIConfig(), PendingRouterConfigs: map[string]model.RouterConfig{}, PendingConfirmations: map[string]PendingConfirmation{}}}
	raw, err := os.ReadFile(s.path)
	if errors.Is(err, os.ErrNotExist) {
		return s, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read state: %w", err)
	}
	var loaded State
	if err := json.Unmarshal(raw, &loaded); err != nil {
		return nil, fmt.Errorf("decode state: %w", err)
	}
	s.data = loaded
	if s.data.PendingRouterConfigs == nil {
		s.data.PendingRouterConfigs = map[string]model.RouterConfig{}
	}
	if s.data.PendingConfirmations == nil {
		s.data.PendingConfirmations = map[string]PendingConfirmation{}
	}
	if s.migrateV3() {
		if err := s.saveLocked(); err != nil {
			return nil, fmt.Errorf("migrate state: %w", err)
		}
	}
	return s, nil
}

func (s *Store) Snapshot() State {
	s.mu.RLock()
	defer s.mu.RUnlock()
	copy := s.data
	if s.data.RouterConfig != nil {
		cfg := cloneRouterConfig(*s.data.RouterConfig)
		copy.RouterConfig = &cfg
	}
	if s.data.Admin != nil {
		admin := *s.data.Admin
		copy.Admin = &admin
	}
	copy.PendingRouterConfigs = make(map[string]model.RouterConfig, len(s.data.PendingRouterConfigs))
	for revision, cfg := range s.data.PendingRouterConfigs {
		copy.PendingRouterConfigs[revision] = cloneRouterConfig(cfg)
	}
	copy.PendingConfirmations = make(map[string]PendingConfirmation, len(s.data.PendingConfirmations))
	for revision, confirmation := range s.data.PendingConfirmations {
		copy.PendingConfirmations[revision] = confirmation
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
	copy := cloneRouterConfig(cfg)
	s.data.RouterConfig = &copy
	return s.saveLocked()
}

func (s *Store) SaveRouterAndXUIConfig(cfg model.RouterConfig, xui model.XUIConfig) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	copy := cloneRouterConfig(cfg)
	s.data.RouterConfig = &copy
	s.data.XUIConfig = normalizeXUIConfig(xui)
	return s.saveLocked()
}

func (s *Store) SavePendingRouterConfig(revision string, cfg model.RouterConfig) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.data.PendingRouterConfigs == nil {
		s.data.PendingRouterConfigs = map[string]model.RouterConfig{}
	}
	s.data.PendingRouterConfigs[revision] = cloneRouterConfig(cfg)
	return s.saveLocked()
}

func (s *Store) SavePendingRouterApply(revision string, cfg model.RouterConfig, token string, expiresAt time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.data.PendingRouterConfigs == nil {
		s.data.PendingRouterConfigs = map[string]model.RouterConfig{}
	}
	if s.data.PendingConfirmations == nil {
		s.data.PendingConfirmations = map[string]PendingConfirmation{}
	}
	s.data.PendingRouterConfigs[revision] = cloneRouterConfig(cfg)
	s.data.PendingConfirmations[revision] = PendingConfirmation{TokenHash: tokenHash(token), ExpiresAt: expiresAt.UTC()}
	return s.saveLocked()
}

func (s *Store) ValidPendingConfirmation(revision, token string, now time.Time) bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	confirmation, ok := s.data.PendingConfirmations[revision]
	if !ok || token == "" || !now.Before(confirmation.ExpiresAt) {
		return false
	}
	expected := []byte(confirmation.TokenHash)
	actual := []byte(tokenHash(token))
	return len(expected) == len(actual) && subtle.ConstantTimeCompare(expected, actual) == 1
}

func (s *Store) ConfirmPendingRouterConfig(revision string) (model.RouterConfig, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	cfg, ok := s.data.PendingRouterConfigs[revision]
	if !ok {
		return model.RouterConfig{}, false, nil
	}
	delete(s.data.PendingRouterConfigs, revision)
	delete(s.data.PendingConfirmations, revision)
	copy := cloneRouterConfig(cfg)
	s.data.RouterConfig = &copy
	return copy, true, s.saveLocked()
}

func (s *Store) DeletePendingRouterConfig(revision string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.data.PendingRouterConfigs, revision)
	delete(s.data.PendingConfirmations, revision)
	return s.saveLocked()
}

func (s *Store) ChangeAdmin(admin Admin) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.data.Admin == nil {
		return ErrNotInitialized
	}
	s.data.Admin = &admin
	return s.saveLocked()
}

func (s *Store) saveLocked() error {
	s.data.Version = 3
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

func cloneRouterConfig(cfg model.RouterConfig) model.RouterConfig {
	cfg.LANInterfaces = append([]string(nil), cfg.LANInterfaces...)
	cfg.DNS = append([]string(nil), cfg.DNS...)
	cfg.ManagerWANSources = append([]string(nil), cfg.ManagerWANSources...)
	cfg.WANPorts = append([]model.PortRule(nil), cfg.WANPorts...)
	for index := range cfg.WANPorts {
		cfg.WANPorts[index].Sources = append([]string(nil), cfg.WANPorts[index].Sources...)
	}
	return cfg
}

func (s *Store) migrateV3() bool {
	changed := s.data.Version < 3
	panelPort := s.data.XUIConfig.PanelPort
	if s.data.RouterConfig != nil {
		cfg := cloneRouterConfig(*s.data.RouterConfig)
		if panelPort == 0 && cfg.PanelPort > 0 {
			panelPort = cfg.PanelPort
		}
		if migrateRouterConfig(&cfg) {
			s.data.RouterConfig = &cfg
			changed = true
		}
	}
	for revision, original := range s.data.PendingRouterConfigs {
		cfg := cloneRouterConfig(original)
		if panelPort == 0 && cfg.PanelPort > 0 {
			panelPort = cfg.PanelPort
		}
		if migrateRouterConfig(&cfg) {
			s.data.PendingRouterConfigs[revision] = cfg
			changed = true
		}
	}
	if panelPort == 0 {
		panelPort = model.DefaultPanelPort
	}
	if s.data.XUIConfig.PanelPort != panelPort {
		s.data.XUIConfig.PanelPort = panelPort
		changed = true
	}
	return changed
}

func migrateRouterConfig(cfg *model.RouterConfig) bool {
	changed := false
	if cfg.ManagerPort == 0 {
		cfg.ManagerPort = model.DefaultManagerPort
		changed = true
	}
	if cfg.ManagerWANAccess {
		found := false
		for index := range cfg.WANPorts {
			if cfg.WANPorts[index].Protocol == "tcp" && cfg.WANPorts[index].Port == cfg.ManagerPort {
				cfg.WANPorts[index].Disabled = false
				if len(cfg.ManagerWANSources) > 0 {
					cfg.WANPorts[index].Sources = append([]string(nil), cfg.ManagerWANSources...)
				}
				found = true
				break
			}
		}
		if !found {
			cfg.WANPorts = append(cfg.WANPorts, model.PortRule{Protocol: "tcp", Port: cfg.ManagerPort, Description: "NanoPi Manager", Sources: append([]string(nil), cfg.ManagerWANSources...)})
		}
		changed = true
	}
	if cfg.ManagerWANAccess || len(cfg.ManagerWANSources) > 0 || cfg.PanelPort != 0 {
		cfg.ManagerWANAccess = false
		cfg.ManagerWANSources = nil
		cfg.PanelPort = 0
		changed = true
	}
	return changed
}

func normalizeXUIConfig(cfg model.XUIConfig) model.XUIConfig {
	if cfg.PanelPort < 1 || cfg.PanelPort > 65535 {
		cfg.PanelPort = model.DefaultPanelPort
	}
	return cfg
}

func tokenHash(token string) string {
	sum := sha256.Sum256([]byte(token))
	return fmt.Sprintf("%x", sum[:])
}
