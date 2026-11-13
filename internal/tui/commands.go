package tui

import (
	"context"
	"fmt"
	"strconv"
	"strings"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/playstructs/structs-guild-toolbox/internal/chain"
	"github.com/playstructs/structs-guild-toolbox/internal/guild"
	"github.com/playstructs/structs-guild-toolbox/internal/wallet"
)

type command struct {
	name    string
	args    string
	desc    string
	group   string
	aliases []string
	minArgs int
	run     func(m *Model, a []string) (tea.Cmd, error)
}

var commands []command

func init() {
	commands = []command{
		// wallet
		{name: "send", args: "<address|player|guild> <amount> [from]", desc: "Send to any structs1… address, or a player/guild vault", group: "Wallet", minArgs: 2, run: cmdSend},
		{name: "consolidate", args: "[vault|primary|addr] [alpha|all|denom]", desc: "Gather funds from every source into one address", group: "Wallet", run: cmdConsolidate},
		{name: "wallet", args: "[player|address]", desc: "Show an account (yours, or anyone's read-only)", group: "Wallet", aliases: []string{"lookup", "whois"}, run: cmdWallet},
		// stake
		{name: "delegate", args: "<reactor> <amount> [from]", desc: "Infuse a reactor from wherever your alpha sits", group: "Stake", aliases: []string{"infuse"}, minArgs: 2, run: cmdDelegate},
		{name: "undelegate", args: "<reactor> <amount|all>", desc: "Defuse, from whichever addresses hold the stake", group: "Stake", aliases: []string{"defuse"}, minArgs: 2, run: cmdUndelegate},
		{name: "redelegate", args: "<from> <to> <amount|all>", desc: "Move stake between reactors", group: "Stake", aliases: []string{"migrate"}, minArgs: 3, run: cmdRedelegate},
		{name: "cancel-defuse", args: "<#> [amount]", desc: "Put a defusion back into its reactor", group: "Stake", minArgs: 1, run: cmdCancel},
		// guild bank
		{name: "convert", args: "<alpha amount> [guild]", desc: "Buy guild tokens with alpha (vault topped up for you)", group: "Guild", minArgs: 1, run: cmdConvert},
		{name: "redeem", args: "<token amount|all> [guild]", desc: "Redeem guild tokens for alpha", group: "Guild", minArgs: 1, run: cmdRedeem},
		{name: "mint", args: "<n>alpha <n>guild.X", desc: "Mint guild tokens from the guild treasury (admin)", group: "Guild", minArgs: 2, run: cmdMint},
		{name: "invite", args: "<player>", desc: "Invite a player to your guild", group: "Guild", minArgs: 1, run: cmdInvite},
		{name: "approve", args: "<player>", desc: "Approve a join request", group: "Guild", minArgs: 1, run: cmdApprove},
		{name: "deny", args: "<player>", desc: "Deny a request or revoke an invite", group: "Guild", aliases: []string{"revoke"}, minArgs: 1, run: cmdDeny},
		{name: "kick", args: "<player>", desc: "Remove a member from your guild", group: "Guild", minArgs: 1, run: cmdKick},
		{name: "members", args: "", desc: "List your guild's members (scans all players)", group: "Guild", run: cmdMembers},
		{name: "withdraw", args: "<provider> [dest]", desc: "Withdraw provider earnings (default: your vault)", group: "Guild", minArgs: 1, run: cmdWithdraw},
		// general
		{name: "key", args: "[name]", desc: "Choose the key you sign with", group: "General", run: cmdKey},
		{name: "unlock", desc: "Enter your keyring passphrase", group: "General", run: cmdUnlock},
		{name: "refresh", desc: "Reload everything", group: "General", run: func(m *Model, _ []string) (tea.Cmd, error) { return m.refresh(), nil }},
		{name: "help", desc: "Commands and shortcuts", group: "General", run: func(m *Model, _ []string) (tea.Cmd, error) { m.showHelp = true; return nil, nil }},
		{name: "quit", desc: "Exit", group: "General", aliases: []string{"exit", "q"}, run: func(m *Model, _ []string) (tea.Cmd, error) { m.cancel(); return tea.Quit, nil }},
	}
}

