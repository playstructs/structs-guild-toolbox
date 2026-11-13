package chain

import (
	"context"
	"encoding/json"
	"runtime"
	"strings"
)

// Key is one entry of `structsd keys list`.
type Key struct {
	Name    string `json:"name"`
	Type    string `json:"type"`
	Address string `json:"address"`
	PubKey  string `json:"pubkey"` // JSON: {"@type": "...", "key": "..."}
}

// KeyringState says whether the keyring could be read.
type KeyringState int

const (
	KeyringOK        KeyringState = iota
	KeyringLocked                 // needs a passphrase (file backend, or "os" falling back to a file keyring)
	KeyringWrongPass              // a passphrase was given and rejected
	KeyringOSLocked               // the OS keychain / secret service refused access
	KeyringError                  // anything else
)

// KeyringStatus is the result of listing keys, with a diagnosis when the
// list is empty for a reason other than "there are no keys".
type KeyringStatus struct {
	Keys   []Key
	State  KeyringState
	Detail string // cleaned structsd output
	Hint   string // what the user can do about it
}

// SetPassphrase stores the keyring passphrase for this process. It is fed to
// structsd on stdin for every command that opens the keyring and is never
// written anywhere.
func (c *Client) SetPassphrase(p string) {
	c.passMu.Lock()
	c.passphrase = p
	c.passMu.Unlock()
}

func (c *Client) HasPassphrase() bool {
	c.passMu.RLock()
	defer c.passMu.RUnlock()
	return c.passphrase != ""
}

// keyStdin is what keyring-opening commands read: the passphrase once per
// prompt structsd might show (it retries up to three times).
func (c *Client) keyStdin() string {
	c.passMu.RLock()
	defer c.passMu.RUnlock()
	if c.passphrase == "" {
		return ""
	}
	return strings.Repeat(c.passphrase+"\n", 3)
}

// ListKeys lists keys and explains an empty or failed result.
func (c *Client) ListKeys(ctx context.Context) KeyringStatus {
	args := append([]string{"keys", "list", "--output", "json"}, c.keyringFlags()...)
	out, stderr, err := c.runCapture(ctx, c.keyStdin(), args...)
	st := KeyringStatus{}
	if err == nil {
		_ = json.Unmarshal(lastJSONArray(out), &st.Keys)
	}
	diag := string(stderr)
	if err != nil {
		diag += " " + err.Error()
	}
	st.State, st.Hint = c.diagnose(diag, len(st.Keys) > 0)
	if st.State != KeyringOK {
		st.Detail = summarize(diag)
	}
	return st
}

// Keys lists keys, failing if the keyring could not be opened.
func (c *Client) Keys(ctx context.Context) ([]Key, error) {
	st := c.ListKeys(ctx)
	if st.State != KeyringOK && len(st.Keys) == 0 {
		return nil, &CommandError{Stderr: st.Detail}
	}
	return st.Keys, nil
}

func (c *Client) Key(ctx context.Context, name string) (Key, error) {
	b, err := c.run(ctx, c.keyStdin(), append([]string{"keys", "show", name, "--output", "json"}, c.keyringFlags()...)...)
	if err != nil {
		return Key{}, err
	}
	var k Key
	err = json.Unmarshal(lastJSON(b), &k)
	return k, err
}

func (c *Client) diagnose(out string, haveKeys bool) (KeyringState, string) {
	o := strings.ToLower(out)
	has := func(subs ...string) bool {
		for _, s := range subs {
			if strings.Contains(o, s) {
				return true
			}
		}
		return false
	}
	switch {
	// macOS keychain, typically over SSH where no approval dialog can appear
	case has("user interaction is not allowed", "errsecinteractionnotallowed", "-25308", "keychain is locked", "-25293"):
		return KeyringOSLocked, "The macOS keychain is locked for this session (common over SSH). Unlock it with:\n" +
			"  security unlock-keychain ~/Library/Keychains/login.keychain-db\n" +
			"then press ctrl+r. On the Mac itself, approve the keychain dialog (\"Always Allow\") instead."
	// Linux secret service / kwallet not available or locked
	case has("org.freedesktop.secrets", "secret service", "secretservice", "dbus", "d-bus", "kwallet", "collection is locked", "cannot create an item in a locked collection"):
		return KeyringOSLocked, "The system keyring (Secret Service / KWallet) is locked or unavailable. Unlock it in your desktop session, " +
			"or on a headless server use the file keyring (keyring-backend = \"file\" in client.toml) and unlock it here."
	case has("too many failed passphrase attempts", "incorrect passphrase", "invalid passphrase", "ciphertext", "aes.keyunwrap", "integrity check failed") && c.HasPassphrase():
		return KeyringWrongPass, "That passphrase did not unlock the keyring."
	case has("passphrase", "password", "eof"):
		hint := "This keyring is encrypted. Enter its passphrase to unlock it."
		if c.KeyringBackend == "os" && runtime.GOOS == "linux" {
			hint = "No desktop keyring is running, so the \"os\" backend is using an encrypted file keyring. Enter its passphrase to unlock it."
		}
		return KeyringLocked, hint
	case strings.TrimSpace(out) != "" && !haveKeys && has("error", "failed", "unknown"):
		return KeyringError, "structsd could not open the keyring."
	}
	return KeyringOK, ""
}

// summarize keeps the useful part of structsd's keyring chatter.
func summarize(s string) string {
	var keep []string
	seen := map[string]bool{}
	for _, l := range strings.Split(s, "\n") {
		l = strings.TrimSpace(l)
		if l == "" || seen[l] || strings.HasPrefix(l, "Enter keyring passphrase") {
			continue
		}
		seen[l] = true
		keep = append(keep, l)
	}
	out := strings.Join(keep, " · ")
	if len(out) > 240 {
		out = out[:240] + "…"
	}
	return Humanize(out)
}
