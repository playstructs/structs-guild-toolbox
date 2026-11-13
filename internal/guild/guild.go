// Package guild loads a guild's state and builds guild admin plans.
package guild

import (
	"context"
	"fmt"
	"sort"
	"sync"

	"github.com/playstructs/structs-guild-toolbox/internal/chain"
	"github.com/playstructs/structs-guild-toolbox/internal/wallet"
)

type View struct {
	Guild         chain.Guild
	Vault         string
	VaultBalances map[string]chain.Int
	Bank          *wallet.BankState
	Reactor       *chain.Validator
	Entry         chain.Substation
	Pending       []chain.Application
	Providers     []chain.Provider
	IsOwner       bool
}

func Load(ctx context.Context, c *chain.Client, guildID, playerID string, vals map[string]*chain.Validator) (*View, error) {
	g, err := c.Guild(ctx, guildID)
	if err != nil || g.ID == "" {
		return nil, fmt.Errorf("guild %s not found", guildID)
	}
	v := &View{Guild: g, IsOwner: g.Owner == playerID, VaultBalances: map[string]chain.Int{}}
	for _, r := range vals {
		if r.ReactorID == g.PrimaryReactorID {
			v.Reactor = r
		}
	}
	var wg sync.WaitGroup
	wg.Add(5)
	go func() {
		defer wg.Done()
		if vault, err := c.Vault(ctx, guildID); err == nil {
			v.Vault = vault
			coins, _ := c.Balances(ctx, vault)
			for _, cn := range coins {
				v.VaultBalances[cn.Denom] = cn.Amount
			}
		}
	}()
	go func() { defer wg.Done(); v.Bank, _ = wallet.LoadBank(ctx, c, guildID) }()
	go func() { defer wg.Done(); v.Entry, _ = c.Substation(ctx, g.EntrySubstationID) }()
	go func() {
		defer wg.Done()
		apps, _ := c.Applications(ctx)
		for _, a := range apps {
			if a.GuildID == guildID && a.Status() == "proposed" {
				v.Pending = append(v.Pending, a)
			}
		}
	}()
	go func() {
		defer wg.Done()
		ps, _ := c.Providers(ctx)
		for _, p := range ps {
			if p.Owner == guildID || p.Owner == playerID {
				v.Providers = append(v.Providers, p)
			}
		}
	}()
	wg.Wait()
	return v, nil
}

// Members scans every player (slow: one pass over player-all).
func Members(ctx context.Context, c *chain.Client, guildID string) ([]chain.Player, error) {
	all, err := c.Players(ctx)
	if err != nil {
		return nil, err
	}
	var out []chain.Player
	for _, p := range all {
		if p.GuildID == guildID {
			out = append(out, p)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		var a, b int
		fmt.Sscan(out[i].GuildRank, &a)
		fmt.Sscan(out[j].GuildRank, &b)
		if a != b {
			return a < b
		}
		return out[i].ID < out[j].ID
	})
	return out, nil
}

func one(title string, msg chain.Msg, notes ...string) *wallet.Plan {
	return &wallet.Plan{Title: title, Msgs: []chain.Msg{msg}, Notes: notes}
}

func (v *View) pending(playerID string) *chain.Application {
	for i := range v.Pending {
		if v.Pending[i].PlayerID == playerID {
			return &v.Pending[i]
		}
	}
	return nil
}

func Invite(v *View, player string) (*wallet.Plan, error) {
	if !chain.IsPlayerID(player) {
		return nil, fmt.Errorf("invite takes a player id (1-N)")
	}
	p := one("Invite "+player+" to "+v.Guild.ID, chain.Msg{"structs", "guild-membership-invite", player})
	if v.Guild.BypassByInvite == "closed" {
		p.Warnings = append(p.Warnings, "This guild's invite bypass is closed — the chain may reject invites until it is opened.")
	}
	return p, nil
}

// Approve accepts a join request.
func Approve(v *View, player string) (*wallet.Plan, error) {
	a := v.pending(player)
	if a == nil {
		return nil, fmt.Errorf("%s has no pending application to %s", player, v.Guild.ID)
	}
	if a.Type() != "request" {
		return nil, fmt.Errorf("%s's application is an invite you sent; they accept it (or /revoke it)", player)
	}
	return one("Approve "+player+"'s request to join", chain.Msg{"structs", "guild-membership-request-approve", player, "--guild-id", v.Guild.ID}), nil
}

// Deny rejects a join request, or revokes an invite we sent.
func Deny(v *View, player string) (*wallet.Plan, error) {
	a := v.pending(player)
	if a == nil {
		return nil, fmt.Errorf("%s has no pending application to %s", player, v.Guild.ID)
	}
	if a.Type() == "request" {
		return one("Deny "+player+"'s request to join", chain.Msg{"structs", "guild-membership-request-deny", player, "--guild-id", v.Guild.ID}), nil
	}
	return one("Revoke the invite to "+player, chain.Msg{"structs", "guild-membership-invite-revoke", v.Guild.ID, player}), nil
}

func Kick(v *View, player string) (*wallet.Plan, error) {
	if !chain.IsPlayerID(player) {
		return nil, fmt.Errorf("kick takes a player id (1-N)")
	}
	return one("Kick "+player+" from "+v.Guild.ID, chain.Msg{"structs", "guild-membership-kick", player, "--guild-id", v.Guild.ID}), nil
}

// Mint spends guild-vault treasury alpha as collateral and mints tokens into the guild vault.
func Mint(v *View, alpha, tokens string) (*wallet.Plan, error) {
	a, err := chain.ParseAmount(alpha, chain.Alpha)
	if err != nil {
		return nil, err
	}
	denom := "uguild." + v.Guild.ID
	t, err := chain.ParseAmount(tokens, denom)
	if err != nil {
		return nil, err
	}
	if t.Denom == chain.Alpha {
		t.Denom = denom
	}
	if have := v.VaultBalances[chain.Alpha]; have.Cmp(a.Value) < 0 {
		return nil, fmt.Errorf("the guild treasury holds %s; send alpha to the guild vault (/send %s <amount>) first", chain.Format(have, chain.Alpha), v.Guild.ID)
	}
	p := &wallet.Plan{
		Title:    "Mint " + chain.Format(t.Value, denom),
		Subtitle: []string{"backed by " + chain.Format(a.Value, chain.Alpha) + " of guild treasury"},
		Steps: []wallet.Step{
			{Amount: chain.Format(a.Value, chain.Alpha), Text: "guild vault → collateral pool"},
			{Amount: chain.Format(t.Value, denom), Text: "minted into the guild vault"},
		},
		Msgs: []chain.Msg{{"structs", "guild-bank-mint", a.Value.String(), t.Value.String(), "--guild-id", v.Guild.ID}},
	}
	return p, nil
}

func WithdrawProvider(provider, dest string) (*wallet.Plan, error) {
	if !chain.IsProviderID(provider) {
		return nil, fmt.Errorf("provider ids look like 10-N")
	}
	return one("Withdraw "+provider+" earnings", chain.Msg{"structs", "provider-withdraw-balance", provider, dest}, "Earnings go to "+wallet.Short(dest)+"."), nil
}
