package tui

import (
	"fmt"
	"math/big"
	"sort"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"

	"github.com/playstructs/structs-guild-toolbox/internal/art"
	"github.com/playstructs/structs-guild-toolbox/internal/chain"
	"github.com/playstructs/structs-guild-toolbox/internal/wallet"
)

func (m Model) View() string {
	if m.width <= 0 || m.height <= 0 {
		// Wait for the real size: drawing at a guess and then redrawing
		// narrower leaves wrapped fragments on screen.
		return ""
	}
	header := m.viewHeader()
	footer := m.viewFooter()
	bodyH := m.height - lipgloss.Height(header) - lipgloss.Height(footer)
	body := m.viewBody(bodyH)
	return clampFrame(header+"\n"+body+"\n"+footer, m.width, m.height)
}

// clampFrame guarantees no line is wider than the terminal and the frame is
// no taller than it. A single over-wide line wraps, shifts every line below
// it and corrupts the renderer's idea of the screen.
func clampFrame(s string, w, h int) string {
	lines := strings.Split(s, "\n")
	if len(lines) > h {
		// keep the prompt and status line; drop body lines from the bottom of the body
		lines = append(lines[:h-countFooter(lines, h)], lines[len(lines)-countFooter(lines, h):]...)
		lines = lines[:h]
	}
	for i, l := range lines {
		if ansi.StringWidth(l) > w {
			lines[i] = ansi.Truncate(l, w, "")
		}
	}
	return strings.Join(lines, "\n")
}

// countFooter is how many trailing lines to preserve when trimming height.
func countFooter(lines []string, h int) int {
	return min(len(lines), max(0, min(6, h/2)))
}

// bodyHeight mirrors View's layout (used for scrolling).
func (m Model) bodyHeight() int {
	return max(3, m.height-lipgloss.Height(m.viewHeader())-lipgloss.Height(m.viewFooter()))
}

// ---------------------------------------------------------------- header

func (m Model) viewHeader() string {
	brand := sAlphaHi.Render("◆ STRUCTS") + sFaint.Render(" ▸ ")
	var tabs []string
	for i, n := range tabNames {
		label := fmt.Sprintf("%d %s", i+1, n)
		if tab(i) == m.tab {
			tabs = append(tabs, sTabActive.Render(label))
		} else {
			tabs = append(tabs, sTabInactive.Render(label))
		}
	}
	left := brand + strings.Join(tabs, "")

	var right []string
	if m.busy() {
		right = append(right, m.spin.View()+" "+sDim.Render(m.busyLabel()))
	}
	if m.status.Network != "" {
		dot := sOK.Render("●")
		if m.status.CatchingUp || time.Since(m.status.Time) > 30*time.Second {
			dot = sWarn.Render("●")
		}
		right = append(right, dot+" "+sDim.Render(m.status.Network)+" "+sSteel.Render("#"+groupInt(m.status.Height)))
	} else {
		right = append(right, sErr.Render("●")+" "+sDim.Render("no node"))
	}
	r := strings.Join(right, sFaint.Render("  │  "))
	gap := m.width - lipgloss.Width(left) - lipgloss.Width(r) - 1
	if gap < 1 {
		return ansi.Truncate(left, m.width, "") + "\n" + sFaint.Render(strings.Repeat("─", m.width))
	}
	return left + strings.Repeat(" ", gap) + r + "\n" + sFaint.Render(strings.Repeat("─", m.width))
}

func (m Model) busyLabel() string {
	switch {
	case m.loading["boot"]:
		return "connecting"
	case m.loading["acct"]:
		return "loading account"
	case m.loading["guild"]:
		return "loading guild"
	case m.loading["members"]:
		return "scanning players"
	}
	return "working"
}

func groupInt(n int64) string { return chain.FormatAmount(chain.NewInt(n), "count") }

// ---------------------------------------------------------------- footer

