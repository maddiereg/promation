package main

// Editor panels (Dear ImGui). Panels edit a local copy of a value and commit it
// through the undo history; a drag becomes one undo step via its merge key.

import "core:fmt"
import "core:math"
import sdl "vendor:sdl3"

import im "third:odin-imgui"

import pm "../core"

draw_ui :: proc(app: ^App) {
	draw_menu_bar(app)
	im.DockSpaceOverViewport(0, nil, {.PassthruCentralNode})
	draw_tools_panel(app)
	draw_layers_panel(app)
	draw_properties_panel(app)
	draw_document_panel(app)
	draw_view_panel(app)
	draw_diagnostics_panels(app)
	if app.show_imgui_demo do im.ShowDemoWindow(&app.show_imgui_demo)
}

@(private = "file")
draw_menu_bar :: proc(app: ^App) {
	if !im.BeginMainMenuBar() do return
	defer im.EndMainMenuBar()
	if im.BeginMenu("File") {
		if im.MenuItem("New", "Ctrl+N") do action_new(app)
		if im.MenuItem("Open...", "Ctrl+O") do action_open(app)
		im.Separator()
		if im.MenuItem("Save", "Ctrl+S") do action_save(app)
		if im.MenuItem("Save As...", "Ctrl+Shift+S") do action_save_as(app)
		im.Separator()
		if im.MenuItem("Quit") do request_quit(app)
		im.EndMenu()
	}
	if im.BeginMenu("Edit") {
		if im.MenuItem("Undo", "Ctrl+Z", false, pm.can_undo(&app.history)) do pm.undo(&app.history, &app.doc)
		if im.MenuItem("Redo", "Ctrl+Y", false, pm.can_redo(&app.history)) do pm.redo(&app.history, &app.doc)
		im.EndMenu()
	}
}

@(private = "file")
draw_tools_panel :: proc(app: ^App) {
	im.SetNextWindowPos({20, 50}, .FirstUseEver)
	defer im.End()
	if !im.Begin("Tools") do return
	if im.RadioButton("Draw (B)", app.tool == .Draw) do app.tool = .Draw
	im.SameLine()
	if im.RadioButton("Pan (H)", app.tool == .Pan) do app.tool = .Pan
	im.SeparatorText("Brush")
	im.ColorEdit4("Colour", &app.brush.color)
	im.SliderFloat("Size", &app.brush.size, 0.5, 200, "%.1f", {.Logarithmic})
	im.Checkbox("Pressure", &app.brush.pressure)
	im.SliderFloat("Smoothing", &app.brush.smoothing, 0, 0.9, "%.2f")
	if drawable_layer(app) == {} {
		im.TextWrapped("Select a visible, unlocked vector layer to draw.")
	}
}

@(private = "file")
draw_layer_rows :: proc(app: ^App, list: []pm.Layer_Handle, depth: f32) {
	#reverse for h in list { // top of the stack first
		l := pm.layer(&app.doc, h)
		if l == nil do continue
		im.PushIDInt(i32(h.index))
		defer im.PopID()

		// Read before any edit below can move the layer in memory.
		props := l.props
		kind := l.kind
		children := l.children[:]

		visible, locked := props.visible, props.locked
		if im.Checkbox("##visible", &visible) {
			props.visible = visible
			pm.set_layer_props(&app.history, &app.doc, h, props)
		}
		im.SameLine()
		if im.Checkbox("##locked", &locked) {
			props.locked = locked
			pm.set_layer_props(&app.history, &app.doc, h, props)
		}
		im.SameLine(0, depth * 16 + 8)
		label := pm.name_string(&props.name)
		if label == "" do label = "(unnamed)"
		if im.Selectable(ctprint_layer_label(kind, label), app.active_layer == h) do app.active_layer = h

		if kind == .Group do draw_layer_rows(app, children, depth + 1)
	}
}

@(private = "file")
ctprint_layer_label :: proc(kind: pm.Layer_Kind, name: string) -> cstring {
	return kind == .Group ? fmt.ctprintf("[%s]", name) : fmt.ctprintf("%s", name)
}

