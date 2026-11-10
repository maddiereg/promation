package core

// Curve geometry used by editing tools: flattening, hit testing, splitting,
// shape builders and freehand curve fitting. Pure functions on knot lists.

import "core:math"
import "core:math/linalg"

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

segment_count :: proc(knots: []Knot, closed: bool) -> int {
	if len(knots) < 2 do return 0
	return closed ? len(knots) : len(knots) - 1
}

segment_is_straight :: proc(a, b: Knot) -> bool {
	return a.handle_out == a.pos && b.handle_in == b.pos
}

// A point on a flattened path, remembering where on the curve it came from.
Flat_Point :: struct {
	pos:     Vec2,
	width:   f32,
	segment: int, // segment index; the point is at parameter t of it
	t:       f32,
}

// Appends the flattened path to `out`. Unlike the renderer's version, closed
// paths repeat the first point at the end, so consecutive pairs are the edges.
flatten :: proc(knots: []Knot, closed: bool, tolerance: f32, out: ^[dynamic]Flat_Point) {
	if len(knots) == 0 do return
	append(out, Flat_Point{knots[0].pos, knots[0].width, 0, 0})
	for i in 0 ..< segment_count(knots, closed) {
		a := knots[i]
		b := knots[(i + 1) % len(knots)]
		n := segment_is_straight(a, b) ? 1 : cubic_segment_count(a.pos, a.handle_out, b.handle_in, b.pos, tolerance)
		for s in 1 ..= n {
			t := f32(s) / f32(n)
			append(out, Flat_Point{cubic_point(a.pos, a.handle_out, b.handle_in, b.pos, t), math.lerp(a.width, b.width, t), i, t})
		}
	}
}

// Closest point of segment ab to p, as (distance, parameter along ab).
point_segment_distance :: proc(p, a, b: Vec2) -> (dist: f32, t: f32) {
	ab := b - a
	l2 := linalg.dot(ab, ab)
	t = l2 > 0 ? clamp(linalg.dot(p - a, ab) / l2, 0, 1) : 0
	return linalg.length(p - (a + ab * t)), t
}

// Non-zero winding number of a closed polygon around p.
winding_number :: proc(points: []Flat_Point, p: Vec2) -> int {
	w := 0
	n := len(points)
	for i in 0 ..< n {
		a := points[i].pos
		b := points[(i + 1) % n].pos
		side := (b.x - a.x) * (p.y - a.y) - (p.x - a.x) * (b.y - a.y)
		if a.y <= p.y {
			if b.y > p.y && side > 0 do w += 1
		} else if b.y <= p.y && side < 0 {
			w -= 1
		}
	}
	return w
}

// True if `p` touches the visible shape (stroke, fill) or, for paths drawn
// with neither, the outline. All values are in the path's own space.
path_hit :: proc(p: ^Path, point: Vec2, tolerance: f32) -> bool {
	flat := make([dynamic]Flat_Point, context.temp_allocator)
	flatten(p.knots[:], p.closed, tolerance * 0.5, &flat)
	if len(flat) == 0 do return false
	if p.has_fill && len(flat) >= 3 && winding_number(flat[:], point) != 0 do return true

	if len(flat) == 1 {
		r := (p.has_stroke ? flat[0].width * 0.5 : 0) + tolerance
		return linalg.length(point - flat[0].pos) <= r
	}
	for i in 0 ..< len(flat) - 1 {
		a, b := flat[i], flat[i + 1]
		d, t := point_segment_distance(point, a.pos, b.pos)
		half := p.has_stroke ? math.lerp(a.width, b.width, t) * 0.5 : 0
		if d <= half + tolerance do return true
	}
	return false
}

Curve_Location :: struct {
	segment:  int,
	t:        f32,
	pos:      Vec2,
	distance: f32,
}

// Closest point on the path's centre line. ok is false for paths without segments.
nearest_on_path :: proc(knots: []Knot, closed: bool, point: Vec2, tolerance: f32) -> (loc: Curve_Location, ok: bool) {
	flat := make([dynamic]Flat_Point, context.temp_allocator)
	flatten(knots, closed, tolerance, &flat)
	if len(flat) < 2 do return {}, false
	loc.distance = max(f32)
	for i in 0 ..< len(flat) - 1 {
		a, b := flat[i], flat[i + 1]
		d, s := point_segment_distance(point, a.pos, b.pos)
		if d < loc.distance {
			t0 := a.t
			if b.segment != a.segment do t0 = 0 // a ends the previous segment
			loc = {b.segment, math.lerp(t0, b.t, s), linalg.lerp(a.pos, b.pos, s), d}
		}
	}
	return loc, true
}

