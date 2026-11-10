package core

import "core:math"

// 2D view: document space -> screen pixels.
Camera :: struct {
	pan:      Vec2, // screen-pixel position of the document origin
	zoom:     f32,
	rotation: f32, // radians
}

CAMERA_MIN_ZOOM :: 0.02
CAMERA_MAX_ZOOM :: 64

world_to_screen :: proc(c: Camera, p: Vec2) -> Vec2 {
	cs, sn := math.cos(c.rotation), math.sin(c.rotation)
	return c.pan + c.zoom * Vec2{cs * p.x - sn * p.y, sn * p.x + cs * p.y}
}

screen_to_world :: proc(c: Camera, s: Vec2) -> Vec2 {
	d := (s - c.pan) / c.zoom
	cs, sn := math.cos(-c.rotation), math.sin(-c.rotation)
	return {cs * d.x - sn * d.y, sn * d.x + cs * d.y}
}

// Zooms by `factor`, keeping the point under `anchor` (screen px) fixed.
camera_zoom_at :: proc(c: ^Camera, anchor: Vec2, factor: f32) {
	world := screen_to_world(c^, anchor)
	c.zoom = clamp(c.zoom * factor, CAMERA_MIN_ZOOM, CAMERA_MAX_ZOOM)
	c.pan += anchor - world_to_screen(c^, world)
}

camera_rotate_at :: proc(c: ^Camera, anchor: Vec2, rotation: f32) {
	world := screen_to_world(c^, anchor)
	c.rotation = rotation
	c.pan += anchor - world_to_screen(c^, world)
}

// Centres a page of `page` units in a viewport of `viewport` pixels.
camera_fit :: proc(c: ^Camera, viewport, page: Vec2) {
	c.rotation = 0
	c.zoom = clamp(min(viewport.x / page.x, viewport.y / page.y) * 0.85, CAMERA_MIN_ZOOM, CAMERA_MAX_ZOOM)
	c.pan = (viewport - page * c.zoom) * 0.5
}
