// Package wallet models a Structs player account as one wallet.
//
// A player account is the Player Vault plus every registered address. Any
// registered key can spend from any of them (player-send, reactor-infuse
// --delegator-address, ...). Account loads all of them, and the planners
// decide which sources to draw from.
package wallet

import (
	"context"
	"fmt"
	"sort"
	"sync"
	"time"

	"github.com/playstructs/structs-guild-toolbox/internal/chain"
)

type Kind int

const (
	KindVault Kind = iota
	KindPrimary
	KindAddress
)

func (k Kind) String() string {
	switch k {
	case KindVault:
		return "Player Vault"
	case KindPrimary:
		return "Primary wallet"
	}
	return "Wallet"
}

type Source struct {
	Address     string
	Kind        Kind
	Local       bool // the key is in this machine's keyring
	Permissions string
	Balances    map[string]chain.Int
	Delegations []chain.Delegation
	Unbondings  []chain.Unbonding
	Rewards     chain.Int
}

func (s *Source) Balance(denom string) chain.Int { return s.Balances[denom] }

func (s *Source) Label() string {
	if s.Kind == KindAddress {
		return "Wallet " + Short(s.Address)
	}
	return s.Kind.String()
}

func Short(a string) string {
	if len(a) < 20 {
		return a
	}
	return a[:12] + "…" + a[len(a)-6:]
}

type Account struct {
	PlayerID string
	Player   chain.PlayerDetail
	Vault    string
	Primary  string
	Sources  []*Source
	LoadedAt time.Time
}

func (a *Account) Name() string    { return a.Player.Player.Name }
func (a *Account) GuildID() string { return a.Player.Player.GuildID }

// ResolvePlayer turns a player id or registered address into a player id.
func ResolvePlayer(ctx context.Context, c *chain.Client, target string) (string, error) {
	switch {
	case chain.IsPlayerID(target):
		return target, nil
	case chain.IsAddress(target):
		p, err := c.PlayerOfAddress(ctx, target)
		if err != nil {
			return "", err
		}
		if p == "" {
			return "", fmt.Errorf("%s is not registered to a player (vault addresses can't be looked up yet — use the player id)", Short(target))
		}
		return p, nil
	}
	return "", fmt.Errorf("%q is not a player id (1-N) or structs1… address", target)
}

// Load fetches the whole account concurrently.
func Load(ctx context.Context, c *chain.Client, target string, localKeys map[string]bool) (*Account, error) {
	pid, err := ResolvePlayer(ctx, c, target)
	if err != nil {
		return nil, err
	}
	acct := &Account{PlayerID: pid}
	var addrs []chain.AddressRecord
	var errP, errV, errA error
	var wg sync.WaitGroup
	wg.Add(3)
	go func() { defer wg.Done(); acct.Player, errP = c.Player(ctx, pid) }()
	go func() { defer wg.Done(); acct.Vault, errV = c.Vault(ctx, pid) }()
	go func() { defer wg.Done(); addrs, errA = c.PlayerAddresses(ctx, pid) }()
	wg.Wait()
	if errP != nil || acct.Player.Player.ID == "" {
		return nil, fmt.Errorf("player %s not found", pid)
	}
	if errV != nil {
		acct.Vault = "" // older chains: no vault
	}
	if errA != nil {
		return nil, fmt.Errorf("listing addresses for %s: %w", pid, errA)
	}
	acct.Primary = acct.Player.Player.PrimaryAddress

	if acct.Vault != "" {
		acct.Sources = append(acct.Sources, &Source{Address: acct.Vault, Kind: KindVault})
	}
	seen := map[string]bool{acct.Vault: true}
	add := func(addr, perms string, k Kind) {
		if addr == "" || seen[addr] {
			return
		}
		seen[addr] = true
		acct.Sources = append(acct.Sources, &Source{Address: addr, Kind: k, Permissions: perms})
	}
	for _, r := range addrs {
		if r.Address == acct.Primary {
			add(r.Address, r.Permissions, KindPrimary)
		}
	}
	add(acct.Primary, "", KindPrimary)
	for _, r := range addrs {
		add(r.Address, r.Permissions, KindAddress)
	}

	errs := make([]error, len(acct.Sources))
	for i, s := range acct.Sources {
		s.Local = localKeys[s.Address]
		s.Balances = map[string]chain.Int{}
		wg.Add(4)
		go func(i int, s *Source) {
			defer wg.Done()
			coins, err := c.Balances(ctx, s.Address)
			if err != nil {
				errs[i] = err
			}
			for _, cn := range coins {
				s.Balances[cn.Denom] = cn.Amount
			}
		}(i, s)
		go func(s *Source) { defer wg.Done(); s.Delegations, _ = c.Delegations(ctx, s.Address) }(s)
		go func(s *Source) { defer wg.Done(); s.Unbondings, _ = c.Unbondings(ctx, s.Address) }(s)
		go func(s *Source) { defer wg.Done(); s.Rewards, _ = c.Rewards(ctx, s.Address) }(s)
	}
	wg.Wait()
	for _, e := range errs {
		if e != nil {
			return nil, e
		}
	}
	acct.LoadedAt = time.Now()
	return acct, nil
}

