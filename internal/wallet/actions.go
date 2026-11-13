package wallet

import (
	"context"
	"fmt"
	"math/big"
	"strings"

	"github.com/playstructs/structs-guild-toolbox/internal/chain"
)

// SlippageBps is how much worse than the live quote a guild bank conversion
// may settle (100 = 1%).
var SlippageBps int64 = 100

// Builder turns user intents into plans for one account.
type Builder struct {
	C    *chain.Client
	A    *Account
	Vals map[string]*chain.Validator
}

// ResolveValidator accepts a valoper address, reactor id (3-N), the player
// id that owns a reactor, a guild id (its primary reactor) or a moniker.
func ResolveValidator(ctx context.Context, c *chain.Client, vals map[string]*chain.Validator, t string) (*chain.Validator, error) {
	t = strings.TrimSpace(t)
	if v, ok := vals[t]; ok {
		return v, nil
	}
	if chain.IsGuildID(t) {
		g, err := c.Guild(ctx, t)
		if err != nil || g.PrimaryReactorID == "" {
			return nil, fmt.Errorf("guild %s has no primary reactor", t)
		}
		t = g.PrimaryReactorID
	}
	for _, v := range vals {
		switch {
		case chain.IsReactorID(t) && v.ReactorID == t,
			chain.IsPlayerID(t) && v.Owner == t,
			!chain.IsPlayerID(t) && !chain.IsReactorID(t) && strings.EqualFold(v.Moniker, t):
			return v, nil
		}
	}
	return nil, fmt.Errorf("no validator matches %q (reactor id 3-N, owner 1-N, guild 0-N, moniker or valoper)", t)
}

func (b *Builder) validator(ctx context.Context, t string) (*chain.Validator, error) {
	return ResolveValidator(ctx, b.C, b.Vals, t)
}

func (b *Builder) only(sel string) (string, error) {
	if sel == "" {
		return "", nil
	}
	s, err := b.A.SourceBySelector(sel)
	if err != nil {
		return "", err
	}
	return s.Address, nil
}

// Recipient is a resolved send destination.
type Recipient struct {
	Address string
	Label   string // "Player Vault of 1-186", "wallet of player 1-186", "external address"
	Notes   []string
}

// ResolveRecipient accepts any structs1… account address (players or not),
// a player id (-> that player's vault) or a guild id (-> the guild vault).
func ResolveRecipient(ctx context.Context, c *chain.Client, to string) (Recipient, error) {
	to = strings.TrimSpace(to)
	switch {
	case chain.IsPlayerID(to):
		v, err := c.Vault(ctx, to)
		if err != nil || v == "" {
			return Recipient{}, fmt.Errorf("player %s has no vault", to)
		}
		return Recipient{Address: v, Label: "Player Vault of " + to,
			Notes: []string{"To pay one of their addresses instead, give the structs1… address."}}, nil
	case chain.IsGuildID(to):
		v, err := c.Vault(ctx, to)
		if err != nil || v == "" {
			return Recipient{}, fmt.Errorf("guild %s has no vault", to)
		}
		return Recipient{Address: v, Label: "Guild Vault of " + to}, nil
	case strings.HasPrefix(strings.ToLower(to), "structs"):
		if err := chain.ValidateAccountAddress(to); err != nil {
			return Recipient{}, err
		}
		addr := strings.ToLower(to)
		r := Recipient{Address: addr}
		if pid, _ := c.PlayerOfAddress(ctx, addr); pid != "" {
			r.Label = "a registered address of player " + pid
			if p, err := c.Player(ctx, pid); err == nil && p.Player.PrimaryAddress == addr {
				r.Label = "Primary wallet of player " + pid
			}
			return r, nil
		}
		r.Label = "not a player address (an external account or a vault)"
		if !c.AccountExists(ctx, addr) {
			r.Label = "new address — never used on chain"
			r.Notes = append(r.Notes, "This address has no history. That's normal for a fresh wallet; otherwise double-check it — sends can't be undone.")
		}
		return r, nil
	}
	return Recipient{}, fmt.Errorf("recipient must be a structs1… address, a player id (1-N) or a guild id (0-N)")
}

