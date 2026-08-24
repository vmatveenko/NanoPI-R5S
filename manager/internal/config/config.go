package config

import (
	"flag"
	"os"
	"path/filepath"
	"strconv"
)

type Config struct {
	ListenAddress string
	StateDir      string
	SocketPath    string
	RootDir       string
	AgentBinary   string
	DryRun        bool
}

func Defaults() Config {
	port := 8080
	if raw := os.Getenv("NANOPI_MANAGER_PORT"); raw != "" {
		if parsed, err := strconv.Atoi(raw); err == nil && parsed > 0 && parsed <= 65535 {
			port = parsed
		}
	}
	stateDir := envOr("NANOPI_MANAGER_STATE_DIR", "/var/lib/nanopi-manager")
	return Config{
		ListenAddress: "0.0.0.0:" + strconv.Itoa(port),
		StateDir:      stateDir,
		SocketPath:    envOr("NANOPI_MANAGER_SOCKET", "/run/nanopi-manager/agent.sock"),
		RootDir:       envOr("NANOPI_MANAGER_ROOT", "/"),
		AgentBinary:   envOr("NANOPI_MANAGER_AGENT_BINARY", "/usr/local/lib/nanopi-manager/nanopi-manager-agent"),
		DryRun:        os.Getenv("NANOPI_MANAGER_DRY_RUN") == "1",
	}
}

func ParseAgent(args []string) (Config, string, string) {
	cfg := Defaults()
	fs := flag.NewFlagSet("nanopi-manager-agent", flag.ContinueOnError)
	mode := fs.String("mode", "serve", "serve or rollback")
	revision := fs.String("revision", "", "revision to restore")
	fs.StringVar(&cfg.SocketPath, "socket", cfg.SocketPath, "Unix socket path")
	fs.StringVar(&cfg.RootDir, "root", cfg.RootDir, "filesystem root for managed files")
	fs.StringVar(&cfg.StateDir, "state-dir", cfg.StateDir, "state directory")
	fs.BoolVar(&cfg.DryRun, "dry-run", cfg.DryRun, "do not execute system changes")
	_ = fs.Parse(args)
	return cfg, *mode, *revision
}

func (c Config) Rooted(path string) string {
	if c.RootDir == "" || c.RootDir == "/" {
		return path
	}
	return filepath.Join(c.RootDir, filepath.FromSlash(path))
}

func envOr(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}
