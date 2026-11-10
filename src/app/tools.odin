package main

// Canvas tools. Pointer input (pen or mouse) arrives here in screen pixels and
// is turned into edits in the active layer's own space. Edits made while
// dragging go through the history every frame and merge into one undo step.

import "core:math"
import "core:math/linalg"
import sdl "vendor:sdl3"

import pm "../core"

Tool :: enum {
	Select,
	Points,
	Draw,
	Pen,
	Rectangle,
	Ellipse,
	Pan,
}

TOOL_LABELS := [Tool]cstring{
	.Select    = "Select (V)",
	.Points    = "Points (A)",
	.Draw      = "Draw (B)",
	.Pen       = "Pen (P)",
	.Rectangle = "Rectangle (R)",
	.Ellipse   = "Ellipse (E)",
	.Pan       = "Pan (H)",
}

// Style for new shapes, and the style shown for (and applied to) the selection.
Style :: struct {
	fill_on:   bool,
	fill:      pm.Color,
	stroke_on: bool,
	stroke:    pm.Color,
	width:     f32, // document units; the maximum width for pressure strokes
}

Grid :: struct {
	show: bool,
	snap: bool,
	size: f32, // document units
}

Point_Ref :: struct {
	path:  pm.Path_Handle,
	index: int,
}

// Belongs to one layer; cleared when another layer becomes active.
Selection :: struct {
	layer:  pm.Layer_Handle,
	paths:  [dynamic]pm.Path_Handle, // Select tool
	points: [dynamic]Point_Ref,      // Points tool
}

Drag_Kind :: enum {
	None,
	Marquee,
	Move,
	Scale,
	Rotate,
	Handle,
	Shape,
	Erase,
}

Handle_Side :: enum {
	In,
	Out,
}

Snapshot :: struct {
	path:  pm.Path_Handle,
	knots: [dynamic]pm.Knot,
}

Drag :: struct {
	kind:        Drag_Kind,
	space:       Layer_Space,
	start_px:    Vec2,
	current_px:  Vec2,
	start:       Vec2, // layer space
	merge_key:   u64,
	snapshots:   [dynamic]Snapshot, // paths as they were when the drag began
	points_only: bool, // only selected knots move (Points tool)
	box:         pm.Bounds, // selection box at the start, layer space
	grip:        [2]int, // scale grip, each axis -1, 0 or 1
	grip_offset: Vec2, // cursor minus the grabbed box edge
	anchor:      Vec2, // layer-space point a move drag snaps to the grid
	started:     bool, // the pointer left the dead zone; edits begin
	handle:      Point_Ref,
	side:        Handle_Side,
	additive:    bool,
}

Pen_Path :: struct {
	active:   bool,
	layer:    pm.Layer_Handle,
	knots:    [dynamic]pm.Knot,
	dragging: bool,
}

Pointer :: struct {
	down:          bool,
	from_pen:      bool,
	last_click_ms: u64,
	last_click_px: Vec2,
}

Layer_Space :: struct {
	to_doc:   pm.Mat3,
	to_layer: pm.Mat3,
	scale:    f32,
}

// Distances in user-interface points, converted to pixels with pt().
GRAB_RADIUS     :: 7
BOX_PADDING     :: 8
ROTATE_DISTANCE :: 28
ERASER_RADIUS   :: 8
DRAG_DEAD_ZONE  :: 3 // movement before a drag starts editing

pt :: proc(app: ^App, points: f32) -> f32 {
	return points * app.density
}

layer_space :: proc(app: ^App, h: pm.Layer_Handle) -> (ls: Layer_Space, ok: bool) {
	ls.to_doc = pm.layer_world_matrix(&app.doc, h)
	ls.to_layer, ok = pm.mat3_invert(ls.to_doc)
	ls.scale = pm.mat3_scale(ls.to_doc)
	return
}

to_layer :: proc(app: ^App, ls: Layer_Space, px: Vec2) -> Vec2 {
	return pm.mat3_apply(ls.to_layer, pm.screen_to_world(app.cam, px))
}

to_screen :: proc(app: ^App, ls: Layer_Space, p: Vec2) -> Vec2 {
	return pm.world_to_screen(app.cam, pm.mat3_apply(ls.to_doc, p))
}

px_to_layer :: proc(app: ^App, ls: Layer_Space, px: f32) -> f32 {
	return px / max(app.cam.zoom * ls.scale, 1e-6)
}

// Snaps a layer-space point to the document grid when snapping is on.
snap :: proc(app: ^App, ls: Layer_Space, p: Vec2) -> Vec2 {
	if !app.grid.snap || app.grid.size <= 0 do return p
	g := app.grid.size
	d := pm.mat3_apply(ls.to_doc, p)
	d = {math.round(d.x / g) * g, math.round(d.y / g) * g}
	return pm.mat3_apply(ls.to_layer, d)
}

@(private = "file")
modifiers :: proc() -> (shift, alt: bool) {
	m := sdl.GetModState()
	return .LSHIFT in m || .RSHIFT in m, .LALT in m || .RALT in m
}

// --- Tool state ---------------------------------------------------------------

set_tool :: proc(app: ^App, t: Tool) {
	if t == app.tool || tool_busy(app) do return
	pen_path_commit(app)
	switch {
	case app.tool == .Points && t == .Select:
		// Keep working on the shapes whose points were selected.
		owners := target_paths(app)
		clear(&app.selection.paths)
		append(&app.selection.paths, ..owners)
		clear(&app.selection.points)
	case t == .Points:
		clear(&app.selection.points)
	}
	app.tool = t
}