// Send spends from the whole account.
func (b *Builder) Send(ctx context.Context, to, amount, fromSel string) (*Plan, error) {
	rcpt, err := ResolveRecipient(ctx, b.C, to)
	if err != nil {
		return nil, err
	}
	addr := rcpt.Address
	amt, err := chain.ParseAmount(amount, chain.Alpha)
	if err != nil {
		return nil, err
	}
	only, err := b.only(fromSel)
	if err != nil {
		return nil, err
	}
	draws, err := b.A.PlanLiquid(amt.Denom, amt, only, addr)
	if err != nil {
		return nil, err
	}
	p := &Plan{Title: "Send " + chain.Format(sumDraws(draws), amt.Denom)}
	p.Subtitle = append(p.Subtitle, "to "+addr)
	if own := b.A.Source(addr); own == nil && rcpt.Label != "" {
		p.Subtitle = append(p.Subtitle, rcpt.Label)
	}
	p.Notes = append(p.Notes, rcpt.Notes...)
	if s := b.A.Source(addr); s != nil {
		p.Notes = append(p.Notes, "This is your own "+s.Label()+" — an internal move.")
	}
	p.steps(b.A, draws, amt.Denom, "from")
	for _, d := range draws {
		p.Msgs = append(p.Msgs, chain.Msg{"structs", "player-send", d.Address, addr, d.Amount.String() + amt.Denom})
	}
	return p, nil
}

// Consolidate moves balances from every other source into target.
func (b *Builder) Consolidate(ctx context.Context, targetSel, denomSel string) (*Plan, error) {
	if targetSel == "" {
		targetSel = "primary"
	}
	target, err := b.A.SourceBySelector(targetSel)
	if err != nil {
		return nil, err
	}
	denoms := []string{chain.Alpha}
	switch strings.ToLower(denomSel) {
	case "", "alpha", "ualpha":
	case "all":
		denoms = b.A.Denoms()
	default:
		a, err := chain.ParseAmount("0"+denomSel, chain.Alpha)
		if err != nil {
			return nil, err
		}
		denoms = []string{a.Denom}
	}
	p := &Plan{Title: "Consolidate into " + target.Label(), Subtitle: []string{target.Address}}
	for _, d := range denoms {
		draws, err := b.A.PlanLiquid(d, chain.Amount{All: true, Denom: d}, "", target.Address)
		if err != nil {
			continue
		}
		p.steps(b.A, draws, d, "from")
		for _, dr := range draws {
			p.Msgs = append(p.Msgs, chain.Msg{"structs", "player-send", dr.Address, target.Address, dr.Amount.String() + d})
		}
	}
	if len(p.Msgs) == 0 {
		return nil, fmt.Errorf("nothing to move — it is all in %s already", target.Label())
	}
	return p, nil
}

func (b *Builder) capWarning(ctx context.Context, v *chain.Validator, amount chain.Int) string {
	if v.ReactorID == "" {
		return v.Label() + " is not a Structs reactor"
	}
	ss, err := b.C.StakeShare(ctx, v.ReactorID)
	if err == nil && ss.CapActive && amount.Cmp(ss.ExternalDepositHeadroom) > 0 {
		return fmt.Sprintf("%s is near its stake cap: only %s more fits right now", v.Label(), chain.Format(ss.ExternalDepositHeadroom, chain.Alpha))
	}
	return ""
}

// Delegate infuses a reactor from wherever the alpha sits.
func (b *Builder) Delegate(ctx context.Context, target, amount, fromSel string) (*Plan, error) {
	v, err := b.validator(ctx, target)
	if err != nil {
		return nil, err
	}
	amt, err := chain.ParseAmount(amount, chain.Alpha)
	if err != nil {
		return nil, err
	}
	if amt.Denom != chain.Alpha {
		return nil, fmt.Errorf("only alpha can be delegated")
	}
	only, err := b.only(fromSel)
	if err != nil {
		return nil, err
	}
	draws, err := b.A.PlanLiquid(chain.Alpha, amt, only, "")
	if err != nil {
		return nil, err
	}
	total := sumDraws(draws)
	p := &Plan{Title: "Delegate " + chain.Format(total, chain.Alpha), Subtitle: []string{"to " + v.Label()}}
	if w := b.capWarning(ctx, v, total); w != "" {
		p.Warnings = append(p.Warnings, w)
	}
	p.steps(b.A, draws, chain.Alpha, "from")
	for _, d := range draws {
		p.Msgs = append(p.Msgs, chain.Msg{"structs", "reactor-infuse", v.Operator, d.Amount.String() + chain.Alpha, "--delegator-address", d.Address})
	}
	return p, nil
}

