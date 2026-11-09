package main

// Phase 0 canvas: camera (pan/zoom/rotate) and freehand strokes with pen
// pressure. This is a test harness, not the final document model.

import "core:math"
import "core:math/linalg"

import "../render"

Vec2 :: render.Vec2

Camera :: struct {
	pan:      Vec2, // screen-pixel position of the world origin
	zoom:     f32,
	rotation: f32, // radians
}

world_to_screen :: proc(c: Camera, p: Vec2) -> Vec2 {
	cs, sn := math.cos(c.rotation), math.sin(c.rotation)
	return c.pan + c.zoom * Vec2{cs * p.x - sn * p.y, sn * p.x + cs * p.y}
}

screen_to_world :: proc(c: Camera, s: Vec2) -> Vec2 {
	d := (s - c.pan) / c.zoom
	cs, sn := math.cos(-c.rotation), math.sin(-c.rotation)
	return {cs * d.x - sn * d.y, sn * d.x + cs * d.y}
}

// Zooms by `factor`, keeping the world point under `anchor` (screen px) fixed.
camera_zoom_at :: proc(c: ^Camera, anchor: Vec2, factor: f32) {
	world := screen_to_world(c^, anchor)
	c.zoom = clamp(c.zoom * factor, 0.02, 64)
	c.pan += anchor - world_to_screen(c^, world)
}

// Rotates about `anchor` (screen px).
camera_rotate_at :: proc(c: ^Camera, anchor: Vec2, new_rotation: f32) {
	world := screen_to_world(c^, anchor)
	c.rotation = new_rotation
	c.pan += anchor - world_to_screen(c^, world)
}

// Frames the 960x540 page in a viewport of `size` pixels.
camera_fit_page :: proc(c: ^Camera, size: Vec2) {
	PAGE :: Vec2{960, 540}
	c.rotation = 0
	c.zoom = min(size.x / PAGE.x, size.y / PAGE.y) * 0.85
	c.pan = (size - PAGE * c.zoom) * 0.5
}

Stroke :: struct {
	samples: [dynamic]render.Sample, // world space
	color:   render.Color,
}

Stroke_Builder :: struct {
	active:    bool,
	from_pen:  bool,
	smoothed:  Vec2, // world space, exponentially smoothed input
	last_kept: Vec2, // screen space of the last stored sample
}

Brush :: struct {
	color:     render.Color,
	size:      f32, // max width in world units
	pressure:  bool,
	smoothing: f32, // 0 = raw input, 0.9 = very smooth
}

// Width from pressure, with a small floor so light strokes stay visible.
brush_width :: proc(b: Brush, pressure: f32) -> f32 {
	if !b.pressure do return b.size
	p := clamp(pressure, 0, 1)
	return b.size * (0.08 + 0.92 * math.pow(p, 1.4))
}

stroke_begin :: proc(app: ^App, screen: Vec2, pressure: f32, from_pen: bool) {
	w := screen_to_world(app.cam, screen)
	append(&app.strokes, Stroke{color = app.brush.color})
	s := &app.strokes[len(app.strokes) - 1]
	append(&s.samples, render.Sample{w, brush_width(app.brush, pressure)})
	app.builder = {active = true, from_pen = from_pen, smoothed = w, last_kept = screen}
}

stroke_add :: proc(app: ^App, screen: Vec2, pressure: f32) {
	b := &app.builder
	if !b.active do return
	MIN_SPACING_PX :: 1.5
	target := screen_to_world(app.cam, screen)
	b.smoothed = linalg.lerp(target, b.smoothed, app.brush.smoothing)
	if linalg.length(world_to_screen(app.cam, b.smoothed) - b.last_kept) < MIN_SPACING_PX do return
	s := &app.strokes[len(app.strokes) - 1]
	append(&s.samples, render.Sample{b.smoothed, brush_width(app.brush, pressure)})
	b.last_kept = world_to_screen(app.cam, b.smoothed)
}

stroke_end :: proc(app: ^App) {
	app.builder.active = false
}

strokes_undo :: proc(app: ^App) {
	if app.builder.active || len(app.strokes) == 0 do return
	s := pop(&app.strokes)
	delete(s.samples)
}

strokes_clear :: proc(app: ^App) {
	for s in app.strokes do delete(s.samples)
	clear(&app.strokes)
	app.builder.active = false
}