func (m Model) viewFooter() string {
	var parts []string
	if m.flash != "" {
		st := sErr
		icon := "✗ "
		if m.flashOK {
			st, icon = sOK, "✓ "
		}
		parts = append(parts, " "+st.Render(icon+m.flash))
	}
	box := sPrompt
	if m.input.Focused() && m.pending == nil {
		box = sPromptActive
	}
	inner := m.input.View()
	if m.pending != nil && m.pending.stage == stagePassphrase {
		inner = m.pass.View()
	}
	parts = append(parts, box.Width(m.width-2).Render(inner))

	if len(m.sugs) > 0 {
		n := min(len(m.sugs), 8)
		start := 0
		if m.sugSel >= n {
			start = m.sugSel - n + 1
		}
		for i := start; i < start+n; i++ {
			c := m.sugs[i]
			name := fmt.Sprintf("/%-14s", c.name)
			argsTxt := fmt.Sprintf("%-34s", c.args)
			line := "  " + name + " " + argsTxt + " " + c.desc
			line = ansi.Truncate(line, m.width-2, "…")
			if i == m.sugSel {
				parts = append(parts, sSugSel.Render(sAlphaHi.Render("  /"+fmt.Sprintf("%-14s", c.name))+" "+sSteel.Render(argsTxt)+" "+sText.Render(c.desc)))
			} else {
				parts = append(parts, sDim.Render(line))
			}
		}
	} else if c := m.currentCommand(); c != nil {
		parts = append(parts, "  "+sAlpha.Render("/"+c.name)+" "+sSteel.Render(c.args)+sFaint.Render("  — "+c.desc))
	}

	// status line
	hints := sKey.Render("/") + sDim.Render(" commands  ") + sKey.Render("tab") + sDim.Render(" panels  ") +
		sKey.Render("ctrl+r") + sDim.Render(" refresh  ") + sKey.Render("?") + sDim.Render(" help  ") +
		sKey.Render("ctrl+c") + sDim.Render(" quit")
	who := sErr.Render("no key")
	if m.signer != nil {
		who = sAlpha.Render("◆ ") + sSteel.Render(m.signer.Name)
		if m.signerPlayer != "" {
			who += sFaint.Render(" · ") + sSteel.Render(m.signerPlayer)
		}
	}
	gap := m.width - lipgloss.Width(hints) - lipgloss.Width(who) - 2
	if gap < 1 {
		parts = append(parts, " "+who)
	} else {
		parts = append(parts, " "+hints+strings.Repeat(" ", gap)+who)
	}
	return strings.Join(parts, "\n")
}

// ---------------------------------------------------------------- body

func (m Model) reactorFor(bodyH int) *art.Reactor {
	bw, bh := art.Size(false)
	if m.width >= 110 && bodyH >= bh+2 {
		return m.reactor
	}
	sw, sh := art.Size(true)
	if m.width >= 84 && bodyH >= sh+2 && (m.tab == tabWallet || m.pending != nil) {
		return m.reactorSmall
	}
	_ = bw
	_ = sw
	return nil
}

func (m Model) viewBody(h int) string {
	if h <= 0 {
		return ""
	}
	r := m.reactorFor(h)
	if m.showHelp {
		r = nil
	}
	leftW := 0
	var left string
	if r != nil {
		left = r.Render(m.profile)
		if m.acct != nil {
			cap := fmt.Sprintf("%s infused", chain.FormatAmount(m.acct.Delegated(), chain.Alpha))
			left += "\n" + lipgloss.PlaceHorizontal(r.Width(), lipgloss.Center, sAlpha.Render("◆ ")+sDim.Render(cap))
		}
		leftW = r.Width() + 3
		left = lipgloss.NewStyle().PaddingLeft(1).Render(left)
	}
	rw := m.width - leftW - 2

	var content string
	switch {
	case m.showHelp:
		content = m.viewHelp(rw)
	case m.pending != nil:
		content = m.viewPlan(rw)
	default:
		switch m.tab {
		case tabWallet:
			content = m.viewWallet(rw)
		case tabStake:
			content = m.viewStake(rw)
		case tabGuild:
			content = m.viewGuild(rw)
		case tabActivity:
			content = m.viewActivity(rw)
		}
	}

	lines := strings.Split(content, "\n")
	scroll := min(m.scroll, max(0, len(lines)-h))
	lines = lines[scroll:]
	more := false
	if len(lines) > h {
		lines = lines[:h]
		more = true
	}
	for i := range lines {
		lines[i] = ansi.Truncate(lines[i], rw, "…")
	}
	if more {
		lines[h-1] = sFaint.Render("  ↓ more — pgdn / ctrl+d")
	}
	right := strings.Join(lines, "\n")
	if r == nil {
		return lipgloss.NewStyle().Height(h).MaxHeight(h).Render(" " + strings.ReplaceAll(right, "\n", "\n "))
	}
	out := lipgloss.JoinHorizontal(lipgloss.Top, lipgloss.NewStyle().Width(leftW).Render(left), right)
	return lipgloss.NewStyle().Height(h).MaxHeight(h).Render(out)
}