// True while a gesture is under way; document-wide actions wait for it.
tool_busy :: proc(app: ^App) -> bool {
	return app.drag.kind != .None || app.builder.active
}

tools_destroy :: proc(app: ^App) {
	drag_clear_snapshots(app)
	delete(app.drag.snapshots)
	delete(app.selection.paths)
	delete(app.selection.points)
	delete(app.pen_path.knots)
}

// Drops selected items that no longer exist (after undo, delete or load).
selection_prune :: proc(app: ^App) {
	s := &app.selection
	if s.layer != app.active_layer {
		s.layer = app.active_layer
		clear(&s.paths)
		clear(&s.points)
	}
	l := pm.layer(&app.doc, s.layer)
	if l == nil {
		clear(&s.paths)
		clear(&s.points)
		return
	}
	for i := len(s.paths) - 1; i >= 0; i -= 1 {
		if pm.index_of_path(l.paths[:], s.paths[i]) < 0 do ordered_remove(&s.paths, i)
	}
	for i := len(s.points) - 1; i >= 0; i -= 1 {
		r := s.points[i]
		p := pm.path(&app.doc, r.path)
		if p == nil || pm.index_of_path(l.paths[:], r.path) < 0 || r.index >= len(p.knots) do ordered_remove(&s.points, i)
	}
	if app.pen_path.active && app.pen_path.layer != app.active_layer do pen_path_commit(app)
}

selection_clear :: proc(app: ^App) {
	clear(&app.selection.paths)
	clear(&app.selection.points)
}

has_path :: proc(app: ^App, h: pm.Path_Handle) -> bool {
	return pm.index_of_path(app.selection.paths[:], h) >= 0
}

has_point :: proc(app: ^App, r: Point_Ref) -> bool {
	for x in app.selection.points do if x == r do return true
	return false
}

@(private = "file")
toggle_point :: proc(app: ^App, r: Point_Ref) {
	for x, i in app.selection.points {
		if x == r {
			ordered_remove(&app.selection.points, i)
			return
		}
	}
	append(&app.selection.points, r)
}

@(private = "file")
toggle_path :: proc(app: ^App, h: pm.Path_Handle) {
	if i := pm.index_of_path(app.selection.paths[:], h); i >= 0 {
		ordered_remove(&app.selection.paths, i)
	} else {
		append(&app.selection.paths, h)
	}
}

// Paths the style panel and shape commands act on, bottom to top.
target_paths :: proc(app: ^App) -> []pm.Path_Handle {
	out := make([dynamic]pm.Path_Handle, context.temp_allocator)
	l := pm.layer(&app.doc, app.selection.layer)
	if l == nil do return out[:]
	for h in l.paths {
		if app.tool == .Points {
			for r in app.selection.points {
				if r.path == h {
					append(&out, h)
					break
				}
			}
		} else if has_path(app, h) {
			append(&out, h)
		}
	}
	return out[:]
}

layer_paths :: proc(app: ^App) -> []pm.Path_Handle {
	l := pm.layer(&app.doc, app.active_layer)
	if l == nil || l.kind != .Vector do return nil
	return l.paths[:]
}

// Shows the style of the first selected shape, so that editing starts from it.
style_from_selection :: proc(app: ^App) {
	targets := target_paths(app)
	if len(targets) == 0 do return
	p := pm.path(&app.doc, targets[0])
	app.style.fill_on = p.has_fill
	app.style.stroke_on = p.has_stroke
	if p.has_fill do app.style.fill = p.fill
	if p.has_stroke do app.style.stroke = p.stroke
	width: f32
	if app.tool == .Points {
		for r in app.selection.points do if r.path == targets[0] do width = max(width, p.knots[r.index].width)
	} else {
		for k in p.knots do width = max(width, k.width)
	}
	if width > 0 do app.style.width = width
	pm.history_seal(&app.history) // edits to a new selection are a new step
}

// --- Picking ------------------------------------------------------------------

// Top-most path of the active layer under the cursor.
pick_path :: proc(app: ^App, ls: Layer_Space, px: Vec2) -> pm.Path_Handle {
	p := to_layer(app, ls, px)
	tolerance := px_to_layer(app, ls, pt(app, 4))
	paths := layer_paths(app)
	#reverse for h in paths {
		if path := pm.path(&app.doc, h); path != nil && pm.path_hit(path, p, tolerance) do return h
	}
	return {}
}

@(private = "file")
pick_knot :: proc(app: ^App, ls: Layer_Space, px: Vec2) -> (ref: Point_Ref, ok: bool) {
	best := pt(app, GRAB_RADIUS)
	paths := layer_paths(app)
	#reverse for h in paths {
		p := pm.path(&app.doc, h)
		for k, i in p.knots {
			d := linalg.length(to_screen(app, ls, k.pos) - px)
			if d < best {
				best = d
				ref, ok = {h, i}, true
			}
		}
	}
	return
}

@(private = "file")
pick_handle :: proc(app: ^App, ls: Layer_Space, px: Vec2) -> (ref: Point_Ref, side: Handle_Side, ok: bool) {
	best := pt(app, GRAB_RADIUS)
	for r in app.selection.points {
		k := pm.path(&app.doc, r.path).knots[r.index]
		for s in Handle_Side {
			h := s == .In ? k.handle_in : k.handle_out
			if h == k.pos do continue
			d := linalg.length(to_screen(app, ls, h) - px)
			if d < best {
				best = d
				ref, side, ok = r, s, true
			}
		}
	}
	return
}

