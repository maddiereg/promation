package render

// GPU vector renderer built on SDL_GPU.
//
// Technique: stencil-then-cover with MSAA.
//   fill:   triangle fans -> stencil (inc/dec wrap by facing = winding number),
//           then a cover quad drawn where stencil != 0, which also resets it.
//   stroke: expanded triangles -> stencil REPLACE 1, then the same cover.
// Each shape therefore touches every covered sample exactly once, so
// translucent fills/strokes blend correctly and MSAA gives anti-aliasing.
//
// Usage per frame:
//   begin_frame(r, world_to_clip)
//   fill_*/stroke_* ...
//   upload(r, cmd)                    // before any render pass
//   pass := begin_scene_pass(r, cmd, target, w, h, clear)
//   draw(r, cmd, pass); sdl.EndGPURenderPass(pass)

import "core:log"
import "core:math/linalg"
import sdl "vendor:sdl3"

VERT_SPV :: #load("../../build/shaders/vector.vert.spv")
FRAG_SPV :: #load("../../build/shaders/vector.frag.spv")

Draw_Kind :: enum u8 {
	Fill,
	Stroke,
}

Draw_Cmd :: struct {
	kind:         Draw_Kind,
	color:        Color,
	first_vertex: u32, // stencil geometry
	vertex_count: u32,
	cover_first:  u32, // 6 vertices, bounding quad
}

Stats :: struct {
	vertices:   int,
	draw_calls: int,
	shapes:     int,
}

Renderer :: struct {
	device:          ^sdl.GPUDevice,
	color_format:    sdl.GPUTextureFormat,
	ds_format:       sdl.GPUTextureFormat,
	samples:         sdl.GPUSampleCount,

	pipe_fill:       ^sdl.GPUGraphicsPipeline,
	pipe_stroke:     ^sdl.GPUGraphicsPipeline,
	pipe_cover:      ^sdl.GPUGraphicsPipeline,

	vbuf:            ^sdl.GPUBuffer,
	tbuf:            ^sdl.GPUTransferBuffer,
	vbuf_capacity:   u32, // bytes

	msaa_tex:        ^sdl.GPUTexture,
	ds_tex:          ^sdl.GPUTexture,
	target_w:        u32,
	target_h:        u32,

	world_to_clip:   matrix[4, 4]f32,
	verts:           [dynamic]Vec2,
	cmds:            [dynamic]Draw_Cmd,
	scratch_samples: [dynamic]Sample,
	stats:           Stats,
}

// Builds a world->clip matrix for a 2D camera.
// World is y-down (like screen space); SDL_GPU NDC is y-up.
view_matrix :: proc(viewport_px: Vec2, pan: Vec2, zoom: f32, rotation: f32) -> matrix[4, 4]f32 {
	// world -> screen pixels: rotate & scale about origin, then translate by pan.
	c := linalg.cos(rotation) * zoom
	s := linalg.sin(rotation) * zoom
	sx := 2 / viewport_px.x
	sy := -2 / viewport_px.y
	// screen px -> NDC: x' = x*sx - 1, y' = y*sy + 1
	return matrix[4, 4]f32{
		c * sx, -s * sx, 0, pan.x * sx - 1,
		s * sy,  c * sy, 0, pan.y * sy + 1,
		0,       0,      1, 0,
		0,       0,      0, 1,
	}
}