func commandByName(n string) *command {
	n = strings.ToLower(n)
	for i := range commands {
		if commands[i].name == n {
			return &commands[i]
		}
		for _, a := range commands[i].aliases {
			if a == n {
				return &commands[i]
			}
		}
	}
	return nil
}

func (m *Model) updateSuggestions() {
	v := m.input.Value()
	m.sugs = nil
	if !strings.HasPrefix(v, "/") || strings.Contains(v, " ") {
		m.sugSel = 0
		return
	}
	q := strings.ToLower(strings.TrimPrefix(v, "/"))
	seen := map[string]bool{}
	addIf := func(c command, ok bool) {
		if ok && !seen[c.name] {
			seen[c.name] = true
			m.sugs = append(m.sugs, c)
		}
	}
	// name prefix, then alias prefix, then substring
	for _, c := range commands {
		addIf(c, strings.HasPrefix(c.name, q))
	}
	for _, c := range commands {
		for _, a := range c.aliases {
			addIf(c, strings.HasPrefix(a, q))
		}
	}
	for _, c := range commands {
		addIf(c, q != "" && strings.Contains(c.name, q))
	}
	if m.sugSel >= len(m.sugs) {
		m.sugSel = 0
	}
}

// currentCommand returns the command being typed (for the argument hint).
func (m *Model) currentCommand() *command {
	v := m.input.Value()
	if !strings.HasPrefix(v, "/") || !strings.Contains(v, " ") {
		return nil
	}
	name, _, _ := strings.Cut(strings.TrimPrefix(v, "/"), " ")
	return commandByName(name)
}

func (m Model) execute(line string) (tea.Model, tea.Cmd) {
	if !strings.HasPrefix(line, "/") {
		// bare player id / address => look it up
		if chain.IsPlayerID(line) || chain.IsAddress(line) {
			cmd, _ := cmdWallet(&m, []string{line})
			return m, cmd
		}
		m.setFlash("Type / to see commands (e.g. /send 1-28 2.5alpha)", false)
		return m, nil
	}
	fields := strings.Fields(strings.TrimPrefix(line, "/"))
	if len(fields) == 0 {
		return m, nil
	}
	c := commandByName(fields[0])
	if c == nil {
		m.setFlash("Unknown command /"+fields[0]+" — type / to browse", false)
		return m, nil
	}
	args := fields[1:]
	if len(args) < c.minArgs {
		m.setFlash(fmt.Sprintf("Usage: /%s %s", c.name, c.args), false)
		return m, nil
	}
	cmd, err := c.run(&m, args)
	if err != nil {
		m.setFlash(err.Error(), false)
		return m, nil
	}
	return m, cmd
}

// ---------------------------------------------------------------- helpers

func (m *Model) builder() (*wallet.Builder, error) {
	if m.signer == nil {
		return nil, fmt.Errorf("no signing key — choose one with /key")
	}
	if m.signerPlayer == "" {
		return nil, fmt.Errorf("key %s is not registered to a player", m.signer.Name)
	}
	if m.acct == nil {
		return nil, fmt.Errorf("account is still loading")
	}
	if !m.ownAccount() {
		return nil, fmt.Errorf("you are viewing %s read-only — press esc to return to your account", m.acct.PlayerID)
	}
	return &wallet.Builder{C: m.c, A: m.acct, Vals: m.vals}, nil
}

func arg(a []string, i int) string {
	if i < len(a) {
		return a[i]
	}
	return ""
}

// amountArg joins "2.5 alpha" style arguments back together.
func amountArgs(a []string, start int) (amount string, rest []string) {
	if start >= len(a) {
		return "", nil
	}
	amount = a[start]
	rest = a[start+1:]
	if len(rest) > 0 && (rest[0] == "alpha" || strings.HasPrefix(rest[0], "guild.") || strings.HasPrefix(rest[0], "uguild.") || rest[0] == "ualpha") {
		amount += rest[0]
		rest = rest[1:]
	}
	return amount, rest
}

func (m *Model) guildView() (*guild.View, error) {
	if m.guild == nil {
		return nil, fmt.Errorf("you are not in a guild (or it is still loading)")
	}
	return m.guild, nil
}

