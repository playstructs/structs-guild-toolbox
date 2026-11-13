package chain

import (
	"strings"
	"testing"
)

func TestValidateAccountAddress(t *testing.T) {
	cases := map[string]string{ // address -> substring of the expected error ("" = valid)
		"structs1nl4lq3m95cmtkqg9nppxu06ll0f96xvyynagxs":        "",
		"STRUCTS1NL4LQ3M95CMTKQG9NPPXU06LL0F96XVYYNAGXS":        "",
		"structs10j3h5e54y4at2wkzjgcext6dnmshuusgxmlmdr":        "", // a player vault
		"structs1nl4lq3m95cmtkqg9nppxu06ll0f96xvyynagxt":        "typo",
		"structs1nl4lq3m95cmtkqg9nppxu06ll0f96xvyynagx":         "typo",
		"structsvaloper1fz6cxatcuk9dkmdks9zun9rpn66g93et7anm64": "validator operator",
		"cosmos1nl4lq3m95cmtkqg9nppxu06ll0f96xvyynagxs":         "not a valid address",
		"structs1nl4lq3m95cmtkqg9nppxu06ll0f96xvyynagxb":        "not a valid address character", // b, i, o are never used
		"structs1Nl4lq3m95cmtkqg9nppxu06ll0f96xvyynagxs":        "mixed",
	}
	for addr, want := range cases {
		err := ValidateAccountAddress(addr)
		switch {
		case want == "" && err != nil:
			t.Errorf("%s: unexpected error %v", addr, err)
		case want != "" && (err == nil || !strings.Contains(err.Error(), want)):
			t.Errorf("%s: got %v, want error containing %q", addr, err, want)
		}
	}
}
