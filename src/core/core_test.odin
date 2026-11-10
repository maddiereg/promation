package core

import "core:math"
import "core:testing"

@(private = "file")
make_path :: proc(n: int) -> Path {
	p := Path{has_stroke = true, stroke = {0, 0, 0, 1}}
	for i in 0 ..< n {
		pos := Vec2{f32(i), 0}
		append(&p.knots, Knot{pos, pos, pos, 2})
	}
	return p
}

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

@(test)
test_pool_stale_handle_is_rejected :: proc(t: ^testing.T) {
	p: Pool(int)
	defer pool_destroy(&p)
	a := pool_add(&p, 1)
	pool_remove(&p, a)
	b := pool_add(&p, 2)
	testing.expect_value(t, b.index, a.index) // slot reused
	testing.expect(t, pool_get(&p, a) == nil, "stale handle must not resolve")
	testing.expect_value(t, pool_get(&p, b)^, 2)
	testing.expect(t, pool_get(&p, Handle{}) == nil, "nil handle must not resolve")
}

@(test)
test_path_add_undo_redo :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	l := add_layer(&f.hist, &f.doc, .Vector, "a")
	p := add_path(&f.hist, &f.doc, l, make_path(3))

	testing.expect_value(t, len(layer(&f.doc, l).paths), 1)
	testing.expect(t, undo(&f.hist, &f.doc))
	testing.expect_value(t, len(layer(&f.doc, l).paths), 0)
	testing.expect(t, redo(&f.hist, &f.doc))
	testing.expect_value(t, layer(&f.doc, l).paths[0], p)
	testing.expect_value(t, len(path(&f.doc, p).knots), 3)
}

@(test)
test_new_edit_discards_redo_and_frees :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	l := add_layer(&f.hist, &f.doc, .Vector, "a")
	p := add_path(&f.hist, &f.doc, l, make_path(3))
	undo(&f.hist, &f.doc)
	add_path(&f.hist, &f.doc, l, make_path(1))
	testing.expect(t, !can_redo(&f.hist))
	testing.expect(t, path(&f.doc, p) == nil, "discarded path should be freed")
}

@(test)
test_layer_delete_undo_keeps_order_and_contents :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	a := add_layer(&f.hist, &f.doc, .Group, "a")
	inner := add_layer(&f.hist, &f.doc, .Vector, "inner", a)
	add_path(&f.hist, &f.doc, inner, make_path(2))
	b := add_layer(&f.hist, &f.doc, .Vector, "b")

	testing.expect(t, remove_layer(&f.hist, &f.doc, a))
	testing.expect_value(t, len(f.doc.root), 1)
	testing.expect(t, !layer_is_linked(&f.doc, inner), "child of a deleted group is unlinked")

	undo(&f.hist, &f.doc)
	testing.expect_value(t, f.doc.root[0], a)
	testing.expect_value(t, f.doc.root[1], b)
	testing.expect(t, layer_is_linked(&f.doc, inner))
	testing.expect_value(t, len(layer(&f.doc, inner).paths), 1)
}

@(test)
test_add_layer_rejects_non_group_parent :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	v := add_layer(&f.hist, &f.doc, .Vector, "v")
	testing.expect_value(t, add_layer(&f.hist, &f.doc, .Vector, "x", v), Layer_Handle{})
}

@(test)
test_move_layer_reorder_and_undo :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	a := add_layer(&f.hist, &f.doc, .Vector, "a")
	b := add_layer(&f.hist, &f.doc, .Vector, "b")
	c := add_layer(&f.hist, &f.doc, .Vector, "c")

	testing.expect(t, move_layer(&f.hist, &f.doc, a, {}, 2))
	testing.expect_value(t, f.doc.root[2], a)
	undo(&f.hist, &f.doc)
	testing.expect_value(t, f.doc.root[0], a)
	testing.expect_value(t, f.doc.root[1], b)
	testing.expect_value(t, f.doc.root[2], c)
	testing.expect(t, !move_layer(&f.hist, &f.doc, a, {}, 0), "moving to the same place is a no-op")
}

@(test)
test_move_layer_refuses_cycle :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	outer := add_layer(&f.hist, &f.doc, .Group, "outer")
	inner := add_layer(&f.hist, &f.doc, .Group, "inner", outer)
	testing.expect(t, !move_layer(&f.hist, &f.doc, outer, inner, 0))
	testing.expect(t, !move_layer(&f.hist, &f.doc, outer, outer, 0))
	testing.expect(t, move_layer(&f.hist, &f.doc, inner, {}, 0), "moving out of a group works")
	testing.expect_value(t, layer(&f.doc, inner).parent, Layer_Handle{})
}

