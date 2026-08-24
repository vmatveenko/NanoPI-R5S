package agent

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"

	"github.com/vmatveenko/nanopi-r5s/manager/internal/config"
)

func TestVerifyArchiveChecksum(t *testing.T) {
	archive := []byte("release archive")
	sum := sha256.Sum256(archive)
	checksums := hex.EncodeToString(sum[:]) + "  nanopi-manager-linux-arm64.tar.gz\n"
	if err := verifyArchiveChecksum("nanopi-manager-linux-arm64.tar.gz", archive, checksums); err != nil {
		t.Fatal(err)
	}
	if err := verifyArchiveChecksum("nanopi-manager-linux-arm64.tar.gz", []byte("changed"), checksums); err == nil {
		t.Fatal("checksum mismatch accepted")
	}
}

func TestExtractManagerArchive(t *testing.T) {
	var archive bytes.Buffer
	gz := gzip.NewWriter(&archive)
	tw := tar.NewWriter(gz)
	for _, name := range []string{"nanopi-manager-web", "nanopi-manager-agent"} {
		content := []byte("binary-" + name)
		if err := tw.WriteHeader(&tar.Header{Name: "release/" + name, Mode: 0o755, Size: int64(len(content))}); err != nil {
			t.Fatal(err)
		}
		if _, err := tw.Write(content); err != nil {
			t.Fatal(err)
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}
	destination := t.TempDir()
	if err := extractManagerArchive(archive.Bytes(), destination); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"nanopi-manager-web", "nanopi-manager-agent"} {
		if _, err := os.Stat(filepath.Join(destination, name)); err != nil {
			t.Fatal(err)
		}
	}
}

func TestConfiguredManagerPort(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "etc", "nanopi-manager")
	if err := os.MkdirAll(path, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(path, "manager.env"), []byte("NANOPI_MANAGER_PORT=9090\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg := config.Defaults()
	cfg.RootDir = root
	service := NewService(cfg, fakeRunner{})
	if got := service.configuredManagerPort(); got != 9090 {
		t.Fatalf("configured port = %d", got)
	}
}

func TestOlderVersionComparison(t *testing.T) {
	for _, test := range []struct {
		candidate string
		current   string
		older     bool
	}{
		{"v0.9.9", "v1.0.0", true},
		{"v1.0.0", "v1.0.0", false},
		{"v1.1.0", "v1.0.9", false},
		{"v1.0.0-rc.1", "v1.0.0", false},
	} {
		if got := isOlderVersion(test.candidate, test.current); got != test.older {
			t.Errorf("isOlderVersion(%q, %q) = %v", test.candidate, test.current, got)
		}
	}
}
