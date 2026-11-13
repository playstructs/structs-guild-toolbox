// Package art renders the Structs reactor as animated terminal pixel art.
//
// The sprite is stored as a palette + letter grid (reactorNN.txt, generated
// from the reactor illustration by block-majority downsampling). Each terminal
// cell shows two vertical pixels using the upper-half block "▀" with
// foreground = top pixel and background = bottom pixel.
//
// Animation layers on top of the static sprite:
//   - the alpha tube breathes (purples brighten and dim)
//   - bubbles rise through the tube
//   - the alpha crystal pulses
//   - the status window above the tube blinks
package art

import (
	_ "embed"
	"fmt"
	"math"
	"math/rand"
	"strconv"
	"strings"

	"github.com/muesli/termenv"
)

//go:embed reactor40.txt
var reactor40 string

//go:embed reactor20.txt
var reactor20 string

type rgb struct{ r, g, b float64 }

func hex(h string) rgb {
	h = strings.TrimPrefix(h, "#")
	v, _ := strconv.ParseUint(h, 16, 32)
	return rgb{float64(v >> 16 & 0xff), float64(v >> 8 & 0xff), float64(v & 0xff)}
}

func (c rgb) mix(o rgb, t float64) rgb {
	if t < 0 {
		t = 0
	}
	if t > 1 {
		t = 1
	}
	return rgb{c.r + (o.r-c.r)*t, c.g + (o.g-c.g)*t, c.b + (o.b-c.b)*t}
}

func (c rgb) hex() string {
	cl := func(v float64) int { return int(math.Max(0, math.Min(255, math.Round(v)))) }
	return fmt.Sprintf("#%02x%02x%02x", cl(c.r), cl(c.g), cl(c.b))
}

func (c rgb) lum() float64 { return (0.2126*c.r + 0.7152*c.g + 0.0722*c.b) / 255 }

// Sprite is a parsed pixel grid.
type Sprite struct {
	W, H    int
	px      [][]int // palette index, -1 = transparent
	palette []rgb
	tube    [][]bool // animated alpha tube cells
	crystal [][]bool // the alpha crystal inside the tube
	window  [][]bool // the small status window at the top
	tubeX0  int
	tubeX1  int
	tubeY0  int
	tubeY1  int
}

var (
	purpleHues  = "gilmEFHIA" // tube purples in the generated palette
	crystalHues = "vBzGu"     // crystal reds/pinks
)

func parse(src string) *Sprite {
	s := &Sprite{}
	letterIdx := map[byte]int{}
	var rows []string
	for _, line := range strings.Split(strings.TrimSpace(src), "\n") {
		line = strings.TrimRight(line, "\r")
		if len(line) > 2 && line[1] == ' ' && line[2] == '#' {
			letterIdx[line[0]] = len(s.palette)
			s.palette = append(s.palette, hex(line[2:]))
			continue
		}
		rows = append(rows, line)
	}
	s.H = len(rows)
	for _, r := range rows {
		if len(r) > s.W {
			s.W = len(r)
		}
	}
	mk := func() [][]bool {
		g := make([][]bool, s.H)
		for i := range g {
			g[i] = make([]bool, s.W)
		}
		return g
	}
	s.tube, s.crystal, s.window = mk(), mk(), mk()
	s.px = make([][]int, s.H)
	// The background colour is palette entry 'a' (the most common colour).
	bg := letterIdx['a']
	for y, r := range rows {
		s.px[y] = make([]int, s.W)
		for x := 0; x < s.W; x++ {
			s.px[y][x] = -1
			if x >= len(r) || r[x] == '.' {
				continue
			}
			idx, ok := letterIdx[r[x]]
			if !ok || idx == bg {
				continue
			}
			s.px[y][x] = idx
		}
	}
	// Locate the tube: purple pixels in the lower 60% of the sprite. The
	// crystal is the red cluster inside it; the window is purple above it.
	s.tubeX0, s.tubeX1, s.tubeY0, s.tubeY1 = s.W, 0, s.H, 0
	for y, r := range rows {
		for x := 0; x < len(r); x++ {
			c := r[x]
			switch {
			case strings.IndexByte(purpleHues, c) >= 0 && y > s.H*2/5:
				s.tube[y][x] = true
				s.tubeX0, s.tubeX1 = min(s.tubeX0, x), max(s.tubeX1, x)
				s.tubeY0, s.tubeY1 = min(s.tubeY0, y), max(s.tubeY1, y)
			case strings.IndexByte(purpleHues, c) >= 0:
				s.window[y][x] = true
			}
		}
	}
	// Crystal colours also appear in the dark band beside the tube, so only
	// count them inside the tube's columns.
	for y, r := range rows {
		for x := s.tubeX0; x <= s.tubeX1 && x < len(r); x++ {
			if strings.IndexByte(crystalHues, r[x]) >= 0 && y >= s.tubeY0 && y <= s.tubeY1 {
				s.crystal[y][x] = true
			}
		}
	}
	return s
}

var (
	large = parse(reactor40)
	small = parse(reactor20)
)

// Size of a variant in terminal cells (two pixels per row).
func Size(compact bool) (w, h int) {
	s := large
	if compact {
		s = small
	}
	return s.W, (s.H + 1) / 2
}

type bubble struct {
	x int
	y float64
	v float64
}

// Reactor is an animated reactor. Advance it with Tick and draw with Render.
type Reactor struct {
	sprite  *Sprite
	frame   int
	bubbles []bubble
	rng     *rand.Rand
	// Charge 0..1 raises the glow; drive it with how much alpha is infused.
	Charge float64
	ASCII  bool
}