func section(title string, w int, extra ...string) string {
	t := sSection.Render(strings.ToUpper(title))
	if len(extra) > 0 {
		t += "  " + sFaint.Render(extra[0])
	}
	rule := w - lipgloss.Width(t) - 2
	if rule > 0 {
		t += " " + sFaint.Render(strings.Repeat("─", rule))
	}
	return t
}

func pad(s string, w int) string {
	if d := w - lipgloss.Width(s); d > 0 {
		return s + strings.Repeat(" ", d)
	}
	return s
}

func padL(s string, w int) string {
	if d := w - lipgloss.Width(s); d > 0 {
		return strings.Repeat(" ", d) + s
	}
	return s
}

func amt(v chain.Int) string { return chain.FormatAmount(v, chain.Alpha) }

func (m Model) emptyState(w int) string {
	if m.loading["boot"] || m.loading["acct"] {
		return "\n  " + m.spin.View() + " " + sDim.Render("Reading the chain…")
	}
	var b strings.Builder
	b.WriteString("\n" + sBold.Render("  Welcome to Structs.") + "\n\n")
	if m.signer == nil {
		b.WriteString(sDim.Render("  Pick the key you play with:  ") + sAlpha.Render("/key <name>") + "\n")
		b.WriteString(sDim.Render("  Or look anyone up:           ") + sAlpha.Render("/wallet 1-186") + "\n")
	} else {
		b.WriteString(sDim.Render("  Key "+m.signer.Name+" is not registered to a player.") + "\n")
	}
	return b.String()
}

// ---------------------------------------------------------------- wallet