// Inserts a knot at parameter t of `segment` without changing the curve's shape.
// Returns the new knot's index.
split_segment :: proc(knots: ^[dynamic]Knot, closed: bool, segment: int, t: f32) -> int {
	n := len(knots)
	ia, ib := segment, (segment + 1) % n
	a, b := knots[ia], knots[ib]
	width := math.lerp(a.width, b.width, t)
	at := segment + 1

	if segment_is_straight(a, b) {
		p := linalg.lerp(a.pos, b.pos, t)
		inject_at(knots, at, Knot{p, p, p, width})
		return at
	}
	// de Casteljau
	p01 := linalg.lerp(a.pos, a.handle_out, t)
	p12 := linalg.lerp(a.handle_out, b.handle_in, t)
	p23 := linalg.lerp(b.handle_in, b.pos, t)
	p012 := linalg.lerp(p01, p12, t)
	p123 := linalg.lerp(p12, p23, t)
	mid := linalg.lerp(p012, p123, t)
	knots[ia].handle_out = p01
	knots[ib].handle_in = p23
	inject_at(knots, at, Knot{mid, p012, p123, width})
	return at
}

Bounds :: struct {
	min, max: Vec2,
}

BOUNDS_EMPTY :: Bounds{{max(f32), max(f32)}, {min(f32), min(f32)}}

bounds_add :: proc(b: ^Bounds, p: Vec2) {
	b.min = linalg.min(b.min, p)
	b.max = linalg.max(b.max, p)
}

bounds_is_empty :: proc(b: Bounds) -> bool {
	return b.min.x > b.max.x
}

// Tight bounds of the curve (flattened), not of the control points.
curve_bounds :: proc(knots: []Knot, closed: bool, tolerance: f32) -> Bounds {
	flat := make([dynamic]Flat_Point, context.temp_allocator)
	flatten(knots, closed, tolerance, &flat)
	b := BOUNDS_EMPTY
	for f in flat do bounds_add(&b, f.pos)
	return b
}

// --- Shapes -------------------------------------------------------------------

rect_knots :: proc(a, b: Vec2, width: f32) -> [4]Knot {
	lo := linalg.min(a, b)
	hi := linalg.max(a, b)
	c := [4]Vec2{lo, {hi.x, lo.y}, hi, {lo.x, hi.y}}
	out: [4]Knot
	for p, i in c do out[i] = {p, p, p, width}
	return out
}

// Four knots with kappa handles: a circle to within 0.03%.
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

// Makes a knot smooth: handles become collinear and keep their lengths, along
// the direction between the neighbouring knots.
knot_make_smooth :: proc(knots: []Knot, closed: bool, i: int) {
	n := len(knots)
	if n < 2 do return
	prev := i > 0 ? knots[i - 1].pos : (closed ? knots[n - 1].pos : knots[i].pos)
	next := i < n - 1 ? knots[i + 1].pos : (closed ? knots[0].pos : knots[i].pos)
	dir := next - prev
	l := linalg.length(dir)
	if l < 1e-6 do return
	dir /= l
	k := &knots[i]
	len_in := linalg.length(k.handle_in - k.pos)
	len_out := linalg.length(k.handle_out - k.pos)
	if len_in < 1e-6 do len_in = linalg.length(k.pos - prev) / 3
	if len_out < 1e-6 do len_out = linalg.length(next - k.pos) / 3
	k.handle_in = k.pos - dir * len_in
	k.handle_out = k.pos + dir * len_out
}

knot_make_corner :: proc(k: ^Knot) {
	k.handle_in = k.pos
	k.handle_out = k.pos
}

knot_is_corner :: proc(k: Knot) -> bool {
	return k.handle_in == k.pos && k.handle_out == k.pos
}

// --- Freehand curve fitting ---------------------------------------------------
//
// Philip J. Schneider, "An Algorithm for Automatically Fitting Digitized
// Curves", Graphics Gems (1990). The error measure also counts stroke width:
// a width mismatch of dw moves the stroke's edge by dw / 2.

// Replaces a dense polyline (knots used as points, handles ignored) with a few
// smooth cubic knots within `tolerance`. Returns knots from `allocator`.
fit_curve :: proc(points: []Knot, tolerance: f32, allocator := context.allocator) -> [dynamic]Knot {
	out := make([dynamic]Knot, allocator)
	pts := make([dynamic]Knot, context.temp_allocator)
	for p in points {
		if len(pts) == 0 || linalg.length(p.pos - pts[len(pts) - 1].pos) > 1e-4 do append(&pts, p)
	}
	switch len(pts) {
	case 0:
		return out
	case 1:
		p := pts[0]
		append(&out, Knot{p.pos, p.pos, p.pos, p.width})
		return out
	}
	n := len(pts)
	t1 := safe_normalize(pts[1].pos - pts[0].pos)
	t2 := safe_normalize(pts[n - 2].pos - pts[n - 1].pos)
	fit_cubic(pts[:], 0, n - 1, t1, t2, max(tolerance, 1e-4), &out)
	return out
}

@(private)
safe_normalize :: proc(v: Vec2) -> Vec2 {
	l := linalg.length(v)
	return l > 1e-9 ? v / l : Vec2{}
}