init :: proc(r: ^Renderer, device: ^sdl.GPUDevice, color_format: sdl.GPUTextureFormat) -> bool {
	r.device = device
	r.color_format = color_format

	r.samples = ._1
	for want in ([]sdl.GPUSampleCount{._8, ._4, ._2}) {
		if sdl.GPUTextureSupportsSampleCount(device, color_format, want) {
			r.samples = want
			break
		}
	}
	// Cap at 4x by default: good quality, lower bandwidth (tablets later).
	if r.samples == ._8 do r.samples = ._4

	r.ds_format = .INVALID
	for f in ([]sdl.GPUTextureFormat{.D24_UNORM_S8_UINT, .D32_FLOAT_S8_UINT}) {
		if sdl.GPUTextureSupportsFormat(device, f, .D2, {.DEPTH_STENCIL_TARGET}) {
			r.ds_format = f
			break
		}
	}
	if r.ds_format == .INVALID {
		log.error("render: no stencil format supported")
		return false
	}

	vs := sdl.CreateGPUShader(device, {
		code_size           = len(VERT_SPV),
		code                = raw_data(VERT_SPV),
		entrypoint          = "main",
		format              = {.SPIRV},
		stage               = .VERTEX,
		num_uniform_buffers = 1,
	})
	fs := sdl.CreateGPUShader(device, {
		code_size           = len(FRAG_SPV),
		code                = raw_data(FRAG_SPV),
		entrypoint          = "main",
		format              = {.SPIRV},
		stage               = .FRAGMENT,
		num_uniform_buffers = 1,
	})
	if vs == nil || fs == nil {
		log.errorf("render: shader creation failed: %s", sdl.GetError())
		return false
	}
	defer sdl.ReleaseGPUShader(device, vs)
	defer sdl.ReleaseGPUShader(device, fs)

	vb_desc := sdl.GPUVertexBufferDescription{slot = 0, pitch = size_of(Vec2), input_rate = .VERTEX}
	vb_attr := sdl.GPUVertexAttribute{location = 0, buffer_slot = 0, format = .FLOAT2, offset = 0}

	make_pipeline :: proc(
		r: ^Renderer, vs, fs: ^sdl.GPUShader,
		vb_desc: ^sdl.GPUVertexBufferDescription, vb_attr: ^sdl.GPUVertexAttribute,
		color_write: bool, front, back: sdl.GPUStencilOpState,
	) -> ^sdl.GPUGraphicsPipeline {
		blend := sdl.GPUColorTargetBlendState{
			src_color_blendfactor = .ONE,
			dst_color_blendfactor = .ONE_MINUS_SRC_ALPHA,
			color_blend_op        = .ADD,
			src_alpha_blendfactor = .ONE,
			dst_alpha_blendfactor = .ONE_MINUS_SRC_ALPHA,
			alpha_blend_op        = .ADD,
			enable_blend          = color_write,
			// Stencil-only passes write no colour.
			enable_color_write_mask = !color_write,
			color_write_mask        = {},
		}
		target := sdl.GPUColorTargetDescription{format = r.color_format, blend_state = blend}
		info := sdl.GPUGraphicsPipelineCreateInfo{
			vertex_shader   = vs,
			fragment_shader = fs,
			vertex_input_state = {
				vertex_buffer_descriptions = vb_desc,
				num_vertex_buffers         = 1,
				vertex_attributes          = vb_attr,
				num_vertex_attributes      = 1,
			},
			primitive_type    = .TRIANGLELIST,
			rasterizer_state  = {fill_mode = .FILL, cull_mode = .NONE, front_face = .COUNTER_CLOCKWISE},
			multisample_state = {sample_count = r.samples},
			depth_stencil_state = {
				enable_stencil_test = true,
				front_stencil_state = front,
				back_stencil_state  = back,
				compare_mask        = 0xFF,
				write_mask          = 0xFF,
			},
			target_info = {
				color_target_descriptions = &target,
				num_color_targets         = 1,
				depth_stencil_format      = r.ds_format,
				has_depth_stencil_target  = true,
			},
		}
		return sdl.CreateGPUGraphicsPipeline(r.device, info)
	}

	inc := sdl.GPUStencilOpState{fail_op = .KEEP, pass_op = .INCREMENT_AND_WRAP, depth_fail_op = .KEEP, compare_op = .ALWAYS}
	dec := sdl.GPUStencilOpState{fail_op = .KEEP, pass_op = .DECREMENT_AND_WRAP, depth_fail_op = .KEEP, compare_op = .ALWAYS}
	rep := sdl.GPUStencilOpState{fail_op = .KEEP, pass_op = .REPLACE,            depth_fail_op = .KEEP, compare_op = .ALWAYS}
	// Cover: draw where ref(0) != stencil, and zero it for the next shape.
	cov := sdl.GPUStencilOpState{fail_op = .KEEP, pass_op = .ZERO,               depth_fail_op = .KEEP, compare_op = .NOT_EQUAL}

	r.pipe_fill   = make_pipeline(r, vs, fs, &vb_desc, &vb_attr, false, inc, dec)
	r.pipe_stroke = make_pipeline(r, vs, fs, &vb_desc, &vb_attr, false, rep, rep)
	r.pipe_cover  = make_pipeline(r, vs, fs, &vb_desc, &vb_attr, true,  cov, cov)
	if r.pipe_fill == nil || r.pipe_stroke == nil || r.pipe_cover == nil {
		log.errorf("render: pipeline creation failed: %s", sdl.GetError())
		return false
	}

	log.infof("render: msaa=%v stencil=%v color=%v", r.samples, r.ds_format, r.color_format)
	return true
}

