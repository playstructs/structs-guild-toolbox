package art

import (
	"image"
	"image/color"
	"image/png"
	"os"
	"testing"
)

// go test ./internal/art -run TestDumpFrames  (with ART_DUMP=<dir>)
func TestDumpFrames(t *testing.T) {
	dir := os.Getenv("ART_DUMP")
	if dir == "" {
		t.Skip("set ART_DUMP to write frames")
	}
	r := New(false)
	r.Charge = 0.9
	const sc, n = 8, 4
	w, h := r.sprite.W, r.sprite.H
	out := image.NewRGBA(image.Rect(0, 0, (w+2)*sc*n, h*sc))
	for f := 0; f < n; f++ {
		for i := 0; i < 9; i++ {
			r.Tick()
		}
		for y := 0; y < h; y++ {
			for x := 0; x < w; x++ {
				c, ok := r.colorAt(x, y)
				if !ok {
					c = hex("#1c3444")
				}
				for yy := 0; yy < sc; yy++ {
					for xx := 0; xx < sc; xx++ {
						out.Set(f*(w+2)*sc+x*sc+xx, y*sc+yy, color.RGBA{uint8(c.r), uint8(c.g), uint8(c.b), 255})
					}
				}
			}
		}
	}
	fh, _ := os.Create(dir + "/frames.png")
	defer fh.Close()
	png.Encode(fh, out)
}