// ---------------------------------------------------------------- totals

func (a *Account) Liquid(denom string) chain.Int {
	t := chain.NewInt(0)
	for _, s := range a.Sources {
		t = t.Add(s.Balance(denom))
	}
	return t
}

func (a *Account) Delegated() chain.Int {
	t := chain.NewInt(0)
	for _, s := range a.Sources {
		for _, d := range s.Delegations {
			t = t.Add(d.Amount)
		}
	}
	return t
}

func (a *Account) Unbonding() chain.Int {
	t := chain.NewInt(0)
	for _, s := range a.Sources {
		for _, u := range s.Unbondings {
			t = t.Add(u.Balance)
		}
	}
	return t
}

func (a *Account) Rewards() chain.Int {
	t := chain.NewInt(0)
	for _, s := range a.Sources {
		t = t.Add(s.Rewards)
	}
	return t
}

// Total alpha: available + delegated + defusing.
func (a *Account) Total() chain.Int {
	return a.Liquid(chain.Alpha).Add(a.Delegated()).Add(a.Unbonding())
}

// Denoms lists every token held, alpha first.
func (a *Account) Denoms() []string {
	set := map[string]bool{}
	for _, s := range a.Sources {
		for d, v := range s.Balances {
			if !v.IsZero() {
				set[d] = true
			}
		}
	}
	out := []string{chain.Alpha}
	delete(set, chain.Alpha)
	var rest []string
	for d := range set {
		rest = append(rest, d)
	}
	sort.Strings(rest)
	return append(out, rest...)
}

func (a *Account) Source(addr string) *Source {
	for _, s := range a.Sources {
		if s.Address == addr {
			return s
		}
	}
	return nil
}

// Label names an address relative to this account.
func (a *Account) Label(addr string) string {
	if s := a.Source(addr); s != nil {
		return s.Label()
	}
	return Short(addr)
}

// SourceBySelector resolves "vault", "primary" or an address of this account.
func (a *Account) SourceBySelector(sel string) (*Source, error) {
	switch sel {
	case "vault":
		sel = a.Vault
	case "primary":
		sel = a.Primary
	}
	if s := a.Source(sel); s != nil {
		return s, nil
	}
	return nil, fmt.Errorf("%q is not part of player %s (use vault, primary or one of its addresses)", sel, a.PlayerID)
}

// ---------------------------------------------------------------- staking views

type StakePart struct {
	Address string
	Amount  chain.Int
}

type Stake struct {
	Validator string
	Total     chain.Int
	Parts     []StakePart
}

// Stakes groups delegations by validator, largest first.
func (a *Account) Stakes() []Stake {
	idx := map[string]*Stake{}
	var order []string
	for _, s := range a.Sources {
		for _, d := range s.Delegations {
			st, ok := idx[d.Validator]
			if !ok {
				st = &Stake{Validator: d.Validator, Total: chain.NewInt(0)}
				idx[d.Validator] = st
				order = append(order, d.Validator)
			}
			st.Total = st.Total.Add(d.Amount)
			st.Parts = append(st.Parts, StakePart{Address: s.Address, Amount: d.Amount})
		}
	}
	out := make([]Stake, 0, len(order))
	for _, v := range order {
		out = append(out, *idx[v])
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Total.Cmp(out[j].Total) > 0 })
	return out
}

type Defusion struct {
	N       int
	Address string
	chain.Unbonding
}

// Defusions lists in-progress unbondings, soonest first, numbered from 1.
func (a *Account) Defusions() []Defusion {
	var out []Defusion
	for _, s := range a.Sources {
		for _, u := range s.Unbondings {
			out = append(out, Defusion{Address: s.Address, Unbonding: u})
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Completion.Before(out[j].Completion) })
	for i := range out {
		out[i].N = i + 1
	}
	return out
}
