package render

// CPU side of the vector renderer: curve flattening and stroke expansion.
// Everything here is pure (no GPU), so it can be unit tested headless.

import "core:math"
import "core:math/linalg"

Vec2  :: [2]f32
Color :: [4]f32 // straight RGBA, 0..1

// A cubic Bézier knot: position, handles (absolute positions) and stroke width.
Knot :: struct {
	pos:        Vec2,
	handle_in:  Vec2,
	handle_out: Vec2,
	width:      f32,
}

// Sample on a flattened path: position plus interpolated stroke width.
Sample :: struct {
	pos:   Vec2,
	width: f32,
}

// Number of line segments needed to approximate a cubic within `tolerance`.
// Uses the bound  err <= max|B''| / (8 n^2)  with  max|B''| <= 6 max(|d1|, |d2|).
cubic_segment_count :: proc(p0, p1, p2, p3: Vec2, tolerance: f32) -> int {
	d1 := linalg.length(p0 - 2*p1 + p2)
	d2 := linalg.length(p1 - 2*p2 + p3)
	dd := max(d1, d2)
	n  := math.sqrt(0.75 * dd / max(tolerance, 1e-6))
	return clamp(int(math.ceil(n)), 1, 512)
}

cubic_point :: proc(p0, p1, p2, p3: Vec2, t: f32) -> Vec2 {
	u := 1 - t
	return u*u*u*p0 + 3*u*u*t*p1 + 3*u*t*t*p2 + t*t*t*p3
}

// Flattens a knot list into samples. `out` is appended to, not cleared.
// For closed paths the last segment returns to the first knot and the
// duplicate end sample is omitted.
flatten_knots :: proc(knots: []Knot, closed: bool, tolerance: f32, out: ^[dynamic]Sample) {
	if len(knots) == 0 do return
	append(out, Sample{knots[0].pos, knots[0].width})
	seg_count := closed ? len(knots) : len(knots) - 1
	for i in 0 ..< seg_count {
		a := knots[i]
		b := knots[(i + 1) % len(knots)]
		n := cubic_segment_count(a.pos, a.handle_out, b.handle_in, b.pos, tolerance)
		last := n
		if closed && i == seg_count - 1 do last = n - 1
		for s in 1 ..= last {
			t := f32(s) / f32(n)
			append(out, Sample{
				cubic_point(a.pos, a.handle_out, b.handle_in, b.pos, t),
				math.lerp(a.width, b.width, t),
			})
		}
	}
}

// Triangle fan anchored at the first point. Rendered with the stencil
// winding pipeline, this fills any polygon (concave, self-intersecting,
// several contours) with the non-zero rule.
fan_triangles :: proc(contour: []Sample, out: ^[dynamic]Vec2) {
	if len(contour) < 3 do return
	p0 := contour[0].pos
	for i in 1 ..< len(contour) - 1 {
		append(out, p0, contour[i].pos, contour[i + 1].pos)
	}
}

// Expands a polyline with per-sample width into triangles: one quad per
// segment plus a disc at every sample (round joins and caps). Overlaps are
// harmless because strokes are resolved through the stencil buffer.
// `tolerance` is the maximum chord error for the discs, in world units.
stroke_triangles :: proc(samples: []Sample, closed: bool, tolerance: f32, out: ^[dynamic]Vec2) {
	n := len(samples)
	if n == 0 do return

	for s in samples do disc_triangles(s.pos, s.width * 0.5, tolerance, out)

	seg_count := closed ? n : n - 1
	for i in 0 ..< seg_count {
		a := samples[i]
		b := samples[(i + 1) % n]
		d := b.pos - a.pos
		l := linalg.length(d)
		if l < 1e-6 do continue
		nrm := Vec2{-d.y, d.x} / l
		a0 := a.pos + nrm * a.width * 0.5
		a1 := a.pos - nrm * a.width * 0.5
		b0 := b.pos + nrm * b.width * 0.5
		b1 := b.pos - nrm * b.width * 0.5
		append(out, a0, b0, b1, a0, b1, a1)
	}
}

disc_triangles :: proc(c: Vec2, r: f32, tolerance: f32, out: ^[dynamic]Vec2) {
	if r <= 0 do return
	// Chord error of a regular n-gon: r (1 - cos(pi/n)) <= tolerance.
	ratio := clamp(1 - tolerance / r, -1, 1)
	segs  := ratio <= -1 ? 3 : int(math.ceil(math.PI / math.acos(ratio)))
	segs   = clamp(segs, 6, 128)
	step  := math.TAU / f32(segs)
	prev  := c + Vec2{r, 0}
	for i in 1 ..= segs {
		a    := step * f32(i)
		next := c + r * Vec2{math.cos(a), math.sin(a)}
		append(out, c, prev, next)
		prev = next
	}
}

Rect :: struct {
	min, max: Vec2,
}

bounds_of :: proc(points: []Vec2) -> Rect {
	r := Rect{{max(f32), max(f32)}, {min(f32), min(f32)}}
	for p in points {
		r.min = linalg.min(r.min, p)
		r.max = linalg.max(r.max, p)
	}
	return r
}

// Knots for a smooth closed circle-ish blob (4 knots, kappa handles).
ellipse_knots :: proc(center, radius: Vec2, width: f32) -> [4]Knot {
	K :: 0.5522847498
	k := radius * K
	return {
		{center + {radius.x, 0}, center + {radius.x, -k.y}, center + {radius.x, k.y}, width},
		{center + {0, radius.y}, center + {k.x, radius.y}, center + {-k.x, radius.y}, width},
		{center + {-radius.x, 0}, center + {-radius.x, k.y}, center + {-radius.x, -k.y}, width},
		{center + {0, -radius.y}, center + {-k.x, -radius.y}, center + {k.x, -radius.y}, width},
	}
}