destroy :: proc(r: ^Renderer) {
	d := r.device
	if r.pipe_fill   != nil do sdl.ReleaseGPUGraphicsPipeline(d, r.pipe_fill)
	if r.pipe_stroke != nil do sdl.ReleaseGPUGraphicsPipeline(d, r.pipe_stroke)
	if r.pipe_cover  != nil do sdl.ReleaseGPUGraphicsPipeline(d, r.pipe_cover)
	if r.vbuf        != nil do sdl.ReleaseGPUBuffer(d, r.vbuf)
	if r.tbuf        != nil do sdl.ReleaseGPUTransferBuffer(d, r.tbuf)
	if r.msaa_tex    != nil do sdl.ReleaseGPUTexture(d, r.msaa_tex)
	if r.ds_tex      != nil do sdl.ReleaseGPUTexture(d, r.ds_tex)
	delete(r.verts)
	delete(r.cmds)
	delete(r.scratch_samples)
	r^ = {}
}

begin_frame :: proc(r: ^Renderer, world_to_clip: matrix[4, 4]f32) {
	r.world_to_clip = world_to_clip
	clear(&r.verts)
	clear(&r.cmds)
	r.stats = {}
}

// --- Shape submission -------------------------------------------------------

@(private)
push_cmd :: proc(r: ^Renderer, kind: Draw_Kind, color: Color, first: u32) {
	count := u32(len(r.verts)) - first
	if count == 0 do return
	b := bounds_of(r.verts[first:])
	cover_first := u32(len(r.verts))
	append(&r.verts,
		Vec2{b.min.x, b.min.y}, Vec2{b.max.x, b.min.y}, Vec2{b.max.x, b.max.y},
		Vec2{b.min.x, b.min.y}, Vec2{b.max.x, b.max.y}, Vec2{b.min.x, b.max.y})
	append(&r.cmds, Draw_Cmd{kind, color, first, count, cover_first})
	r.stats.shapes += 1
}

// Fills one or more already-flattened contours as a single shape (non-zero rule).
fill_contours :: proc(r: ^Renderer, contours: [][]Sample, color: Color) {
	first := u32(len(r.verts))
	for c in contours do fan_triangles(c, &r.verts)
	push_cmd(r, .Fill, color, first)
}

fill_knots :: proc(r: ^Renderer, knots: []Knot, color: Color, tolerance: f32) {
	clear(&r.scratch_samples)
	flatten_knots(knots, true, tolerance, &r.scratch_samples)
	contour := [][]Sample{r.scratch_samples[:]}
	fill_contours(r, contour, color)
}

stroke_samples :: proc(r: ^Renderer, samples: []Sample, closed: bool, color: Color, tolerance: f32) {
	first := u32(len(r.verts))
	stroke_triangles(samples, closed, tolerance, &r.verts)
	push_cmd(r, .Stroke, color, first)
}

stroke_knots :: proc(r: ^Renderer, knots: []Knot, closed: bool, color: Color, tolerance: f32) {
	clear(&r.scratch_samples)
	flatten_knots(knots, closed, tolerance, &r.scratch_samples)
	stroke_samples(r, r.scratch_samples[:], closed, color, tolerance)
}

// --- GPU submission ---------------------------------------------------------

