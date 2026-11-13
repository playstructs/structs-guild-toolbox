package tui

import "github.com/charmbracelet/lipgloss"

// Colours lifted from the reactor sprite.
var (
	cAlpha    = lipgloss.Color("#a46cf0") // tube purple
	cAlphaHi  = lipgloss.Color("#dcadeb")
	cCrystal  = lipgloss.Color("#ff7ab8")
	cHazard   = lipgloss.Color("#e59c39")
	cSteel    = lipgloss.Color("#aeb6c4")
	cSteelDim = lipgloss.Color("#6b7994")
	cFaint    = lipgloss.Color("#4b5567")
	cText     = lipgloss.Color("#e6e9ef")
	cOK       = lipgloss.Color("#6fd39b")
	cErr      = lipgloss.Color("#ff6b6b")
	cWarn     = cHazard
)

var (
	sBold    = lipgloss.NewStyle().Bold(true).Foreground(cText)
	sText    = lipgloss.NewStyle().Foreground(cText)
	sDim     = lipgloss.NewStyle().Foreground(cSteelDim)
	sFaint   = lipgloss.NewStyle().Foreground(cFaint)
	sSteel   = lipgloss.NewStyle().Foreground(cSteel)
	sAlpha   = lipgloss.NewStyle().Foreground(cAlpha)
	sAlphaHi = lipgloss.NewStyle().Foreground(cAlphaHi).Bold(true)
	sCrystal = lipgloss.NewStyle().Foreground(cCrystal)
	sHazard  = lipgloss.NewStyle().Foreground(cHazard)
	sOK      = lipgloss.NewStyle().Foreground(cOK)
	sErr     = lipgloss.NewStyle().Foreground(cErr)
	sWarn    = lipgloss.NewStyle().Foreground(cWarn)

	sSection = lipgloss.NewStyle().Foreground(cSteelDim).Bold(true)

	sTabActive   = lipgloss.NewStyle().Foreground(lipgloss.Color("#0d0f14")).Background(cAlpha).Bold(true).Padding(0, 1)
	sTabInactive = lipgloss.NewStyle().Foreground(cSteelDim).Padding(0, 1)

	sPrompt       = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(cFaint).Padding(0, 1)
	sPromptActive = sPrompt.BorderForeground(cAlpha)

	sCard    = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(cAlpha).Padding(0, 2)
	sCardErr = sCard.BorderForeground(cErr)
	sCardOK  = sCard.BorderForeground(cOK)
	sBadge   = lipgloss.NewStyle().Foreground(lipgloss.Color("#0d0f14")).Background(cHazard).Bold(true).Padding(0, 1)
	sSugSel  = lipgloss.NewStyle().Foreground(cText).Background(lipgloss.Color("#2a2f3a"))
	sKey     = lipgloss.NewStyle().Foreground(cSteel).Bold(true)
)