@(private)
fit_cubic :: proc(pts: []Knot, first, last: int, t1, t2: Vec2, tolerance: f32, out: ^[dynamic]Knot) {
	p0, p3 := pts[first].pos, pts[last].pos
	if last - first == 1 {
		dist := linalg.length(p3 - p0) / 3
		emit_cubic(out, pts[first], p0 + t1 * dist, p3 + t2 * dist, pts[last])
		return
	}

	u := chord_parameters(pts, first, last)
	b1, b2 := generate_bezier(pts, first, last, u, t1, t2)
	err, split := max_error(pts, first, last, b1, b2, u)
	if err < tolerance {
		emit_cubic(out, pts[first], b1, b2, pts[last])
		return
	}
	if err < tolerance * 4 {
		for _ in 0 ..< 4 {
			reparameterize(pts, first, last, u, b1, b2)
			b1, b2 = generate_bezier(pts, first, last, u, t1, t2)
			err, split = max_error(pts, first, last, b1, b2, u)
			if err < tolerance {
				emit_cubic(out, pts[first], b1, b2, pts[last])
				return
			}
		}
	}
	tc := safe_normalize(pts[split - 1].pos - pts[split + 1].pos)
	if tc == {} do tc = safe_normalize(Vec2{-(pts[split].pos - pts[split - 1].pos).y, (pts[split].pos - pts[split - 1].pos).x})
	fit_cubic(pts, first, split, t1, tc, tolerance, out)
	fit_cubic(pts, split, last, -tc, t2, tolerance, out)
}

@(private)
emit_cubic :: proc(out: ^[dynamic]Knot, a: Knot, h1, h2: Vec2, b: Knot) {
	if len(out) == 0 {
		append(out, Knot{a.pos, a.pos, h1, a.width})
	} else {
		out[len(out) - 1].handle_out = h1
	}
	append(out, Knot{b.pos, h2, b.pos, b.width})
}

@(private)
chord_parameters :: proc(pts: []Knot, first, last: int) -> []f32 {
	u := make([]f32, last - first + 1, context.temp_allocator)
	for i in first + 1 ..= last {
		u[i - first] = u[i - first - 1] + linalg.length(pts[i].pos - pts[i - 1].pos)
	}
	total := u[last - first]
	if total > 0 do for &x in u do x /= total
	return u
}

@(private)
generate_bezier :: proc(pts: []Knot, first, last: int, u: []f32, t1, t2: Vec2) -> (b1, b2: Vec2) {
	p0, p3 := pts[first].pos, pts[last].pos
	c: [2][2]f32
	x: [2]f32
	for i in first ..= last {
		t := u[i - first]
		s := 1 - t
		B0, B1, B2, B3 := s*s*s, 3*t*s*s, 3*t*t*s, t*t*t
		a1, a2 := t1 * B1, t2 * B2
		c[0][0] += linalg.dot(a1, a1)
		c[0][1] += linalg.dot(a1, a2)
		c[1][1] += linalg.dot(a2, a2)
		tmp := pts[i].pos - (p0 * (B0 + B1) + p3 * (B2 + B3))
		x[0] += linalg.dot(a1, tmp)
		x[1] += linalg.dot(a2, tmp)
	}
	c[1][0] = c[0][1]
	det := c[0][0] * c[1][1] - c[1][0] * c[0][1]
	alpha1, alpha2: f32
	if abs(det) > 1e-12 {
		alpha1 = (x[0] * c[1][1] - x[1] * c[0][1]) / det
		alpha2 = (c[0][0] * x[1] - c[1][0] * x[0]) / det
	}
	seg := linalg.length(p3 - p0)
	eps := 1e-6 * seg
	if alpha1 < eps || alpha2 < eps {
		// Degenerate fit: fall back to the Wu/Barsky heuristic.
		alpha1, alpha2 = seg / 3, seg / 3
	}
	return p0 + t1 * alpha1, p3 + t2 * alpha2
}

@(private)
max_error :: proc(pts: []Knot, first, last: int, b1, b2: Vec2, u: []f32) -> (err: f32, split: int) {
	p0, p3 := pts[first].pos, pts[last].pos
	w0, w3 := pts[first].width, pts[last].width
	split = (first + last) / 2
	for i in first + 1 ..< last {
		t := u[i - first]
		d := linalg.length(cubic_point(p0, b1, b2, p3, t) - pts[i].pos)
		dw := abs(math.lerp(w0, w3, t) - pts[i].width) * 0.5
		e := max(d, dw)
		if e >= err {
			err = e
			split = i
		}
	}
	return
}

// One Newton-Raphson step per point towards the closest curve parameter.
@(private)
reparameterize :: proc(pts: []Knot, first, last: int, u: []f32, b1, b2: Vec2) {
	p0, p3 := pts[first].pos, pts[last].pos
	for i in first ..= last {
		t := u[i - first]
		s := 1 - t
		q := cubic_point(p0, b1, b2, p3, t)
		d1 := 3 * (s*s * (b1 - p0) + 2*s*t * (b2 - b1) + t*t * (p3 - b2))
		d2 := 6 * (s * (b2 - 2*b1 + p0) + t * (p3 - 2*b2 + b1))
		diff := q - pts[i].pos
		num := linalg.dot(diff, d1)
		den := linalg.dot(d1, d1) + linalg.dot(diff, d2)
		if abs(den) > 1e-12 do u[i - first] = clamp(t - num / den, 0, 1)
	}
}
