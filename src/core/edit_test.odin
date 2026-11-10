package core

import "core:math"
import "core:math/linalg"
import "core:testing"

@(private = "file")
Fixture :: struct {
	doc:  Document,
	hist: History,
}

@(private = "file")
fixture_destroy :: proc(f: ^Fixture) {
	history_destroy(&f.hist)
	document_destroy(&f.doc)
}

@(private = "file")
square_path :: proc() -> Path {
	p := Path{closed = true, has_fill = true, fill = {1, 0, 0, 1}}
	k := rect_knots({0, 0}, {10, 10}, 1)
	append(&p.knots, ..k[:])
	return p
}

@(private = "file")
moved :: proc(p: ^Path, by: Vec2) -> Path {
	out := clone_path(p^, context.temp_allocator)
	for &k in out.knots {
		k.pos += by
		k.handle_in += by
		k.handle_out += by
	}
	return out
}

@(test)
test_set_path_undo_redo :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	l := add_layer(&f.hist, &f.doc, .Vector, "a")
	h := add_path(&f.hist, &f.doc, l, square_path())

	set_path(&f.hist, &f.doc, h, moved(path(&f.doc, h), {5, 0}))
	testing.expect_value(t, path(&f.doc, h).knots[0].pos, Vec2{5, 0})
	undo(&f.hist, &f.doc)
	testing.expect_value(t, path(&f.doc, h).knots[0].pos, Vec2{0, 0})
	redo(&f.hist, &f.doc)
	testing.expect_value(t, path(&f.doc, h).knots[0].pos, Vec2{5, 0})
	undo(&f.hist, &f.doc)
	undo(&f.hist, &f.doc)
	// New edit discards the redo stack, including the set-path copies.
	add_layer(&f.hist, &f.doc, .Vector, "b")
	testing.expect(t, !can_redo(&f.hist))
}

@(test)
test_set_path_identical_is_noop :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	l := add_layer(&f.hist, &f.doc, .Vector, "a")
	h := add_path(&f.hist, &f.doc, l, square_path())
	id := history_state_id(&f.hist)
	set_path(&f.hist, &f.doc, h, path(&f.doc, h)^)
	testing.expect_value(t, history_state_id(&f.hist), id)
}

@(test)
test_grouped_drag_merges_into_one_step :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	l := add_layer(&f.hist, &f.doc, .Vector, "a")
	a := add_path(&f.hist, &f.doc, l, square_path())
	b := add_path(&f.hist, &f.doc, l, square_path())
	start_a := clone_path(path(&f.doc, a)^, context.temp_allocator)
	start_b := clone_path(path(&f.doc, b)^, context.temp_allocator)
	steps := len(f.hist.undo_stack)

	for frame in 1 ..= 5 {
		history_begin_group(&f.hist)
		set_path(&f.hist, &f.doc, a, moved(&start_a, {f32(frame), 0}))
		set_path(&f.hist, &f.doc, b, moved(&start_b, {0, f32(frame)}))
		history_end_group(&f.hist, 77)
	}
	testing.expect_value(t, len(f.hist.undo_stack), steps + 1)
	testing.expect_value(t, path(&f.doc, a).knots[0].pos, Vec2{5, 0})
	testing.expect_value(t, path(&f.doc, b).knots[0].pos, Vec2{0, 5})

	undo(&f.hist, &f.doc)
	testing.expect_value(t, path(&f.doc, a).knots[0].pos, Vec2{0, 0})
	testing.expect_value(t, path(&f.doc, b).knots[0].pos, Vec2{0, 0})
}

@(test)
test_group_of_removals_undoes_together :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	l := add_layer(&f.hist, &f.doc, .Vector, "a")
	a := add_path(&f.hist, &f.doc, l, square_path())
	b := add_path(&f.hist, &f.doc, l, square_path())
	history_begin_group(&f.hist)
	remove_path(&f.hist, &f.doc, l, a)
	remove_path(&f.hist, &f.doc, l, b)
	testing.expect(t, !undo(&f.hist, &f.doc), "undo is refused while a group is open")
	history_end_group(&f.hist)
	testing.expect_value(t, len(layer(&f.doc, l).paths), 0)
	undo(&f.hist, &f.doc)
	testing.expect_value(t, len(layer(&f.doc, l).paths), 2)
	testing.expect_value(t, layer(&f.doc, l).paths[0], a)
	testing.expect_value(t, layer(&f.doc, l).paths[1], b)
}

