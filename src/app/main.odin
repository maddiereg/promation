package main

// Promation desktop front end: SDL3 + SDL_GPU + Dear ImGui (docking) on top
// of the shared core (../core) and the vector renderer (../render).

import "core:log"
import "core:math"
import "core:os"
import sdl "vendor:sdl3"

import im "third:odin-imgui"
import im_sdl "third:odin-imgui/backends/sdl3"
import im_gpu "third:odin-imgui/backends/sdlgpu3"

import pm "../core"
import "../render"

Pen_State :: struct {
	seen:        bool, // any pen event received this session
	in_range:    bool,
	down:        bool,
	eraser:      bool,
	pressure:    f32,
	tilt:        Vec2,
	events:      int,

	// Diagnostics for the stroke in progress (Phase 0 pressure investigation).
	stroke_pressure_events: int,
	stroke_pressure_min:    f32,
	stroke_pressure_max:    f32,
	stroke_start_pressure:  f32,
	stroke_which:           sdl.PenID,
	stroke_motion_events:   int,
	stroke_axis_events:     [sdl.PenAxis]int,
	stray_pressure_events:  int, // non-zero pressure seen with no active pen stroke
}

App :: struct {
	window:     ^sdl.Window,
	device:     ^sdl.GPUDevice,
	renderer:   render.Renderer,
	density:    f32, // pixels per window point
	size_px:    Vec2,

	doc:          pm.Document,
	history:      pm.History,
	active_layer: pm.Layer_Handle,
	file_path:    string, // empty until first saved

	cam:        pm.Camera,
	tool:       Tool,
	style:      Style,
	brush:      Brush,
	grid:       Grid,
	builder:    Stroke_Builder,
	pen_path:   Pen_Path,
	selection:  Selection,
	drag:       Drag,
	pointer:    Pointer,
	pen:        Pen_State,

	panning:    bool,
	space_held: bool,
	last_mouse: Vec2, // px
	hover_px:   Vec2, // last pointer position over the canvas

	show_imgui_demo:  bool,
	clear_color:      render.Color,
	running:          bool,
}

main :: proc() {
	context.logger = log.create_console_logger(.Info when ODIN_DEBUG else .Warning)

	app: App
	if !app_init(&app) do os.exit(1)
	defer app_shutdown(&app)

	for app.running {
		app_events(&app)
		app_frame(&app)
	}
}

app_init :: proc(app: ^App) -> bool {
	// Closing the window should send only WINDOW_CLOSE_REQUESTED, not a QUIT
	// as well; otherwise the unsaved-changes prompt appears twice.
	_ = sdl.SetHint(sdl.HINT_QUIT_ON_LAST_WINDOW_CLOSE, "0")
	if !sdl.Init({.VIDEO}) {
		log.errorf("SDL_Init: %s", sdl.GetError())
		return false
	}
	app.window = sdl.CreateWindow("Promation", 1600, 960, {.RESIZABLE, .HIGH_PIXEL_DENSITY})
	if app.window == nil {
		log.errorf("CreateWindow: %s", sdl.GetError())
		return false
	}
	app.device = sdl.CreateGPUDevice({.SPIRV}, ODIN_DEBUG, nil)
	if app.device == nil {
		log.errorf("CreateGPUDevice: %s", sdl.GetError())
		return false
	}
	if !sdl.ClaimWindowForGPUDevice(app.device, app.window) {
		log.errorf("ClaimWindowForGPUDevice: %s", sdl.GetError())
		return false
	}
	_ = sdl.SetGPUSwapchainParameters(app.device, app.window, .SDR, .VSYNC)

	swap_format := sdl.GetGPUSwapchainTextureFormat(app.device, app.window)
	if !render.init(&app.renderer, app.device, swap_format) do return false

	// Dear ImGui
	im.CHECKVERSION()
	im.CreateContext()
	io := im.GetIO()
	io.ConfigFlags += {.DockingEnable, .NavEnableKeyboard}
	content_scale := sdl.GetDisplayContentScale(sdl.GetPrimaryDisplay())
	if content_scale <= 0 do content_scale = 1
	im.StyleColorsDark()
	style := im.GetStyle()
	im.Style_ScaleAllSizes(style, content_scale)
	style.FontScaleDpi = content_scale

	im_sdl.InitForSDLGPU(app.window)
	init_info := im_gpu.InitInfo{
		Device            = app.device,
		ColorTargetFormat = swap_format,
		MSAASamples       = ._1,
	}
	im_gpu.Init(&init_info)

	app.tool = .Draw
	app.style = {fill_on = true, fill = {0.96, 0.62, 0.27, 1}, stroke_on = true, stroke = {0.1, 0.12, 0.2, 1}, width = 6}
	app.brush = {pressure = true, smoothing = 0.35, fit_curves = true, fit_px = 1}
	app.grid = {size = 40}
	app.clear_color = {0.16, 0.16, 0.18, 1}
	app.running = true
	update_window_metrics(app)
	project_io_init()
	reset_document(app)

	log.infof("gpu driver: %s, video driver: %s", sdl.GetGPUDeviceDriver(app.device), sdl.GetCurrentVideoDriver())
	return true
}

