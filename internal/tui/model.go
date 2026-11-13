// Package tui is the interactive structs client.
package tui

import (
	"context"
	"encoding/json"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/charmbracelet/bubbles/spinner"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/termenv"

	"github.com/playstructs/structs-guild-toolbox/internal/art"
	"github.com/playstructs/structs-guild-toolbox/internal/chain"
	"github.com/playstructs/structs-guild-toolbox/internal/guild"
	"github.com/playstructs/structs-guild-toolbox/internal/wallet"
)

type tab int

const (
	tabWallet tab = iota
	tabStake
	tabGuild
	tabActivity
)

var tabNames = []string{"Wallet", "Stake", "Guild", "Activity"}

// Options configure the app at start-up.
type Options struct {
	Client  *chain.Client
	KeyName string // signing key; default from saved config
	View    string // player id / address to open instead of your own
	ASCII   bool
	DryRun  bool // simulate only; never sign or broadcast
}

type txStage int

const (
	stagePlanning txStage = iota
	stageSimulating
	stageReady
	stagePassphrase
	stageSigning
	stageConfirming
	stageDone
	stageFailed
)

type pendingTx struct {
	stage  txStage
	plan   *wallet.Plan
	prep   *chain.Prepared
	err    error
	hash   string
	result chain.TxResult
	what   string // command text, for the log
}

type logEntry struct {
	at   time.Time
	kind string // ok | err | info | tx
	text string
	hash string
}

type Model struct {
	opts   Options
	c      *chain.Client
	ctx    context.Context
	cancel context.CancelFunc

	keys         []chain.Key
	keyPlayers   map[string]string
	localKeys    map[string]bool
	signer       *chain.Signer
	signerPlayer string

	vals    map[string]*chain.Validator
	acct    *wallet.Account
	viewing string // player id shown
	guild   *guild.View
	members []chain.Player
	status  chain.NodeStatus
	unbond  string

	tab     tab
	input   textinput.Model
	sugs    []command
	sugSel  int
	history []string
	histIdx int
	scroll  int

	spin    spinner.Model
	loading map[string]bool
	pending *pendingTx
	pass    textinput.Model
	log     []logEntry
	flash   string
	flashOK bool

	reactor      *art.Reactor
	reactorSmall *art.Reactor
	profile      termenv.Profile
	width        int
	height       int
	showHelp     bool
}

func New(o Options) Model {
	ctx, cancel := context.WithCancel(context.Background())
	in := textinput.New()
	in.Prompt = "› "
	in.PromptStyle = sAlpha
	in.Placeholder = "Type / for commands, or a player id to look someone up"
	in.PlaceholderStyle = sFaint
	in.TextStyle = sText
	in.Cursor.Style = sAlpha
	in.Focus()

	pass := textinput.New()
	pass.Prompt = "passphrase › "
	pass.EchoMode = textinput.EchoPassword
	pass.EchoCharacter = '•'

	sp := spinner.New()
	sp.Spinner = spinner.Spinner{Frames: []string{"·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"}, FPS: 90 * time.Millisecond}
	sp.Style = sCrystal

	big, small := art.New(false), art.New(true)
	big.ASCII, small.ASCII = o.ASCII, o.ASCII

	return Model{
		opts: o, c: o.Client, ctx: ctx, cancel: cancel,
		input: in, pass: pass, spin: sp,
		loading: map[string]bool{}, localKeys: map[string]bool{},
		reactor: big, reactorSmall: small, profile: lipgloss.ColorProfile(),
	}
}

// ---------------------------------------------------------------- messages

type tickMsg time.Time
type statusMsg struct {
	st  chain.NodeStatus
	err error
}
type bootMsg struct {
	keys         []chain.Key
	signer       *chain.Signer
	signerPlayer string
	vals         map[string]*chain.Validator
	unbond       string
	err          error
	note         string
	keyPlayers   map[string]string // key address -> player id ("" = unregistered)
	keySource    string
}
type acctMsg struct {
	acct *wallet.Account
	err  error
}
type guildMsg struct {
	v   *guild.View
	err error
}
type membersMsg struct {
	m   []chain.Player
	err error
}
type planMsg struct {
	plan *wallet.Plan
	err  error
	what string
}
type preparedMsg struct {
	prep *chain.Prepared
	err  error
}
type broadcastMsg struct {
	hash string
	err  error
}
type confirmedMsg struct {
	res chain.TxResult
	err error
}
type flashMsg struct {
	text string
	ok   bool
}