func New(compact bool) *Reactor {
	s := large
	if compact {
		s = small
	}
	return &Reactor{sprite: s, rng: rand.New(rand.NewSource(7)), Charge: 0.5}
}

func (r *Reactor) Width() int  { return r.sprite.W }
func (r *Reactor) Height() int { return (r.sprite.H + 1) / 2 }

// Tick advances the animation by one frame.
func (r *Reactor) Tick() {
	r.frame++
	s := r.sprite
	if s.tubeX1 <= s.tubeX0 {
		return
	}
	// spawn
	maxBubbles := 3 + int(r.Charge*6)
	if len(r.bubbles) < maxBubbles && r.rng.Float64() < 0.25+r.Charge*0.3 {
		x := s.tubeX0 + 1 + r.rng.Intn(max(1, s.tubeX1-s.tubeX0-1))
		r.bubbles = append(r.bubbles, bubble{x: x, y: float64(s.tubeY1), v: 0.35 + r.rng.Float64()*0.5})
	}
	// move
	alive := r.bubbles[:0]
	for _, b := range r.bubbles {
		b.y -= b.v
		if r.rng.Float64() < 0.08 {
			b.x += r.rng.Intn(3) - 1
		}
		if int(b.y) >= s.tubeY0 && b.x >= s.tubeX0 && b.x <= s.tubeX1 {
			alive = append(alive, b)
		}
	}
	r.bubbles = alive
}

var (
	tubeBright    = hex("#f6e6ff")
	crystalBright = hex("#ff7ab8")
	windowBright  = hex("#c9a8ff")
	bubbleColor   = hex("#f8eefe")
)

// colorAt returns the animated colour of a pixel and whether it is visible.
func (r *Reactor) colorAt(x, y int) (rgb, bool) {
	s := r.sprite
	if y < 0 || y >= s.H || x < 0 || x >= s.W {
		return rgb{}, false
	}
	idx := s.px[y][x]
	if idx < 0 {
		return rgb{}, false
	}
	c := s.palette[idx]
	t := float64(r.frame)
	switch {
	case s.tube[y][x]:
		// a slow breathing glow plus a band of light that sweeps upward
		breathe := 0.5 + 0.5*math.Sin(t/9)
		band := 0.5 + 0.5*math.Sin(float64(y)/2.2+t/3)
		c = c.mix(tubeBright, (0.08+0.18*r.Charge)*breathe+0.10*band*band)
		for _, b := range r.bubbles {
			if b.x == x && int(b.y) == y {
				return bubbleColor, true
			}
		}
	case s.crystal[y][x]:
		pulse := 0.5 + 0.5*math.Sin(t/5)
		c = c.mix(crystalBright, 0.15+0.45*pulse*pulse)
	case s.window[y][x]:
		if (r.frame/6)%5 != 0 {
			c = c.mix(windowBright, 0.6)
		}
	}
	return c, true
}

// Render draws the current frame. The profile decides how colours are
// emitted (truecolor, 256, 16); termenv.Ascii falls back to a character ramp.
func (r *Reactor) Render(p termenv.Profile) string {
	if r.ASCII || p == termenv.Ascii {
		return r.renderASCII()
	}
	s := r.sprite
	var b strings.Builder
	for y := 0; y < s.H; y += 2 {
		for x := 0; x < s.W; x++ {
			top, okT := r.colorAt(x, y)
			bot, okB := r.colorAt(x, y+1)
			switch {
			case !okT && !okB:
				b.WriteByte(' ')
			case okT && okB:
				b.WriteString(termenv.String("▀").Foreground(p.Color(top.hex())).Background(p.Color(bot.hex())).String())
			case okT:
				b.WriteString(termenv.String("▀").Foreground(p.Color(top.hex())).String())
			default:
				b.WriteString(termenv.String("▄").Foreground(p.Color(bot.hex())).String())
			}
		}
		if y+2 < s.H {
			b.WriteByte('\n')
		}
	}
	return b.String()
}

// renderASCII draws with plain characters chosen by brightness — for terminals
// without colour, logs, or the old-school look (--ascii).
func (r *Reactor) renderASCII() string {
	const ramp = " .:-=+*%#@"
	s := r.sprite
	var b strings.Builder
	for y := 0; y < s.H; y += 2 {
		for x := 0; x < s.W; x++ {
			top, okT := r.colorAt(x, y)
			bot, okB := r.colorAt(x, y+1)
			if !okT && !okB {
				b.WriteByte(' ')
				continue
			}
			var l float64
			n := 0.0
			if okT {
				l += top.lum()
				n++
			}
			if okB {
				l += bot.lum()
				n++
			}
			l /= n
			// tube and crystal get distinctive glyphs
			switch {
			case s.crystal[y][x] || (y+1 < s.H && s.crystal[y+1][x]):
				b.WriteByte('A')
			case s.tube[y][x] || (y+1 < s.H && s.tube[y+1][x]):
				if c, _ := r.colorAt(x, y); c == bubbleColor {
					b.WriteByte('o')
				} else {
					b.WriteByte(":;|"[(x+r.frame/2)%3])
				}
			default:
				b.WriteByte(ramp[int(math.Min(float64(len(ramp)-1), l*float64(len(ramp))))])
			}
		}
		if y+2 < s.H {
			b.WriteByte('\n')
		}
	}
	return b.String()
}
