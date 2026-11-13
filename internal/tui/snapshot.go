package tui

import (
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/cursor"
	"github.com/charmbracelet/bubbles/spinner"
	tea "github.com/charmbracelet/bubbletea"
)

// Snapshot drives the model headlessly: it boots, applies each input line
// (commands typed into the prompt, or "tab"/"esc"/"enter" keys), waits for
// the resulting work to finish, and returns the final frame. Used by
// `structs snapshot` for docs, debugging and tests.
func Snapshot(o Options, width, height int, inputs []string, frames int) string {
	o.DryRun = true // a snapshot must never sign
	var m tea.Model = New(o)
	m, _ = m.Update(tea.WindowSizeMsg{Width: width, Height: height})
	mm := m.(Model)
	pump(&m, []tea.Cmd{mm.boot(), mm.pollStatus(0)})
	for _, in := range inputs {
		var cmd tea.Cmd
		switch in {
		case "tab", "shift+tab", "esc", "enter", "ctrl+r", "?":
			m, cmd = m.Update(keyMsg(in))
		default:
			for _, r := range strings.TrimSuffix(in, "…") {
				m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
			}
			if !strings.HasSuffix(in, "…") {
				m, cmd = m.Update(tea.KeyMsg{Type: tea.KeyEnter})
			}
		}
		pump(&m, []tea.Cmd{cmd})
	}
	for i := 0; i < frames; i++ {
		m, _ = m.Update(tickMsg(time.Now()))
	}
	return m.View()
}

func keyMsg(s string) tea.KeyMsg {
	switch s {
	case "tab":
		return tea.KeyMsg{Type: tea.KeyTab}
	case "shift+tab":
		return tea.KeyMsg{Type: tea.KeyShiftTab}
	case "esc":
		return tea.KeyMsg{Type: tea.KeyEsc}
	case "enter":
		return tea.KeyMsg{Type: tea.KeyEnter}
	case "ctrl+r":
		return tea.KeyMsg{Type: tea.KeyCtrlR}
	}
	return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(s)}
}

// pump runs commands to completion, feeding their messages back into the
// model, but ignores animation and polling loops.
func pump(m *tea.Model, cmds []tea.Cmd) {
	for len(cmds) > 0 {
		c := cmds[0]
		cmds = cmds[1:]
		if c == nil {
			continue
		}
		ch := make(chan tea.Msg, 1)
		go func() { ch <- c() }()
		var msg tea.Msg
		select {
		case msg = <-ch:
		case <-time.After(150 * time.Second):
			continue
		}
		switch msg := msg.(type) {
		case tea.BatchMsg:
			cmds = append(cmds, msg...)
			continue
		case tickMsg, spinner.TickMsg, cursor.BlinkMsg:
			continue
		case statusMsg:
			*m, _ = (*m).Update(msg) // apply once, don't keep polling
			continue
		}
		var next tea.Cmd
		*m, next = (*m).Update(msg)
		cmds = append(cmds, next)
	}
}
