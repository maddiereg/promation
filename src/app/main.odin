package main

// Promation, Phase 0: SDL3 + SDL_GPU + Dear ImGui (docking) + vector renderer
// + pen input. Goal: validate the stack before building the real editor.

import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import sdl "vendor:sdl3"

import im "third:odin-imgui"
import im_sdl "third:odin-imgui/backends/sdl3"
import im_gpu "third:odin-imgui/backends/sdlgpu3"

import "../render"

Tool :: enum {
	Draw,
	Pan,
}

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

	cam:        Camera,
	tool:       Tool,
	brush:      Brush,
	strokes:    [dynamic]Stroke,
	builder:    Stroke_Builder,
	pen:        Pen_State,

	panning:    bool,
	space_held: bool,
	last_mouse: Vec2, // px

	show_demo_scene:  bool,
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
	app.brush = {color = {0.1, 0.12, 0.2, 1}, size = 8, pressure = true, smoothing = 0.35}
	app.show_demo_scene = true
	app.clear_color = {0.16, 0.16, 0.18, 1}
	app.running = true
	update_window_metrics(app)
	camera_fit_page(&app.cam, app.size_px)

	log.infof("gpu driver: %s, video driver: %s", sdl.GetGPUDeviceDriver(app.device), sdl.GetCurrentVideoDriver())
	return true
}

