package main

// New / Open / Save on desktop: paths, native dialogs, unsaved-changes prompts.

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import sdl "vendor:sdl3"

import pm "../core"

PROJECT_EXTENSION :: ".promation"

@(private = "file")
Dialog_Kind :: enum i32 {
	Open,
	Save,
}

// Dialog callbacks can run on another thread, so the chosen path is handed to
// the main loop as an SDL event of this type.
@(private = "file")
dialog_event_type: u32

project_io_init :: proc() {
	dialog_event_type = sdl.RegisterEvents(1)
}

@(private = "file")
dialog_filters := [?]sdl.DialogFileFilter{{"Promation project", "promation"}}

@(private = "file")
dialog_callback :: proc "c" (userdata: rawptr, filelist: [^]cstring, filter: c.int) {
	context = runtime.default_context()
	if filelist == nil {
		log.errorf("file dialog failed: %s", sdl.GetError())
		return
	}
	if filelist[0] == nil do return // cancelled

	e: sdl.Event
	e.user.type = sdl.EventType(dialog_event_type)
	e.user.code = i32(uintptr(userdata))
	e.user.data1 = rawptr(strings.clone_to_cstring(string(filelist[0])))
	if !sdl.PushEvent(&e) do delete(cstring(e.user.data1))
}

// Returns true if the event was a finished file dialog.
project_io_handle_event :: proc(app: ^App, e: ^sdl.Event) -> bool {
	if u32(e.type) != dialog_event_type do return false
	path_c := cstring(e.user.data1)
	defer delete(path_c)
	path := string(path_c)
	switch Dialog_Kind(e.user.code) {
	case .Open: open_path(app, path)
	case .Save: save_to_path(app, path)
	}
	return true
}

// New documents start with one layer to draw on, already counted as "clean".
reset_document :: proc(app: ^App) {
	tools_reset(app)
	pm.history_destroy(&app.history)
	pm.document_destroy(&app.doc)
	pm.document_init(&app.doc)
	first := pm.add_layer(&app.history, &app.doc, .Vector, "Layer 1")
	pm.history_mark_saved(&app.history)
	app.active_layer = first
	set_file_path(app, "")
	fit_view(app)
}

fit_view :: proc(app: ^App) {
	s := app.doc.settings
	pm.camera_fit(&app.cam, app.size_px, {f32(s.width), f32(s.height)})
}

// Asks before discarding unsaved work. Returns true if it's fine to continue.
confirm_discard :: proc(app: ^App) -> bool {
	if !pm.history_is_dirty(&app.history) do return true
	DISCARD :: 1
	buttons := [?]sdl.MessageBoxButtonData{
		{flags = {.ESCAPEKEY_DEFAULT, .RETURNKEY_DEFAULT}, buttonID = 0, text = "Cancel"},
		{buttonID = DISCARD, text = "Discard changes"},
	}
	data := sdl.MessageBoxData{
		flags      = {.WARNING},
		window     = app.window,
		title      = "Unsaved changes",
		message    = "This project has unsaved changes. Discard them?",
		numbuttons = len(buttons),
		buttons    = &buttons[0],
	}
	pressed: c.int
	if !sdl.ShowMessageBox(data, &pressed) do return false
	return pressed == DISCARD
}

action_new :: proc(app: ^App) {
	if confirm_discard(app) do reset_document(app)
}

action_open :: proc(app: ^App) {
	if !confirm_discard(app) do return
	sdl.ShowOpenFileDialog(dialog_callback, rawptr(uintptr(Dialog_Kind.Open)), app.window, &dialog_filters[0], len(dialog_filters), nil, false)
}

action_save_as :: proc(app: ^App) {
	tools_reset(app)
	sdl.ShowSaveFileDialog(dialog_callback, rawptr(uintptr(Dialog_Kind.Save)), app.window, &dialog_filters[0], len(dialog_filters), nil)
}

action_save :: proc(app: ^App) {
	if app.file_path == "" {
		action_save_as(app)
	} else {
		save_to_path(app, app.file_path)
	}
}

@(private = "file")
show_error :: proc(app: ^App, title, message: string) {
	log.errorf("%s: %s", title, message)
	_ = sdl.ShowSimpleMessageBox({.ERROR}, fmt.ctprint(title), fmt.ctprint(message), app.window)
}

@(private = "file")
open_path :: proc(app: ^App, path: string) {
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		show_error(app, "Could not open project", fmt.tprintf("%s\n%v", path, read_err))
		return
	}
	defer delete(data)

	loaded: pm.Document
	if err := pm.document_from_json(data, &loaded); err != .None {
		message: string
		switch err {
		case .None:          unreachable()
		case .Malformed:     message = "The file is damaged or isn't a project file."
		case .Wrong_Format:  message = "This isn't a Promation project."
		case .Newer_Version: message = "This project was saved by a newer version of Promation."
		case .Invalid_Value: message = "The project contains invalid data."
		case .Too_Deep:      message = "The project's layers are nested too deeply."
		}
		show_error(app, "Could not open project", message)
		return
	}

	tools_reset(app)
	pm.history_destroy(&app.history)
	pm.document_destroy(&app.doc)
	app.doc = loaded
	app.active_layer = {}
	ensure_active_layer(app)
	set_file_path(app, path)
	fit_view(app)
}

// Writes to a temporary file first, so a failed save can't damage the old one.
@(private = "file")
save_to_path :: proc(app: ^App, chosen: string) {
	path := chosen
	if filepath.ext(path) == "" do path = fmt.tprintf("%s%s", chosen, PROJECT_EXTENSION)

	data, ok := pm.document_to_json(&app.doc)
	if !ok {
		show_error(app, "Could not save project", "The project could not be encoded.")
		return
	}
	defer delete(data)

	temp := fmt.tprintf("%s.tmp", path)
	if err := os.write_entire_file(temp, data); err != nil {
		show_error(app, "Could not save project", fmt.tprintf("%s\n%v", temp, err))
		return
	}
	if err := os.rename(temp, path); err != nil {
		_ = os.remove(temp)
		show_error(app, "Could not save project", fmt.tprintf("%s\n%v", path, err))
		return
	}
	pm.history_mark_saved(&app.history)
	set_file_path(app, path)
}

@(private = "file")
set_file_path :: proc(app: ^App, path: string) {
	if path == app.file_path do return
	replacement := strings.clone(path)
	delete(app.file_path)
	app.file_path = replacement
}

update_window_title :: proc(app: ^App) {
	name := app.file_path != "" ? filepath.base(app.file_path) : "Untitled"
	dirty := pm.history_is_dirty(&app.history) ? "*" : ""
	_ = sdl.SetWindowTitle(app.window, fmt.ctprintf("%s%s - Promation", name, dirty))
}
