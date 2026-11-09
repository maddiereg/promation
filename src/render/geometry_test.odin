package render

import "core:testing"
import "core:math/linalg"

@(test)
test_flatten_closed_ellipse :: proc(t: ^testing.T) {
	knots := ellipse_knots({0, 0}, {100, 100}, 2)
	samples: [dynamic]Sample
	defer delete(samples)
	flatten_knots(knots[:], true, 0.25, &samples)

	testing.expect(t, len(samples) > 16, "ellipse should flatten to many samples")
	// All samples close to the circle (kappa approximation error ~0.03%).
	for s in samples {
		r := linalg.length(s.pos)
		testing.expectf(t, abs(r - 100) < 0.5, "sample off circle: r=%v", r)
	}
	// Closed path: no duplicate end sample.
	testing.expect(t, linalg.length(samples[0].pos - samples[len(samples) - 1].pos) > 1)
}

@(test)
test_flatten_open_interpolates_width :: proc(t: ^testing.T) {
	knots := []Knot{
		{{0, 0}, {0, 0}, {0, 0}, 0},
		{{100, 0}, {100, 0}, {100, 0}, 10},
	}
	samples: [dynamic]Sample
	defer delete(samples)
	flatten_knots(knots, false, 0.25, &samples)
	testing.expect_value(t, samples[0].width, 0)
	testing.expect_value(t, samples[len(samples) - 1].width, 10)
	testing.expect_value(t, samples[len(samples) - 1].pos, Vec2{100, 0})
}

@(test)
test_fan_triangle_count :: proc(t: ^testing.T) {
	quad := []Sample{{{0, 0}, 0}, {{1, 0}, 0}, {{1, 1}, 0}, {{0, 1}, 0}}
	tris: [dynamic]Vec2
	defer delete(tris)
	fan_triangles(quad, &tris)
	testing.expect_value(t, len(tris), 6)
}

@(test)
test_stroke_has_geometry :: proc(t: ^testing.T) {
	line := []Sample{{{0, 0}, 4}, {{50, 0}, 4}}
	tris: [dynamic]Vec2
	defer delete(tris)
	stroke_triangles(line, false, 0.25, &tris)
	testing.expect(t, len(tris) > 6 && len(tris) % 3 == 0)
	b := bounds_of(tris[:])
	testing.expect(t, abs(b.min.y + 2) < 0.01 && abs(b.max.y - 2) < 0.01, "stroke half-width should be 2")
}