func tick() tea.Cmd {
	return tea.Tick(110*time.Millisecond, func(t time.Time) tea.Msg { return tickMsg(t) })
}

func (m Model) pollStatus(delay time.Duration) tea.Cmd {
	return tea.Tick(delay, func(time.Time) tea.Msg {
		ctx, cancel := context.WithTimeout(m.ctx, 4*time.Second)
		defer cancel()
		st, err := m.c.Status(ctx)
		return statusMsg{st, err}
	})
}

func (m Model) Init() tea.Cmd {
	return tea.Batch(tick(), m.spin.Tick, m.pollStatus(0), m.boot(), textinput.Blink)
}

// ---------------------------------------------------------------- config

type savedConfig struct {
	AccountName    string `json:"account_name"`
	AccountAddress string `json:"account_address"`
	PlayerID       string `json:"account_player_id"`
}

func configPath() string {
	if d := os.Getenv("CONFIG_DIR"); d != "" {
		return filepath.Join(d, "config.json")
	}
	h, _ := os.UserHomeDir()
	return filepath.Join(h, ".structs-guild-admin", "config.json")
}

func loadConfig() savedConfig {
	var c savedConfig
	if b, err := os.ReadFile(configPath()); err == nil {
		_ = json.Unmarshal(b, &c)
	}
	return c
}

func saveConfig(c savedConfig) {
	_ = os.MkdirAll(filepath.Dir(configPath()), 0o700)
	b, _ := json.MarshalIndent(c, "", "  ")
	_ = os.WriteFile(configPath(), b, 0o600)
}

// ---------------------------------------------------------------- commands (async work)

func (m Model) boot() tea.Cmd {
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(m.ctx, 60*time.Second)
		defer cancel()
		var out bootMsg
		keys, err := m.c.Keys(ctx)
		if err != nil {
			out.note = "Could not read the " + m.c.KeyringLabel() + ": " + err.Error()
		}
		out.keys = keys

		// Which player does each local key belong to? (also drives /key)
		out.keyPlayers = map[string]string{}
		var mu sync.Mutex
		var wg sync.WaitGroup
		for _, k := range keys {
			wg.Add(1)
			go func(k chain.Key) {
				defer wg.Done()
				p, _ := m.c.PlayerOfAddress(ctx, k.Address)
				mu.Lock()
				out.keyPlayers[k.Address] = p
				mu.Unlock()
			}(k)
		}
		wg.Wait()
		inKeyring := func(name string) bool {
			for _, k := range keys {
				if k.Name == name || k.Address == name {
					return true
				}
			}
			return false
		}

		// Signing key, most explicit first:
		//   --key / STRUCTS_ACCOUNT
		//   client.toml keyring-default-keyname (structsd's own default --from)
		//   the key last chosen with /key, if it is in this keyring
		//   the only key in the keyring that belongs to a player
		name, source := m.opts.KeyName, "--key"
		if name == "" && m.c.DefaultKey != "" {
			name, source = m.c.DefaultKey, "client.toml keyring-default-keyname"
		}
		if saved := loadConfig().AccountName; name == "" && saved != "" && inKeyring(saved) {
			name, source = saved, "last used"
		}
		if name == "" {
			var cands []chain.Key
			for _, k := range keys {
				if out.keyPlayers[k.Address] != "" {
					cands = append(cands, k)
				}
			}
			if len(cands) == 1 {
				name, source = cands[0].Name, "only player key in the keyring"
			}
		}
		out.keySource = source
		switch {
		case name != "" && !inKeyring(name):
			out.note = fmt.Sprintf("Key %q (from %s) is not in the %s. Pick one with /key.", name, source, m.c.KeyringLabel())
		case name != "":
			for _, k := range keys {
				if k.Name == name || k.Address == name {
					out.signer = &chain.Signer{Name: k.Name, Address: k.Address, PubKey: k.PubKey}
				}
			}
			out.signerPlayer = out.keyPlayers[out.signer.Address]
			if out.signerPlayer == "" {
				out.note = fmt.Sprintf("Key %s is not registered to a player yet.", out.signer.Name)
			}
		case len(keys) == 0:
			out.note = "No keys in the " + m.c.KeyringLabel() + ". Add one with: structsd keys add <name> --recover"
		default:
			out.note = "No signing key selected. Choose one with /key."
		}
		out.vals, out.err = m.c.Validators(ctx)
		out.unbond = m.c.UnbondingTime(ctx)
		return out
	}
}