// Copies this frame's vertices to the GPU. Call before beginning a render pass.
upload :: proc(r: ^Renderer, cmd: ^sdl.GPUCommandBuffer) {
	size := u32(len(r.verts) * size_of(Vec2))
	r.stats.vertices = len(r.verts)
	if size == 0 do return

	if size > r.vbuf_capacity {
		capacity := max(size, r.vbuf_capacity * 2, 64 * 1024)
		if r.vbuf != nil do sdl.ReleaseGPUBuffer(r.device, r.vbuf)
		if r.tbuf != nil do sdl.ReleaseGPUTransferBuffer(r.device, r.tbuf)
		r.vbuf = sdl.CreateGPUBuffer(r.device, {usage = {.VERTEX}, size = capacity})
		r.tbuf = sdl.CreateGPUTransferBuffer(r.device, {usage = .UPLOAD, size = capacity})
		r.vbuf_capacity = capacity
	}

	dst := sdl.MapGPUTransferBuffer(r.device, r.tbuf, true)
	copy(([^]Vec2)(dst)[:len(r.verts)], r.verts[:])
	sdl.UnmapGPUTransferBuffer(r.device, r.tbuf)

	pass := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUBuffer(pass, {transfer_buffer = r.tbuf}, {buffer = r.vbuf, size = size}, true)
	sdl.EndGPUCopyPass(pass)
}

// (Re)creates the MSAA colour and stencil targets for a given size.
ensure_targets :: proc(r: ^Renderer, w, h: u32) {
	if r.msaa_tex != nil && r.target_w == w && r.target_h == h do return
	if r.msaa_tex != nil do sdl.ReleaseGPUTexture(r.device, r.msaa_tex)
	if r.ds_tex   != nil do sdl.ReleaseGPUTexture(r.device, r.ds_tex)
	r.msaa_tex = nil
	if r.samples != ._1 {
		r.msaa_tex = sdl.CreateGPUTexture(r.device, {
			type = .D2, format = r.color_format, usage = {.COLOR_TARGET},
			width = w, height = h, layer_count_or_depth = 1, num_levels = 1,
			sample_count = r.samples,
		})
	}
	r.ds_tex = sdl.CreateGPUTexture(r.device, {
		type = .D2, format = r.ds_format, usage = {.DEPTH_STENCIL_TARGET},
		width = w, height = h, layer_count_or_depth = 1, num_levels = 1,
		sample_count = r.samples,
	})
	r.target_w, r.target_h = w, h
}

// Begins a render pass that draws into `target` (resolved from MSAA if enabled).
begin_scene_pass :: proc(
	r: ^Renderer, cmd: ^sdl.GPUCommandBuffer, target: ^sdl.GPUTexture, w, h: u32, clear_color: Color,
) -> ^sdl.GPURenderPass {
	ensure_targets(r, w, h)
	color := sdl.GPUColorTargetInfo{
		clear_color = {clear_color.r, clear_color.g, clear_color.b, clear_color.a},
		load_op     = .CLEAR,
	}
	if r.msaa_tex != nil {
		color.texture = r.msaa_tex
		color.store_op = .RESOLVE
		color.resolve_texture = target
		color.cycle = true
	} else {
		color.texture = target
		color.store_op = .STORE
	}
	ds := sdl.GPUDepthStencilTargetInfo{
		texture          = r.ds_tex,
		clear_depth      = 1,
		load_op          = .CLEAR,
		store_op         = .DONT_CARE,
		stencil_load_op  = .CLEAR,
		stencil_store_op = .DONT_CARE,
		cycle            = true,
		clear_stencil    = 0,
	}
	return sdl.BeginGPURenderPass(cmd, &color, 1, &ds)
}

draw :: proc(r: ^Renderer, cmd: ^sdl.GPUCommandBuffer, pass: ^sdl.GPURenderPass) {
	if len(r.cmds) == 0 do return
	binding := sdl.GPUBufferBinding{buffer = r.vbuf}
	sdl.BindGPUVertexBuffers(pass, 0, &binding, 1)
	m := r.world_to_clip
	sdl.PushGPUVertexUniformData(cmd, 0, &m, size_of(m))

	for &c in r.cmds {
		sdl.BindGPUGraphicsPipeline(pass, c.kind == .Fill ? r.pipe_fill : r.pipe_stroke)
		sdl.SetGPUStencilReference(pass, 1)
		sdl.DrawGPUPrimitives(pass, c.vertex_count, 1, c.first_vertex, 0)

		sdl.BindGPUGraphicsPipeline(pass, r.pipe_cover)
		sdl.SetGPUStencilReference(pass, 0)
		sdl.PushGPUFragmentUniformData(cmd, 0, &c.color, size_of(c.color))
		sdl.DrawGPUPrimitives(pass, 6, 1, c.cover_first, 0)
		r.stats.draw_calls += 2
	}
}
