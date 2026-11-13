package chain

import (
	"errors"
	"fmt"
	"strings"
)

// Bech32 checksum verification (BIP-173), so a mistyped recipient is caught
// before anything is built or simulated.

const bech32Charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

func bech32Polymod(values []int) int {
	gen := []int{0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3}
	chk := 1
	for _, v := range values {
		top := chk >> 25
		chk = (chk&0x1ffffff)<<5 ^ v
		for i := 0; i < 5; i++ {
			if (top>>uint(i))&1 == 1 {
				chk ^= gen[i]
			}
		}
	}
	return chk
}

func bech32HRPExpand(hrp string) []int {
	out := make([]int, 0, len(hrp)*2+1)
	for _, c := range hrp {
		out = append(out, int(c)>>5)
	}
	out = append(out, 0)
	for _, c := range hrp {
		out = append(out, int(c)&31)
	}
	return out
}

// DecodeBech32 checks a bech32 string and returns its human-readable part.
func DecodeBech32(s string) (hrp string, err error) {
	if strings.ToLower(s) != s && strings.ToUpper(s) != s {
		return "", errors.New("mixed upper and lower case")
	}
	s = strings.ToLower(s)
	pos := strings.LastIndexByte(s, '1')
	if pos < 1 || pos+7 > len(s) {
		return "", errors.New("not a bech32 address")
	}
	hrp = s[:pos]
	data := make([]int, 0, len(s)-pos-1)
	for _, c := range s[pos+1:] {
		d := strings.IndexRune(bech32Charset, c)
		if d < 0 {
			return "", fmt.Errorf("%q is not a valid address character", c)
		}
		data = append(data, d)
	}
	if bech32Polymod(append(bech32HRPExpand(hrp), data...)) != 1 {
		return hrp, errors.New("checksum does not match")
	}
	return hrp, nil
}

// ValidateAccountAddress accepts a structs1… account address with a correct
// checksum, and explains what is wrong otherwise.
func ValidateAccountAddress(s string) error {
	hrp, err := DecodeBech32(s)
	switch {
	case err != nil && hrp == "structs":
		return fmt.Errorf("%s has a typo: its checksum does not match (check every character)", s)
	case err != nil:
		return fmt.Errorf("%q is not a valid address: %v", s, err)
	case hrp == "structsvaloper":
		return fmt.Errorf("that is a validator operator address — to stake, use /delegate %s <amount>", s)
	case hrp == "structsvalcons":
		return fmt.Errorf("that is a validator consensus address, which cannot receive funds")
	case hrp != "structs":
		return fmt.Errorf("%s is a %q address, not a Structs (structs1…) address", s, hrp)
	}
	return nil
}