func (m Model) viewWallet(w int) string {
	a := m.acct
	if a == nil {
		return m.emptyState(w)
	}
	var b strings.Builder
	title := sBold.Render("PLAYER "+a.PlayerID) + " "
	if a.Name() != "" {
		title += sAlphaHi.Render(a.Name()) + " "
	}
	if g := a.GuildID(); g != "" {
		title += sDim.Render("· guild " + g)
	}
	if !m.ownAccount() {
		title += "  " + sBadge.Render("VIEW ONLY") + sFaint.Render("  esc → your account")
	}
	b.WriteString(title + "\n\n")

	avail, deleg, unb, rew := a.Liquid(chain.Alpha), a.Delegated(), a.Unbonding(), a.Rewards()
	total := a.Total()
	b.WriteString("  " + lipgloss.NewStyle().Foreground(cAlphaHi).Bold(true).Render(amt(total)) + sAlpha.Render(" alpha") + "\n")
	whose := "your"
	if !m.ownAccount() {
		whose = "the player's"
	}
	b.WriteString("  " + sDim.Render(fmt.Sprintf("total across %d sources · all spendable with any of %s keys", len(a.Sources), whose)) + "\n\n")

	barW := min(w-4, 60)
	b.WriteString("  " + stackBar(barW, total, []barSeg{{avail, cSteel}, {deleg, cAlpha}, {unb, cCrystal}}) + "\n")
	row := func(color lipgloss.Color, label string, v chain.Int, note string) {
		b.WriteString("  " + lipgloss.NewStyle().Foreground(color).Render("■") + " " + pad(sSteel.Render(label), 12) + padL(sText.Render(amt(v)), 22) + "  " + sFaint.Render(note) + "\n")
	}
	row(cSteel, "available", avail, "")
	row(cAlpha, "delegated", deleg, "")
	if unb.Sign() > 0 {
		row(cCrystal, "defusing", unb, "")
	}
	if rew.Sign() > 0 {
		b.WriteString("  " + sHazard.Render("✦") + " " + pad(sSteel.Render("rewards"), 12) + padL(sText.Render(amt(rew)), 22) + "  " + sFaint.Render("unclaimed") + "\n")
	}

	b.WriteString("\n" + section("Where it is", w) + "\n")
	b.WriteString(sFaint.Render(fmt.Sprintf("  %-19s %-20s %14s %16s", "", "", "AVAILABLE", "DELEGATED")) + "\n")
	for _, s := range a.Sources {
		icon := sSteel.Render("●")
		if s.Kind == wallet.KindVault {
			icon = sAlpha.Render("◆")
		}
		label := s.Kind.String()
		if m.signer != nil && s.Address == m.signer.Address {
			label += " ★"
		}
		del := chain.NewInt(0)
		for _, d := range s.Delegations {
			del = del.Add(d.Amount)
		}
		b.WriteString("  " + icon + " " + pad(sText.Render(label), 17) + " " + pad(sDim.Render(wallet.Short(s.Address)), 20) +
			padL(sText.Render(amt(s.Balance(chain.Alpha))), 14) + padL(sAlpha.Render(amt(del)), 17) + "\n")
	}
	if m.signer != nil && m.ownAccount() {
		b.WriteString("  " + sFaint.Render("★ the key you sign with") + "\n")
	}

	if denoms := a.Denoms(); len(denoms) > 1 {
		b.WriteString("\n" + section("Other tokens", w) + "\n")
		for _, d := range denoms[1:] {
			b.WriteString("  " + pad(sSteel.Render(chain.DisplayDenom(d)), 20) + padL(sText.Render(chain.FormatAmount(a.Liquid(d), d)), 20) + "\n")
		}
	}

	if m.ownAccount() {
		b.WriteString("\n" + sFaint.Render("  try  ") + sAlpha.Render("/send <player> 2.5alpha") + sFaint.Render("   ") + sAlpha.Render("/delegate 3-12 all") + sFaint.Render("   ") + sAlpha.Render("/consolidate vault") + "\n")
	}
	return b.String()
}

type barSeg struct {
	v chain.Int
	c lipgloss.Color
}

func stackBar(w int, total chain.Int, segs []barSeg) string {
	if total.Sign() <= 0 || w <= 0 {
		return sFaint.Render(strings.Repeat("░", max(0, w)))
	}
	var out strings.Builder
	used := 0
	for i, s := range segs {
		n := int(new(big.Int).Quo(new(big.Int).Mul(s.v.Big(), big.NewInt(int64(w))), total.Big()).Int64())
		if s.v.Sign() > 0 && n == 0 {
			n = 1
		}
		if i == len(segs)-1 {
			n = max(0, w-used)
			if s.v.Sign() == 0 {
				n = 0
			}
		}
		n = min(n, w-used)
		used += n
		out.WriteString(lipgloss.NewStyle().Foreground(s.c).Render(strings.Repeat("█", n)))
	}
	if used < w {
		out.WriteString(sFaint.Render(strings.Repeat("░", w-used)))
	}
	return out.String()
}

// ---------------------------------------------------------------- stake

func (m Model) valLabel(op string) string {
	if v := m.vals[op]; v != nil {
		return v.Label()
	}
	return wallet.Short(op)
}