// Undelegate defuses from whichever addresses hold the delegation.
func (b *Builder) Undelegate(ctx context.Context, target, amount, fromSel string) (*Plan, error) {
	v, err := b.validator(ctx, target)
	if err != nil {
		return nil, err
	}
	amt, err := chain.ParseAmount(amount, chain.Alpha)
	if err != nil {
		return nil, err
	}
	only, err := b.only(fromSel)
	if err != nil {
		return nil, err
	}
	draws, err := b.A.PlanDelegation(v.Operator, amt, only)
	if err != nil {
		return nil, err
	}
	p := &Plan{Title: "Undelegate " + chain.Format(sumDraws(draws), chain.Alpha), Subtitle: []string{"from " + v.Label()}}
	if t := b.C.UnbondingTime(ctx); t != "" {
		p.Notes = append(p.Notes, "Defusing takes "+t+"; the alpha returns to the address it was delegated from.")
	}
	p.steps(b.A, draws, chain.Alpha, "held by")
	for _, d := range draws {
		p.Msgs = append(p.Msgs, chain.Msg{"structs", "reactor-defuse", v.Operator, d.Amount.String() + chain.Alpha, "--delegator-address", d.Address})
	}
	return p, nil
}

// Redelegate migrates stake between reactors.
func (b *Builder) Redelegate(ctx context.Context, from, to, amount string) (*Plan, error) {
	src, err := b.validator(ctx, from)
	if err != nil {
		return nil, err
	}
	dst, err := b.validator(ctx, to)
	if err != nil {
		return nil, err
	}
	if src.Operator == dst.Operator {
		return nil, fmt.Errorf("source and destination are the same reactor")
	}
	amt, err := chain.ParseAmount(amount, chain.Alpha)
	if err != nil {
		return nil, err
	}
	draws, err := b.A.PlanDelegation(src.Operator, amt, "")
	if err != nil {
		return nil, err
	}
	total := sumDraws(draws)
	p := &Plan{Title: "Move " + chain.Format(total, chain.Alpha), Subtitle: []string{"from " + src.Label(), "to   " + dst.Label()}}
	if w := b.capWarning(ctx, dst, total); w != "" {
		p.Warnings = append(p.Warnings, w)
	}
	p.steps(b.A, draws, chain.Alpha, "held by")
	for _, d := range draws {
		p.Msgs = append(p.Msgs, chain.Msg{"structs", "reactor-begin-migration", src.Operator, dst.Operator, d.Amount.String() + chain.Alpha, "--delegator-address", d.Address})
	}
	return p, nil
}

// CancelDefuse puts a defusing entry (numbered as in Account.Defusions) back.
func (b *Builder) CancelDefuse(ctx context.Context, n int, amount string) (*Plan, error) {
	defs := b.A.Defusions()
	if n < 1 || n > len(defs) {
		return nil, fmt.Errorf("no defusion #%d (there are %d)", n, len(defs))
	}
	d := defs[n-1]
	amt := d.Balance
	if amount != "" {
		a, err := chain.ParseAmount(amount, chain.Alpha)
		if err != nil {
			return nil, err
		}
		if !a.All {
			if a.Value.Cmp(d.Balance) > 0 {
				return nil, fmt.Errorf("defusion #%d only has %s", n, chain.Format(d.Balance, chain.Alpha))
			}
			amt = a.Value
		}
	}
	label := d.Validator
	if v := b.Vals[d.Validator]; v != nil {
		label = v.Label()
	}
	p := &Plan{Title: "Cancel defusion of " + chain.Format(amt, chain.Alpha), Subtitle: []string{"back into " + label}}
	p.Steps = append(p.Steps, Step{Amount: chain.Format(amt, chain.Alpha), Text: "held by " + b.A.Label(d.Address), Detail: "started at height " + d.CreationHeight})
	p.Msgs = append(p.Msgs, chain.Msg{"structs", "reactor-cancel-defusion", d.Validator, amt.String() + chain.Alpha, d.CreationHeight, "--delegator-address", d.Address})
	return p, nil
}

