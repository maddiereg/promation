package main

// Editing overlays drawn over the canvas with ImGui's background draw list:
// grid, selection outlines, knots and handles, transform box, marquee.
// ImGui works in window points, so pixel positions are divided by density.

import im "third:odin-imgui"

import pm "../core"

@(private = "file")
rgba :: proc "contextless" (r, g, b, a: u8) -> u32 {
	return u32(a) << 24 | u32(b) << 16 | u32(g) << 8 | u32(r)
}

@(private = "file") COL_GRID       := rgba(90, 110, 140, 70)
@(private = "file") COL_GRID_MAJOR := rgba(90, 110, 140, 140)
@(private = "file") COL_ACCENT     := rgba(60, 150, 255, 255)
@(private = "file") COL_OUTLINE    := rgba(60, 150, 255, 140)
@(private = "file") COL_KNOT       := rgba(255, 255, 255, 255)
@(private = "file") COL_KNOT_EDGE  := rgba(20, 30, 50, 255)
@(private = "file") COL_SELECTED   := rgba(255, 140, 30, 255)
@(private = "file") COL_HANDLE     := rgba(255, 140, 30, 200)
@(private = "file") COL_MARQUEE    := rgba(60, 150, 255, 40)

@(private = "file")
iv :: proc(app: ^App, px: Vec2) -> im.Vec2 {
	p := px / app.density
	return {p.x, p.y}
}

draw_overlays :: proc(app: ^App) {
	dl := im.GetBackgroundDrawList()
	if app.grid.show do draw_grid(app, dl)

	ls, ok := layer_space(app, app.active_layer)
	if ok && pm.layer(&app.doc, app.active_layer) != nil {
		#partial switch app.tool {
		case .Select:
			for h in app.selection.paths do draw_outline(app, dl, ls, pm.path(&app.doc, h), COL_ACCENT, 1.5)
			draw_box(app, dl, ls)
		case .Points:
			draw_points(app, dl, ls)
			draw_box(app, dl, ls)
		case .Pen:
			draw_pen_path(app, dl)
		}
	}

	if app.drag.kind == .Marquee {
		lo, hi := marquee_rect(app)
		im.DrawList_AddRectFilled(dl, iv(app, lo), iv(app, hi), COL_MARQUEE)
		im.DrawList_AddRect(dl, iv(app, lo), iv(app, hi), COL_ACCENT)
	}
	if app.drag.kind == .Erase || (app.pen.in_range && app.pen.eraser && !app.pointer.down) {
		im.DrawList_AddCircle(dl, iv(app, app.hover_px), ERASER_RADIUS, COL_SELECTED, 0, 1.5)
	}
}

// Document grid over the page. Lines closer than a few pixels are skipped by
// widening the step, so zooming out never floods the screen.
@(private = "file")
draw_grid :: proc(app: ^App, dl: ^im.DrawList) {
	s := app.doc.settings
	w, h := f32(s.width), f32(s.height)
	step := app.grid.size
	if step <= 0 do return
	major := 5
	for step * app.cam.zoom < pt(app, 6) {
		step *= 5
		major = 1 // every remaining line is a major one
	}
	nx := int(w / step)
	ny := int(h / step)
	if nx + ny > 2000 do return
	for i in 0 ..= nx {
		x := f32(i) * step
		col := (major > 1 && i % major == 0) ? COL_GRID_MAJOR : COL_GRID
		a := pm.world_to_screen(app.cam, {x, 0})
		b := pm.world_to_screen(app.cam, {x, h})
		im.DrawList_AddLine(dl, iv(app, a), iv(app, b), col)
	}
	for j in 0 ..= ny {
		y := f32(j) * step
		col := (major > 1 && j % major == 0) ? COL_GRID_MAJOR : COL_GRID
		a := pm.world_to_screen(app.cam, {0, y})
		b := pm.world_to_screen(app.cam, {w, y})
		im.DrawList_AddLine(dl, iv(app, a), iv(app, b), col)
	}
}

@(private = "file")
draw_outline :: proc(app: ^App, dl: ^im.DrawList, ls: Layer_Space, p: ^pm.Path, col: u32, thickness: f32) {
	if p == nil do return
	draw_knot_outline(app, dl, ls, p.knots[:], p.closed, col, thickness)
}

@(private = "file")
draw_knot_outline :: proc(app: ^App, dl: ^im.DrawList, ls: Layer_Space, knots: []pm.Knot, closed: bool, col: u32, thickness: f32) {
	flat := make([dynamic]pm.Flat_Point, context.temp_allocator)
	pm.flatten(knots, closed, px_to_layer(app, ls, 0.5), &flat)
	if len(flat) < 2 do return
	pts := make([]im.Vec2, len(flat), context.temp_allocator)
	for f, i in flat do pts[i] = iv(app, to_screen(app, ls, f.pos))
	im.DrawList_AddPolyline(dl, &pts[0], i32(len(pts)), col, thickness)
}

