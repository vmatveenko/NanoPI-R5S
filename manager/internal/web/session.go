package web

import (
	"crypto/rand"
	"encoding/base64"
	"net/http"
	"sync"
	"time"
)

const sessionCookie = "nanopi_manager_session"

type session struct {
	Token     string
	CSRF      string
	ExpiresAt time.Time
}

type sessions struct {
	mu    sync.Mutex
	items map[string]session
}

func newSessions() *sessions { return &sessions{items: map[string]session{}} }

func (s *sessions) create(w http.ResponseWriter) session {
	s.mu.Lock()
	defer s.mu.Unlock()
	value := session{Token: randomToken(32), CSRF: randomToken(24), ExpiresAt: time.Now().Add(12 * time.Hour)}
	s.items[value.Token] = value
	http.SetCookie(w, &http.Cookie{
		Name: sessionCookie, Value: value.Token, Path: "/", HttpOnly: true,
		SameSite: http.SameSiteStrictMode, MaxAge: int((12 * time.Hour).Seconds()),
	})
	return value
}

func (s *sessions) get(r *http.Request) (session, bool) {
	cookie, err := r.Cookie(sessionCookie)
	if err != nil {
		return session{}, false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	value, ok := s.items[cookie.Value]
	if !ok || time.Now().After(value.ExpiresAt) {
		delete(s.items, cookie.Value)
		return session{}, false
	}
	value.ExpiresAt = time.Now().Add(12 * time.Hour)
	s.items[cookie.Value] = value
	return value, true
}

func (s *sessions) remove(w http.ResponseWriter, r *http.Request) {
	if cookie, err := r.Cookie(sessionCookie); err == nil {
		s.mu.Lock()
		delete(s.items, cookie.Value)
		s.mu.Unlock()
	}
	http.SetCookie(w, &http.Cookie{Name: sessionCookie, Path: "/", MaxAge: -1, HttpOnly: true, SameSite: http.SameSiteStrictMode})
}

func (s *sessions) clear(w http.ResponseWriter) {
	s.mu.Lock()
	s.items = map[string]session{}
	s.mu.Unlock()
	http.SetCookie(w, &http.Cookie{Name: sessionCookie, Path: "/", MaxAge: -1, HttpOnly: true, SameSite: http.SameSiteStrictMode})
}

func randomToken(size int) string {
	raw := make([]byte, size)
	if _, err := rand.Read(raw); err != nil {
		panic(err)
	}
	return base64.RawURLEncoding.EncodeToString(raw)
}
