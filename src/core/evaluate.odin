package core

// evaluate: document -> posed scene, as a pure function. Phase 3 adds a time
// argument and channel sampling; bones (Phase 4) add a deformation step.

Posed_Path :: struct {
	knots:      []Knot, // document space
	closed:     bool,
	has_fill:   bool,
	has_stroke: bool,
	fill:       Color,
	stroke:     Color,
}

// A path not yet in the document (e.g. a stroke being drawn), shown on top of
// its layer's paths so it is stacked and faded exactly as it will be once added.
Preview :: struct {
	layer: Layer_Handle,
	path:  Path, // layer space; borrowed, not freed
}

// Returns visible paths bottom to top. Everything is allocated from `allocator`.
evaluate :: proc(d: ^Document, preview: Preview = {}, allocator := context.temp_allocator) -> []Posed_Path {
	out := make([dynamic]Posed_Path, allocator)
	preview := preview
	for h in d.root do evaluate_layer(d, h, MAT3_IDENTITY, 1, &preview, &out, allocator)
	return out[:]
}

pose_knots :: proc(knots: []Knot, m: Mat3, allocator := context.temp_allocator) -> []Knot {
	out := make([]Knot, len(knots), allocator)
	scale := mat3_scale(m)
	for k, i in knots {
		out[i] = {
			pos        = mat3_apply(m, k.pos),
			handle_in  = mat3_apply(m, k.handle_in),
			handle_out = mat3_apply(m, k.handle_out),
			width      = k.width * scale,
		}
	}
	return out
}

@(private)
evaluate_layer :: proc(
	d: ^Document, h: Layer_Handle, parent_matrix: Mat3, parent_opacity: f32,
	preview: ^Preview, out: ^[dynamic]Posed_Path, allocator := context.temp_allocator,
) {
	l := layer(d, h)
	if l == nil || !l.visible do return
	world := parent_matrix * transform_matrix(l.transform)
	opacity := parent_opacity * l.opacity

	switch l.kind {
	case .Group:
		// Group opacity multiplies into each child for now, so overlapping
		// children show through each other.
		for child in l.children do evaluate_layer(d, child, world, opacity, preview, out, allocator)
	case .Vector:
		for ph in l.paths {
			p := path(d, ph)
			if p != nil do append(out, pose_path(p, world, opacity, allocator))
		}
		if preview.layer == h && len(preview.path.knots) > 0 {
			append(out, pose_path(&preview.path, world, opacity, allocator))
		}
	}
}

@(private)
pose_path :: proc(p: ^Path, world: Mat3, opacity: f32, allocator := context.temp_allocator) -> Posed_Path {
	fill, stroke := p.fill, p.stroke
	fill.a *= opacity
	stroke.a *= opacity
	return {
		knots      = pose_knots(p.knots[:], world, allocator),
		closed     = p.closed,
		has_fill   = p.has_fill,
		has_stroke = p.has_stroke,
		fill       = fill,
		stroke     = stroke,
	}
}