app_shutdown :: proc(app: ^App) {
	_ = sdl.WaitForGPUIdle(app.device)
	im_sdl.Shutdown()
	im_gpu.Shutdown()
	im.DestroyContext()
	delete(app.builder.knots)
	tools_destroy(app)
	delete(app.file_path)
	pm.history_destroy(&app.history)
	pm.document_destroy(&app.doc)
	render.destroy(&app.renderer)
	sdl.ReleaseWindowFromGPUDevice(app.device, app.window)
	sdl.DestroyGPUDevice(app.device)
	sdl.DestroyWindow(app.window)
	sdl.Quit()
}

update_window_metrics :: proc(app: ^App) {
	w, h: i32
	_ = sdl.GetWindowSizeInPixels(app.window, &w, &h)
	app.size_px = {f32(w), f32(h)}
	app.density = sdl.GetWindowPixelDensity(app.window)
	if app.density <= 0 do app.density = 1
}

// --- Input --------------------------------------------------------------------

// Records a pressure reading for the active pen stroke. PEN_DOWN arrives before
// the first pressure event, so points drawn before it are corrected here.
note_stroke_pressure :: proc(app: ^App, pressure: f32) {
	b := &app.builder
	if !b.pressure_seen {
		// Points so far used the full-width fallback; give them real pressure.
		b.pressure_seen = true
		for &k in b.knots do k.width = brush_width(app, pressure) / b.scale
	}
	app.pen.stroke_pressure_events += 1
	app.pen.stroke_pressure_min = min(app.pen.stroke_pressure_min, pressure)
	app.pen.stroke_pressure_max = max(app.pen.stroke_pressure_max, pressure)
}