func (m Model) viewStake(w int) string {
	a := m.acct
	if a == nil {
		return m.emptyState(w)
	}
	var b strings.Builder
	stakes := a.Stakes()
	b.WriteString(section("Delegations", w, amt(a.Delegated())+" alpha") + "\n")
	if len(stakes) == 0 {
		b.WriteString(sDim.Render("  Nothing delegated yet. ") + sAlpha.Render("/delegate <reactor> <amount>") + "\n")
	}
	maxV := chain.NewInt(1)
	for _, s := range stakes {
		if s.Total.Cmp(maxV) > 0 {
			maxV = s.Total
		}
	}
	for _, s := range stakes {
		bar := int(new(big.Int).Quo(new(big.Int).Mul(s.Total.Big(), big.NewInt(16)), maxV.Big()).Int64())
		b.WriteString("  " + pad(sText.Render(m.valLabel(s.Validator)), 34) + padL(sAlphaHi.Render(amt(s.Total)), 18) + "  " + sAlpha.Render(strings.Repeat("▰", max(1, bar))) + "\n")
		for _, p := range s.Parts {
			b.WriteString("     " + pad(sDim.Render("via "+a.Label(p.Address)), 31) + padL(sDim.Render(amt(p.Amount)), 18) + "\n")
		}
	}

	defs := a.Defusions()
	if len(defs) > 0 {
		b.WriteString("\n" + section("Defusing", w, "/cancel-defuse <#> puts it back") + "\n")
		for _, d := range defs {
			left := time.Until(d.Completion)
			when := "ready"
			if left > 0 {
				when = "in " + humanDuration(left)
			}
			b.WriteString("  " + sCrystal.Render(fmt.Sprintf("#%-3d", d.N)) + pad(sText.Render(m.valLabel(d.Validator)), 30) + padL(sText.Render(amt(d.Balance)), 16) + "  " + pad(sSteel.Render(when), 12) + sFaint.Render(a.Label(d.Address)) + "\n")
		}
	}

	b.WriteString("\n" + section("Reactors", w, "targets for /delegate — use the id") + "\n")
	var vs []*chain.Validator
	for _, v := range m.vals {
		if v.ReactorID != "" {
			vs = append(vs, v)
		}
	}
	sort.Slice(vs, func(i, j int) bool { return vs[i].Tokens.Cmp(vs[j].Tokens) > 0 })
	b.WriteString(sFaint.Render(fmt.Sprintf("  %-7s %-22s %-9s %18s  %s", "ID", "MONIKER", "STATUS", "STAKE", "OWNER")) + "\n")
	for _, v := range vs {
		st := sOK.Render("bonded  ")
		if v.Jailed {
			st = sErr.Render("jailed  ")
		} else if !v.Bonded() {
			st = sWarn.Render(strings.ToLower(strings.TrimPrefix(v.Status, "BOND_STATUS_")))
		}
		mine := ""
		for _, s := range stakes {
			if s.Validator == v.Operator {
				mine = sAlpha.Render(" ◆")
			}
		}
		var ow []string
		if v.Owner != "" {
			ow = append(ow, v.Owner)
		}
		if v.GuildID != "" {
			ow = append(ow, "guild "+v.GuildID)
		}
		owner := strings.Join(ow, " · ")
		b.WriteString("  " + pad(sAlpha.Render(v.ReactorID), 8) + pad(sText.Render(trunc(v.Moniker, 21)), 23) + pad(st, 10) + padL(sSteel.Render(amt(v.Tokens)), 18) + "  " + sDim.Render(owner) + mine + "\n")
	}
	return b.String()
}

func trunc(s string, n int) string {
	if len([]rune(s)) <= n {
		return s
	}
	return string([]rune(s)[:n-1]) + "…"
}

func humanDuration(d time.Duration) string {
	h := int(d.Hours())
	switch {
	case h >= 48:
		return fmt.Sprintf("%dd %dh", h/24, h%24)
	case h >= 1:
		return fmt.Sprintf("%dh %dm", h, int(d.Minutes())%60)
	}
	return fmt.Sprintf("%dm", int(d.Minutes()))
}

