package chain

import "testing"

func TestDiagnoseKeyring(t *testing.T) {
	c := New("structsd", []string{"--home", t.TempDir()}, nil)
	cases := []struct {
		name, stderr string
		withPass     bool
		haveKeys     bool
		want         KeyringState
	}{
		{"file keyring, no passphrase (structsd exits 0 with [])", "EOF\nEOF\nEOF\nmigrate err for key x.info: \"too many failed passphrase attempts\"", false, false, KeyringLocked},
		{"file keyring, wrong passphrase", "migrate err for key x.info: \"too many failed passphrase attempts\"", true, false, KeyringWrongPass},
		{"macOS keychain over SSH", "User interaction is not allowed.", false, false, KeyringOSLocked},
		{"linux, no secret service", "The name org.freedesktop.secrets was not provided by any .service files", false, false, KeyringOSLocked},
		{"clean", "", false, true, KeyringOK},
		{"empty but fine", "", false, false, KeyringOK},
	}
	for _, tc := range cases {
		if tc.withPass {
			c.SetPassphrase("x")
		} else {
			c.SetPassphrase("")
		}
		got, hint := c.diagnose(tc.stderr, tc.haveKeys)
		if got != tc.want {
			t.Errorf("%s: state %d, want %d", tc.name, got, tc.want)
		}
		if got != KeyringOK && hint == "" {
			t.Errorf("%s: no hint", tc.name)
		}
	}
}

func TestPassphraseFedOnStdin(t *testing.T) {
	c := New("structsd", []string{"--home", t.TempDir()}, nil)
	if c.keyStdin() != "" {
		t.Fatal("no passphrase should mean empty stdin")
	}
	c.SetPassphrase("pw")
	if c.keyStdin() != "pw\npw\npw\n" {
		t.Fatalf("got %q", c.keyStdin())
	}
}