@(private = "file")
draw_layers_panel :: proc(app: ^App) {
	im.SetNextWindowPos({20, 340}, .FirstUseEver)
	im.SetNextWindowSize({300, 300}, .FirstUseEver)
	defer im.End()
	if !im.Begin("Layers") do return

	if im.Button("+ Vector") do add_layer_near_active(app, .Vector)
	im.SameLine()
	if im.Button("+ Group") do add_layer_near_active(app, .Group)
	im.SameLine()
	if im.Button("Delete") do pm.remove_layer(&app.history, &app.doc, app.active_layer)

	active := app.active_layer
	if l := pm.layer(&app.doc, active); l != nil {
		parent := l.parent
		siblings := pm.children_of(&app.doc, parent)
		index := pm.index_of_layer(siblings[:], active)
		if im.Button("Up") do pm.move_layer(&app.history, &app.doc, active, parent, index + 1)
		im.SameLine()
		if im.Button("Down") do pm.move_layer(&app.history, &app.doc, active, parent, index - 1 < 0 ? index : index - 1)
		im.SameLine()
		if im.Button("Into group") do move_into_group_below(app, active, parent, index)
		im.SameLine()
		if im.Button("Out of group") && parent != {} {
			grandparent := pm.layer(&app.doc, parent).parent
			parent_index := pm.index_of_layer(pm.children_of(&app.doc, grandparent)[:], parent)
			pm.move_layer(&app.history, &app.doc, active, grandparent, parent_index + 1)
		}
	}
	im.Separator()
	im.TextDisabled("Show / Lock / Name")
	draw_layer_rows(app, app.doc.root[:], 0)
}

@(private = "file")
add_layer_near_active :: proc(app: ^App, kind: pm.Layer_Kind) {
	name := kind == .Group ? "Group" : "Layer"
	created: pm.Layer_Handle
	l := pm.layer(&app.doc, app.active_layer)
	switch {
	case l == nil:
		created = pm.add_layer(&app.history, &app.doc, kind, name)
	case l.kind == .Group:
		created = pm.add_layer(&app.history, &app.doc, kind, name, app.active_layer)
	case:
		parent := l.parent
		index := pm.index_of_layer(pm.children_of(&app.doc, parent)[:], app.active_layer)
		created = pm.add_layer(&app.history, &app.doc, kind, name, parent, index + 1)
	}
	if created != {} do app.active_layer = created
}

// Puts the layer on top of the group directly beneath it in the stack, if any.
@(private = "file")
move_into_group_below :: proc(app: ^App, active, parent: pm.Layer_Handle, index: int) {
	if index <= 0 do return
	below := pm.children_of(&app.doc, parent)[index - 1]
	group := pm.layer(&app.doc, below)
	if group == nil || group.kind != .Group do return
	pm.move_layer(&app.history, &app.doc, active, below, len(group.children))
}

@(private = "file")
draw_properties_panel :: proc(app: ^App) {
	im.SetNextWindowPos({340, 340}, .FirstUseEver)
	defer im.End()
	if !im.Begin("Layer properties") do return
	h := app.active_layer
	l := pm.layer(&app.doc, h)
	if l == nil {
		im.TextDisabled("No layer selected.")
		return
	}

	props := l.props
	field: u64 // 1-based id of the widget edited this frame
	sealed := false
	check :: proc(changed: bool, id: u64, field: ^u64, sealed: ^bool) {
		if changed do field^ = id
		if im.IsItemDeactivatedAfterEdit() do sealed^ = true
	}

	check(im.InputText("Name", pm.name_cstring(&props.name), pm.NAME_CAPACITY), 1, &field, &sealed)
	check(im.SliderFloat("Opacity", &props.opacity, 0, 1, "%.2f"), 2, &field, &sealed)
	check(im.DragFloat2("Position", &props.transform.position, 1, 0, 0, "%.1f"), 3, &field, &sealed)
	degrees := math.to_degrees(props.transform.rotation)
	if im.DragFloat("Rotation", &degrees, 0.5, 0, 0, "%.1f deg") {
		props.transform.rotation = math.to_radians(degrees)
		field = 4
	}
	check(false, 4, &field, &sealed)
	check(im.DragFloat2("Scale", &props.transform.scale, 0.01, 0, 0, "%.3f"), 5, &field, &sealed)
	check(im.DragFloat2("Origin", &props.transform.origin, 1, 0, 0, "%.1f"), 6, &field, &sealed)

	if field != 0 {
		pm.set_layer_props(&app.history, &app.doc, h, props, u64(h.index + 1) << 8 | field)
	}
	if sealed do pm.history_seal(&app.history)
}