// ---------------------------------------------------------------- guild

func (m Model) viewGuild(w int) string {
	if m.acct == nil {
		return m.emptyState(w)
	}
	v := m.guild
	if v == nil {
		if m.loading["guild"] {
			return "\n  " + m.spin.View() + sDim.Render(" loading guild…")
		}
		return "\n" + sDim.Render("  Not in a guild.") + "\n"
	}
	g := v.Guild
	var b strings.Builder
	title := sBold.Render("GUILD "+g.ID) + " "
	if g.Name != "" {
		title += sAlphaHi.Render(g.Name) + " "
	}
	title += sDim.Render("· owner " + g.Owner)
	if v.IsOwner {
		title += "  " + sBadge.Render("YOU OWN THIS GUILD")
	}
	b.WriteString(title + "\n\n")
	kv := func(k, val string) { b.WriteString("  " + pad(sSteel.Render(k), 20) + val + "\n") }
	if v.Reactor != nil {
		kv("primary reactor", sText.Render(v.Reactor.Label()))
	}
	if v.Entry.ID != "" {
		kv("entry substation", sText.Render(v.Entry.ID)+sDim.Render(fmt.Sprintf("  load %s / %s · connections %s / %s",
			orZero(v.Entry.Grid["load"]), orZero(v.Entry.Grid["capacity"]), orZero(v.Entry.Grid["connectionCount"]), orZero(v.Entry.Grid["connectionCapacity"]))))
	}
	kv("joining", sDim.Render(fmt.Sprintf("entry rank %s · by request: %s · by invite: %s", orDash(g.EntryRank), orDash(g.BypassByRequest), orDash(g.BypassByInvite))))

	if bs := v.Bank; bs != nil {
		b.WriteString("\n" + section("Bank", w, chain.DisplayDenom(bs.Denom)) + "\n")
		kv("collateral", sText.Render(amt(bs.Collateral)+" alpha"))
		kv("supply", sText.Render(chain.FormatAmount(bs.Supply, bs.Denom)+" "+chain.DisplayDenom(bs.Denom)))
		if bs.Ready() {
			one := chain.NewInt(1_000_000)
			a, _ := bs.QuoteRedeem(one)
			kv("price", sAlphaHi.Render("1 "+chain.DisplayDenom(bs.Denom)+" ≈ "+amt(a)+" alpha"))
		} else {
			kv("price", sDim.Render("not bootstrapped — /mint first"))
		}
		kv("fees", sDim.Render("convert-in "+pct(g.BankConvertInFee)+" · convert-out "+pct(g.BankConvertOutFee)))
		kv("treasury (vault)", sText.Render(amt(v.VaultBalances[chain.Alpha])+" alpha")+sDim.Render("  ·  "+chain.FormatAmount(v.VaultBalances[bs.Denom], bs.Denom)+" "+chain.DisplayDenom(bs.Denom)))
		if m.acct != nil {
			kv("you hold", sText.Render(chain.FormatAmount(m.acct.Liquid(bs.Denom), bs.Denom)+" "+chain.DisplayDenom(bs.Denom)))
		}
		b.WriteString("  " + sFaint.Render("/convert 10alpha · /redeem all · /mint <alpha> <tokens>") + "\n")
	}

	b.WriteString("\n" + section("Pending applications", w, fmt.Sprint(len(v.Pending))) + "\n")
	if len(v.Pending) == 0 {
		b.WriteString(sDim.Render("  none") + "\n")
	}
	for _, a := range v.Pending {
		action := "/deny " + a.PlayerID + " to revoke"
		if a.Type() == "request" {
			action = "/approve " + a.PlayerID + " · /deny " + a.PlayerID
		}
		b.WriteString("  " + pad(sAlpha.Render(a.PlayerID), 12) + pad(sText.Render(a.Type()), 10) + sFaint.Render(action) + "\n")
	}

	b.WriteString("\n" + section("Providers", w, "yours and the guild's") + "\n")
	if len(v.Providers) == 0 {
		b.WriteString(sDim.Render("  none") + "\n")
	}
	for _, p := range v.Providers {
		b.WriteString("  " + pad(sAlpha.Render(p.ID), 9) + pad(sDim.Render("owner "+p.Owner), 14) + pad(sText.Render(p.Rate.Amount.String()+p.Rate.Denom), 18) +
			pad(sSteel.Render(p.Policy()), 15) + sFaint.Render("cap "+p.CapacityMinimum+"–"+p.CapacityMaximum) + "\n")
	}

	if m.members != nil {
		b.WriteString("\n" + section("Members", w, fmt.Sprint(len(m.members))) + "\n")
		for _, p := range m.members {
			b.WriteString("  " + pad(sAlpha.Render(p.ID), 12) + pad(sDim.Render("rank "+orDash(p.GuildRank)), 12) + sText.Render(p.Name) + "\n")
		}
	} else {
		b.WriteString("\n" + sFaint.Render("  /members lists everyone in the guild") + "\n")
	}
	return b.String()
}