@(test)
test_move_path_restacks :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	l := add_layer(&f.hist, &f.doc, .Vector, "a")
	a := add_path(&f.hist, &f.doc, l, square_path())
	b := add_path(&f.hist, &f.doc, l, square_path())
	c := add_path(&f.hist, &f.doc, l, square_path())
	testing.expect(t, move_path(&f.hist, &f.doc, l, a, 99)) // to the top
	testing.expect_value(t, layer(&f.doc, l).paths[2], a)
	testing.expect(t, !move_path(&f.hist, &f.doc, l, a, 2))
	undo(&f.hist, &f.doc)
	ps := layer(&f.doc, l).paths
	testing.expect(t, ps[0] == a && ps[1] == b && ps[2] == c)
}

@(test)
test_path_hit_fill_and_stroke :: proc(t: ^testing.T) {
	p := square_path()
	defer delete(p.knots)
	testing.expect(t, path_hit(&p, {5, 5}, 0.5), "inside the fill")
	testing.expect(t, !path_hit(&p, {15, 5}, 0.5))
	p.has_fill = false
	testing.expect(t, !path_hit(&p, {5, 5}, 0.5), "no fill: the inside is empty")
	testing.expect(t, path_hit(&p, {10.3, 5}, 0.5), "the outline is still clickable")
	p.has_stroke = true
	for &k in p.knots do k.width = 4
	testing.expect(t, path_hit(&p, {11.9, 5}, 0.5), "within half the stroke width")
}

@(test)
test_split_keeps_the_curve :: proc(t: ^testing.T) {
	e := ellipse_knots({0, 0}, {50, 30}, 1)
	knots: [dynamic]Knot
	defer delete(knots)
	append(&knots, ..e[:])
	before := cubic_point(e[0].pos, e[0].handle_out, e[1].handle_in, e[1].pos, 0.7)

	i := split_segment(&knots, true, 0, 0.4)
	testing.expect_value(t, i, 1)
	testing.expect_value(t, len(knots), 5)
	// t = 0.7 on the old segment is t = 0.5 on the new second half.
	after := cubic_point(knots[1].pos, knots[1].handle_out, knots[2].handle_in, knots[2].pos, 0.5)
	testing.expectf(t, linalg.length(after - before) < 1e-3, "split moved the curve: %v vs %v", after, before)
}

@(test)
test_nearest_on_path_finds_segment :: proc(t: ^testing.T) {
	k := rect_knots({0, 0}, {10, 10}, 1)
	loc, ok := nearest_on_path(k[:], true, {10.5, 7}, 0.1)
	testing.expect(t, ok)
	testing.expect_value(t, loc.segment, 1) // right edge
	testing.expect(t, abs(loc.t - 0.7) < 1e-3)
	testing.expect(t, abs(loc.distance - 0.5) < 1e-3)
}

@(test)
test_fit_curve_reduces_points_within_tolerance :: proc(t: ^testing.T) {
	// A dense quarter circle with a width ramp.
	points: [dynamic]Knot
	defer delete(points)
	N :: 200
	for i in 0 ..= N {
		a := f32(i) / N * math.PI * 0.5
		p := Vec2{math.cos(a), math.sin(a)} * 100
		append(&points, Knot{p, p, p, 2 + 6 * f32(i) / N})
	}
	fitted := fit_curve(points[:], 0.5)
	defer delete(fitted)
	testing.expectf(t, len(fitted) >= 2 && len(fitted) <= 6, "expected a few knots, got %d", len(fitted))
	testing.expect_value(t, fitted[0].pos, points[0].pos)
	testing.expect_value(t, fitted[len(fitted) - 1].pos, points[N].pos)

	flat: [dynamic]Flat_Point
	defer delete(flat)
	flatten(fitted[:], false, 0.05, &flat)
	for f in flat {
		r := linalg.length(f.pos)
		testing.expectf(t, abs(r - 100) < 0.75, "fitted curve strays from the circle: r=%v", r)
	}
}

@(test)
test_fit_curve_single_point :: proc(t: ^testing.T) {
	p := []Knot{{{3, 4}, {}, {}, 5}, {{3, 4}, {}, {}, 5}}
	fitted := fit_curve(p, 0.5)
	defer delete(fitted)
	testing.expect_value(t, len(fitted), 1)
	testing.expect_value(t, fitted[0], Knot{{3, 4}, {3, 4}, {3, 4}, 5})
}