@(private = "file")
draw_document_panel :: proc(app: ^App) {
	im.SetNextWindowPos({1250, 300}, .FirstUseEver)
	defer im.End()
	if !im.Begin("Document") do return

	s := app.doc.settings
	field: u64
	sealed := false
	check :: proc(changed: bool, id: u64, field: ^u64, sealed: ^bool) {
		if changed do field^ = id
		if im.IsItemDeactivatedAfterEdit() do sealed^ = true
	}
	check(im.InputInt("Width", &s.width), 1, &field, &sealed)
	check(im.InputInt("Height", &s.height), 2, &field, &sealed)
	check(im.InputInt("FPS", &s.fps), 3, &field, &sealed)
	check(im.InputInt("Frames", &s.frame_count), 4, &field, &sealed)
	check(im.ColorEdit4("Background", &s.background), 5, &field, &sealed)

	s.width = clamp(s.width, 1, pm.MAX_DOC_SIZE)
	s.height = clamp(s.height, 1, pm.MAX_DOC_SIZE)
	s.fps = clamp(s.fps, 1, pm.MAX_FPS)
	s.frame_count = clamp(s.frame_count, 1, pm.MAX_FRAMES)

	if field != 0 do pm.set_settings(&app.history, &app.doc, s, field)
	if sealed do pm.history_seal(&app.history)
}

@(private = "file")
draw_view_panel :: proc(app: ^App) {
	im.SetNextWindowPos({20, 660}, .FirstUseEver)
	defer im.End()
	if !im.Begin("View") do return
	zoom := app.cam.zoom * 100
	center := app.size_px * 0.5
	if im.SliderFloat("Zoom %", &zoom, 2, 6400, "%.0f", {.Logarithmic}) {
		pm.camera_zoom_at(&app.cam, center, zoom / 100 / app.cam.zoom)
	}
	rot := app.cam.rotation
	if im.SliderAngle("Rotation", &rot, -180, 180) do pm.camera_rotate_at(&app.cam, center, rot)
	if im.Button("Fit page (Home)") do fit_view(app)
	im.TextDisabled("Wheel: zoom   Ctrl+wheel: rotate")
	im.TextDisabled("Middle drag / Space+drag: pan")
}

@(private = "file")
draw_diagnostics_panels :: proc(app: ^App) {
	io := im.GetIO()

	im.SetNextWindowPos({20, 860}, .FirstUseEver)
	if im.Begin("Pen") {
		p := app.pen
		if !p.seen {
			im.TextWrapped("No pen events yet. Bring a stylus near the tablet.")
		} else {
			im.Text("In range: %s   Down: %s   Eraser: %s", yes_no(p.in_range), yes_no(p.down), yes_no(p.eraser))
			im.ProgressBar(p.pressure, {-1, 0}, fmt.ctprintf("pressure %.3f", p.pressure))
			im.Text("Events: %d", i32(p.events))
		}
	}
	im.End()

	im.SetNextWindowPos({1250, 50}, .FirstUseEver)
	if im.Begin("Renderer") {
		st := app.renderer.stats
		im.Text("Driver: %s", sdl.GetGPUDeviceDriver(app.device))
		im.Text("%.1f fps (%.2f ms)", io.Framerate, 1000 / max(io.Framerate, 0.001))
		im.Text("Shapes: %d   Vertices: %d   Draws: %d", i32(st.shapes), i32(st.vertices), i32(st.draw_calls))
		im.Text("Viewport: %.0fx%.0f px @ %.2fx", app.size_px.x, app.size_px.y, app.density)
		im.Checkbox("ImGui demo window", &app.show_imgui_demo)
	}
	im.End()
}

@(private = "file")
yes_no :: proc(v: bool) -> cstring {
	return v ? "yes" : "no"
}
