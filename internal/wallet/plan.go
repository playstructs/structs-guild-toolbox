package wallet

import (
	"fmt"
	"sort"

	"github.com/playstructs/structs-guild-toolbox/internal/chain"
)

// Draw takes Amount from Address.
type Draw struct {
	Address string
	Amount  chain.Int
}

func sumDraws(d []Draw) chain.Int {
	t := chain.NewInt(0)
	for _, x := range d {
		t = t.Add(x.Amount)
	}
	return t
}

// spendOrder: vault first (where the game puts funds), then the primary,
// then other addresses by balance.
func (a *Account) spendOrder(denom string) []*Source {
	out := append([]*Source{}, a.Sources...)
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].Kind != out[j].Kind {
			return out[i].Kind < out[j].Kind
		}
		return out[i].Balance(denom).Cmp(out[j].Balance(denom)) > 0
	})
	return out
}

// PlanLiquid picks liquid balances to cover amt. only restricts to one
// source; exclude skips one (the recipient, for internal moves).
func (a *Account) PlanLiquid(denom string, amt chain.Amount, only, exclude string) ([]Draw, error) {
	var cands []Draw
	avail := chain.NewInt(0)
	for _, s := range a.spendOrder(denom) {
		if (only != "" && s.Address != only) || s.Address == exclude {
			continue
		}
		b := s.Balance(denom)
		if b.Sign() > 0 {
			cands = append(cands, Draw{s.Address, b})
			avail = avail.Add(b)
		}
	}
	want := amt.Value
	if amt.All {
		want = avail
	}
	if want.Sign() <= 0 {
		return nil, fmt.Errorf("nothing to move: %s available", chain.Format(avail, denom))
	}
	if avail.Cmp(want) < 0 {
		where := ""
		if only != "" {
			where = " in " + a.Label(only)
		}
		return nil, fmt.Errorf("not enough: need %s, %s available%s", chain.Format(want, denom), chain.Format(avail, denom), where)
	}
	return take(cands, want), nil
}

// PlanDelegation picks delegations to validator, largest first.
func (a *Account) PlanDelegation(validator string, amt chain.Amount, only string) ([]Draw, error) {
	var cands []Draw
	avail := chain.NewInt(0)
	for _, s := range a.Sources {
		if only != "" && s.Address != only {
			continue
		}
		for _, d := range s.Delegations {
			if d.Validator == validator {
				cands = append(cands, Draw{s.Address, d.Amount})
				avail = avail.Add(d.Amount)
			}
		}
	}
	sort.SliceStable(cands, func(i, j int) bool { return cands[i].Amount.Cmp(cands[j].Amount) > 0 })
	want := amt.Value
	if amt.All {
		want = avail
	}
	if want.Sign() <= 0 {
		return nil, fmt.Errorf("nothing is delegated to that validator")
	}
	if avail.Cmp(want) < 0 {
		return nil, fmt.Errorf("only %s is delegated there", chain.Format(avail, chain.Alpha))
	}
	return take(cands, want), nil
}

func take(cands []Draw, want chain.Int) []Draw {
	var out []Draw
	rem := want
	for _, c := range cands {
		if rem.Sign() <= 0 {
			break
		}
		t := chain.MinInt(c.Amount, rem)
		out = append(out, Draw{c.Address, t})
		rem = rem.Sub(t)
	}
	return out
}

// ---------------------------------------------------------------- plans

// Step is one human-readable line of a plan.
type Step struct {
	Amount string // "0.5 alpha"
	Text   string // "from Player Vault"
	Detail string // address
}

// Plan is everything the UI needs to show and execute an action.
type Plan struct {
	Title    string
	Subtitle []string
	Steps    []Step
	Notes    []string
	Warnings []string
	Msgs     []chain.Msg
}

func (p *Plan) steps(a *Account, draws []Draw, denom, verb string) {
	for _, d := range draws {
		p.Steps = append(p.Steps, Step{Amount: chain.Format(d.Amount, denom), Text: verb + " " + a.Label(d.Address), Detail: d.Address})
	}
}
