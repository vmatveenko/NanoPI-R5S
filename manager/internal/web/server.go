package web

import (
	"context"
	"embed"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"log"
	"net"
	"net/http"
	"sync"
	"time"

	"github.com/vmatveenko/nanopi-r5s/manager/internal/auth"
	"github.com/vmatveenko/nanopi-r5s/manager/internal/config"
	"github.com/vmatveenko/nanopi-r5s/manager/internal/model"
	"github.com/vmatveenko/nanopi-r5s/manager/internal/store"
)

//go:embed static/*
var staticFiles embed.FS

type loginAttempt struct {
	Count int
	Reset time.Time
}

type Server struct {
	cfg      config.Config
	store    *store.Store
	agent    *AgentClient
	sessions *sessions
	limitMu  sync.Mutex
	limits   map[string]loginAttempt
}

func NewServer(cfg config.Config, state *store.Store, agent *AgentClient) *Server {
	return &Server{cfg: cfg, store: state, agent: agent, sessions: newSessions(), limits: map[string]loginAttempt{}}
}

func (s *Server) Serve(ctx context.Context) error {
	server := &http.Server{
		Addr: s.cfg.ListenAddress, Handler: s.Handler(), ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout: 20 * time.Second, WriteTimeout: 5 * time.Minute, IdleTimeout: 60 * time.Second,
	}
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdown)
	}()
	log.Printf("NanoPi Manager listening on %s", s.cfg.ListenAddress)
	err := server.ListenAndServe()
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/bootstrap", s.handleBootstrap)
	mux.HandleFunc("POST /api/setup", s.handleSetup)
	mux.HandleFunc("POST /api/login", s.handleLogin)
	mux.HandleFunc("POST /api/logout", s.handleLogout)
	mux.Handle("GET /api/session", s.requireAuth(http.HandlerFunc(s.handleSession)))
	mux.Handle("GET /api/state", s.requireAuth(http.HandlerFunc(s.handleState)))
	mux.Handle("POST /api/password", s.requireAuth(s.requireCSRF(http.HandlerFunc(s.handlePassword))))
	mux.Handle("GET /api/inventory", s.requireAuth(http.HandlerFunc(s.proxyGET("/v1/inventory"))))
	mux.Handle("GET /api/diagnostics", s.requireAuth(http.HandlerFunc(s.proxyGET("/v1/diagnostics"))))
	mux.Handle("GET /api/diagnostics/export", s.requireAuth(http.HandlerFunc(s.handleDiagnosticsExport)))
	mux.Handle("POST /api/router/plan", s.requireAuth(s.requireCSRF(http.HandlerFunc(s.handlePlan))))
	mux.Handle("POST /api/router/apply", s.requireAuth(s.requireCSRF(http.HandlerFunc(s.handleApply))))
	mux.Handle("POST /api/router/confirm", s.requireAuth(s.requireCSRF(http.HandlerFunc(s.handleConfirm))))
	mux.Handle("POST /api/router/rollback", s.requireAuth(s.requireCSRF(http.HandlerFunc(s.handleRollback))))
	mux.Handle("GET /api/router/status", s.requireAuth(http.HandlerFunc(s.handleRouterStatus)))
	mux.Handle("POST /api/router/deactivate", s.requireAuth(s.requireCSRF(http.HandlerFunc(s.handleDeactivate))))
	mux.Handle("POST /api/firewall/status", s.requireAuth(s.requireCSRF(http.HandlerFunc(s.handleFirewallStatus))))
	mux.Handle("POST /api/firewall/apply", s.requireAuth(s.requireCSRF(http.HandlerFunc(s.handleFirewallApply))))
	mux.Handle("POST /api/docker/install", s.requireAuth(s.requireCSRF(http.HandlerFunc(s.proxyPOST("/v1/docker/install")))))
	mux.Handle("GET /api/docker/status", s.requireAuth(http.HandlerFunc(s.proxyGET("/v1/docker/status"))))
	mux.Handle("POST /api/xui/action", s.requireAuth(s.requireCSRF(http.HandlerFunc(s.proxyPOST("/v1/xui/action")))))
	mux.Handle("POST /api/xui/bootstrap-tun", s.requireAuth(s.requireCSRF(http.HandlerFunc(s.proxyPOST("/v1/xui/bootstrap-tun")))))
	mux.Handle("GET /api/manager/releases", s.requireAuth(http.HandlerFunc(s.handleManagerReleases)))
	mux.Handle("POST /api/manager/update", s.requireAuth(s.requireCSRF(http.HandlerFunc(s.proxyPOST("/v1/manager/update")))))
	assets, _ := fs.Sub(staticFiles, "static")
	mux.Handle("/", http.FileServer(http.FS(assets)))
	return s.securityHeaders(s.accessLog(mux))
}

