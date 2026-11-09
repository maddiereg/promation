package render

// Phase 0 test scene, shared by the app and the headless render test.
// Exercises: concave fill, self-intersecting fill (non-zero), translucency,
// variable-width strokes, curves at several scales.

import "core:math"

demo_scene :: proc(r: ^Renderer, tolerance: f32) {
	// Page / canvas.
	page := [4]Knot{
		{{0, 0}, {0, 0}, {0, 0}, 0},
		{{960, 0}, {960, 0}, {960, 0}, 0},
		{{960, 540}, {960, 540}, {960, 540}, 0},
		{{0, 540}, {0, 540}, {0, 540}, 0},
	}
	fill_knots(r, page[:], {0.98, 0.97, 0.94, 1}, tolerance)

	// Body: a smooth blob with a thick dark outline.
	body := ellipse_knots({300, 300}, {150, 120}, 10)
	body[1].width = 24 // thicker at the bottom: variable stroke width
	body[3].width = 4
	fill_knots(r, body[:], {0.35, 0.65, 0.95, 1}, tolerance)
	stroke_knots(r, body[:], true, {0.10, 0.12, 0.20, 1}, tolerance)

	// Eyes.
	for x in ([]f32{250, 350}) {
		eye := ellipse_knots({x, 260}, {22, 30}, 4)
		fill_knots(r, eye[:], {1, 1, 1, 1}, tolerance)
		stroke_knots(r, eye[:], true, {0.10, 0.12, 0.20, 1}, tolerance)
		pupil := ellipse_knots({x + 6, 268}, {9, 12}, 0)
		fill_knots(r, pupil[:], {0.10, 0.12, 0.20, 1}, tolerance)
	}

	// Smile: an open curve tapering at both ends.
	smile := [3]Knot{
		{{240, 340}, {240, 340}, {260, 380}, 1},
		{{300, 372}, {268, 372}, {332, 372}, 9},
		{{360, 340}, {340, 380}, {360, 340}, 1},
	}
	stroke_knots(r, smile[:], false, {0.10, 0.12, 0.20, 1}, tolerance)

	// Self-intersecting star (non-zero winding fills the centre).
	star: [10]Knot
	for i in 0 ..< 10 {
		a := f32(i) * math.TAU / 10 - math.PI / 2
		rad: f32 = i % 2 == 0 ? 110 : 45
		p := Vec2{700, 270} + rad * Vec2{math.cos(a), math.sin(a)}
		star[i] = {p, p, p, 3}
	}
	fill_knots(r, star[:], {1.0, 0.78, 0.2, 1}, tolerance)
	stroke_knots(r, star[:], true, {0.55, 0.35, 0.05, 1}, tolerance)

	// Translucent overlapping discs: each must blend exactly once.
	for i in 0 ..< 3 {
		c := Vec2{620 + f32(i) * 60, 440}
		disc := ellipse_knots(c, {55, 55}, 0)
		colors := [3]Color{{0.9, 0.2, 0.3, 0.5}, {0.2, 0.8, 0.4, 0.5}, {0.3, 0.3, 0.9, 0.5}}
		fill_knots(r, disc[:], colors[i], tolerance)
	}

	// Translucent thick stroke crossing itself: no double-blended joins.
	loop := [4]Knot{
		{{60, 480}, {60, 480}, {200, 380}, 18},
		{{300, 500}, {250, 540}, {350, 460}, 18},
		{{200, 420}, {150, 380}, {150, 520}, 18},
		{{520, 500}, {420, 520}, {520, 500}, 18},
	}
	stroke_knots(r, loop[:], false, {0.6, 0.1, 0.7, 0.45}, tolerance)
}