@(test)
test_props_merge_into_one_undo_step :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	l := add_layer(&f.hist, &f.doc, .Vector, "a")
	props := layer(&f.doc, l).props
	for i in 1 ..= 5 {
		props.opacity = 1 - f32(i) * 0.1
		set_layer_props(&f.hist, &f.doc, l, props, 42)
	}
	testing.expect_value(t, len(f.hist.undo_stack), 2)

	undo(&f.hist, &f.doc)
	testing.expect_value(t, layer(&f.doc, l).opacity, f32(1))
	redo(&f.hist, &f.doc)
	testing.expect_value(t, layer(&f.doc, l).opacity, props.opacity)
}

@(test)
test_seal_stops_merging :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	s := f.doc.settings
	s.fps = 30
	set_settings(&f.hist, &f.doc, s, 7)
	history_seal(&f.hist)
	s.fps = 60
	set_settings(&f.hist, &f.doc, s, 7)
	testing.expect_value(t, len(f.hist.undo_stack), 2)
}

@(test)
test_dirty_tracking :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	testing.expect(t, !history_is_dirty(&f.hist))
	add_layer(&f.hist, &f.doc, .Vector, "a")
	testing.expect(t, history_is_dirty(&f.hist))
	history_mark_saved(&f.hist)
	testing.expect(t, !history_is_dirty(&f.hist))
	undo(&f.hist, &f.doc)
	testing.expect(t, history_is_dirty(&f.hist))
	redo(&f.hist, &f.doc)
	testing.expect(t, !history_is_dirty(&f.hist), "back at the saved state")
}

@(test)
test_project_round_trip :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	f.doc.settings = DEFAULT_SETTINGS
	f.doc.settings.fps = 12
	g := add_layer(&f.hist, &f.doc, .Group, "Character \"é\"")
	v := add_layer(&f.hist, &f.doc, .Vector, "Arm", g)
	props := layer(&f.doc, v).props
	props.opacity = 0.123456
	props.locked = true
	props.transform.position = {1.5, -2.25}
	props.transform.rotation = 0.7853982
	set_layer_props(&f.hist, &f.doc, v, props)
	p := make_path(3)
	p.knots[1] = {{0.1, 0.2}, {0.3, 0.4}, {0.5, 0.6}, 0.7}
	add_path(&f.hist, &f.doc, v, p)

	data, ok := document_to_json(&f.doc)
	defer delete(data)
	testing.expect(t, ok)

	loaded: Document
	testing.expect_value(t, document_from_json(data, &loaded), Load_Error.None)
	defer document_destroy(&loaded)

	testing.expect_value(t, loaded.settings, f.doc.settings)
	lg := layer(&loaded, loaded.root[0])
	testing.expect_value(t, name_string(&lg.name), "Character \"é\"")
	lv := layer(&loaded, lg.children[0])
	testing.expect_value(t, lv.parent, loaded.root[0])
	testing.expect_value(t, lv.props, props) // exact: floats must survive the text round trip
	lp := path(&loaded, lv.paths[0])
	testing.expect_value(t, lp.knots[1], Knot{{0.1, 0.2}, {0.3, 0.4}, {0.5, 0.6}, 0.7})
	testing.expect(t, lp.has_stroke && !lp.has_fill)
}

@(test)
test_project_load_rejects_bad_input :: proc(t: ^testing.T) {
	Case :: struct {
		json: string,
		want: Load_Error,
	}
	cases := []Case{
		{"not json", .Malformed},
		{`{"format":"other","version":1}`, .Wrong_Format},
		{`{"format":"promation","version":99}`, .Newer_Version},
		{`{"format":"promation","version":1,"width":0,"height":10,"fps":24,"frame_count":1}`, .Invalid_Value},
		{`{"format":"promation","version":1,"width":10,"height":10,"fps":24,"frame_count":1,"layers":[{"kind":"banana"}]}`, .Invalid_Value},
		{`{"format":"promation","version":1,"width":10,"height":10,"fps":24,"frame_count":1,"layers":[{"kind":"vector","scale":[1,1]},{"kind":"banana"}]}`, .Invalid_Value},
	}
	for c in cases {
		d: Document
		got := document_from_json(transmute([]u8)c.json, &d)
		testing.expectf(t, got == c.want, "%q: got %v, want %v", c.json, got, c.want)
		if got == .None do document_destroy(&d)
	}
}