func (m Model) loadAccount(target string) tea.Cmd {
	local := m.localKeys
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(m.ctx, 90*time.Second)
		defer cancel()
		a, err := wallet.Load(ctx, m.c, target, local)
		return acctMsg{a, err}
	}
}

func (m Model) loadGuild(id string) tea.Cmd {
	vals, pid := m.vals, m.signerPlayer
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(m.ctx, 90*time.Second)
		defer cancel()
		v, err := guild.Load(ctx, m.c, id, pid, vals)
		return guildMsg{v, err}
	}
}

func (m Model) planCmd(what string, f func(ctx context.Context) (*wallet.Plan, error)) tea.Cmd {
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(m.ctx, 60*time.Second)
		defer cancel()
		p, err := f(ctx)
		return planMsg{p, err, what}
	}
}

func (m Model) prepareCmd(p *wallet.Plan) tea.Cmd {
	s := *m.signer
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(m.ctx, 90*time.Second)
		defer cancel()
		prep, err := m.c.Prepare(ctx, s, p.Msgs)
		return preparedMsg{prep, err}
	}
}

func (m Model) broadcastCmd(prep *chain.Prepared, pass string) tea.Cmd {
	s := *m.signer
	if m.opts.DryRun {
		return func() tea.Msg {
			return broadcastMsg{err: fmt.Errorf("dry-run mode: simulated only, nothing was signed or broadcast")}
		}
	}
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(m.ctx, 90*time.Second)
		defer cancel()
		h, err := m.c.SignAndBroadcast(ctx, s, prep, pass)
		return broadcastMsg{h, err}
	}
}

func (m Model) confirmCmd(hash string) tea.Cmd {
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(m.ctx, 60*time.Second)
		defer cancel()
		r, err := m.c.WaitTx(ctx, hash)
		return confirmedMsg{r, err}
	}
}

func (m *Model) addLog(kind, text, hash string) {
	m.log = append(m.log, logEntry{at: time.Now(), kind: kind, text: text, hash: hash})
}

func (m *Model) setFlash(text string, ok bool) {
	m.flash, m.flashOK = text, ok
}

// ownAccount reports whether the loaded account is the signer's.
func (m *Model) ownAccount() bool {
	return m.acct != nil && m.signer != nil && m.acct.PlayerID == m.signerPlayer
}