app_events :: proc(app: ^App) {
	io := im.GetIO()
	e: sdl.Event
	for sdl.PollEvent(&e) {
		if project_io_handle_event(app, &e) do continue
		im_sdl.ProcessEvent(&e)

		#partial switch e.type {
		case .QUIT, .WINDOW_CLOSE_REQUESTED:
			request_quit(app)

		case .WINDOW_PIXEL_SIZE_CHANGED, .WINDOW_RESIZED, .WINDOW_DISPLAY_SCALE_CHANGED:
			update_window_metrics(app)

		// Pen: drawing uses pen events directly so we get pressure and tilt.
		case .PEN_PROXIMITY_IN:
			app.pen.seen, app.pen.in_range = true, true
		case .PEN_PROXIMITY_OUT:
			app.pen.in_range = false
		case .PEN_AXIS:
			app.pen.seen = true
			app.pen.events += 1
			if app.builder.active && app.builder.from_pen {
				app.pen.stroke_axis_events[e.paxis.axis] += 1
			} else if e.paxis.axis == .PRESSURE && e.paxis.value > 0 {
				app.pen.stray_pressure_events += 1
			}
			#partial switch e.paxis.axis {
			case .PRESSURE:
				app.pen.pressure = e.paxis.value
				if app.builder.active && app.builder.from_pen do note_stroke_pressure(app, e.paxis.value)
			case .XTILT:    app.pen.tilt.x = e.paxis.value
			case .YTILT:    app.pen.tilt.y = e.paxis.value
			}
			pen_pointer := app.pointer.down && app.pointer.from_pen
			if pen_pointer do pointer_move(app, Vec2{e.paxis.x, e.paxis.y} * app.density, app.pen.pressure)
		case .PEN_DOWN, .PEN_UP:
			app.pen.seen = true
			app.pen.events += 1
			app.pen.down = e.ptouch.down
			app.pen.eraser = e.ptouch.eraser
			p := Vec2{e.ptouch.x, e.ptouch.y} * app.density
			if e.ptouch.down {
				if io.WantCaptureMouse || app.pointer.down do break
				app.pen.stroke_pressure_events = 0
				app.pen.stroke_pressure_min = 1
				app.pen.stroke_pressure_max = 0
				app.pen.stroke_start_pressure = app.pen.pressure
				app.pen.stroke_which = e.ptouch.which
				app.pen.stroke_motion_events = 0
				app.pen.stroke_axis_events = {}
				pointer_down(app, p, app.pen.pressure, true, e.ptouch.eraser)
			} else if app.pointer.down && app.pointer.from_pen {
				if app.builder.active {
					log.infof("pen stroke: pen=%v points=%d motion=%d pressure_events=%d min=%.3f max=%.3f pressure_at_down=%.3f axes=%v stray_pressure=%d",
						app.pen.stroke_which, len(app.builder.knots), app.pen.stroke_motion_events,
						app.pen.stroke_pressure_events, app.pen.stroke_pressure_min, app.pen.stroke_pressure_max,
						app.pen.stroke_start_pressure, app.pen.stroke_axis_events, app.pen.stray_pressure_events)
				}
				app.pen.stray_pressure_events = 0
				pointer_up(app, p)
			}
		case .PEN_MOTION:
			app.pen.events += 1
			p := Vec2{e.pmotion.x, e.pmotion.y} * app.density
			if app.pointer.down && app.pointer.from_pen {
				app.pen.stroke_motion_events += 1
				pointer_move(app, p, app.pen.pressure)
			} else if !app.pointer.down {
				app.hover_px = p
			}

		// Mouse. Pen-synthesised mouse events (which == PEN_MOUSEID) only feed
		// ImGui and panning; the canvas handles the pen through the events above.
		case .MOUSE_BUTTON_DOWN:
			if e.button.which == sdl.PEN_MOUSEID || io.WantCaptureMouse || app.pointer.down do break
			p := Vec2{e.button.x, e.button.y} * app.density
			app.last_mouse = p
			if e.button.button == sdl.BUTTON_MIDDLE {
				app.panning = true
			} else if e.button.button == sdl.BUTTON_LEFT {
				pointer_down(app, p, 1, false, false)
			}
		case .MOUSE_BUTTON_UP:
			if e.button.which == sdl.PEN_MOUSEID do break
			p := Vec2{e.button.x, e.button.y} * app.density
			if e.button.button == sdl.BUTTON_MIDDLE do app.panning = false
			if e.button.button == sdl.BUTTON_LEFT && app.pointer.down && !app.pointer.from_pen do pointer_up(app, p)
		case .MOUSE_MOTION:
			p := Vec2{e.motion.x, e.motion.y} * app.density
			if app.panning do app.cam.pan += p - app.last_mouse // the pen pans through these too
			if e.motion.which != sdl.PEN_MOUSEID {
				if app.pointer.down && !app.pointer.from_pen {
					pointer_move(app, p, 1)
				} else if !app.pointer.down {
					app.hover_px = p
				}
			}
			app.last_mouse = p
		case .MOUSE_WHEEL:
			if io.WantCaptureMouse do break
			anchor := Vec2{e.wheel.mouse_x, e.wheel.mouse_y} * app.density
			if .LCTRL in sdl.GetModState() || .RCTRL in sdl.GetModState() {
				pm.camera_rotate_at(&app.cam, anchor, app.cam.rotation + e.wheel.y * math.to_radians(f32(5)))
			} else {
				pm.camera_zoom_at(&app.cam, anchor, math.pow(1.15, e.wheel.y))
			}

		case .KEY_DOWN:
			if e.key.key == sdl.K_SPACE do app.space_held = true
			// A focused panel doesn't block shortcuts; typing in a text field does
			// (it has its own Ctrl+Z).
			if io.WantTextInput do break
			ctrl := .LCTRL in e.key.mod || .RCTRL in e.key.mod
			shift := .LSHIFT in e.key.mod || .RSHIFT in e.key.mod
			switch {
			case tool_busy(app):               // no document changes mid-gesture
			case tool_key(app, e.key.key, ctrl, shift):
			case ctrl && shift && e.key.key == sdl.K_Z: pm.redo(&app.history, &app.doc)
			case ctrl && e.key.key == sdl.K_Z: pm.undo(&app.history, &app.doc)
			case ctrl && e.key.key == sdl.K_Y: pm.redo(&app.history, &app.doc)
			case ctrl && shift && e.key.key == sdl.K_S: action_save_as(app)
			case ctrl && e.key.key == sdl.K_S: action_save(app)
			case ctrl && e.key.key == sdl.K_O: action_open(app)
			case ctrl && e.key.key == sdl.K_N: action_new(app)
			case e.key.key == sdl.K_HOME:      fit_view(app)
			}
		case .KEY_UP:
			if e.key.key == sdl.K_SPACE {
				app.space_held = false
				app.panning = false
			}
		}
	}
}