// --- Transform box ------------------------------------------------------------

// Bounds of what the transform box acts on, in layer space.
selection_box :: proc(app: ^App, ls: Layer_Space) -> (b: pm.Bounds, ok: bool) {
	b = pm.BOUNDS_EMPTY
	tolerance := px_to_layer(app, ls, 0.5)
	#partial switch app.tool {
	case .Select:
		for h in app.selection.paths {
			p := pm.path(&app.doc, h)
			c := pm.curve_bounds(p.knots[:], p.closed, tolerance)
			if !pm.bounds_is_empty(c) {
				pm.bounds_add(&b, c.min)
				pm.bounds_add(&b, c.max)
			}
		}
	case .Points:
		if len(app.selection.points) < 2 do return b, false
		for r in app.selection.points do pm.bounds_add(&b, pm.path(&app.doc, r.path).knots[r.index].pos)
	case:
		return b, false
	}
	return b, !pm.bounds_is_empty(b)
}

// Position of a box grip, padded outwards so it doesn't cover the corner knots.
grip_position :: proc(app: ^App, ls: Layer_Space, b: pm.Bounds, grip: [2]int) -> Vec2 {
	pad := px_to_layer(app, ls, pt(app, BOX_PADDING))
	c := (b.min + b.max) * 0.5
	half := (b.max - b.min) * 0.5 + pad
	return c + {f32(grip.x) * half.x, f32(grip.y) * half.y}
}

rotate_grip_position :: proc(app: ^App, ls: Layer_Space, b: pm.Bounds) -> Vec2 {
	top := grip_position(app, ls, b, {0, -1})
	// Straight up on screen, whatever the view rotation.
	up_px := to_screen(app, ls, top) + Vec2{0, -pt(app, ROTATE_DISTANCE)}
	return to_layer(app, ls, up_px)
}

GRIPS := [8][2]int{{-1, -1}, {0, -1}, {1, -1}, {1, 0}, {1, 1}, {0, 1}, {-1, 1}, {-1, 0}}

// --- Drags --------------------------------------------------------------------

@(private = "file")
next_merge_key: u64 = 1 << 48

@(private = "file")
drag_begin :: proc(app: ^App, kind: Drag_Kind, ls: Layer_Space, px: Vec2) {
	drag_clear_snapshots(app)
	d := &app.drag
	snapshots := d.snapshots
	d^ = {kind = kind, space = ls, start_px = px, current_px = px, start = to_layer(app, ls, px), snapshots = snapshots}
	next_merge_key += 1
	d.merge_key = next_merge_key
}

@(private = "file")
drag_clear_snapshots :: proc(app: ^App) {
	for s in app.drag.snapshots do delete(s.knots)
	clear(&app.drag.snapshots)
}

// Remembers the affected paths so every frame starts from the original shape.
@(private = "file")
drag_take_snapshots :: proc(app: ^App) {
	for h in target_paths(app) {
		p := pm.path(&app.doc, h)
		knots := make([dynamic]pm.Knot, len(p.knots))
		copy(knots[:], p.knots[:])
		append(&app.drag.snapshots, Snapshot{h, knots})
	}
}

@(private = "file")
drag_end :: proc(app: ^App) {
	drag_clear_snapshots(app)
	app.drag.kind = .None
	pm.history_seal(&app.history)
}

mat_translate :: proc(v: Vec2) -> pm.Mat3 {
	return {1, 0, v.x, 0, 1, v.y, 0, 0, 1}
}

mat_scale_about :: proc(c, s: Vec2) -> pm.Mat3 {
	return {s.x, 0, c.x - s.x * c.x, 0, s.y, c.y - s.y * c.y, 0, 0, 1}
}

mat_rotate_about :: proc(c: Vec2, angle: f32) -> pm.Mat3 {
	co, si := math.cos(angle), math.sin(angle)
	return {co, -si, c.x - (co * c.x - si * c.y), si, co, c.y - (si * c.x + co * c.y), 0, 0, 1}
}

// Rewrites every snapshot path through `m` as one (merged) undo step.
@(private = "file")
apply_matrix :: proc(app: ^App, m: pm.Mat3) {
	selected := make(map[Point_Ref]bool, context.temp_allocator)
	if app.drag.points_only do for r in app.selection.points do selected[r] = true

	pm.history_begin_group(&app.history)
	for s in app.drag.snapshots {
		p := pm.path(&app.doc, s.path)
		if p == nil do continue
		value := p^
		value.knots = make([dynamic]pm.Knot, len(s.knots), context.temp_allocator)
		copy(value.knots[:], s.knots[:])
		for &k, i in value.knots {
			if app.drag.points_only && !selected[{s.path, i}] do continue
			k.pos = pm.mat3_apply(m, k.pos)
			k.handle_in = pm.mat3_apply(m, k.handle_in)
			k.handle_out = pm.mat3_apply(m, k.handle_out)
		}
		pm.set_path(&app.history, &app.doc, s.path, value)
	}
	pm.history_end_group(&app.history, app.drag.merge_key)
}

