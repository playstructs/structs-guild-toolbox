package chain

import (
	"os"
	"path/filepath"
	"slices"
	"testing"
)

func writeClientToml(t *testing.T, body string) string {
	home := t.TempDir()
	if err := os.MkdirAll(filepath.Join(home, "config"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(home, "config", "client.toml"), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return home
}

func TestClientTomlDrivesKeyring(t *testing.T) {
	home := writeClientToml(t, `
broadcast-mode = "sync"
chain-id = "structstestnet-111"
keyring-backend = "file"
keyring-default-keyname = "commander"
node = "tcp://node.example:26657"
`)
	c := New("structsd", []string{"--home", home}, nil)
	if c.KeyringBackend != "file" || c.DefaultKey != "commander" || c.Node != "tcp://node.example:26657" || c.chainID != "structstestnet-111" {
		t.Fatalf("client.toml not applied: %+v", c)
	}
	if c.ConfigFile == "" {
		t.Fatal("ConfigFile not recorded")
	}
	kf := c.keyringFlags()
	if flagValue(kf, "--keyring-backend") != "file" || flagValue(kf, "--home") != home {
		t.Fatalf("keyring flags = %v", kf)
	}
}

func TestFlagsOverrideClientToml(t *testing.T) {
	home := writeClientToml(t, `keyring-backend = "file"`+"\n"+`node = "tcp://a:1"`)
	c := New("structsd", []string{"--home", home, "--keyring-backend", "test", "--node", "tcp://b:2"}, nil)
	if c.KeyringBackend != "test" || c.Node != "tcp://b:2" {
		t.Fatalf("flags should win: %+v", c)
	}
	// the explicit flag is passed once, not duplicated
	n := 0
	for _, f := range c.keyringFlags() {
		if f == "--keyring-backend" {
			n++
		}
	}
	if n != 1 {
		t.Fatalf("--keyring-backend passed %d times", n)
	}
}

func TestDefaultsWithoutClientToml(t *testing.T) {
	c := New("structsd", []string{"--home", t.TempDir()}, nil)
	if c.KeyringBackend != "os" || c.ConfigFile != "" || c.DefaultKey != "" {
		t.Fatalf("structsd defaults expected: %+v", c)
	}
	if !slices.Contains(c.keyringFlags(), "os") {
		t.Fatal("os backend not passed")
	}
}