// --- Frame --------------------------------------------------------------------

app_frame :: proc(app: ^App) {
	defer free_all(context.temp_allocator)
	ensure_active_layer(app)
	selection_prune(app)
	update_window_title(app)

	im_gpu.NewFrame()
	im_sdl.NewFrame()
	im.NewFrame()
	draw_ui(app)
	im.Render()
	draw_data := im.GetDrawData()

	draw_document(app)

	cmd := sdl.AcquireGPUCommandBuffer(app.device)
	swap: ^sdl.GPUTexture
	sw, sh: u32
	if !sdl.WaitAndAcquireGPUSwapchainTexture(cmd, app.window, &swap, &sw, &sh) || swap == nil {
		// Minimised or swapchain unavailable: nothing to draw this frame.
		_ = sdl.SubmitGPUCommandBuffer(cmd)
		return
	}

	r := &app.renderer
	render.upload(r, cmd)
	im_gpu.PrepareDrawData(draw_data, cmd)

	pass := render.begin_scene_pass(r, cmd, swap, sw, sh, app.clear_color)
	render.draw(r, cmd, pass)
	sdl.EndGPURenderPass(pass)

	ui_target := sdl.GPUColorTargetInfo{texture = swap, load_op = .LOAD, store_op = .STORE}
	ui_pass := sdl.BeginGPURenderPass(cmd, &ui_target, 1, nil)
	im_gpu.RenderDrawData(draw_data, cmd, ui_pass)
	sdl.EndGPURenderPass(ui_pass)

	_ = sdl.SubmitGPUCommandBuffer(cmd)
}

// Builds this frame's vector draw list from the evaluated document.
draw_document :: proc(app: ^App) {
	r := &app.renderer
	tolerance := 0.25 / app.cam.zoom // quarter-pixel flattening error
	render.begin_frame(r, render.view_matrix(app.size_px, app.cam.pan, app.cam.zoom, app.cam.rotation))

	s := app.doc.settings
	w, h := f32(s.width), f32(s.height)
	page := [4]pm.Knot{
		{{0, 0}, {0, 0}, {0, 0}, 0},
		{{w, 0}, {w, 0}, {w, 0}, 0},
		{{w, h}, {w, h}, {w, h}, 0},
		{{0, h}, {0, h}, {0, h}, 0},
	}
	render.fill_knots(r, page[:], s.background, tolerance)

	// The stroke being drawn is shown inside its layer, not on top of everything.
	for &p in pm.evaluate(&app.doc, tool_preview(app)) {
		if p.has_fill do render.fill_knots(r, p.knots, p.fill, tolerance)
		if p.has_stroke do render.stroke_knots(r, p.knots, p.closed, p.stroke, tolerance)
	}
}

// Keeps a valid selection after undo, delete or load.
ensure_active_layer :: proc(app: ^App) {
	if pm.layer_is_linked(&app.doc, app.active_layer) do return
	app.active_layer = len(app.doc.root) > 0 ? app.doc.root[len(app.doc.root) - 1] : {}
}

request_quit :: proc(app: ^App) {
	if confirm_discard(app) do app.running = false
}