func (m *Model) busy() bool {
	for _, v := range m.loading {
		if v {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------- update

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	var cmds []tea.Cmd
	switch msg := msg.(type) {

	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		if m.width <= 0 || m.height <= 0 {
			m.width, m.height = 80, 24 // terminals that report 0x0
		}
		m.input.Width = max(10, m.width-8)
		return m, nil

	case tickMsg:
		m.reactor.Tick()
		m.reactorSmall.Tick()
		return m, tick()

	case spinner.TickMsg:
		var cmd tea.Cmd
		m.spin, cmd = m.spin.Update(msg)
		return m, cmd

	case statusMsg:
		if msg.err == nil {
			m.status = msg.st
		}
		return m, m.pollStatus(4 * time.Second)

	case bootMsg:
		m.loading["boot"] = false
		m.keys = msg.keys
		for _, k := range msg.keys {
			m.localKeys[k.Address] = true
		}
		m.signer, m.signerPlayer = msg.signer, msg.signerPlayer
		m.vals, m.unbond = msg.vals, msg.unbond
		if msg.err != nil {
			m.addLog("err", "Loading validators: "+msg.err.Error(), "")
		}
		if msg.note != "" {
			m.addLog("info", msg.note, "")
			m.setFlash(msg.note, false)
		}
		m.keyPlayers = msg.keyPlayers
		src := "structsd defaults (no client.toml)"
		if m.c.ConfigFile != "" {
			src = tildePath(m.c.ConfigFile)
		}
		m.addLog("info", fmt.Sprintf("Keyring: %s · node %s · from %s", m.c.KeyringLabel(), m.c.Node, src), "")
		if m.signer != nil {
			m.addLog("info", fmt.Sprintf("Signing as %s (%s) — %s", m.signer.Name, wallet.Short(m.signer.Address), msg.keySource), "")
		}
		target := m.opts.View
		if target == "" {
			target = m.signerPlayer
		}
		if target != "" {
			m.viewing = target
			m.loading["acct"] = true
			cmds = append(cmds, m.loadAccount(target))
		} else if m.signer == nil {
			m.tab = tabActivity
			m.input.SetValue("/key ")
			m.input.CursorEnd()
		}
		return m, tea.Batch(cmds...)

	case acctMsg:
		m.loading["acct"] = false
		if msg.err != nil {
			m.setFlash(msg.err.Error(), false)
			m.addLog("err", msg.err.Error(), "")
			return m, nil
		}
		m.acct = msg.acct
		m.viewing = msg.acct.PlayerID
		m.reactor.Charge = chargeOf(msg.acct)
		m.reactorSmall.Charge = m.reactor.Charge
		if g := msg.acct.GuildID(); g != "" && (m.guild == nil || m.guild.Guild.ID != g) {
			m.loading["guild"] = true
			cmds = append(cmds, m.loadGuild(g))
		}
		return m, tea.Batch(cmds...)

	case guildMsg:
		m.loading["guild"] = false
		if msg.err != nil {
			m.addLog("err", msg.err.Error(), "")
			return m, nil
		}
		m.guild = msg.v
		return m, nil

	case membersMsg:
		m.loading["members"] = false
		if msg.err != nil {
			m.setFlash(msg.err.Error(), false)
			return m, nil
		}
		m.members = msg.m
		m.tab = tabGuild
		return m, nil

	case planMsg:
		if m.pending == nil {
			return m, nil // cancelled
		}
		if msg.err != nil {
			m.pending.stage, m.pending.err = stageFailed, msg.err
			return m, nil
		}
		m.pending.plan = msg.plan
		m.pending.stage = stageSimulating
		return m, m.prepareCmd(msg.plan)

	case preparedMsg:
		if m.pending == nil {
			return m, nil
		}
		m.pending.prep = msg.prep
		if msg.err != nil {
			m.pending.stage, m.pending.err = stageFailed, msg.err
			return m, nil
		}
		m.pending.stage = stageReady
		return m, nil

	case broadcastMsg:
		if m.pending == nil {
			return m, nil
		}
		if msg.err != nil {
			m.pending.stage, m.pending.err = stageFailed, msg.err
			m.addLog("err", m.pending.plan.Title+": "+msg.err.Error(), msg.hash)
			return m, nil
		}
		m.pending.hash = msg.hash
		m.pending.stage = stageConfirming
		return m, m.confirmCmd(msg.hash)

	case confirmedMsg:
		if m.pending == nil {
			return m, nil
		}
		m.pending.result = msg.res
		if msg.err != nil {
			m.pending.stage, m.pending.err = stageFailed, msg.err
			m.addLog("err", m.pending.plan.Title+": "+msg.err.Error(), m.pending.hash)
			return m, nil
		}
		m.pending.stage = stageDone
		m.addLog("tx", fmt.Sprintf("%s — block %d", m.pending.plan.Title, msg.res.Height), m.pending.hash)
		m.loading["acct"] = true
		cmds = append(cmds, m.loadAccount(m.viewing))
		if m.guild != nil {
			cmds = append(cmds, m.loadGuild(m.guild.Guild.ID))
		}
		return m, tea.Batch(cmds...)

	case flashMsg:
		m.setFlash(msg.text, msg.ok)
		return m, nil

	case tea.KeyMsg:
		return m.handleKey(msg)
	}
	return m, nil
}

func chargeOf(a *wallet.Account) float64 {
	tot := a.Total()
	if tot.IsZero() {
		return 0.15
	}
	f, _ := new(big.Rat).SetFrac(a.Delegated().Big(), tot.Big()).Float64()
	return 0.2 + 0.8*f
}

func (m Model) handleKey(k tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch k.String() {
	case "ctrl+c":
		m.cancel()
		return m, tea.Quit
	}

	// passphrase entry
	if m.pending != nil && m.pending.stage == stagePassphrase {
		switch k.String() {
		case "esc":
			m.pending = nil
			m.input.Focus()
			return m, nil
		case "enter":
			p := m.pass.Value()
			m.pass.SetValue("")
			m.pending.stage = stageSigning
			return m, m.broadcastCmd(m.pending.prep, p)
		}
		var cmd tea.Cmd
		m.pass, cmd = m.pass.Update(k)
		return m, cmd
	}

	// confirmation card
	if m.pending != nil {
		switch m.pending.stage {
		case stageReady:
			switch k.String() {
			case "enter", "y":
				if m.c.KeyringBackend == "file" {
					m.pending.stage = stagePassphrase
					m.pass.Focus()
					return m, textinput.Blink
				}
				m.pending.stage = stageSigning
				return m, m.broadcastCmd(m.pending.prep, "")
			case "esc", "n":
				m.addLog("info", "Cancelled: "+m.pending.plan.Title, "")
				m.pending = nil
				return m, nil
			}
			return m, nil
		case stageDone, stageFailed:
			if k.String() == "esc" || k.String() == "enter" {
				m.pending = nil
				return m, nil
			}
			// any other key falls through to the prompt and dismisses the card
			m.pending = nil
		default:
			if k.String() == "esc" {
				if m.pending.stage <= stageSimulating {
					m.pending = nil
				}
			}
			return m, nil
		}
	}

	switch k.String() {
	case "esc":
		switch {
		case m.showHelp:
			m.showHelp = false
		case m.input.Value() != "":
			m.input.SetValue("")
			m.updateSuggestions()
		case m.acct != nil && m.signerPlayer != "" && m.acct.PlayerID != m.signerPlayer:
			m.viewing = m.signerPlayer
			m.loading["acct"] = true
			return m, m.loadAccount(m.signerPlayer)
		default:
			m.flash = ""
		}
		return m, nil
	case "tab":
		if len(m.sugs) > 0 {
			m.input.SetValue("/" + m.sugs[m.sugSel].name + " ")
			m.input.CursorEnd()
			m.updateSuggestions()
			return m, nil
		}
		m.tab = (m.tab + 1) % tab(len(tabNames))
		m.scroll = 0
		return m, nil
	case "shift+tab":
		m.tab = (m.tab + tab(len(tabNames)) - 1) % tab(len(tabNames))
		m.scroll = 0
		return m, nil
	case "ctrl+r":
		return m, m.refresh()
	case "pgdown", "ctrl+d":
		m.scroll += max(1, m.bodyHeight()/2)
		return m, nil
	case "pgup", "ctrl+u":
		m.scroll = max(0, m.scroll-max(1, m.bodyHeight()/2))
		return m, nil
	case "up":
		if len(m.sugs) > 0 {
			m.sugSel = (m.sugSel + len(m.sugs) - 1) % len(m.sugs)
			return m, nil
		}
		if len(m.history) > 0 && m.histIdx > 0 {
			m.histIdx--
			m.input.SetValue(m.history[m.histIdx])
			m.input.CursorEnd()
		}
		return m, nil
	case "down":
		if len(m.sugs) > 0 {
			m.sugSel = (m.sugSel + 1) % len(m.sugs)
			return m, nil
		}
		if m.histIdx < len(m.history)-1 {
			m.histIdx++
			m.input.SetValue(m.history[m.histIdx])
			m.input.CursorEnd()
		} else {
			m.histIdx = len(m.history)
			m.input.SetValue("")
		}
		return m, nil
	case "enter":
		line := strings.TrimSpace(m.input.Value())
		// Enter on a half-typed command name completes it (and runs it if it takes no arguments)
		if len(m.sugs) > 0 && !strings.Contains(line, " ") {
			c := m.sugs[m.sugSel]
			if c.minArgs > 0 {
				m.input.SetValue("/" + c.name + " ")
				m.input.CursorEnd()
				m.updateSuggestions()
				return m, nil
			}
			line = "/" + c.name
		}
		m.input.SetValue("")
		m.updateSuggestions()
		if line == "" {
			return m, nil
		}
		m.history = append(m.history, line)
		m.histIdx = len(m.history)
		m.flash = ""
		return m.execute(line)
	case "?":
		if m.input.Value() == "" {
			m.showHelp = !m.showHelp
			return m, nil
		}
	}

	var cmd tea.Cmd
	m.input, cmd = m.input.Update(k)
	m.updateSuggestions()
	return m, cmd
}

func (m *Model) refresh() tea.Cmd {
	var cmds []tea.Cmd
	if m.viewing != "" {
		m.loading["acct"] = true
		cmds = append(cmds, m.loadAccount(m.viewing))
	}
	if m.guild != nil {
		m.loading["guild"] = true
		cmds = append(cmds, m.loadGuild(m.guild.Guild.ID))
	}
	return tea.Batch(cmds...)
}

// startPlan opens the confirmation card and plans in the background.
func (m *Model) startPlan(what string, f func(ctx context.Context) (*wallet.Plan, error)) tea.Cmd {
	m.pending = &pendingTx{stage: stagePlanning, what: what}
	return m.planCmd(what, f)
}

func tildePath(p string) string {
	if h, err := os.UserHomeDir(); err == nil && strings.HasPrefix(p, h) {
		return "~" + strings.TrimPrefix(p, h)
	}
	return p
}