@(private = "file")
drag_update :: proc(app: ^App, px: Vec2) {
	d := &app.drag
	d.current_px = px
	ls := d.space
	shift, alt := modifiers()
	cur := to_layer(app, ls, px)

	// A click on a point, shape or grip must not change it (snapping would
	// jump it to the grid), so edits wait until the pointer really moves.
	#partial switch d.kind {
	case .Move, .Scale, .Rotate, .Handle:
		if !d.started {
			if linalg.length(px - d.start_px) < pt(app, DRAG_DEAD_ZONE) do return
			d.started = true
		}
	}

	#partial switch d.kind {
	case .Move:
		// The grabbed point lands on the grid, not just moves in grid steps.
		raw := cur - d.start
		lock_x, lock_y: bool
		if shift { // constrain to the main axis
			if abs(raw.x) > abs(raw.y) do lock_y = true
			else do lock_x = true
		}
		delta := snap(app, ls, d.anchor + raw) - d.anchor
		if lock_x do delta.x = 0
		if lock_y do delta.y = 0
		apply_matrix(app, mat_translate(delta))

	case .Scale:
		b := d.box
		c := (b.min + b.max) * 0.5
		edge := c + {f32(d.grip.x), f32(d.grip.y)} * (b.max - b.min) * 0.5
		anchor := alt ? c : c - {f32(d.grip.x), f32(d.grip.y)} * (b.max - b.min) * 0.5
		target := snap(app, ls, cur - d.grip_offset)
		s := Vec2{1, 1}
		for axis in 0 ..< 2 {
			span := edge[axis] - anchor[axis]
			if d.grip[axis] != 0 && abs(span) > 1e-6 do s[axis] = (target[axis] - anchor[axis]) / span
		}
		if shift { // keep proportions
			u: f32
			switch {
			case d.grip.x == 0: u = s.y
			case d.grip.y == 0: u = s.x
			case:               u = abs(s.x) > abs(s.y) ? s.x : s.y
			}
			s = {u, u}
		}
		apply_matrix(app, mat_scale_about(anchor, s))

	case .Rotate:
		c := (d.box.min + d.box.max) * 0.5
		a0 := math.atan2(d.start.y - c.y, d.start.x - c.x)
		a1 := math.atan2(cur.y - c.y, cur.x - c.x)
		angle := a1 - a0
		if shift {
			step := math.to_radians(f32(15))
			angle = math.round(angle / step) * step
		}
		apply_matrix(app, mat_rotate_about(c, angle))

	case .Handle:
		drag_handle(app, snap(app, ls, cur), alt)

	case .Erase:
		erase_at(app, px)
	}
}

// Moves one Bézier handle. Smooth knots keep their handles in line unless Alt
// is held, which turns the knot into a cusp.
@(private = "file")
drag_handle :: proc(app: ^App, cur: Vec2, alt: bool) {
	d := &app.drag
	if len(d.snapshots) == 0 do return
	s := d.snapshots[0]
	p := pm.path(&app.doc, s.path)
	if p == nil do return
	value := p^
	value.knots = make([dynamic]pm.Knot, len(s.knots), context.temp_allocator)
	copy(value.knots[:], s.knots[:])
	k := &value.knots[d.handle.index]
	orig := s.knots[d.handle.index]

	moved := d.side == .Out ? &k.handle_out : &k.handle_in
	other := d.side == .Out ? &k.handle_in : &k.handle_out
	other_orig := d.side == .Out ? orig.handle_in : orig.handle_out
	moved_orig := d.side == .Out ? orig.handle_out : orig.handle_in
	moved^ = cur
	if !alt && other_orig != orig.pos && handles_in_line(orig.pos, moved_orig, other_orig) {
		dir := cur - k.pos
		if l := linalg.length(dir); l > 1e-6 {
			other^ = k.pos - dir / l * linalg.length(other_orig - orig.pos)
		}
	}
	pm.history_begin_group(&app.history)
	pm.set_path(&app.history, &app.doc, s.path, value)
	pm.history_end_group(&app.history, d.merge_key)
}

@(private = "file")
handles_in_line :: proc(pos, a, b: Vec2) -> bool {
	da := a - pos
	db := pos - b
	la, lb := linalg.length(da), linalg.length(db)
	if la < 1e-6 || lb < 1e-6 do return false
	da /= la
	db /= lb
	return linalg.dot(da, db) > 0.999
}

// Starts a scale or rotate drag if the cursor is on a box grip.
@(private = "file")
try_box_grip :: proc(app: ^App, ls: Layer_Space, px: Vec2) -> bool {
	b, ok := selection_box(app, ls)
	if !ok do return false
	r := pt(app, GRAB_RADIUS)
	if linalg.length(to_screen(app, ls, rotate_grip_position(app, ls, b)) - px) < r {
		drag_begin(app, .Rotate, ls, px)
		app.drag.box = b
		app.drag.points_only = app.tool == .Points
		drag_take_snapshots(app)
		return true
	}
	for g in GRIPS {
		gp := grip_position(app, ls, b, g)
		if linalg.length(to_screen(app, ls, gp) - px) < r {
			drag_begin(app, .Scale, ls, px)
			app.drag.box = b
			app.drag.grip = g
			c := (b.min + b.max) * 0.5
			edge := c + {f32(g.x), f32(g.y)} * (b.max - b.min) * 0.5
			app.drag.grip_offset = app.drag.start - edge
			app.drag.points_only = app.tool == .Points
			drag_take_snapshots(app)
			return true
		}
	}
	return false
}

