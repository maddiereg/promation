package core

// Project file format: JSON, nested by layer so it contains no handles.
// Conversion only; reading and writing files is the front end's job, because
// Android storage works differently from desktop paths.

import "base:runtime"
import "core:encoding/json"
import "core:math"

PROJECT_FORMAT  :: "promation"
PROJECT_VERSION :: 1
PROJECT_MAX_LAYER_DEPTH :: 64

Load_Error :: enum {
	None,
	Malformed,      // not JSON, or the wrong shape
	Wrong_Format,   // JSON, but not a Promation project
	Newer_Version,  // written by a newer Promation
	Invalid_Value,  // out-of-range or non-finite data
	Too_Deep,       // layer nesting beyond PROJECT_MAX_LAYER_DEPTH
}

@(private) Knot_File :: [7]f32 // x, y, in x, in y, out x, out y, width

@(private)
Path_File :: struct {
	knots:      []Knot_File,
	closed:     bool,
	has_fill:   bool,
	has_stroke: bool,
	fill:       [4]f32,
	stroke:     [4]f32,
}

@(private)
Layer_File :: struct {
	name:     string,
	kind:     string,
	visible:  bool,
	locked:   bool,
	opacity:  f32,
	position: [2]f32,
	rotation: f32,
	scale:    [2]f32,
	origin:   [2]f32,
	children: []Layer_File,
	paths:    []Path_File,
}

@(private)
Project_File :: struct {
	format:      string,
	version:     int,
	width:       i32,
	height:      i32,
	fps:         i32,
	frame_count: i32,
	background:  [4]f32,
	layers:      []Layer_File,
}

@(private)
LAYER_KIND_NAMES := [Layer_Kind]string{
	.Group  = "group",
	.Vector = "vector",
}

// --- Save ---------------------------------------------------------------------

// Returns JSON allocated from `allocator`.
document_to_json :: proc(d: ^Document, allocator := context.allocator) -> (data: []u8, ok: bool) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	s := d.settings
	file := Project_File{
		format      = PROJECT_FORMAT,
		version     = PROJECT_VERSION,
		width       = s.width,
		height      = s.height,
		fps         = s.fps,
		frame_count = s.frame_count,
		background  = s.background,
		layers      = layers_to_file(d, d.root[:]),
	}
	bytes, err := json.marshal(file, allocator = allocator)
	return bytes, err == nil
}

@(private)
layers_to_file :: proc(d: ^Document, handles: []Layer_Handle) -> []Layer_File {
	out := make([]Layer_File, len(handles), context.temp_allocator)
	for h, i in handles {
		l := layer(d, h)
		t := l.transform
		paths := make([]Path_File, len(l.paths), context.temp_allocator)
		for ph, j in l.paths {
			p := path(d, ph)
			knots := make([]Knot_File, len(p.knots), context.temp_allocator)
			for k, n in p.knots {
				knots[n] = {k.pos.x, k.pos.y, k.handle_in.x, k.handle_in.y, k.handle_out.x, k.handle_out.y, k.width}
			}
			paths[j] = {knots, p.closed, p.has_fill, p.has_stroke, p.fill, p.stroke}
		}
		out[i] = {
			name     = name_string(&l.name),
			kind     = LAYER_KIND_NAMES[l.kind],
			visible  = l.visible,
			locked   = l.locked,
			opacity  = l.opacity,
			position = t.position,
			rotation = t.rotation,
			scale    = t.scale,
			origin   = t.origin,
			children = layers_to_file(d, l.children[:]),
			paths    = paths,
		}
	}
	return out
}

// --- Load ---------------------------------------------------------------------

// Fills `d`, which must not be initialised. On error `d` is left empty and
// needs no cleanup.
document_from_json :: proc(data: []u8, d: ^Document) -> Load_Error {
	d^ = {}
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file: Project_File
	if json.unmarshal(data, &file, allocator = context.temp_allocator) != nil do return .Malformed
	if file.format != PROJECT_FORMAT do return .Wrong_Format
	if file.version > PROJECT_VERSION do return .Newer_Version
	if file.version < 1 do return .Malformed

	settings := Doc_Settings{file.width, file.height, file.fps, file.frame_count, file.background}
	if !settings_are_valid(settings) do return .Invalid_Value

	document_init(d, settings)
	if err := layers_from_file(d, file.layers, {}, 1); err != .None {
		document_destroy(d)
		return err
	}
	return .None
}

settings_are_valid :: proc(settings: Doc_Settings) -> bool {
	s := settings
	return s.width >= 1 && s.width <= MAX_DOC_SIZE && s.height >= 1 && s.height <= MAX_DOC_SIZE &&
		s.fps >= 1 && s.fps <= MAX_FPS && s.frame_count >= 1 && s.frame_count <= MAX_FRAMES &&
		all_finite(s.background[:])
}

MAX_DOC_SIZE :: 16384
MAX_FPS      :: 240
MAX_FRAMES   :: 1_000_000

@(private)
all_finite :: proc(values: []f32) -> bool {
	for v in values {
		if math.is_nan(v) || math.is_inf(v) do return false
	}
	return true
}

@(private)
layers_from_file :: proc(d: ^Document, files: []Layer_File, parent: Layer_Handle, depth: int) -> Load_Error {
	if depth > PROJECT_MAX_LAYER_DEPTH do return .Too_Deep
	for &f in files {
		kind: Layer_Kind
		switch f.kind {
		case LAYER_KIND_NAMES[.Group]:  kind = .Group
		case LAYER_KIND_NAMES[.Vector]: kind = .Vector
		case: return .Invalid_Value
		}
		if kind == .Group && len(f.paths) > 0 do return .Invalid_Value
		if kind == .Vector && len(f.children) > 0 do return .Invalid_Value
		numbers := [?]f32{f.opacity, f.position.x, f.position.y, f.rotation, f.scale.x, f.scale.y, f.origin.x, f.origin.y}
		if !all_finite(numbers[:]) do return .Invalid_Value

		handle := Layer_Handle(pool_add(&d.layers, Layer{
			props = {
				name      = name_make(f.name),
				visible   = f.visible,
				locked    = f.locked,
				opacity   = clamp(f.opacity, 0, 1),
				transform = {f.position, f.rotation, f.scale, f.origin},
			},
			kind = kind,
			parent = parent,
		}))
		append(children_of(d, parent), handle)

		for &pf in f.paths {
			if !all_finite(pf.fill[:]) || !all_finite(pf.stroke[:]) do return .Invalid_Value
			p := Path{closed = pf.closed, has_fill = pf.has_fill, has_stroke = pf.has_stroke, fill = pf.fill, stroke = pf.stroke}
			for &k in pf.knots {
				if !all_finite(k[:]) {
					delete(p.knots)
					return .Invalid_Value
				}
				append(&p.knots, Knot{{k[0], k[1]}, {k[2], k[3]}, {k[4], k[5]}, k[6]})
			}
			ph := Path_Handle(pool_add(&d.paths, p))
			append(&layer(d, handle).paths, ph)
		}
		if err := layers_from_file(d, f.children, handle, depth + 1); err != .None do return err
	}
	return .None
}