func (s *Server) handleBootstrap(w http.ResponseWriter, _ *http.Request) {
	state := s.store.Snapshot()
	writeJSON(w, http.StatusOK, map[string]any{"initialized": state.Admin != nil})
}

func (s *Server) handleSetup(w http.ResponseWriter, r *http.Request) {
	if !s.allowAttempt(r) {
		writeError(w, http.StatusTooManyRequests, "too many attempts")
		return
	}
	if s.store.Snapshot().Admin != nil {
		writeError(w, http.StatusConflict, "administrator already exists")
		return
	}
	var request struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := readJSON(r, &request); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	admin, err := auth.NewAdmin(request.Username, request.Password)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if err := s.store.InitializeAdmin(admin); err != nil {
		writeError(w, http.StatusConflict, err.Error())
		return
	}
	session := s.sessions.create(w)
	writeJSON(w, http.StatusCreated, map[string]any{"username": admin.Username, "csrfToken": session.CSRF})
}

func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	if !s.allowAttempt(r) {
		writeError(w, http.StatusTooManyRequests, "too many attempts")
		return
	}
	var request struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := readJSON(r, &request); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request")
		return
	}
	state := s.store.Snapshot()
	if state.Admin == nil || !auth.Verify(*state.Admin, request.Username, request.Password) {
		time.Sleep(250 * time.Millisecond)
		writeError(w, http.StatusUnauthorized, "invalid login or password")
		return
	}
	session := s.sessions.create(w)
	writeJSON(w, http.StatusOK, map[string]any{"username": state.Admin.Username, "csrfToken": session.CSRF})
}

func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request) {
	s.sessions.remove(w, r)
	writeJSON(w, http.StatusOK, map[string]bool{"loggedOut": true})
}

func (s *Server) handleSession(w http.ResponseWriter, r *http.Request) {
	session, _ := s.sessions.get(r)
	state := s.store.Snapshot()
	writeJSON(w, http.StatusOK, map[string]any{"username": state.Admin.Username, "csrfToken": session.CSRF})
}

func (s *Server) handleState(w http.ResponseWriter, _ *http.Request) {
	state := s.store.Snapshot()
	cfg := state.RouterConfig
	if cfg == nil {
		defaults := model.DefaultRouterConfig()
		cfg = &defaults
	}
	writeJSON(w, http.StatusOK, map[string]any{"routerConfig": cfg, "pendingRouterConfigs": state.PendingRouterConfigs})
}

func (s *Server) handlePassword(w http.ResponseWriter, r *http.Request) {
	var request struct {
		CurrentPassword string `json:"currentPassword"`
		NewPassword     string `json:"newPassword"`
		Confirmation    string `json:"confirmation"`
	}
	if err := readJSON(r, &request); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	state := s.store.Snapshot()
	if state.Admin == nil || !auth.Verify(*state.Admin, state.Admin.Username, request.CurrentPassword) {
		writeError(w, http.StatusUnauthorized, "current password is incorrect")
		return
	}
	if request.NewPassword != request.Confirmation {
		writeError(w, http.StatusBadRequest, "password confirmation does not match")
		return
	}
	admin, err := auth.NewAdmin(state.Admin.Username, request.NewPassword)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if err := s.store.ChangeAdmin(admin); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.sessions.clear(w)
	writeJSON(w, http.StatusOK, map[string]bool{"changed": true})
}

func (s *Server) handleDiagnosticsExport(w http.ResponseWriter, r *http.Request) {
	var result any
	if err := s.agent.Call(r.Context(), http.MethodGet, "/v1/diagnostics", nil, &result); err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Content-Disposition", "attachment; filename=nanopi-manager-diagnostics.json")
	encoder := json.NewEncoder(w)
	encoder.SetIndent("", "  ")
	_ = encoder.Encode(result)
}

func (s *Server) handlePlan(w http.ResponseWriter, r *http.Request) {
	var cfg model.RouterConfig
	if err := readJSON(r, &cfg); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	var result model.Plan
	if err := s.agent.Call(r.Context(), http.MethodPost, "/v1/router/plan", cfg, &result); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, result)
}

func (s *Server) handleApply(w http.ResponseWriter, r *http.Request) {
	var cfg model.RouterConfig
	if err := readJSON(r, &cfg); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	var normalized model.Plan
	if err := s.agent.Call(r.Context(), http.MethodPost, "/v1/router/plan", cfg, &normalized); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	var result model.ApplyResult
	if err := s.agent.Call(r.Context(), http.MethodPost, "/v1/router/apply", normalized.Config, &result); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if err := s.store.SavePendingRouterConfig(result.RevisionID, normalized.Config); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, result)
}

