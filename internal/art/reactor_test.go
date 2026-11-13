package art

import (
	"strings"
	"testing"

	"github.com/muesli/termenv"
)

func TestSpritesParse(t *testing.T) {
	for name, s := range map[string]*Sprite{"large": large, "small": small} {
		if s.W == 0 || s.H == 0 || len(s.palette) == 0 {
			t.Fatalf("%s: empty sprite", name)
		}
		if s.tubeX1 <= s.tubeX0 || s.tubeY1 <= s.tubeY0 {
			t.Fatalf("%s: tube not found (%d..%d x %d..%d)", name, s.tubeX0, s.tubeX1, s.tubeY0, s.tubeY1)
		}
		t.Logf("%s: %dx%d tube x%d..%d y%d..%d", name, s.W, s.H, s.tubeX0, s.tubeX1, s.tubeY0, s.tubeY1)
	}
}

func TestRender(t *testing.T) {
	r := New(false)
	for i := 0; i < 30; i++ {
		r.Tick()
	}
	out := r.Render(termenv.TrueColor)
	if lines := strings.Count(out, "\n") + 1; lines != r.Height() {
		t.Fatalf("got %d lines, want %d", lines, r.Height())
	}
	t.Log("\n" + r.Render(termenv.Ascii))
}