func orZero(s string) string {
	if s == "" {
		return "0"
	}
	return s
}

func orDash(s string) string {
	if s == "" {
		return "–"
	}
	return s
}

func pct(dec string) string {
	r, ok := new(big.Rat).SetString(dec)
	if !ok {
		return dec
	}
	f, _ := new(big.Rat).Mul(r, big.NewRat(100, 1)).Float64()
	return strings.TrimRight(strings.TrimRight(fmt.Sprintf("%.2f", f), "0"), ".") + "%"
}

// ---------------------------------------------------------------- activity

func (m Model) viewActivity(w int) string {
	var b strings.Builder
	b.WriteString(section("Activity", w, "this session") + "\n")
	if len(m.log) == 0 {
		b.WriteString(sDim.Render("  nothing yet") + "\n")
	}
	for i := len(m.log) - 1; i >= 0; i-- {
		e := m.log[i]
		icon := sDim.Render("·")
		switch e.kind {
		case "tx":
			icon = sOK.Render("✓")
		case "err":
			icon = sErr.Render("✗")
		case "info":
			icon = sAlpha.Render("◆")
		}
		line := "  " + sFaint.Render(e.at.Format("15:04:05")) + " " + icon + " " + sText.Render(e.text)
		if e.hash != "" {
			line += sFaint.Render("  " + e.hash)
		}
		b.WriteString(line + "\n")
	}
	return b.String()
}

// ---------------------------------------------------------------- plan card