// ---------------------------------------------------------------- handlers

func cmdWallet(m *Model, a []string) (tea.Cmd, error) {
	target := arg(a, 0)
	if target == "" {
		target = m.signerPlayer
	}
	if target == "" {
		return nil, fmt.Errorf("give a player id or address: /wallet 1-186")
	}
	m.viewing = target
	m.tab = tabWallet
	m.scroll = 0
	m.loading["acct"] = true
	return m.loadAccount(target), nil
}

func cmdSend(m *Model, a []string) (tea.Cmd, error) {
	b, err := m.builder()
	if err != nil {
		return nil, err
	}
	amount, rest := amountArgs(a, 1)
	to, from := a[0], arg(rest, 0)
	return m.startPlan("/send", func(ctx context.Context) (*wallet.Plan, error) { return b.Send(ctx, to, amount, from) }), nil
}

func cmdConsolidate(m *Model, a []string) (tea.Cmd, error) {
	b, err := m.builder()
	if err != nil {
		return nil, err
	}
	return m.startPlan("/consolidate", func(ctx context.Context) (*wallet.Plan, error) { return b.Consolidate(ctx, arg(a, 0), arg(a, 1)) }), nil
}

func cmdDelegate(m *Model, a []string) (tea.Cmd, error) {
	b, err := m.builder()
	if err != nil {
		return nil, err
	}
	amount, rest := amountArgs(a, 1)
	return m.startPlan("/delegate", func(ctx context.Context) (*wallet.Plan, error) { return b.Delegate(ctx, a[0], amount, arg(rest, 0)) }), nil
}

func cmdUndelegate(m *Model, a []string) (tea.Cmd, error) {
	b, err := m.builder()
	if err != nil {
		return nil, err
	}
	amount, rest := amountArgs(a, 1)
	return m.startPlan("/undelegate", func(ctx context.Context) (*wallet.Plan, error) { return b.Undelegate(ctx, a[0], amount, arg(rest, 0)) }), nil
}

func cmdRedelegate(m *Model, a []string) (tea.Cmd, error) {
	b, err := m.builder()
	if err != nil {
		return nil, err
	}
	amount, _ := amountArgs(a, 2)
	return m.startPlan("/redelegate", func(ctx context.Context) (*wallet.Plan, error) { return b.Redelegate(ctx, a[0], a[1], amount) }), nil
}

func cmdCancel(m *Model, a []string) (tea.Cmd, error) {
	b, err := m.builder()
	if err != nil {
		return nil, err
	}
	n, err := strconv.Atoi(strings.TrimPrefix(a[0], "#"))
	if err != nil {
		return nil, fmt.Errorf("give the defusion number from the Stake tab, e.g. /cancel-defuse 1")
	}
	amount, _ := amountArgs(a, 1)
	return m.startPlan("/cancel-defuse", func(ctx context.Context) (*wallet.Plan, error) { return b.CancelDefuse(ctx, n, amount) }), nil
}

func cmdConvert(m *Model, a []string) (tea.Cmd, error) {
	b, err := m.builder()
	if err != nil {
		return nil, err
	}
	amount, rest := amountArgs(a, 0)
	return m.startPlan("/convert", func(ctx context.Context) (*wallet.Plan, error) { return b.Convert(ctx, arg(rest, 0), amount) }), nil
}

func cmdRedeem(m *Model, a []string) (tea.Cmd, error) {
	b, err := m.builder()
	if err != nil {
		return nil, err
	}
	amount, rest := amountArgs(a, 0)
	return m.startPlan("/redeem", func(ctx context.Context) (*wallet.Plan, error) { return b.Redeem(ctx, arg(rest, 0), amount) }), nil
}

func guildPlan(m *Model, what string, f func(v *guild.View) (*wallet.Plan, error)) (tea.Cmd, error) {
	if _, err := m.builder(); err != nil {
		return nil, err
	}
	v, err := m.guildView()
	if err != nil {
		return nil, err
	}
	return m.startPlan(what, func(context.Context) (*wallet.Plan, error) { return f(v) }), nil
}