// --- Pointer entry points -----------------------------------------------------

pointer_down :: proc(app: ^App, px: Vec2, pressure: f32, from_pen, eraser: bool) {
	selection_prune(app) // an undo earlier in this event batch may have removed items
	now := sdl.GetTicks()
	double := now - app.pointer.last_click_ms < 400 && linalg.length(px - app.pointer.last_click_px) < pt(app, 6)
	app.pointer.last_click_ms = double ? 0 : now // a third click starts over
	app.pointer.last_click_px = px
	app.pointer.down = true
	app.pointer.from_pen = from_pen
	app.hover_px = px

	if app.tool == .Pan || app.space_held {
		app.panning = true
		app.last_mouse = px
		return
	}
	target := drawable_layer(app)
	if target == {} do return
	ls, _ := layer_space(app, target)
	shift, _ := modifiers()

	if eraser {
		drag_begin(app, .Erase, ls, px)
		pm.history_begin_group(&app.history)
		erase_at(app, px)
		return
	}

	switch app.tool {
	case .Draw:
		stroke_begin(app, px, pressure, from_pen)
	case .Select:
		select_down(app, ls, px, shift)
	case .Points:
		points_down(app, ls, px, shift, double)
	case .Pen:
		pen_down(app, ls, px, double)
	case .Rectangle, .Ellipse:
		drag_begin(app, .Shape, ls, px)
		app.drag.start = snap(app, ls, app.drag.start)
	case .Pan:
	}
}

pointer_move :: proc(app: ^App, px: Vec2, pressure: f32) {
	app.hover_px = px
	if !app.pointer.down do return
	switch {
	case app.builder.active:
		stroke_add(app, px, pressure)
	case app.tool == .Pen && app.pen_path.dragging:
		pen_drag(app, px)
	case app.drag.kind != .None:
		drag_update(app, px)
	}
}

pointer_up :: proc(app: ^App, px: Vec2) {
	if !app.pointer.down do return
	app.pointer.down = false
	app.panning = false
	if app.builder.active do stroke_end(app)
	app.pen_path.dragging = false

	shift, alt := modifiers()
	#partial switch app.drag.kind {
	case .Marquee:
		marquee_select(app, shift)
	case .Shape:
		shape_finish(app, px, shift, alt)
	case .Erase:
		pm.history_end_group(&app.history)
	}
	if app.drag.kind != .None do drag_end(app)
}

// --- Select tool --------------------------------------------------------------

@(private = "file")
select_down :: proc(app: ^App, ls: Layer_Space, px: Vec2, shift: bool) {
	if !shift && try_box_grip(app, ls, px) do return
	hit := pick_path(app, ls, px)
	if hit == {} {
		drag_begin(app, .Marquee, ls, px)
		app.drag.additive = shift
		return
	}
	if shift {
		toggle_path(app, hit)
		style_from_selection(app)
		if !has_path(app, hit) do return
	} else if !has_path(app, hit) {
		clear(&app.selection.paths)
		append(&app.selection.paths, hit)
		style_from_selection(app)
	}
	drag_begin(app, .Move, ls, px)
	app.drag.anchor = nearest_knot_pos(app, hit, app.drag.start)
	drag_take_snapshots(app)
}

// The knot of `h` closest to `p` (layer space): the point a shape move snaps by.
@(private = "file")
nearest_knot_pos :: proc(app: ^App, h: pm.Path_Handle, p: Vec2) -> Vec2 {
	path := pm.path(&app.doc, h)
	if path == nil || len(path.knots) == 0 do return p
	best := path.knots[0].pos
	for k in path.knots[1:] {
		if linalg.length2(k.pos - p) < linalg.length2(best - p) do best = k.pos
	}
	return best
}

// --- Points tool --------------------------------------------------------------

@(private = "file")
points_down :: proc(app: ^App, ls: Layer_Space, px: Vec2, shift, double: bool) {
	if ref, side, ok := pick_handle(app, ls, px); ok {
		drag_begin(app, .Handle, ls, px)
		app.drag.handle = ref
		app.drag.side = side
		p := pm.path(&app.doc, ref.path)
		knots := make([dynamic]pm.Knot, len(p.knots))
		copy(knots[:], p.knots[:])
		append(&app.drag.snapshots, Snapshot{ref.path, knots})
		return
	}
	if ref, ok := pick_knot(app, ls, px); ok {
		if double {
			toggle_corner(app, ref)
			return
		}
		if shift {
			toggle_point(app, ref)
			style_from_selection(app)
			if !has_point(app, ref) do return
		} else if !has_point(app, ref) {
			clear(&app.selection.points)
			append(&app.selection.points, ref)
			style_from_selection(app)
		}
		drag_begin(app, .Move, ls, px)
		app.drag.points_only = true
		app.drag.anchor = pm.path(&app.doc, ref.path).knots[ref.index].pos
		drag_take_snapshots(app)
		return
	}
	if !shift && try_box_grip(app, ls, px) do return
	if double && insert_point(app, ls, px) do return
	drag_begin(app, .Marquee, ls, px)
	app.drag.additive = shift
}

// Turns a corner into a smooth point or back.
@(private = "file")
toggle_corner :: proc(app: ^App, ref: Point_Ref) {
	p := pm.path(&app.doc, ref.path)
	value := pm.clone_path(p^, context.temp_allocator)
	k := &value.knots[ref.index]
	if pm.knot_is_corner(k^) {
		pm.knot_make_smooth(value.knots[:], value.closed, ref.index)
	} else {
		pm.knot_make_corner(k)
	}
	pm.set_path(&app.history, &app.doc, ref.path, value)
}

