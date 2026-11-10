package main

// Freehand stroke input. A stroke in progress lives here and enters the
// document, as one undoable step, when the pen is lifted.

import "core:math"
import "core:math/linalg"

import pm "../core"

Vec2 :: pm.Vec2

Stroke_Builder :: struct {
	active:    bool,
	from_pen:  bool,
	layer:     pm.Layer_Handle,
	knots:     [dynamic]pm.Knot, // layer space
	color:     pm.Color,
	to_layer:  pm.Mat3, // document -> layer
	to_doc:    pm.Mat3, // layer -> document
	scale:     f32, // layer -> document width scale
	smoothed:  Vec2, // document space, exponentially smoothed input
	last_kept: Vec2, // screen space of the last stored point

	// SDL on Wayland sometimes delivers no pressure at all for a pen stroke
	// (docs/phase0.md). Until a reading arrives, the stroke uses full width
	// rather than the near-zero minimum.
	pressure_seen: bool,
}

Brush :: struct {
	color:     pm.Color,
	size:      f32, // maximum width in document units
	pressure:  bool,
	smoothing: f32, // 0 = raw input, 0.9 = very smooth
}

// Width from pressure, with a small floor so light strokes stay visible.
brush_width :: proc(b: Brush, pressure: f32) -> f32 {
	if !b.pressure do return b.size
	p := clamp(pressure, 0, 1)
	return b.size * (0.08 + 0.92 * math.pow(p, 1.4))
}

// The layer new strokes go to, or the nil handle if drawing isn't possible now.
drawable_layer :: proc(app: ^App) -> pm.Layer_Handle {
	l := pm.layer(&app.doc, app.active_layer)
	if l == nil || l.kind != .Vector || l.locked do return {}
	if !effectively_visible(app, app.active_layer) do return {}
	if _, ok := pm.mat3_invert(pm.layer_world_matrix(&app.doc, app.active_layer)); !ok do return {}
	return app.active_layer
}

effectively_visible :: proc(app: ^App, h: pm.Layer_Handle) -> bool {
	current := h
	for current != {} {
		l := pm.layer(&app.doc, current)
		if l == nil || !l.visible do return false
		current = l.parent
	}
	return true
}

@(private = "file")
stroke_width :: proc(app: ^App, pressure: f32) -> f32 {
	return brush_width(app.brush, app.builder.pressure_seen ? pressure : 1)
}

@(private = "file")
append_point :: proc(b: ^Stroke_Builder, doc_pos: Vec2, width: f32) {
	p := pm.mat3_apply(b.to_layer, doc_pos)
	append(&b.knots, pm.Knot{p, p, p, width / b.scale})
}

// Returns false if there is no layer that can be drawn on.
stroke_begin :: proc(app: ^App, screen: Vec2, pressure: f32, from_pen: bool) -> bool {
	target := drawable_layer(app)
	if target == {} do return false

	b := &app.builder
	b.to_doc = pm.layer_world_matrix(&app.doc, target)
	b.to_layer, _ = pm.mat3_invert(b.to_doc)
	b.scale = pm.mat3_scale(b.to_doc)
	b.active = true
	b.from_pen = from_pen
	b.layer = target
	b.color = app.brush.color
	b.smoothed = pm.screen_to_world(app.cam, screen)
	b.last_kept = screen
	b.pressure_seen = !from_pen // a mouse has no pressure to wait for
	clear(&b.knots)
	append_point(b, b.smoothed, stroke_width(app, pressure))
	return true
}

stroke_add :: proc(app: ^App, screen: Vec2, pressure: f32) {
	b := &app.builder
	if !b.active do return
	MIN_SPACING_PX :: 1.5
	target := pm.screen_to_world(app.cam, screen)
	b.smoothed = linalg.lerp(target, b.smoothed, app.brush.smoothing)
	kept := pm.world_to_screen(app.cam, b.smoothed)
	if linalg.length(kept - b.last_kept) < MIN_SPACING_PX do return
	append_point(b, b.smoothed, stroke_width(app, pressure))
	b.last_kept = kept
}

// Moves the finished stroke into the document.
stroke_end :: proc(app: ^App) {
	b := &app.builder
	if !b.active do return
	b.active = false
	path := pm.Path{knots = b.knots, has_stroke = true, stroke = b.color}
	b.knots = nil
	pm.add_path(&app.history, &app.doc, b.layer, path)
}

stroke_cancel :: proc(app: ^App) {
	app.builder.active = false
	clear(&app.builder.knots)
}