func cmdMint(m *Model, a []string) (tea.Cmd, error) {
	return guildPlan(m, "/mint", func(v *guild.View) (*wallet.Plan, error) { return guild.Mint(v, a[0], a[1]) })
}
func cmdInvite(m *Model, a []string) (tea.Cmd, error) {
	return guildPlan(m, "/invite", func(v *guild.View) (*wallet.Plan, error) { return guild.Invite(v, a[0]) })
}
func cmdApprove(m *Model, a []string) (tea.Cmd, error) {
	return guildPlan(m, "/approve", func(v *guild.View) (*wallet.Plan, error) { return guild.Approve(v, a[0]) })
}
func cmdDeny(m *Model, a []string) (tea.Cmd, error) {
	return guildPlan(m, "/deny", func(v *guild.View) (*wallet.Plan, error) { return guild.Deny(v, a[0]) })
}
func cmdKick(m *Model, a []string) (tea.Cmd, error) {
	return guildPlan(m, "/kick", func(v *guild.View) (*wallet.Plan, error) { return guild.Kick(v, a[0]) })
}

func cmdWithdraw(m *Model, a []string) (tea.Cmd, error) {
	if _, err := m.builder(); err != nil {
		return nil, err
	}
	dest := arg(a, 1)
	if dest == "" {
		dest = m.acct.Vault
	}
	return m.startPlan("/withdraw", func(context.Context) (*wallet.Plan, error) { return guild.WithdrawProvider(a[0], dest) }), nil
}

func cmdMembers(m *Model, _ []string) (tea.Cmd, error) {
	v, err := m.guildView()
	if err != nil {
		return nil, err
	}
	id := v.Guild.ID
	m.loading["members"] = true
	c, ctx := m.c, m.ctx
	return func() tea.Msg {
		ms, err := guild.Members(ctx, c, id)
		return membersMsg{ms, err}
	}, nil
}

func cmdKey(m *Model, a []string) (tea.Cmd, error) {
	name := arg(a, 0)
	if name == "" {
		m.tab = tabActivity
		if len(m.keys) == 0 {
			return nil, fmt.Errorf("no keys in the %s — add one with: structsd keys add <name> --recover", m.c.KeyringLabel())
		}
		var parts []string
		for _, k := range m.keys {
			p := m.keyPlayers[k.Address]
			if p == "" {
				p = "not a player"
			}
			mark := ""
			if m.signer != nil && m.signer.Address == k.Address {
				mark = "★ "
			}
			parts = append(parts, fmt.Sprintf("%s%s (%s)", mark, k.Name, p))
		}
		m.addLog("info", "Keys in the "+m.c.KeyringLabel()+": "+strings.Join(parts, ", ")+" — choose with /key <name>", "")
		return nil, nil
	}
	for _, k := range m.keys {
		if k.Name == name || k.Address == name {
			// Remember for next time, and use it now (it outranks client.toml's default this session).
			m.opts.KeyName = k.Name
			saveConfig(savedConfig{AccountName: k.Name, AccountAddress: k.Address, PlayerID: m.keyPlayers[k.Address]})
			m.addLog("info", "Switched signing key to "+k.Name, "")
			if d := m.c.DefaultKey; d != "" && d != k.Name {
				m.addLog("info", fmt.Sprintf("client.toml's keyring-default-keyname is %q, which is used at start-up. To make %s the default: structsd config set client keyring-default-keyname %s", d, k.Name, k.Name), "")
			}
			m.acct, m.guild, m.members = nil, nil, nil
			m.opts.View = ""
			m.loading["boot"] = true
			return m.boot(), nil
		}
	}
	return nil, fmt.Errorf("no key named %q in the %s (see /key)", name, m.c.KeyringLabel())
}

func cmdUnlock(m *Model, _ []string) (tea.Cmd, error) {
	if m.keyring.Hint == "" {
		m.keyring.Hint = "Enter the passphrase for the " + m.c.KeyringLabel() + "."
	}
	m.unlocking = true
	m.pass.SetValue("")
	m.pass.Focus()
	m.input.Blur()
	return nil, nil
}