app_shutdown :: proc(app: ^App) {
	_ = sdl.WaitForGPUIdle(app.device)
	im_sdl.Shutdown()
	im_gpu.Shutdown()
	im.DestroyContext()
	strokes_clear(app)
	delete(app.strokes)
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

// Records a pressure reading for the active pen stroke. PEN_DOWN can arrive
// before the first pressure event, so the first point's width is corrected here.
note_stroke_pressure :: proc(app: ^App, pressure: f32) {
	if app.pen.stroke_pressure_events == 0 {
		s := &app.strokes[len(app.strokes) - 1]
		s.samples[0].width = brush_width(app.brush, pressure)
	}
	app.pen.stroke_pressure_events += 1
	app.pen.stroke_pressure_min = min(app.pen.stroke_pressure_min, pressure)
	app.pen.stroke_pressure_max = max(app.pen.stroke_pressure_max, pressure)
}

app_events :: proc(app: ^App) {
	io := im.GetIO()
	e: sdl.Event
	for sdl.PollEvent(&e) {
		im_sdl.ProcessEvent(&e)

		#partial switch e.type {
		case .QUIT, .WINDOW_CLOSE_REQUESTED:
			app.running = false

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
			if app.builder.active && app.builder.from_pen {
				stroke_add(app, Vec2{e.paxis.x, e.paxis.y} * app.density, app.pen.pressure)
			}
		case .PEN_DOWN, .PEN_UP:
			app.pen.seen = true
			app.pen.events += 1
			app.pen.down = e.ptouch.down
			app.pen.eraser = e.ptouch.eraser
			p := Vec2{e.ptouch.x, e.ptouch.y} * app.density
			if e.ptouch.down {
				if !io.WantCaptureMouse && app.tool == .Draw && !app.space_held {
					stroke_begin(app, p, app.pen.pressure, true)
					app.pen.stroke_pressure_events = 0
					app.pen.stroke_pressure_min = 1
					app.pen.stroke_pressure_max = 0
					app.pen.stroke_start_pressure = app.pen.pressure
					app.pen.stroke_which = e.ptouch.which
					app.pen.stroke_motion_events = 0
					app.pen.stroke_axis_events = {}
				} else {
					log.infof("pen down ignored: ui_capture=%v tool=%v space=%v", io.WantCaptureMouse, app.tool, app.space_held)
				}
			} else if app.builder.active && app.builder.from_pen {
				stroke_end(app)
				log.infof("pen stroke: pen=%v eraser=%v points=%d motion=%d pressure_events=%d min=%.3f max=%.3f pressure_at_down=%.3f axes=%v stray_pressure=%d",
					app.pen.stroke_which, app.pen.eraser,
					len(app.strokes[len(app.strokes) - 1].samples), app.pen.stroke_motion_events,
					app.pen.stroke_pressure_events, app.pen.stroke_pressure_min, app.pen.stroke_pressure_max,
					app.pen.stroke_start_pressure, app.pen.stroke_axis_events, app.pen.stray_pressure_events)
				app.pen.stray_pressure_events = 0
			}
		case .PEN_MOTION:
			app.pen.events += 1
			if app.builder.active && app.builder.from_pen {
				app.pen.stroke_motion_events += 1
				stroke_add(app, Vec2{e.pmotion.x, e.pmotion.y} * app.density, app.pen.pressure)
			}

		// Mouse. Pen-synthesised mouse events (which == PEN_MOUSEID) only feed
		// ImGui; the canvas handles the pen through the events above.
		case .MOUSE_BUTTON_DOWN:
			if e.button.which == sdl.PEN_MOUSEID || io.WantCaptureMouse do break
			p := Vec2{e.button.x, e.button.y} * app.density
			app.last_mouse = p
			if e.button.button == sdl.BUTTON_MIDDLE || (e.button.button == sdl.BUTTON_LEFT && (app.tool == .Pan || app.space_held)) {
				app.panning = true
			} else if e.button.button == sdl.BUTTON_LEFT && app.tool == .Draw {
				stroke_begin(app, p, 1, false)
				log.infof("non-pen stroke (constant width): source=%s", e.button.which == sdl.TOUCH_MOUSEID ? "touch" : "mouse")
			}
		case .MOUSE_BUTTON_UP:
			if e.button.which == sdl.PEN_MOUSEID do break
			app.panning = false
			if app.builder.active && !app.builder.from_pen do stroke_end(app)
		case .MOUSE_MOTION:
			p := Vec2{e.motion.x, e.motion.y} * app.density
			if e.motion.which != sdl.PEN_MOUSEID {
				if app.panning do app.cam.pan += p - app.last_mouse
				if app.builder.active && !app.builder.from_pen do stroke_add(app, p, 1)
			} else if app.panning {
				app.cam.pan += p - app.last_mouse // pen + space pans too
			}
			app.last_mouse = p
		case .MOUSE_WHEEL:
			if io.WantCaptureMouse do break
			anchor := Vec2{e.wheel.mouse_x, e.wheel.mouse_y} * app.density
			if .LCTRL in sdl.GetModState() || .RCTRL in sdl.GetModState() {
				camera_rotate_at(&app.cam, anchor, app.cam.rotation + e.wheel.y * math.to_radians(f32(5)))
			} else {
				camera_zoom_at(&app.cam, anchor, math.pow(1.15, e.wheel.y))
			}

		case .KEY_DOWN:
			if e.key.key == sdl.K_SPACE do app.space_held = true
			if io.WantCaptureKeyboard do break
			ctrl := .LCTRL in e.key.mod || .RCTRL in e.key.mod
			switch {
			case ctrl && e.key.key == sdl.K_Z: strokes_undo(app)
			case e.key.key == sdl.K_HOME:      camera_fit_page(&app.cam, app.size_px)
			case e.key.key == sdl.K_B:         app.tool = .Draw
			case e.key.key == sdl.K_H:         app.tool = .Pan
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
	im_gpu.NewFrame()
	im_sdl.NewFrame()
	im.NewFrame()
	draw_ui(app)
	im.Render()
	draw_data := im.GetDrawData()

	// Scene
	r := &app.renderer
	tolerance := 0.25 / app.cam.zoom // quarter-pixel flattening error
	render.begin_frame(r, render.view_matrix(app.size_px, app.cam.pan, app.cam.zoom, app.cam.rotation))
	if app.show_demo_scene do render.demo_scene(r, tolerance)
	for &s in app.strokes {
		render.stroke_samples(r, s.samples[:], false, s.color, tolerance)
	}

	cmd := sdl.AcquireGPUCommandBuffer(app.device)
	swap: ^sdl.GPUTexture
	sw, sh: u32
	if !sdl.WaitAndAcquireGPUSwapchainTexture(cmd, app.window, &swap, &sw, &sh) || swap == nil {
		// Minimised or swapchain unavailable: nothing to draw this frame.
		_ = sdl.SubmitGPUCommandBuffer(cmd)
		return
	}

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

draw_ui :: proc(app: ^App) {
	im.DockSpaceOverViewport(0, nil, {.PassthruCentralNode})
	io := im.GetIO()

	im.SetNextWindowPos({20, 40}, .FirstUseEver)
	if im.Begin("Tools") {
		if im.RadioButton("Draw (B)", app.tool == .Draw) do app.tool = .Draw
		im.SameLine()
		if im.RadioButton("Pan (H)", app.tool == .Pan) do app.tool = .Pan
		im.SeparatorText("Brush")
		im.ColorEdit4("Colour", &app.brush.color)
		im.SliderFloat("Size", &app.brush.size, 0.5, 64, "%.1f")
		im.Checkbox("Pressure", &app.brush.pressure)
		im.SliderFloat("Smoothing", &app.brush.smoothing, 0, 0.9, "%.2f")
		im.SeparatorText("Strokes")
		im.Text("%d strokes", i32(len(app.strokes)))
		if im.Button("Undo (Ctrl+Z)") do strokes_undo(app)
		im.SameLine()
		if im.Button("Clear") do strokes_clear(app)
		im.Checkbox("Show test scene", &app.show_demo_scene)
	}
	im.End()

	im.SetNextWindowPos({20, 420}, .FirstUseEver)
	if im.Begin("View") {
		zoom := app.cam.zoom * 100
		center := app.size_px * 0.5
		if im.SliderFloat("Zoom %", &zoom, 2, 6400, "%.0f", {.Logarithmic}) {
			camera_zoom_at(&app.cam, center, zoom / 100 / app.cam.zoom)
		}
		rot := app.cam.rotation
		if im.SliderAngle("Rotation", &rot, -180, 180) do camera_rotate_at(&app.cam, center, rot)
		if im.Button("Fit page (Home)") do camera_fit_page(&app.cam, app.size_px)
		im.TextDisabled("Wheel: zoom   Ctrl+wheel: rotate")
		im.TextDisabled("Middle drag / Space+drag: pan")
	}
	im.End()

	im.SetNextWindowPos({20, 600}, .FirstUseEver)
	if im.Begin("Pen") {
		p := app.pen
		if !p.seen {
			im.TextWrapped("No pen events yet. Bring a stylus near the tablet.")
		} else {
			im.Text("In range: %s   Down: %s   Eraser: %s",
				p.in_range ? cstring("yes") : "no", p.down ? cstring("yes") : "no", p.eraser ? cstring("yes") : "no")
			im.ProgressBar(p.pressure, {-1, 0}, fmt.ctprintf("pressure %.3f", p.pressure))
			im.Text("Tilt: %.1f, %.1f", p.tilt.x, p.tilt.y)
			im.Text("Events: %d", i32(p.events))
		}
	}
	im.End()

	im.SetNextWindowPos({1250, 40}, .FirstUseEver)
	if im.Begin("Renderer") {
		st := app.renderer.stats
		im.Text("Driver: %s", sdl.GetGPUDeviceDriver(app.device))
		im.Text("MSAA: %s   Stencil: %s", fmt.ctprint(app.renderer.samples), fmt.ctprint(app.renderer.ds_format))
		im.Text("%.1f fps (%.2f ms)", io.Framerate, 1000 / max(io.Framerate, 0.001))
		im.Text("Shapes: %d   Vertices: %d   Draws: %d", i32(st.shapes), i32(st.vertices), i32(st.draw_calls))
		im.Text("Viewport: %.0fx%.0f px @ %.2fx", app.size_px.x, app.size_px.y, app.density)
		im.Checkbox("ImGui demo window", &app.show_imgui_demo)
	}
	im.End()

	if app.show_imgui_demo do im.ShowDemoWindow(&app.show_imgui_demo)
}
