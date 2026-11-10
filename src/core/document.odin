package core

// The document model. No UI, GPU or platform dependencies, so it can be tested
// headless and shared with the Android front end.
//
// All edits that should be undoable go through the operations in history.odin.

import "core:math"
import "core:strings"

Vec2  :: [2]f32
Color :: [4]f32 // straight RGBA, 0..1
Mat3  :: matrix[3, 3]f32

MAT3_IDENTITY :: Mat3{
	1, 0, 0,
	0, 1, 0,
	0, 0, 1,
}

// A cubic Bézier knot: position, handles (absolute positions) and stroke width.
// A corner has its handles equal to its position.
Knot :: struct {
	pos:        Vec2,
	handle_in:  Vec2,
	handle_out: Vec2,
	width:      f32,
}

Layer_Handle :: distinct Handle
Path_Handle  :: distinct Handle

Path :: struct {
	knots:      [dynamic]Knot,
	closed:     bool,
	has_fill:   bool,
	has_stroke: bool,
	fill:       Color,
	stroke:     Color,
}

Layer_Kind :: enum u8 {
	Group,
	Vector,
}

NAME_CAPACITY :: 64

// Fixed-size, NUL-terminated, so props can be copied and compared by value and
// edited in place by a text widget.
Name :: struct {
	buf: [NAME_CAPACITY]u8,
}

Transform :: struct {
	position: Vec2,
	rotation: f32, // radians
	scale:    Vec2,
	origin:   Vec2, // pivot, in layer space
}

TRANSFORM_IDENTITY :: Transform{scale = {1, 1}}

// The plain-value part of a layer: everything one undo step can swap wholesale.
Layer_Props :: struct {
	name:      Name,
	visible:   bool,
	locked:    bool,
	opacity:   f32,
	transform: Transform,
}

Layer :: struct {
	using props: Layer_Props,
	kind:        Layer_Kind,
	parent:      Layer_Handle, // nil handle = top level
	children:    [dynamic]Layer_Handle, // bottom to top, groups only
	paths:       [dynamic]Path_Handle, // bottom to top, vector layers only
}

Doc_Settings :: struct {
	width:       i32,
	height:      i32,
	fps:         i32,
	frame_count: i32,
	background:  Color,
}

DEFAULT_SETTINGS :: Doc_Settings{
	width       = 1920,
	height      = 1080,
	fps         = 24,
	frame_count = 240,
	background  = {0.98, 0.97, 0.94, 1},
}

Document :: struct {
	settings: Doc_Settings,
	layers:   Pool(Layer),
	paths:    Pool(Path),
	root:     [dynamic]Layer_Handle, // bottom to top
}

document_init :: proc(d: ^Document, settings := DEFAULT_SETTINGS) {
	d^ = {}
	d.settings = settings
}

// Frees every object, including those only reachable from undo history.
document_destroy :: proc(d: ^Document) {
	for &s in d.layers.slots {
		if s.alive {
			delete(s.value.children)
			delete(s.value.paths)
		}
	}
	for &s in d.paths.slots {
		if s.alive do delete(s.value.knots)
	}
	pool_destroy(&d.layers)
	pool_destroy(&d.paths)
	delete(d.root)
	d^ = {}
}

layer :: proc(d: ^Document, h: Layer_Handle) -> ^Layer {
	return pool_get(&d.layers, Handle(h))
}

path :: proc(d: ^Document, h: Path_Handle) -> ^Path {
	return pool_get(&d.paths, Handle(h))
}

// The ordered sibling list a layer with this parent lives in; nil if the parent is gone.
children_of :: proc(d: ^Document, parent: Layer_Handle) -> ^[dynamic]Layer_Handle {
	if parent == {} do return &d.root
	l := layer(d, parent)
	return l != nil ? &l.children : nil
}

index_of_layer :: proc(list: []Layer_Handle, h: Layer_Handle) -> int {
	for x, i in list do if x == h do return i
	return -1
}

// True only if the layer is part of the visible tree. A layer that was deleted
// stays alive in the pool for undo, but is unlinked from its parent.
layer_is_linked :: proc(d: ^Document, h: Layer_Handle) -> bool {
	current := h
	for {
		l := layer(d, current)
		if l == nil do return false
		siblings := children_of(d, l.parent)
		if siblings == nil || index_of_layer(siblings[:], current) < 0 do return false
		if l.parent == {} do return true
		current = l.parent
	}
}

// True if `h` is `ancestor` or lies inside it.
layer_is_within :: proc(d: ^Document, h, ancestor: Layer_Handle) -> bool {
	current := h
	for current != {} {
		if current == ancestor do return true
		l := layer(d, current)
		if l == nil do return false
		current = l.parent
	}
	return false
}

name_make :: proc(s: string) -> (n: Name) {
	// Cut on a UTF-8 boundary so a truncated name stays valid text.
	end := min(len(s), NAME_CAPACITY - 1)
	for end > 0 && end < len(s) && s[end] & 0xC0 == 0x80 do end -= 1
	copy(n.buf[:end], s[:end])
	return
}

name_string :: proc(n: ^Name) -> string {
	return strings.truncate_to_byte(string(n.buf[:]), 0)
}

name_cstring :: proc(n: ^Name) -> cstring {
	return cstring(&n.buf[0])
}

// --- Transforms ---------------------------------------------------------------

transform_matrix :: proc(t: Transform) -> Mat3 {
	c, s := math.cos(t.rotation), math.sin(t.rotation)
	a, b := c * t.scale.x, -s * t.scale.y
	e, f := s * t.scale.x, c * t.scale.y
	return Mat3{
		a, b, t.position.x - (a * t.origin.x + b * t.origin.y),
		e, f, t.position.y - (e * t.origin.x + f * t.origin.y),
		0, 0, 1,
	}
}

mat3_apply :: proc(m: Mat3, p: Vec2) -> Vec2 {
	r := m * [3]f32{p.x, p.y, 1}
	return r.xy
}

// Uniform scale factor of a matrix: how much it grows a stroke's width.
mat3_scale :: proc(m: Mat3) -> f32 {
	return math.sqrt(abs(m[0, 0] * m[1, 1] - m[0, 1] * m[1, 0]))
}

mat3_invert :: proc(m: Mat3) -> (inverse: Mat3, ok: bool) {
	det := m[0, 0] * m[1, 1] - m[0, 1] * m[1, 0]
	if abs(det) < 1e-9 do return MAT3_IDENTITY, false
	id := 1 / det
	a, b := m[1, 1] * id, -m[0, 1] * id
	e, f := -m[1, 0] * id, m[0, 0] * id
	inverse = Mat3{
		a, b, -(a * m[0, 2] + b * m[1, 2]),
		e, f, -(e * m[0, 2] + f * m[1, 2]),
		0, 0, 1,
	}
	return inverse, true
}

// Layer space -> document space.
layer_world_matrix :: proc(d: ^Document, h: Layer_Handle) -> Mat3 {
	l := layer(d, h)
	if l == nil do return MAT3_IDENTITY
	local := transform_matrix(l.transform)
	if l.parent == {} do return local
	return layer_world_matrix(d, l.parent) * local
}