toggle_selected_corners :: proc(app: ^App) {
	refs := make([]Point_Ref, len(app.selection.points), context.temp_allocator)
	copy(refs, app.selection.points[:])
	pm.history_begin_group(&app.history)
	for r in refs do toggle_corner(app, r)
	pm.history_end_group(&app.history)
}

// Adds a knot on the curve under the cursor. Returns false if there is none.
@(private = "file")
insert_point :: proc(app: ^App, ls: Layer_Space, px: Vec2) -> bool {
	p := to_layer(app, ls, px)
	tolerance := px_to_layer(app, ls, 0.5)
	limit := px_to_layer(app, ls, pt(app, 5))
	best: pm.Curve_Location
	best_path: pm.Path_Handle
	best.distance = limit
	paths := layer_paths(app)
	#reverse for h in paths {
		path := pm.path(&app.doc, h)
		if loc, ok := pm.nearest_on_path(path.knots[:], path.closed, p, tolerance); ok && loc.distance < best.distance {
			best, best_path = loc, h
		}
	}
	if best_path == {} do return false
	value := pm.clone_path(pm.path(&app.doc, best_path)^, context.temp_allocator)
	index := pm.split_segment(&value.knots, value.closed, best.segment, best.t)
	pm.set_path(&app.history, &app.doc, best_path, value)

	// Indices after the new knot have shifted.
	for &r in app.selection.points do if r.path == best_path && r.index >= index do r.index += 1
	clear(&app.selection.points)
	append(&app.selection.points, Point_Ref{best_path, index})
	return true
}

delete_selected_points :: proc(app: ^App) {
	if len(app.selection.points) == 0 do return
	selected := make(map[Point_Ref]bool, context.temp_allocator)
	for r in app.selection.points do selected[r] = true
	targets := target_paths(app)
	pm.history_begin_group(&app.history)
	for h in targets {
		p := pm.path(&app.doc, h)
		value := p^
		value.knots = make([dynamic]pm.Knot, context.temp_allocator)
		for k, i in p.knots do if !selected[{h, i}] do append(&value.knots, k)
		if len(value.knots) < 2 {
			pm.remove_path(&app.history, &app.doc, app.selection.layer, h)
			continue
		}
		if len(value.knots) < 3 do value.closed = false
		pm.set_path(&app.history, &app.doc, h, value)
	}
	pm.history_end_group(&app.history)
	clear(&app.selection.points)
}

// --- Selection-wide commands --------------------------------------------------

select_all :: proc(app: ^App) {
	selection_clear(app)
	for h in layer_paths(app) {
		if app.tool == .Points {
			for _, i in pm.path(&app.doc, h).knots do append(&app.selection.points, Point_Ref{h, i})
		} else {
			append(&app.selection.paths, h)
		}
	}
	style_from_selection(app)
}

delete_selection :: proc(app: ^App) {
	if app.tool == .Points {
		delete_selected_points(app)
		return
	}
	targets := target_paths(app)
	pm.history_begin_group(&app.history)
	for h in targets do pm.remove_path(&app.history, &app.doc, app.selection.layer, h)
	pm.history_end_group(&app.history)
	clear(&app.selection.paths)
}

Restack :: enum {
	Raise,
	Lower,
	To_Front,
	To_Back,
}

// Changes the stacking order of the target shapes, keeping their relative order.
restack_selection :: proc(app: ^App, how: Restack) {
	l := pm.layer(&app.doc, app.selection.layer)
	if l == nil do return
	targets := target_paths(app) // bottom to top
	is_target :: proc(targets: []pm.Path_Handle, h: pm.Path_Handle) -> bool {
		return pm.index_of_path(targets, h) >= 0
	}
	pm.history_begin_group(&app.history)
	defer pm.history_end_group(&app.history)
	switch how {
	case .To_Front:
		for h in targets do pm.move_path(&app.history, &app.doc, app.selection.layer, h, len(l.paths) - 1)
	case .To_Back:
		#reverse for h in targets do pm.move_path(&app.history, &app.doc, app.selection.layer, h, 0)
	case .Raise:
		#reverse for h in targets {
			i := pm.index_of_path(l.paths[:], h)
			if i + 1 < len(l.paths) && !is_target(targets, l.paths[i + 1]) {
				pm.move_path(&app.history, &app.doc, app.selection.layer, h, i + 1)
			}
		}
	case .Lower:
		for h in targets {
			i := pm.index_of_path(l.paths[:], h)
			if i > 0 && !is_target(targets, l.paths[i - 1]) {
				pm.move_path(&app.history, &app.doc, app.selection.layer, h, i - 1)
			}
		}
	}
}

Style_Field :: enum {
	Fill,
	Stroke,
	Width,
	Closed,
}

