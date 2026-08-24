package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/user"
	"path/filepath"
	"strconv"
	"time"

	"github.com/vmatveenko/nanopi-r5s/manager/internal/model"
)

func (s *Service) Serve(ctx context.Context) error {
	if err := os.MkdirAll(filepath.Dir(s.cfg.SocketPath), 0o750); err != nil {
		return err
	}
	if err := os.Remove(s.cfg.SocketPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	listener, err := net.Listen("unix", s.cfg.SocketPath)
	if err != nil {
		return err
	}
	defer listener.Close()
	if err := os.Chmod(s.cfg.SocketPath, 0o660); err != nil {
		return err
	}
	if group, err := user.LookupGroup("nanopi-manager"); err == nil {
		if gid, err := strconv.Atoi(group.Gid); err == nil {
			_ = os.Chown(s.cfg.SocketPath, 0, gid)
		}
	}
	server := &http.Server{Handler: s.Handler(), ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 30 * time.Second}
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdown)
	}()
	err = server.Serve(listener)
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

func (s *Service) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/inventory", s.handleInventory)
	mux.HandleFunc("POST /v1/router/plan", s.handlePlan)
	mux.HandleFunc("POST /v1/router/apply", s.handleApply)
	mux.HandleFunc("POST /v1/router/confirm", s.handleConfirm)
	mux.HandleFunc("POST /v1/router/rollback", s.handleRollback)
	mux.HandleFunc("POST /v1/docker/install", s.handleDockerInstall)
	mux.HandleFunc("POST /v1/xui/action", s.handleXUIAction)
	mux.HandleFunc("POST /v1/xui/bootstrap-tun", s.handleBootstrapTUN)
	mux.HandleFunc("GET /v1/diagnostics", s.handleDiagnostics)
	return requestLog(mux)
}

func (s *Service) handleInventory(w http.ResponseWriter, _ *http.Request) {
	value, err := s.Inventory()
	writeResponse(w, value, err)
}

func (s *Service) handlePlan(w http.ResponseWriter, r *http.Request) {
	var cfg model.RouterConfig
	if err := decodeJSON(r, &cfg); err != nil {
		writeResponse(w, nil, err)
		return
	}
	value, err := s.Plan(cfg)
	writeResponse(w, value, err)
}

func (s *Service) handleApply(w http.ResponseWriter, r *http.Request) {
	var cfg model.RouterConfig
	if err := decodeJSON(r, &cfg); err != nil {
		writeResponse(w, nil, err)
		return
	}
	value, err := s.Apply(r.Context(), cfg)
	writeResponse(w, value, err)
}

func (s *Service) handleConfirm(w http.ResponseWriter, r *http.Request) {
	var request struct {
		RevisionID string `json:"revisionId"`
	}
	if err := decodeJSON(r, &request); err != nil {
		writeResponse(w, nil, err)
		return
	}
	err := s.Confirm(r.Context(), request.RevisionID)
	writeResponse(w, map[string]bool{"confirmed": err == nil}, err)
}

func (s *Service) handleRollback(w http.ResponseWriter, r *http.Request) {
	var request struct {
		RevisionID string `json:"revisionId"`
	}
	if err := decodeJSON(r, &request); err != nil {
		writeResponse(w, nil, err)
		return
	}
	err := s.Rollback(r.Context(), request.RevisionID)
	writeResponse(w, map[string]bool{"rolledBack": err == nil}, err)
}

func (s *Service) handleDockerInstall(w http.ResponseWriter, r *http.Request) {
	err := s.DockerInstall(r.Context())
	writeResponse(w, map[string]bool{"installed": err == nil}, err)
}

func (s *Service) handleXUIAction(w http.ResponseWriter, r *http.Request) {
	var request model.XUIActionRequest
	if err := decodeJSON(r, &request); err != nil {
		writeResponse(w, nil, err)
		return
	}
	message, err := s.XUIAction(r.Context(), request, request.PanelPort)
	writeResponse(w, map[string]string{"message": message}, err)
}

func (s *Service) handleBootstrapTUN(w http.ResponseWriter, r *http.Request) {
	var request model.XUITUNRequest
	if err := decodeJSON(r, &request); err != nil {
		writeResponse(w, nil, err)
		return
	}
	message, err := s.BootstrapTUN(r.Context(), request)
	writeResponse(w, map[string]string{"message": message}, err)
}

func (s *Service) handleDiagnostics(w http.ResponseWriter, r *http.Request) {
	writeResponse(w, s.Diagnostics(r.Context()), nil)
}

func writeResponse(w http.ResponseWriter, value any, err error) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	if err != nil {
		w.WriteHeader(http.StatusBadRequest)
		_ = json.NewEncoder(w).Encode(map[string]any{"ok": false, "error": err.Error()})
		return
	}
	_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "data": value})
}

func requestLog(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		started := time.Now()
		next.ServeHTTP(w, r)
		fmt.Printf("agent %s %s %s\n", r.Method, r.URL.Path, time.Since(started).Round(time.Millisecond))
	})
}
