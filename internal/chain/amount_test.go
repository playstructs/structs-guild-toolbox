package chain

import "testing"

func TestParseAmount(t *testing.T) {
	cases := []struct {
		in, val, denom string
		all            bool
		err            bool
	}{
		{"2.5alpha", "2500000", "ualpha", false, false},
		{"2.5 alpha", "2500000", "ualpha", false, false},
		{"2.5", "2500000", "ualpha", false, false},
		{"2500000ualpha", "2500000", "ualpha", false, false},
		{"1000", "1000", "ualpha", false, false},
		{"1,000alpha", "1000000000", "ualpha", false, false},
		{"10guild.0-3", "10000000", "uguild.0-3", false, false},
		{"500uguild.0-3", "500", "uguild.0-3", false, false},
		{"0.000001alpha", "1", "ualpha", false, false},
		{"all", "", "ualpha", true, false},
		{"all guild.0-3", "", "uguild.0-3", true, false},
		{"1.1234567alpha", "", "", false, true},
		{"1.5ualpha", "", "", false, true},
		{"abc", "", "", false, true},
	}
	for _, c := range cases {
		a, err := ParseAmount(c.in, Alpha)
		if c.err {
			if err == nil {
				t.Errorf("%q: expected error", c.in)
			}
			continue
		}
		if err != nil {
			t.Errorf("%q: %v", c.in, err)
			continue
		}
		if a.All != c.all || a.Denom != c.denom || (!c.all && a.Value.String() != c.val) {
			t.Errorf("%q: got %+v (%s)", c.in, a, a.Value)
		}
	}
}

func TestFormat(t *testing.T) {
	for in, want := range map[string]string{"2161000259": "2,161.000259 alpha", "4000000": "4 alpha", "1": "0.000001 alpha", "0": "0 alpha"} {
		if got := Format(MustInt(in), Alpha); got != want {
			t.Errorf("%s: got %q want %q", in, got, want)
		}
	}
}

func TestHumanize(t *testing.T) {
	in := "rpc error: code = Unknown desc = failed to execute message; message index: 1: spendable balance 0ualpha is smaller than 1ualpha: insufficient funds [cosmos/cosmos-sdk@v0.53.8/x/bank/keeper/send.go:298] with gas used: '85170'"
	if got := Humanize(in); got != "step 2: spendable balance 0ualpha is smaller than 1ualpha: insufficient funds" {
		t.Errorf("got %q", got)
	}
}