// ---------------------------------------------------------------- guild bank

// BankState is what a guild bank quote needs.
type BankState struct {
	GuildID    string
	Denom      string
	Collateral chain.Int
	Supply     chain.Int
	FeeIn      *big.Rat
	FeeOut     *big.Rat
}

func LoadBank(ctx context.Context, c *chain.Client, guildID string) (*BankState, error) {
	g, err := c.Guild(ctx, guildID)
	if err != nil || g.ID == "" {
		return nil, fmt.Errorf("guild %s not found", guildID)
	}
	pool, err := c.GuildBankCollateral(ctx, guildID)
	if err != nil {
		return nil, err
	}
	bs := &BankState{GuildID: guildID, Denom: "uguild." + guildID, FeeIn: rat(g.BankConvertInFee), FeeOut: rat(g.BankConvertOutFee)}
	if pool != "" {
		bs.Collateral, _ = c.Balance(ctx, pool, chain.Alpha)
	}
	bs.Supply, _ = c.Supply(ctx, bs.Denom)
	return bs, nil
}

func rat(s string) *big.Rat {
	r, ok := new(big.Rat).SetString(s)
	if !ok {
		return new(big.Rat)
	}
	return r
}

// ceilFee = ceil(amount * fee), as the chain computes it.
func ceilFee(amount chain.Int, fee *big.Rat) chain.Int {
	x := new(big.Rat).Mul(new(big.Rat).SetInt(amount.Big()), fee)
	q, r := new(big.Int).QuoRem(x.Num(), x.Denom(), new(big.Int))
	if r.Sign() > 0 {
		q.Add(q, big.NewInt(1))
	}
	return chain.IntFromBig(q)
}

func withSlippage(v chain.Int) chain.Int {
	m := v.Mul(chain.NewInt(10000 - SlippageBps)).Quo(chain.NewInt(10000))
	if m.Sign() <= 0 {
		return chain.NewInt(1)
	}
	return m
}

func (bs *BankState) Ready() bool { return bs.Collateral.Sign() > 0 && bs.Supply.Sign() > 0 }

// QuoteConvert: alpha in -> tokens out (before slippage).
func (bs *BankState) QuoteConvert(alpha chain.Int) (tokens, fee chain.Int) {
	fee = ceilFee(alpha, bs.FeeIn)
	return alpha.Sub(fee).Mul(bs.Supply).Quo(bs.Collateral), fee
}

// QuoteRedeem: tokens in -> alpha out (before slippage).
func (bs *BankState) QuoteRedeem(tokens chain.Int) (alpha, fee chain.Int) {
	gross := tokens.Mul(bs.Collateral).Quo(bs.Supply)
	fee = ceilFee(gross, bs.FeeOut)
	return gross.Sub(fee), fee
}

// topUpVault adds player-send messages so the vault holds need of denom.
// Guild bank operations only use the player vault.
func (b *Builder) topUpVault(p *Plan, denom string, need chain.Int) error {
	vault := b.A.Source(b.A.Vault)
	if vault == nil {
		return fmt.Errorf("this player has no vault")
	}
	have := vault.Balance(denom)
	if have.Cmp(need) >= 0 {
		return nil
	}
	draws, err := b.A.PlanLiquid(denom, chain.Amount{Value: need.Sub(have), Denom: denom}, "", vault.Address)
	if err != nil {
		return fmt.Errorf("the vault has %s and the rest of the account cannot cover %s: %w", chain.Format(have, denom), chain.Format(need, denom), err)
	}
	for _, d := range draws {
		p.Steps = append(p.Steps, Step{Amount: chain.Format(d.Amount, denom), Text: "moved into Player Vault from " + b.A.Label(d.Address), Detail: d.Address})
		p.Msgs = append(p.Msgs, chain.Msg{"structs", "player-send", d.Address, vault.Address, d.Amount.String() + denom})
	}
	p.Notes = append(p.Notes, "Guild banks only use your Player Vault, so the shortfall is moved in first (same transaction).")
	return nil
}