// Applies one style field from app.style to the target shapes. In the Points
// tool, width applies to the selected points only.
apply_style :: proc(app: ^App, field: Style_Field, closed := false, merge_key: u64 = 0) {
	targets := target_paths(app)
	pm.history_begin_group(&app.history)
	for h in targets {
		value := pm.clone_path(pm.path(&app.doc, h)^, context.temp_allocator)
		switch field {
		case .Fill:
			value.has_fill = app.style.fill_on
			value.fill = app.style.fill
		case .Stroke:
			value.has_stroke = app.style.stroke_on
			value.stroke = app.style.stroke
		case .Closed:
			value.closed = closed && len(value.knots) >= 3
		case .Width:
			if app.tool == .Points {
				for r in app.selection.points do if r.path == h do value.knots[r.index].width = app.style.width
			} else {
				// Scale, so pressure variation along a stroke survives.
				widest: f32
				for k in value.knots do widest = max(widest, k.width)
				for &k in value.knots do k.width = widest > 0 ? k.width * app.style.width / widest : app.style.width
			}
		}
		pm.set_path(&app.history, &app.doc, h, value)
	}
	pm.history_end_group(&app.history, merge_key)
}

// --- Marquee ------------------------------------------------------------------

marquee_rect :: proc(app: ^App) -> (lo, hi: Vec2) {
	return linalg.min(app.drag.start_px, app.drag.current_px), linalg.max(app.drag.start_px, app.drag.current_px)
}

@(private = "file")
marquee_select :: proc(app: ^App, additive: bool) {
	ls := app.drag.space
	lo, hi := marquee_rect(app)
	inside :: proc(p, lo, hi: Vec2) -> bool {
		return p.x >= lo.x && p.y >= lo.y && p.x <= hi.x && p.y <= hi.y
	}
	if !additive do selection_clear(app)
	tolerance := px_to_layer(app, ls, 0.5)
	for h in layer_paths(app) {
		p := pm.path(&app.doc, h)
		if app.tool == .Points {
			for k, i in p.knots {
				r := Point_Ref{h, i}
				if inside(to_screen(app, ls, k.pos), lo, hi) && !has_point(app, r) do append(&app.selection.points, r)
			}
			continue
		}
		flat := make([dynamic]pm.Flat_Point, context.temp_allocator)
		pm.flatten(p.knots[:], p.closed, tolerance, &flat)
		all_in := len(flat) > 0
		for f in flat {
			if !inside(to_screen(app, ls, f.pos), lo, hi) {
				all_in = false
				break
			}
		}
		if all_in && !has_path(app, h) do append(&app.selection.paths, h)
	}
	style_from_selection(app)
}

// --- Rectangle and ellipse ----------------------------------------------------

// Corners of the shape being dragged out, in layer space.
shape_corners :: proc(app: ^App, px: Vec2, square, from_center: bool) -> (a, b: Vec2) {
	ls := app.drag.space
	a = app.drag.start
	b = snap(app, ls, to_layer(app, ls, px))
	if square {
		d := b - a
		s := max(abs(d.x), abs(d.y))
		b = a + {math.sign(d.x) * s, math.sign(d.y) * s}
	}
	if from_center do a = 2 * a - b
	return
}

shape_knots :: proc(app: ^App, px: Vec2, shift, alt: bool) -> [4]pm.Knot {
	a, b := shape_corners(app, px, shift, alt)
	width := app.style.width / max(app.drag.space.scale, 1e-6)
	if app.tool == .Ellipse do return pm.ellipse_knots((a + b) * 0.5, linalg.abs(b - a) * 0.5, width)
	return pm.rect_knots(a, b, width)
}

@(private = "file")
shape_finish :: proc(app: ^App, px: Vec2, shift, alt: bool) {
	if linalg.length(px - app.drag.start_px) < pt(app, 3) do return
	knots := shape_knots(app, px, shift, alt)
	p := new_shape_path(app, true)
	append(&p.knots, ..knots[:])
	add_shape(app, p)
}

new_shape_path :: proc(app: ^App, closed: bool) -> pm.Path {
	s := app.style
	return {
		closed     = closed,
		has_fill   = closed && s.fill_on,
		has_stroke = s.stroke_on || !closed || !s.fill_on, // never invisible
		fill       = s.fill,
		stroke     = s.stroke,
	}
}

// Adds a finished shape to the active layer and selects it.
@(private = "file")
add_shape :: proc(app: ^App, p: pm.Path) {
	h := pm.add_path(&app.history, &app.doc, app.active_layer, p)
	if h == {} do return
	selection_clear(app)
	append(&app.selection.paths, h)
}

// --- Pen (Bézier) tool --------------------------------------------------------
//
// Click: corner point. Click and drag: smooth point with handles. Click the
// first point to close the shape; Enter or a double click finishes it open.

@(private = "file")
pen_down :: proc(app: ^App, ls: Layer_Space, px: Vec2, double: bool) {
	pp := &app.pen_path
	if !pp.active {
		pp.active = true
		pp.layer = app.active_layer
		clear(&pp.knots)
	}
	if n := len(pp.knots); n >= 2 {
		if linalg.length(to_screen(app, ls, pp.knots[0].pos) - px) < pt(app, GRAB_RADIUS) {
			pen_path_finish(app, true)
			return
		}
		if double && linalg.length(to_screen(app, ls, pp.knots[n - 1].pos) - px) < pt(app, GRAB_RADIUS) {
			pen_path_finish(app, false)
			return
		}
	}
	p := snap(app, ls, to_layer(app, ls, px))
	width := app.style.width / max(ls.scale, 1e-6)
	append(&pp.knots, pm.Knot{p, p, p, width})
	pp.dragging = true
}

