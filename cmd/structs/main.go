// Command structs is an interactive terminal client for Structs.
//
//	structs                     open the TUI on your own account
//	structs 1-186               open the TUI looking at player 1-186 (read only)
//	structs --key alice         sign with the "alice" key
//	structs --dry-run           simulate everything, never sign
//	structs reactor             just watch the reactor
//	structs snapshot [opts] [inputs...]
//	                            render one frame headlessly (docs/testing)
//
// structsd flags can be passed through: --node, --home, --keyring-backend,
// --chain-id, --fees, --gas-prices. STRUCTSD_FLAGS / STRUCTSD_TX_FLAGS
// environment variables work as in structs.sh.
package main

import (
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/termenv"

	"github.com/playstructs/structs-guild-toolbox/internal/art"
	"github.com/playstructs/structs-guild-toolbox/internal/chain"
	"github.com/playstructs/structs-guild-toolbox/internal/tui"
)

func main() {
	fs := flag.NewFlagSet("structs", flag.ExitOnError)
	var (
		key     = fs.String("key", os.Getenv("STRUCTS_ACCOUNT"), "keyring key to sign with")
		bin     = fs.String("structsd", envOr("STRUCTSD", "structsd"), "path to structsd")
		node    = fs.String("node", "", "CometBFT RPC, e.g. tcp://localhost:26657")
		home    = fs.String("home", "", "structsd home directory")
		backend = fs.String("keyring-backend", "", "keyring backend (os|file|test)")
		chainID = fs.String("chain-id", os.Getenv("STRUCTS_CHAIN_ID"), "chain id (default: detected)")
		fees    = fs.String("fees", "", "transaction fees, e.g. 0ualpha")
		dryRun  = fs.Bool("dry-run", false, "simulate transactions but never sign or broadcast")
		ascii   = fs.Bool("ascii", false, "draw the reactor with plain ASCII characters")
		size    = fs.String("size", "140x44", "snapshot: terminal size WxH")
		frames  = fs.Int("frames", 12, "snapshot: animation frames to advance")
		noColor = fs.Bool("no-color", false, "snapshot: plain text output")
	)
	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, "usage: structs [flags] [player-id|address]\n       structs reactor\n       structs snapshot [flags] [inputs...]\n\nflags:")
		fs.PrintDefaults()
	}

	args := os.Args[1:]
	mode := ""
	if len(args) > 0 && (args[0] == "snapshot" || args[0] == "reactor") {
		mode, args = args[0], args[1:]
	}
	_ = fs.Parse(args)

	flags := strings.Fields(os.Getenv("STRUCTSD_FLAGS"))
	add := func(name, v string) {
		if v != "" {
			flags = append(flags, "--"+name, v)
		}
	}
	add("node", *node)
	add("home", *home)
	add("keyring-backend", *backend)
	txFlags := strings.Fields(os.Getenv("STRUCTSD_TX_FLAGS"))
	if *fees != "" {
		txFlags = append(txFlags, "--fees", *fees)
	}
	if *chainID != "" {
		flags = append(flags, "--chain-id", *chainID)
	}
	client := chain.New(*bin, flags, txFlags)

	opts := tui.Options{Client: client, KeyName: *key, View: fs.Arg(0), ASCII: *ascii, DryRun: *dryRun}

	switch mode {
	case "snapshot":
		var w, h int
		fmt.Sscanf(*size, "%dx%d", &w, &h)
		if *noColor {
			lipgloss.SetColorProfile(termenv.Ascii)
		} else {
			lipgloss.SetColorProfile(termenv.TrueColor)
		}
		opts.View = ""
		fmt.Println(tui.Snapshot(opts, w, h, fs.Args(), *frames))
		return
	case "reactor":
		runReactor(*ascii)
		return
	}

	p := tea.NewProgram(tui.New(opts), tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// reactor mode: a tiny program that just animates the reactor.
type reactorModel struct{ r *art.Reactor }

type frame struct{}

func (m reactorModel) Init() tea.Cmd { return next() }
func next() tea.Cmd {
	return tea.Tick(100*time.Millisecond, func(time.Time) tea.Msg { return frame{} })
}
func (m reactorModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg.(type) {
	case tea.KeyMsg:
		return m, tea.Quit
	case frame:
		m.r.Tick()
		return m, next()
	}
	return m, nil
}
func (m reactorModel) View() string {
	return "\n" + m.r.Render(lipgloss.ColorProfile()) + "\n\n   " + lipgloss.NewStyle().Foreground(lipgloss.Color("#6b7994")).Render("any key to exit")
}

func runReactor(ascii bool) {
	r := art.New(false)
	r.ASCII = ascii
	r.Charge = 0.9
	if _, err := tea.NewProgram(reactorModel{r}, tea.WithAltScreen()).Run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
	}
}