func (m Model) viewPlan(w int) string {
	p := m.pending
	cw := min(w-2, 84)
	var b strings.Builder
	if p.plan == nil {
		if p.stage == stageFailed {
			b.WriteString(sErr.Render("✗ ") + sText.Render(p.err.Error()) + "\n\n" + sFaint.Render("esc dismiss"))
			return "\n" + sCardErr.Width(cw).Render(b.String())
		}
		b.WriteString(m.spin.View() + " " + sDim.Render("Planning "+p.what+"…"))
		return "\n" + sCard.Width(cw).Render(b.String())
	}
	pl := p.plan
	b.WriteString(sAlphaHi.Render(pl.Title) + "\n")
	for _, s := range pl.Subtitle {
		b.WriteString(sDim.Render(s) + "\n")
	}
	if len(pl.Steps) > 0 {
		b.WriteString("\n")
		aw := 0
		for _, s := range pl.Steps {
			aw = max(aw, lipgloss.Width(s.Amount))
		}
		for _, s := range pl.Steps {
			line := padL(sText.Render(s.Amount), aw+2) + "  " + sSteel.Render(s.Text)
			if s.Detail != "" && lipgloss.Width(line)+lipgloss.Width(wallet.Short(s.Detail))+2 <= cw-6 {
				line += "  " + sFaint.Render(wallet.Short(s.Detail))
			}
			b.WriteString(line + "\n")
		}
	}
	if len(pl.Warnings)+len(pl.Notes) > 0 {
		b.WriteString("\n")
	}
	for _, s := range pl.Warnings {
		b.WriteString(sWarn.Render("⚠ "+s) + "\n")
	}
	for _, s := range pl.Notes {
		b.WriteString(sDim.Render("ℹ "+s) + "\n")
	}
	b.WriteString("\n")
	n := len(pl.Msgs)
	what := "1 message"
	if n > 1 {
		what = fmt.Sprintf("%d messages, 1 atomic tx", n)
	}
	style := sCard
	switch p.stage {
	case stageSimulating, stagePlanning:
		b.WriteString(m.spin.View() + " " + sDim.Render("Simulating "+what+"…"))
	case stageReady:
		b.WriteString(sOK.Render("✓ Simulated OK") + sDim.Render(fmt.Sprintf(" · %s · gas %s", what, groupInt(int64(p.prep.GasUsed)))) + "\n\n")
		b.WriteString(sKey.Render("⏎") + sDim.Render(" sign & broadcast    ") + sKey.Render("esc") + sDim.Render(" cancel"))
	case stagePassphrase:
		b.WriteString(sDim.Render("Enter your keyring passphrase below, then ⏎"))
	case stageSigning:
		b.WriteString(m.spin.View() + " " + sDim.Render("Signing and broadcasting…"))
	case stageConfirming:
		b.WriteString(m.spin.View() + " " + sDim.Render("Waiting for a block… ") + sFaint.Render(p.hash))
	case stageDone:
		style = sCardOK
		b.WriteString(sOK.Render(fmt.Sprintf("✓ Confirmed in block %s", groupInt(p.result.Height))) + "\n" + sFaint.Render(p.hash) + "\n\n" + sFaint.Render("⏎ dismiss"))
	case stageFailed:
		style = sCardErr
		msg := "failed"
		if p.err != nil {
			msg = p.err.Error()
		}
		label := "✗ Simulation failed: "
		if p.prep != nil && p.prep.GasUsed > 0 || p.hash != "" {
			label = "✗ "
		}
		b.WriteString(sErr.Render(label) + sText.Render(msg) + "\n\n")
		if p.hash != "" {
			b.WriteString(sFaint.Render("esc dismiss · tx " + p.hash))
		} else {
			b.WriteString(sFaint.Render("esc dismiss — nothing was broadcast"))
		}
	}
	return "\n" + style.Width(cw).Render(b.String())
}

// ---------------------------------------------------------------- help

func (m Model) viewHelp(w int) string {
	var b strings.Builder
	b.WriteString(sAlphaHi.Render("Commands") + sFaint.Render("   (esc to close)") + "\n")
	groups := []string{"Wallet", "Stake", "Guild", "General"}
	for _, g := range groups {
		b.WriteString("\n" + section(g, w) + "\n")
		for _, c := range commands {
			if c.group != g {
				continue
			}
			b.WriteString("  " + pad(sAlpha.Render("/"+c.name), 16) + pad(sSteel.Render(c.args), 40) + sDim.Render(c.desc) + "\n")
		}
	}
	b.WriteString("\n" + section("Amounts & names", w) + "\n")
	b.WriteString(sDim.Render("  2.5alpha · 2500000ualpha · 10guild.0-3 · all") + "\n")
	b.WriteString(sDim.Render("  recipients: structs1… address, player id 1-N (their vault), guild id 0-N (guild vault)") + "\n")
	b.WriteString(sDim.Render("  reactors:   3-N, owning player 1-N, guild 0-N, moniker or structsvaloper1…") + "\n")
	b.WriteString("\n" + section("Keys", w) + "\n")
	b.WriteString(sDim.Render("  tab / shift+tab  switch panels      ctrl+r  refresh       pgup/pgdn  scroll") + "\n")
	b.WriteString(sDim.Render("  ↑ ↓              history / menu     esc     back / clear  ctrl+c     quit") + "\n")
	return b.String()
}
