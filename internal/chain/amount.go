package chain

import (
	"encoding/json"
	"fmt"
	"math/big"
	"regexp"
	"strings"
)

// Int is an arbitrary-precision integer that unmarshals from JSON strings or
// numbers (Cosmos encodes amounts as strings). Guild token supplies can exceed
// 2^53, so never round-trip amounts through float64.
type Int struct{ v *big.Int }

func NewInt(i int64) Int        { return Int{big.NewInt(i)} }
func IntFromBig(b *big.Int) Int { return Int{new(big.Int).Set(b)} }
func (i Int) Big() *big.Int     { return new(big.Int).Set(i.b()) }
func (i Int) b() *big.Int {
	if i.v == nil {
		return big.NewInt(0)
	}
	return i.v
}
func (i Int) String() string { return i.b().String() }
func (i Int) IsZero() bool   { return i.b().Sign() == 0 }
func (i Int) Sign() int      { return i.b().Sign() }
func (i Int) Cmp(o Int) int  { return i.b().Cmp(o.b()) }
func (i Int) Add(o Int) Int  { return Int{new(big.Int).Add(i.b(), o.b())} }
func (i Int) Sub(o Int) Int  { return Int{new(big.Int).Sub(i.b(), o.b())} }
func (i Int) Mul(o Int) Int  { return Int{new(big.Int).Mul(i.b(), o.b())} }
func (i Int) Quo(o Int) Int {
	if o.IsZero() {
		return NewInt(0)
	}
	return Int{new(big.Int).Quo(i.b(), o.b())}
}
func (i Int) Uint64() uint64 { return i.b().Uint64() }
func MinInt(a, b Int) Int {
	if a.Cmp(b) <= 0 {
		return a
	}
	return b
}

func ParseInt(s string) (Int, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return NewInt(0), nil
	}
	// decimals such as reward amounts "74.1037"; truncate
	if dot := strings.IndexByte(s, '.'); dot >= 0 {
		s = s[:dot]
		if s == "" {
			s = "0"
		}
	}
	v, ok := new(big.Int).SetString(s, 10)
	if !ok {
		return Int{}, fmt.Errorf("not an integer: %q", s)
	}
	return Int{v}, nil
}

func MustInt(s string) Int {
	i, err := ParseInt(s)
	if err != nil {
		panic(err)
	}
	return i
}

func (i *Int) UnmarshalJSON(b []byte) error {
	var s string
	if len(b) > 0 && b[0] == '"' {
		if err := json.Unmarshal(b, &s); err != nil {
			return err
		}
	} else {
		s = string(b)
	}
	if s == "null" {
		*i = NewInt(0)
		return nil
	}
	v, err := ParseInt(s)
	if err != nil {
		return err
	}
	*i = v
	return nil
}

func (i Int) MarshalJSON() ([]byte, error) { return json.Marshal(i.String()) }

// Coin is a denom + amount.
type Coin struct {
	Denom  string `json:"denom"`
	Amount Int    `json:"amount"`
}

func (c Coin) String() string { return c.Amount.String() + c.Denom }

const Alpha = "ualpha"

// HasMicroUnits reports whether a denom is displayed with 6 decimals.
func HasMicroUnits(denom string) bool {
	return denom == Alpha || strings.HasPrefix(denom, "uguild.")
}

// DisplayDenom: ualpha -> alpha, uguild.0-3 -> guild.0-3
func DisplayDenom(denom string) string {
	if HasMicroUnits(denom) {
		return strings.TrimPrefix(denom, "u")
	}
	return denom
}

// FormatAmount renders a base amount with grouping: 2161000259 -> "2,161.000259".
func FormatAmount(a Int, denom string) string {
	if !HasMicroUnits(denom) {
		return group(a.String())
	}
	neg := a.Sign() < 0
	v := new(big.Int).Abs(a.b())
	whole, frac := new(big.Int).QuoRem(v, big.NewInt(1_000_000), new(big.Int))
	s := group(whole.String())
	if frac.Sign() != 0 {
		s += "." + strings.TrimRight(fmt.Sprintf("%06d", frac.Int64()), "0")
	}
	if neg {
		s = "-" + s
	}
	return s
}

// Format renders amount + display denom: "2,161.000259 alpha".
func Format(a Int, denom string) string { return FormatAmount(a, denom) + " " + DisplayDenom(denom) }

func group(s string) string {
	if len(s) <= 3 {
		return s
	}
	var b strings.Builder
	pre := len(s) % 3
	if pre > 0 {
		b.WriteString(s[:pre])
	}
	for i := pre; i < len(s); i += 3 {
		if b.Len() > 0 {
			b.WriteByte(',')
		}
		b.WriteString(s[i : i+3])
	}
	return b.String()
}

var amountRe = regexp.MustCompile(`^([0-9][0-9,_]*)(?:\.([0-9]+))?([a-zA-Z][a-zA-Z0-9./-]*)?$`)

// Amount is a parsed user amount. All means "everything available".
type Amount struct {
	Value Int
	Denom string
	All   bool
}

// ParseAmount understands:
//
//	2.5alpha | 2.5 alpha | 2500000ualpha | 10guild.0-3 | 500uguild.0-3
//	1000 (base units of defaultDenom) | all | all guild.0-3 | 25%
func ParseAmount(raw, defaultDenom string) (Amount, error) {
	s := strings.ReplaceAll(strings.TrimSpace(raw), " ", "")
	if s == "" {
		return Amount{}, fmt.Errorf("missing amount")
	}
	if strings.HasPrefix(strings.ToLower(s), "all") || s == "max" {
		d := strings.TrimPrefix(strings.TrimPrefix(strings.ToLower(s), "all"), "max")
		return Amount{All: true, Denom: normalizeDenom(d, defaultDenom)}, nil
	}
	m := amountRe.FindStringSubmatch(s)
	if m == nil {
		return Amount{}, fmt.Errorf("could not read amount %q (try 2.5alpha, 2500000ualpha or all)", raw)
	}
	intPart := strings.NewReplacer(",", "", "_", "").Replace(m[1])
	dec, unit := m[2], m[3]
	denom := normalizeDenom(unit, defaultDenom)
	// "2.5alpha" and a bare "2.5" are display units; "2500000" and "2500000ualpha" are base units
	displayUnit := (unit != "" && !strings.HasPrefix(unit, "u")) || (unit == "" && dec != "")
	if displayUnit && HasMicroUnits(denom) {
		if len(dec) > 6 {
			return Amount{}, fmt.Errorf("%q has more than 6 decimal places", raw)
		}
		dec += strings.Repeat("0", 6-len(dec))
		v, err := ParseInt(intPart + dec)
		return Amount{Value: v, Denom: denom}, err
	}
	if dec != "" {
		return Amount{}, fmt.Errorf("%s amounts are whole numbers (use %s for decimals)", denom, DisplayDenom(denom))
	}
	v, err := ParseInt(intPart)
	return Amount{Value: v, Denom: denom}, err
}

func normalizeDenom(unit, def string) string {
	u := strings.TrimSpace(unit)
	switch {
	case u == "":
		return def
	case u == "alpha" || u == "a" || u == "α":
		return Alpha
	case strings.HasPrefix(u, "guild."):
		return "u" + u
	}
	return u
}