@(private = "file")
draw_knot :: proc(app: ^App, dl: ^im.DrawList, at: im.Vec2, selected, corner: bool) {
	r: f32 = selected ? 4 : 3
	fill := selected ? COL_SELECTED : COL_KNOT
	if corner {
		im.DrawList_AddRectFilled(dl, {at.x - r, at.y - r}, {at.x + r, at.y + r}, fill)
		im.DrawList_AddRect(dl, {at.x - r, at.y - r}, {at.x + r, at.y + r}, COL_KNOT_EDGE)
	} else {
		im.DrawList_AddCircleFilled(dl, at, r + 0.5, fill)
		im.DrawList_AddCircle(dl, at, r + 0.5, COL_KNOT_EDGE)
	}
}

// Points tool: every path of the layer with its knots; handles for the
// selected knots. Corners are squares, smooth points circles.
@(private = "file")
draw_points :: proc(app: ^App, dl: ^im.DrawList, ls: Layer_Space) {
	selected := make(map[Point_Ref]bool, context.temp_allocator)
	for r in app.selection.points do selected[r] = true
	for h in layer_paths(app) {
		p := pm.path(&app.doc, h)
		draw_outline(app, dl, ls, p, COL_OUTLINE, 1)
	}
	for h in layer_paths(app) {
		p := pm.path(&app.doc, h)
		for k, i in p.knots {
			if !selected[{h, i}] do continue
			at := iv(app, to_screen(app, ls, k.pos))
			for handle in ([2]Vec2{k.handle_in, k.handle_out}) {
				if handle == k.pos do continue
				hp := iv(app, to_screen(app, ls, handle))
				im.DrawList_AddLine(dl, at, hp, COL_HANDLE)
				im.DrawList_AddCircleFilled(dl, hp, 3, COL_HANDLE)
			}
		}
		for k, i in p.knots {
			draw_knot(app, dl, iv(app, to_screen(app, ls, k.pos)), selected[{h, i}], pm.knot_is_corner(k))
		}
	}
}

// Transform box: scale grips on corners and edges, rotation grip above.
@(private = "file")
draw_box :: proc(app: ^App, dl: ^im.DrawList, ls: Layer_Space) {
	if app.drag.kind == .Marquee do return
	b, ok := selection_box(app, ls)
	if !ok do return
	corners := [4][2]int{{-1, -1}, {1, -1}, {1, 1}, {-1, 1}}
	pts: [4]im.Vec2
	for c, i in corners do pts[i] = iv(app, to_screen(app, ls, grip_position(app, ls, b, c)))
	im.DrawList_AddQuad(dl, pts[0], pts[1], pts[2], pts[3], COL_ACCENT, 1)

	top := iv(app, to_screen(app, ls, grip_position(app, ls, b, {0, -1})))
	rot := iv(app, to_screen(app, ls, rotate_grip_position(app, ls, b)))
	im.DrawList_AddLine(dl, top, rot, COL_ACCENT)
	im.DrawList_AddCircleFilled(dl, rot, 4.5, COL_KNOT)
	im.DrawList_AddCircle(dl, rot, 4.5, COL_ACCENT, 0, 1.5)

	for g in GRIPS {
		at := iv(app, to_screen(app, ls, grip_position(app, ls, b, g)))
		r: f32 = 3.5
		im.DrawList_AddRectFilled(dl, {at.x - r, at.y - r}, {at.x + r, at.y + r}, COL_KNOT)
		im.DrawList_AddRect(dl, {at.x - r, at.y - r}, {at.x + r, at.y + r}, COL_ACCENT)
	}
}

// Pen tool: the path so far, a rubber band to the cursor and the last handles.
@(private = "file")
draw_pen_path :: proc(app: ^App, dl: ^im.DrawList) {
	pp := &app.pen_path
	if !pp.active || len(pp.knots) == 0 do return
	ls, ok := layer_space(app, pp.layer)
	if !ok do return
	draw_knot_outline(app, dl, ls, pp.knots[:], false, COL_ACCENT, 1)

	last := pp.knots[len(pp.knots) - 1]
	if !pp.dragging {
		// The segment the next click would add.
		cursor := snap(app, ls, to_layer(app, ls, app.hover_px))
		next := []pm.Knot{last, {cursor, cursor, cursor, 0}}
		draw_knot_outline(app, dl, ls, next, false, COL_OUTLINE, 1)
	}
	at := iv(app, to_screen(app, ls, last.pos))
	for handle in ([2]Vec2{last.handle_in, last.handle_out}) {
		if handle == last.pos do continue
		hp := iv(app, to_screen(app, ls, handle))
		im.DrawList_AddLine(dl, at, hp, COL_HANDLE)
		im.DrawList_AddCircleFilled(dl, hp, 3, COL_HANDLE)
	}
	for k, i in pp.knots {
		// The first knot is drawn larger: clicking it closes the shape.
		p := iv(app, to_screen(app, ls, k.pos))
		if i == 0 && len(pp.knots) >= 2 {
			im.DrawList_AddCircle(dl, p, GRAB_RADIUS, COL_ACCENT, 0, 1.5)
		}
		draw_knot(app, dl, p, false, pm.knot_is_corner(k))
	}
}