// Convert alpha into a guild's token.
func (b *Builder) Convert(ctx context.Context, guildID, amount string) (*Plan, error) {
	if guildID == "" {
		guildID = b.A.GuildID()
	}
	bs, err := LoadBank(ctx, b.C, guildID)
	if err != nil {
		return nil, err
	}
	if !bs.Ready() {
		return nil, fmt.Errorf("guild %s's bank has no collateral/supply yet", guildID)
	}
	amt, err := chain.ParseAmount(amount, chain.Alpha)
	if err != nil {
		return nil, err
	}
	if amt.Denom != chain.Alpha {
		return nil, fmt.Errorf("convert takes alpha; use redeem to turn tokens into alpha")
	}
	if amt.All {
		amt.Value = b.A.Liquid(chain.Alpha)
	}
	tokens, fee := bs.QuoteConvert(amt.Value)
	minTokens := withSlippage(tokens)
	p := &Plan{Title: "Convert " + chain.Format(amt.Value, chain.Alpha), Subtitle: []string{fmt.Sprintf("into ~%s (min %s)", chain.Format(tokens, bs.Denom), chain.Format(minTokens, bs.Denom))}}
	if fee.Sign() > 0 {
		p.Notes = append(p.Notes, "Guild convert-in fee: "+chain.Format(fee, chain.Alpha))
	}
	if err := b.topUpVault(p, chain.Alpha, amt.Value); err != nil {
		return nil, err
	}
	p.Steps = append(p.Steps, Step{Amount: chain.Format(amt.Value, chain.Alpha), Text: "converted at the guild " + guildID + " bank"})
	p.Msgs = append(p.Msgs, chain.Msg{"structs", "guild-bank-convert", guildID, amt.Value.String(), minTokens.String()})
	return p, nil
}

// Redeem a guild token for alpha.
func (b *Builder) Redeem(ctx context.Context, guildID, amount string) (*Plan, error) {
	if guildID == "" {
		guildID = b.A.GuildID()
	}
	bs, err := LoadBank(ctx, b.C, guildID)
	if err != nil {
		return nil, err
	}
	if !bs.Ready() {
		return nil, fmt.Errorf("guild %s's bank has nothing to redeem against", guildID)
	}
	amt, err := chain.ParseAmount(amount, bs.Denom)
	if err != nil {
		return nil, err
	}
	if amt.All {
		amt.Value = b.A.Liquid(bs.Denom)
	}
	if amt.Denom != bs.Denom {
		return nil, fmt.Errorf("guild %s redeems %s, not %s", guildID, bs.Denom, amt.Denom)
	}
	alpha, fee := bs.QuoteRedeem(amt.Value)
	minAlpha := withSlippage(alpha)
	p := &Plan{Title: "Redeem " + chain.Format(amt.Value, bs.Denom), Subtitle: []string{fmt.Sprintf("for ~%s (min %s) into your Player Vault", chain.Format(alpha, chain.Alpha), chain.Format(minAlpha, chain.Alpha))}}
	if fee.Sign() > 0 {
		p.Notes = append(p.Notes, "Guild convert-out fee: "+chain.Format(fee, chain.Alpha))
	}
	if err := b.topUpVault(p, bs.Denom, amt.Value); err != nil {
		return nil, err
	}
	p.Steps = append(p.Steps, Step{Amount: chain.Format(amt.Value, bs.Denom), Text: "redeemed at the guild " + guildID + " bank"})
	p.Msgs = append(p.Msgs, chain.Msg{"structs", "guild-bank-redeem", amt.Value.String() + bs.Denom, minAlpha.String()})
	return p, nil
}