func (s *Server) handleConfirm(w http.ResponseWriter, r *http.Request) {
	var request struct {
		RevisionID string `json:"revisionId"`
	}
	if err := readJSON(r, &request); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if err := s.agent.Call(r.Context(), http.MethodPost, "/v1/router/confirm", request, nil); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if _, _, err := s.store.ConfirmPendingRouterConfig(request.RevisionID); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"confirmed": true})
}

func (s *Server) handleRollback(w http.ResponseWriter, r *http.Request) {
	var request struct {
		RevisionID string `json:"revisionId"`
	}
	if err := readJSON(r, &request); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	var result any
	if err := s.agent.Call(r.Context(), http.MethodPost, "/v1/router/rollback", request, &result); err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	_ = s.store.DeletePendingRouterConfig(request.RevisionID)
	writeJSON(w, http.StatusOK, result)
}

func (s *Server) handleRouterStatus(w http.ResponseWriter, r *http.Request) {
	var result model.RouterStatus
	if err := s.agent.Call(r.Context(), http.MethodGet, "/v1/router/status", nil, &result); err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	for revision := range s.store.Snapshot().PendingRouterConfigs {
		if !result.Pending || revision != result.PendingRevision {
			_ = s.store.DeletePendingRouterConfig(revision)
		}
	}
	writeJSON(w, http.StatusOK, result)
}

func (s *Server) handleDeactivate(w http.ResponseWriter, r *http.Request) {
	var request map[string]any
	if err := readJSON(r, &request); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	var result any
	if err := s.agent.Call(r.Context(), http.MethodPost, "/v1/router/deactivate", request, &result); err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	for revision := range s.store.Snapshot().PendingRouterConfigs {
		_ = s.store.DeletePendingRouterConfig(revision)
	}
	writeJSON(w, http.StatusOK, result)
}

func (s *Server) handleFirewallStatus(w http.ResponseWriter, r *http.Request) {
	var cfg model.RouterConfig
	if err := readJSON(r, &cfg); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	var result model.FirewallStatus
	if err := s.agent.Call(r.Context(), http.MethodPost, "/v1/firewall/status", cfg, &result); err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, result)
}

func (s *Server) handleFirewallApply(w http.ResponseWriter, r *http.Request) {
	var cfg model.RouterConfig
	if err := readJSON(r, &cfg); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	var normalized model.Plan
	if err := s.agent.Call(r.Context(), http.MethodPost, "/v1/router/plan", cfg, &normalized); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	var result model.FirewallApplyResult
	if err := s.agent.Call(r.Context(), http.MethodPost, "/v1/firewall/apply", normalized.Config, &result); err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	if err := s.store.SaveRouterConfig(normalized.Config); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, result)
}

func (s *Server) handleManagerReleases(w http.ResponseWriter, r *http.Request) {
	path := "/v1/manager/releases"
	if r.URL.Query().Get("prerelease") == "true" {
		path += "?prerelease=true"
	}
	var result model.ReleaseStatus
	if err := s.agent.Call(r.Context(), http.MethodGet, path, nil, &result); err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, result)
}

func (s *Server) proxyGET(path string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var result any
		if err := s.agent.Call(r.Context(), http.MethodGet, path, nil, &result); err != nil {
			writeError(w, http.StatusBadGateway, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, result)
	}
}

func (s *Server) proxyPOST(path string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var request any
		if err := readJSON(r, &request); err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
		var result any
		if err := s.agent.Call(r.Context(), http.MethodPost, path, request, &result); err != nil {
			writeError(w, http.StatusBadGateway, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, result)
	}
}

func (s *Server) requireAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if _, ok := s.sessions.get(r); !ok {
			writeError(w, http.StatusUnauthorized, "authentication required")
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) requireCSRF(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		session, ok := s.sessions.get(r)
		if !ok || r.Header.Get("X-CSRF-Token") != session.CSRF {
			writeError(w, http.StatusForbidden, "invalid CSRF token")
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) allowAttempt(r *http.Request) bool {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	now := time.Now()
	s.limitMu.Lock()
	defer s.limitMu.Unlock()
	attempt := s.limits[host]
	if now.After(attempt.Reset) {
		attempt = loginAttempt{Reset: now.Add(time.Minute)}
	}
	attempt.Count++
	s.limits[host] = attempt
	return attempt.Count <= 10
}

func (s *Server) securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Cache-Control", "no-store")
		next.ServeHTTP(w, r)
	})
}

func (s *Server) accessLog(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		started := time.Now()
		next.ServeHTTP(w, r)
		log.Printf("web %s %s %s", r.Method, r.URL.Path, time.Since(started).Round(time.Millisecond))
	})
}

func readJSON(r *http.Request, dst any) error {
	decoder := json.NewDecoder(io.LimitReader(r.Body, 1<<20))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(dst); err != nil {
		return err
	}
	return nil
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{"error": message})
}