@(private = "file")
pen_drag :: proc(app: ^App, px: Vec2) {
	pp := &app.pen_path
	if len(pp.knots) == 0 do return
	ls, ok := layer_space(app, pp.layer)
	if !ok do return
	k := &pp.knots[len(pp.knots) - 1]
	if linalg.length(to_screen(app, ls, k.pos) - px) < pt(app, 3) {
		pm.knot_make_corner(k)
		return
	}
	out := to_layer(app, ls, px)
	k.handle_out = out
	k.handle_in = 2 * k.pos - out
}

// Adds the path being drawn to the document (if it has a segment).
@(private = "file")
pen_path_finish :: proc(app: ^App, closed: bool) {
	pp := &app.pen_path
	if !pp.active do return
	pp.active = false
	pp.dragging = false
	if len(pp.knots) < 2 {
		clear(&pp.knots)
		return
	}
	p := new_shape_path(app, closed && len(pp.knots) >= 3)
	append(&p.knots, ..pp.knots[:])
	clear(&pp.knots)
	if pm.layer(&app.doc, pp.layer) == nil {
		delete(p.knots)
		return
	}
	saved := app.active_layer
	app.active_layer = pp.layer
	add_shape(app, p)
	app.active_layer = saved
}

pen_path_commit :: proc(app: ^App) {
	pen_path_finish(app, false)
}

pen_path_cancel :: proc(app: ^App) {
	app.pen_path.active = false
	app.pen_path.dragging = false
	clear(&app.pen_path.knots)
}

pen_path_remove_last :: proc(app: ^App) {
	pp := &app.pen_path
	if len(pp.knots) > 0 do pop(&pp.knots)
	if len(pp.knots) == 0 do pen_path_cancel(app)
}

// --- Eraser -------------------------------------------------------------------

// Deletes every shape of the active layer under the eraser. Runs inside the
// erase drag's history group, so a whole eraser stroke is one undo step.
@(private = "file")
erase_at :: proc(app: ^App, px: Vec2) {
	ls := app.drag.space
	p := to_layer(app, ls, px)
	tolerance := px_to_layer(app, ls, pt(app, ERASER_RADIUS))
	hits := make([dynamic]pm.Path_Handle, context.temp_allocator)
	for h in layer_paths(app) {
		if path := pm.path(&app.doc, h); path != nil && pm.path_hit(path, p, tolerance) do append(&hits, h)
	}
	for h in hits do pm.remove_path(&app.history, &app.doc, app.active_layer, h)
}

// --- Preview ------------------------------------------------------------------

// The unfinished shape to show inside its layer this frame, if any.
tool_preview :: proc(app: ^App) -> pm.Preview {
	if b := &app.builder; b.active {
		return {b.layer, {knots = b.knots, has_stroke = true, stroke = b.color}}
	}
	if pp := &app.pen_path; pp.active && len(pp.knots) > 0 {
		return {pp.layer, {knots = pp.knots, has_stroke = true, stroke = app.style.stroke}}
	}
	if app.drag.kind == .Shape && app.pointer.down {
		shift, alt := modifiers()
		k := shape_knots(app, app.drag.current_px, shift, alt)
		knots := make([dynamic]pm.Knot, context.temp_allocator)
		append(&knots, ..k[:])
		p := new_shape_path(app, true)
		p.knots = knots
		return {app.active_layer, p}
	}
	return {}
}

// --- Keys ---------------------------------------------------------------------

// Tool shortcuts. Returns true if the key was used.
tool_key :: proc(app: ^App, key: sdl.Keycode, ctrl, shift: bool) -> bool {
	if app.tool == .Pen && app.pen_path.active {
		switch {
		case key == sdl.K_RETURN || key == sdl.K_KP_ENTER: pen_path_commit(app); return true
		case key == sdl.K_ESCAPE:                          pen_path_cancel(app); return true
		case key == sdl.K_BACKSPACE || (ctrl && key == sdl.K_Z && !shift): pen_path_remove_last(app); return true
		}
	}
	if ctrl {
		if key == sdl.K_A {
			select_all(app)
			return true
		}
		return false
	}
	switch key {
	case sdl.K_V: set_tool(app, .Select)
	case sdl.K_A: set_tool(app, .Points)
	case sdl.K_B: set_tool(app, .Draw)
	case sdl.K_P: set_tool(app, .Pen)
	case sdl.K_R: set_tool(app, .Rectangle)
	case sdl.K_E: set_tool(app, .Ellipse)
	case sdl.K_H: set_tool(app, .Pan)
	case sdl.K_G:
		if shift do app.grid.snap = !app.grid.snap
		else do app.grid.show = !app.grid.show
	case sdl.K_DELETE, sdl.K_BACKSPACE: delete_selection(app)
	case sdl.K_ESCAPE:                  selection_clear(app)
	case sdl.K_C:
		if app.tool == .Points do toggle_selected_corners(app)
		else do return false
	case sdl.K_PAGEUP:   restack_selection(app, shift ? .To_Front : .Raise)
	case sdl.K_PAGEDOWN: restack_selection(app, shift ? .To_Back : .Lower)
	case: return false
	}
	return true
}

// Abandons any gesture and the selection, e.g. before a new document loads.
tools_reset :: proc(app: ^App) {
	stroke_cancel(app)
	pen_path_cancel(app)
	if app.drag.kind == .Erase do pm.history_end_group(&app.history)
	drag_clear_snapshots(app)
	app.drag.kind = .None
	app.pointer.down = false
	selection_clear(app)
}
