package web

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/vmatveenko/nanopi-r5s/manager/internal/agent"
	"github.com/vmatveenko/nanopi-r5s/manager/internal/config"
	"github.com/vmatveenko/nanopi-r5s/manager/internal/store"
)

func TestFirstLoginFlow(t *testing.T) {
	state, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	server := NewServer(config.Defaults(), state, nil)
	ts := httptest.NewServer(server.Handler())
	defer ts.Close()
	jar, _ := cookiejar.New(nil)
	client := &http.Client{Jar: jar}

	setupBody := bytes.NewBufferString(`{"username":"router-admin","password":"a reasonably long passphrase"}`)
	response, err := client.Post(ts.URL+"/api/setup", "application/json", setupBody)
	if err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != http.StatusCreated {
		t.Fatalf("setup status %d", response.StatusCode)
	}
	var session map[string]any
	if err := json.NewDecoder(response.Body).Decode(&session); err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if session["csrfToken"] == "" {
		t.Fatal("CSRF token missing")
	}

	response, err = client.Get(ts.URL + "/api/session")
	if err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != http.StatusOK {
		t.Fatalf("session status %d", response.StatusCode)
	}
	response.Body.Close()

	duplicate := bytes.NewBufferString(`{"username":"other-admin","password":"another long password"}`)
	response, err = client.Post(ts.URL+"/api/setup", "application/json", duplicate)
	if err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != http.StatusConflict {
		t.Fatalf("duplicate setup status %d", response.StatusCode)
	}
	response.Body.Close()
}

func TestRouterRoundTripOverAgentSocket(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("covered by Linux CI; Windows temporary directory cleanup races with AF_UNIX")
	}
	socket := filepath.Join(os.TempDir(), fmt.Sprintf("nm-%d.sock", os.Getpid()))
	_ = os.Remove(socket)
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Skipf("Unix sockets unavailable: %v", err)
	}
	defer func() { listener.Close(); _ = os.Remove(socket) }()
	root := t.TempDir()
	cfg := config.Defaults()
	cfg.DryRun = true
	cfg.RootDir = filepath.Join(root, "root")
	cfg.StateDir = filepath.Join(root, "state")
	cfg.SocketPath = socket
	if err := os.MkdirAll(cfg.RootDir, 0o700); err != nil {
		t.Fatal(err)
	}
	agentService := agent.NewService(cfg, agent.ExecRunner{DryRun: true})
	agentHTTP := &http.Server{Handler: agentService.Handler()}
	go agentHTTP.Serve(listener)
	defer agentHTTP.Shutdown(context.Background())

	state, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	webServer := NewServer(cfg, state, NewAgentClient(socket))
	ts := httptest.NewServer(webServer.Handler())
	defer ts.Close()
	jar, _ := cookiejar.New(nil)
	client := &http.Client{Jar: jar}
	response, err := client.Post(ts.URL+"/api/setup", "application/json", bytes.NewBufferString(`{"username":"router-admin","password":"a reasonably long passphrase"}`))
	if err != nil {
		t.Fatal(err)
	}
	var setup map[string]any
	if err := json.NewDecoder(response.Body).Decode(&setup); err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	requestBody := []byte(`{"wanInterface":"eth0","wanMacMode":"current","lanInterfaces":["eth1","eth2"],"bridge":"br0","lanCidr":"192.168.10.1/24","dhcpStart":"192.168.10.10","dhcpEnd":"192.168.10.200","dns":["8.8.8.8"],"managerPort":8080,"panelPort":2053}`)
	post := func(path string, body []byte) map[string]any {
		req, _ := http.NewRequest(http.MethodPost, ts.URL+path, bytes.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("X-CSRF-Token", setup["csrfToken"].(string))
		resp, err := client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			var problem map[string]any
			_ = json.NewDecoder(resp.Body).Decode(&problem)
			t.Fatalf("%s returned %d: %#v", path, resp.StatusCode, problem)
		}
		var result map[string]any
		if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
			t.Fatal(err)
		}
		return result
	}
	plan := post("/api/router/plan", requestBody)
	if len(plan["files"].([]any)) < 5 {
		t.Fatal("plan is incomplete")
	}
	apply := post("/api/router/apply", requestBody)
	revision := apply["revisionId"].(string)
	confirmBody, _ := json.Marshal(map[string]string{"revisionId": revision})
	confirmed := post("/api/router/confirm", confirmBody)
	if confirmed["confirmed"] != true {
		t.Fatal("apply was not confirmed")
	}
}