@(test)
test_evaluate_applies_nested_transforms_and_opacity :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	g := add_layer(&f.hist, &f.doc, .Group, "g")
	v := add_layer(&f.hist, &f.doc, .Vector, "v", g)
	gp := layer(&f.doc, g).props
	gp.transform.position = {100, 0}
	gp.transform.scale = {2, 2}
	gp.opacity = 0.5
	set_layer_props(&f.hist, &f.doc, g, gp)
	vp := layer(&f.doc, v).props
	vp.transform.position = {10, 0}
	set_layer_props(&f.hist, &f.doc, v, vp)
	add_path(&f.hist, &f.doc, v, make_path(2))

	posed := evaluate(&f.doc, allocator = context.temp_allocator)
	testing.expect_value(t, len(posed), 1)
	testing.expect_value(t, posed[0].knots[0].pos, Vec2{120, 0})
	testing.expect_value(t, posed[0].knots[1].pos, Vec2{122, 0})
	testing.expect_value(t, posed[0].knots[0].width, f32(4))
	testing.expect_value(t, posed[0].stroke.a, f32(0.5))

	gp.visible = false
	set_layer_props(&f.hist, &f.doc, g, gp)
	testing.expect_value(t, len(evaluate(&f.doc, allocator = context.temp_allocator)), 0)
}

@(test)
test_preview_is_stacked_inside_its_layer :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	bottom := add_layer(&f.hist, &f.doc, .Vector, "bottom")
	top := add_layer(&f.hist, &f.doc, .Vector, "top")
	add_path(&f.hist, &f.doc, bottom, make_path(2))
	add_path(&f.hist, &f.doc, top, make_path(5))
	props := layer(&f.doc, bottom).props
	props.opacity = 0.5
	set_layer_props(&f.hist, &f.doc, bottom, props)

	preview_path := make_path(3)
	defer delete(preview_path.knots)
	posed := evaluate(&f.doc, Preview{bottom, preview_path}, context.temp_allocator)

	testing.expect_value(t, len(posed), 3)
	testing.expect_value(t, len(posed[1].knots), 3) // above the bottom layer's path...
	testing.expect_value(t, len(posed[2].knots), 5) // ...and below the top layer
	testing.expect_value(t, posed[1].stroke.a, f32(0.5)) // faded with its layer
}

@(test)
test_transform_rotates_about_origin :: proc(t: ^testing.T) {
	m := transform_matrix({position = {10, 0}, rotation = math.PI / 2, scale = {1, 1}, origin = {10, 0}})
	p := mat3_apply(m, {10, 0})
	testing.expect(t, abs(p.x - 10) < 1e-4 && abs(p.y) < 1e-4, "the origin must not move")
	q := mat3_apply(m, {11, 0})
	testing.expect(t, abs(q.x - 10) < 1e-4 && abs(q.y - 1) < 1e-4)
}

@(test)
test_matrix_inverse :: proc(t: ^testing.T) {
	m := transform_matrix({position = {3, 4}, rotation = 0.5, scale = {2, 3}, origin = {1, 1}})
	inv, ok := mat3_invert(m)
	testing.expect(t, ok)
	p := mat3_apply(inv, mat3_apply(m, {7, -2}))
	testing.expect(t, abs(p.x - 7) < 1e-3 && abs(p.y + 2) < 1e-3)
	_, singular_ok := mat3_invert(transform_matrix({scale = {0, 1}}))
	testing.expect(t, !singular_ok)
}

@(test)
test_camera_zoom_keeps_anchor_fixed :: proc(t: ^testing.T) {
	c := Camera{pan = {50, 20}, zoom = 1.5, rotation = 0.3}
	anchor := Vec2{400, 300}
	before := screen_to_world(c, anchor)
	camera_zoom_at(&c, anchor, 2)
	after := screen_to_world(c, anchor)
	testing.expect(t, abs(before.x - after.x) < 1e-2 && abs(before.y - after.y) < 1e-2)
}

@(test)
test_name_truncates_on_utf8_boundary :: proc(t: ^testing.T) {
	long: [NAME_CAPACITY + 10]u8
	for i := 0; i + 1 < len(long); i += 2 {
		long[i], long[i + 1] = 0xC3, 0xA9 // é
	}
	n := name_make(string(long[:]))
	s := name_string(&n)
	testing.expect(t, len(s) % 2 == 0, "must not split a two-byte character")
	testing.expect(t, len(s) < NAME_CAPACITY)
}
