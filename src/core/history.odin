package core

// Undo/redo. Every undoable edit is a Command.
//
// Deleting does not free anything: the object is unlinked from its parent and
// stays in the pool, so its handle remains valid for undo. It is freed only
// when the command holding it is discarded. An object is owned by a command
// when it is unlinked:
//   insert command that has been undone (on the redo stack)
//   erase  command that has been applied (on the undo stack)

Cmd_Link_Path :: struct {
	layer:  Layer_Handle,
	path:   Path_Handle,
	index:  int,
	insert: bool, // false = erase
}

Cmd_Link_Layer :: struct {
	parent: Layer_Handle,
	layer:  Layer_Handle,
	index:  int,
	insert: bool, // false = erase
}

Cmd_Move_Layer :: struct {
	layer:       Layer_Handle,
	from_parent: Layer_Handle,
	from_index:  int,
	to_parent:   Layer_Handle,
	to_index:    int,
}

Cmd_Set_Layer_Props :: struct {
	layer:  Layer_Handle,
	before: Layer_Props,
	after:  Layer_Props,
}

Cmd_Set_Settings :: struct {
	before: Doc_Settings,
	after:  Doc_Settings,
}

// Replaces a path's knots and style. Owns both knot arrays, whichever stack
// it is on; the document's path always has its own copy.
Cmd_Set_Path :: struct {
	path:   Path_Handle,
	before: Path,
	after:  Path,
}

Cmd_Move_Path :: struct {
	layer:      Layer_Handle,
	path:       Path_Handle,
	from_index: int,
	to_index:   int,
}

// Several commands as one undo step, applied in order and reverted in reverse.
Cmd_Group :: struct {
	cmds: [dynamic]Command,
}

Command :: union {
	Cmd_Link_Path,
	Cmd_Link_Layer,
	Cmd_Move_Layer,
	Cmd_Set_Layer_Props,
	Cmd_Set_Settings,
	Cmd_Set_Path,
	Cmd_Move_Path,
	Cmd_Group,
}

History_Entry :: struct {
	cmd: Command,
	id:  u64,
}

History :: struct {
	undo_stack: [dynamic]History_Entry,
	redo_stack: [dynamic]History_Entry,
	last_id:    u64,
	merge_key:  u64, // key of the top entry while it may still be merged into
	saved_id:   u64, // state id at the last save; 0 = the initial state

	group_depth: int, // > 0 while commands are being collected into one step
	group:       [dynamic]Command,
}

// Frees the stacks and the data commands own. Document objects held by
// commands (unlinked layers and paths) are freed by document_destroy.
history_destroy :: proc(h: ^History) {
	for e in h.undo_stack do free_command_data(e.cmd)
	for e in h.redo_stack do free_command_data(e.cmd)
	for c in h.group do free_command_data(c)
	delete(h.undo_stack)
	delete(h.redo_stack)
	delete(h.group)
	h^ = {}
}

// Commands executed until the matching history_end_group form one undo step.
// Groups nest; only the outermost one makes the step.
history_begin_group :: proc(h: ^History) {
	h.group_depth += 1
}

// Consecutive groups ended with the same non-zero merge_key merge into one
// step when they hold mergeable commands in the same order (e.g. a drag that
// edits the same paths every frame).
history_end_group :: proc(h: ^History, merge_key: u64 = 0) {
	assert(h.group_depth > 0)
	h.group_depth -= 1
	if h.group_depth > 0 do return
	cmds := h.group
	h.group = {}
	switch len(cmds) {
	case 0:
		delete(cmds)
	case 1:
		cmd := cmds[0]
		delete(cmds)
		push_entry(h, cmd, merge_key)
	case:
		push_entry(h, Cmd_Group{cmds}, merge_key)
	}
}

history_in_group :: proc(h: ^History) -> bool {
	return h.group_depth > 0
}

can_undo :: proc(h: ^History) -> bool { return len(h.undo_stack) > 0 }
can_redo :: proc(h: ^History) -> bool { return len(h.redo_stack) > 0 }

// Identifies the current document state; used for unsaved-changes tracking.
history_state_id :: proc(h: ^History) -> u64 {
	return can_undo(h) ? h.undo_stack[len(h.undo_stack) - 1].id : 0
}

history_is_dirty :: proc(h: ^History) -> bool {
	return history_state_id(h) != h.saved_id
}

history_mark_saved :: proc(h: ^History) {
	h.saved_id = history_state_id(h)
	history_seal(h)
}

// Ends the current merge run, e.g. when a slider drag is released.
history_seal :: proc(h: ^History) {
	h.merge_key = 0
}

undo :: proc(h: ^History, d: ^Document) -> bool {
	if !can_undo(h) || history_in_group(h) do return false
	entry := pop(&h.undo_stack)
	revert_command(d, entry.cmd)
	append(&h.redo_stack, entry)
	history_seal(h)
	return true
}

redo :: proc(h: ^History, d: ^Document) -> bool {
	if !can_redo(h) || history_in_group(h) do return false
	entry := pop(&h.redo_stack)
	apply_command(d, entry.cmd)
	append(&h.undo_stack, entry)
	history_seal(h)
	return true
}

// --- Operations ---------------------------------------------------------------

// Creates a layer inside `parent` (nil handle = top level). index < 0 = on top.
// Returns the nil handle if `parent` can't hold layers.
add_layer :: proc(
	h: ^History, d: ^Document, kind: Layer_Kind, name: string,
	parent := Layer_Handle{}, index := -1,
) -> Layer_Handle {
	if !can_hold_layers(d, parent) do return {}
	siblings := children_of(d, parent)
	at := index < 0 ? len(siblings) : min(index, len(siblings))
	l := Layer{
		props = {name = name_make(name), visible = true, opacity = 1, transform = TRANSFORM_IDENTITY},
		kind = kind,
		parent = parent,
	}
	handle := Layer_Handle(pool_add(&d.layers, l))
	execute(h, d, Cmd_Link_Layer{parent, handle, at, true})
	return handle
}

remove_layer :: proc(h: ^History, d: ^Document, handle: Layer_Handle) -> bool {
	if !layer_is_linked(d, handle) do return false
	parent := layer(d, handle).parent
	index := index_of_layer(children_of(d, parent)[:], handle)
	execute(h, d, Cmd_Link_Layer{parent, handle, index, false})
	return true
}

// Moves a layer to `to_index` among the children of `to_parent`, where the
// index is counted after the layer has been taken out of its current place.
move_layer :: proc(h: ^History, d: ^Document, handle, to_parent: Layer_Handle, to_index: int) -> bool {
	if !layer_is_linked(d, handle) || !can_hold_layers(d, to_parent) do return false
	if to_parent != {} && layer_is_within(d, to_parent, handle) do return false // no cycles

	from_parent := layer(d, handle).parent
	from_index := index_of_layer(children_of(d, from_parent)[:], handle)
	limit := len(children_of(d, to_parent))
	if to_parent == from_parent do limit -= 1
	to := clamp(to_index, 0, limit)
	if to_parent == from_parent && to == from_index do return false

	execute(h, d, Cmd_Move_Layer{handle, from_parent, from_index, to_parent, to})
	return true
}

// Adds a path on top of a vector layer, taking ownership of `p.knots`.
add_path :: proc(h: ^History, d: ^Document, layer_handle: Layer_Handle, p: Path) -> Path_Handle {
	l := layer(d, layer_handle)
	if l == nil || l.kind != .Vector {
		delete(p.knots)
		return {}
	}
	index := len(l.paths)
	handle := Path_Handle(pool_add(&d.paths, p))
	execute(h, d, Cmd_Link_Path{layer_handle, handle, index, true})
	return handle
}

remove_path :: proc(h: ^History, d: ^Document, layer_handle: Layer_Handle, handle: Path_Handle) -> bool {
	l := layer(d, layer_handle)
	if l == nil do return false
	for x, i in l.paths {
		if x == handle {
			execute(h, d, Cmd_Link_Path{layer_handle, handle, i, false})
			return true
		}
	}
	return false
}

// Consecutive calls with the same non-zero merge_key form a single undo step.
set_layer_props :: proc(h: ^History, d: ^Document, handle: Layer_Handle, props: Layer_Props, merge_key: u64 = 0) {
	l := layer(d, handle)
	if l == nil || l.props == props do return
	execute(h, d, Cmd_Set_Layer_Props{handle, l.props, props}, merge_key)
}

set_settings :: proc(h: ^History, d: ^Document, settings: Doc_Settings, merge_key: u64 = 0) {
	if d.settings == settings do return
	execute(h, d, Cmd_Set_Settings{d.settings, settings}, merge_key)
}

// Sets a path's knots and style from `value`, which is copied, not taken.
set_path :: proc(h: ^History, d: ^Document, handle: Path_Handle, value: Path, merge_key: u64 = 0) {
	p := path(d, handle)
	if p == nil || paths_equal(p^, value) do return
	execute(h, d, Cmd_Set_Path{handle, clone_path(p^), clone_path(value)}, merge_key)
}

// Restacks a path within its layer; to_index is clamped.
move_path :: proc(h: ^History, d: ^Document, layer_handle: Layer_Handle, handle: Path_Handle, to_index: int) -> bool {
	l := layer(d, layer_handle)
	if l == nil do return false
	from := index_of_path(l.paths[:], handle)
	if from < 0 do return false
	to := clamp(to_index, 0, len(l.paths) - 1)
	if to == from do return false
	execute(h, d, Cmd_Move_Path{layer_handle, handle, from, to})
	return true
}

index_of_path :: proc(list: []Path_Handle, h: Path_Handle) -> int {
	for x, i in list do if x == h do return i
	return -1
}

clone_path :: proc(p: Path, allocator := context.allocator) -> Path {
	out := p
	out.knots = make([dynamic]Knot, len(p.knots), allocator)
	copy(out.knots[:], p.knots[:])
	return out
}

paths_equal :: proc(a, b: Path) -> bool {
	if a.closed != b.closed || a.has_fill != b.has_fill || a.has_stroke != b.has_stroke do return false
	if a.fill != b.fill || a.stroke != b.stroke || len(a.knots) != len(b.knots) do return false
	for k, i in a.knots do if k != b.knots[i] do return false
	return true
}

// --- Internals ----------------------------------------------------------------

@(private)
can_hold_layers :: proc(d: ^Document, parent: Layer_Handle) -> bool {
	if parent == {} do return true
	l := layer(d, parent)
	return l != nil && l.kind == .Group
}

@(private)
execute :: proc(h: ^History, d: ^Document, cmd: Command, merge_key: u64 = 0) {
	apply_command(d, cmd)
	clear_redo(h, d)
	if history_in_group(h) {
		append(&h.group, cmd) // merging happens for the group as a whole
		return
	}
	push_entry(h, cmd, merge_key)
}

@(private)
push_entry :: proc(h: ^History, cmd: Command, merge_key: u64) {
	h.last_id += 1
	if merge_key != 0 && merge_key == h.merge_key && can_undo(h) {
		top := &h.undo_stack[len(h.undo_stack) - 1]
		if can_merge(top.cmd, cmd) {
			merge_into(&top.cmd, cmd)
			top.id = h.last_id
			return
		}
	}
	append(&h.undo_stack, History_Entry{cmd, h.last_id})
	h.merge_key = merge_key
}

@(private)
can_merge :: proc(top, cmd: Command) -> bool {
	switch t in top {
	case Cmd_Set_Layer_Props:
		c, ok := cmd.(Cmd_Set_Layer_Props)
		return ok && c.layer == t.layer
	case Cmd_Set_Settings:
		_, ok := cmd.(Cmd_Set_Settings)
		return ok
	case Cmd_Set_Path:
		c, ok := cmd.(Cmd_Set_Path)
		return ok && c.path == t.path
	case Cmd_Group:
		c, ok := cmd.(Cmd_Group)
		if !ok || len(c.cmds) != len(t.cmds) do return false
		for sub, i in t.cmds do if !can_merge(sub, c.cmds[i]) do return false
		return true
	case Cmd_Link_Path, Cmd_Link_Layer, Cmd_Move_Layer, Cmd_Move_Path:
	}
	return false
}

// Folds `cmd` (already applied) into `top`, consuming it. Needs can_merge.
@(private)
merge_into :: proc(top: ^Command, cmd: Command) {
	#partial switch &t in top {
	case Cmd_Set_Layer_Props:
		t.after = cmd.(Cmd_Set_Layer_Props).after
	case Cmd_Set_Settings:
		t.after = cmd.(Cmd_Set_Settings).after
	case Cmd_Set_Path:
		c := cmd.(Cmd_Set_Path)
		delete(t.after.knots)
		delete(c.before.knots)
		t.after = c.after
	case Cmd_Group:
		c := cmd.(Cmd_Group)
		for &sub, i in t.cmds do merge_into(&sub, c.cmds[i])
		delete(c.cmds)
	}
}

// Frees memory a command owns outright (not document objects).
@(private)
free_command_data :: proc(cmd: Command) {
	#partial switch c in cmd {
	case Cmd_Set_Path:
		delete(c.before.knots)
		delete(c.after.knots)
	case Cmd_Group:
		for sub in c.cmds do free_command_data(sub)
		delete(c.cmds)
	}
}

// Frees an undone command being dropped from the redo stack, including the
// objects its undone inserts own.
@(private)
discard_undone :: proc(d: ^Document, cmd: Command) {
	#partial switch c in cmd {
	case Cmd_Link_Path:
		if c.insert do free_path(d, c.path)
	case Cmd_Link_Layer:
		if c.insert do free_layer_subtree(d, c.layer)
	case Cmd_Group:
		#reverse for sub in c.cmds do discard_undone(d, sub)
		delete(c.cmds)
		return
	}
	free_command_data(cmd)
}

@(private)
clear_redo :: proc(h: ^History, d: ^Document) {
	#reverse for entry in h.redo_stack do discard_undone(d, entry.cmd)
	clear(&h.redo_stack)
}

@(private)
free_path :: proc(d: ^Document, handle: Path_Handle) {
	p := path(d, handle)
	if p == nil do return
	delete(p.knots)
	pool_remove(&d.paths, Handle(handle))
}

@(private)
free_layer_subtree :: proc(d: ^Document, handle: Layer_Handle) {
	l := layer(d, handle)
	if l == nil do return
	for child in l.children do free_layer_subtree(d, child)
	for p in l.paths do free_path(d, p)
	delete(l.children)
	delete(l.paths)
	pool_remove(&d.layers, Handle(handle))
}

@(private)
link_layer :: proc(d: ^Document, parent, handle: Layer_Handle, index: int) {
	inject_at(children_of(d, parent), index, handle)
	layer(d, handle).parent = parent
}

@(private)
unlink_layer :: proc(d: ^Document, parent, handle: Layer_Handle) {
	siblings := children_of(d, parent)
	ordered_remove(siblings, index_of_layer(siblings[:], handle))
}

@(private)
link_path :: proc(d: ^Document, layer_handle: Layer_Handle, handle: Path_Handle, index: int) {
	inject_at(&layer(d, layer_handle).paths, index, handle)
}

@(private)
unlink_path :: proc(d: ^Document, layer_handle: Layer_Handle, handle: Path_Handle) {
	l := layer(d, layer_handle)
	for x, i in l.paths {
		if x == handle {
			ordered_remove(&l.paths, i)
			return
		}
	}
}

@(private)
apply_command :: proc(d: ^Document, cmd: Command) {
	switch c in cmd {
	case Cmd_Link_Path:
		if c.insert do link_path(d, c.layer, c.path, c.index)
		else do unlink_path(d, c.layer, c.path)
	case Cmd_Link_Layer:
		if c.insert do link_layer(d, c.parent, c.layer, c.index)
		else do unlink_layer(d, c.parent, c.layer)
	case Cmd_Move_Layer:
		unlink_layer(d, c.from_parent, c.layer)
		link_layer(d, c.to_parent, c.layer, c.to_index)
	case Cmd_Set_Layer_Props:
		layer(d, c.layer).props = c.after
	case Cmd_Set_Settings:
		d.settings = c.after
	case Cmd_Set_Path:
		assign_path(path(d, c.path), c.after)
	case Cmd_Move_Path:
		l := layer(d, c.layer)
		ordered_remove(&l.paths, c.from_index)
		inject_at(&l.paths, c.to_index, c.path)
	case Cmd_Group:
		for sub in c.cmds do apply_command(d, sub)
	}
}

@(private)
revert_command :: proc(d: ^Document, cmd: Command) {
	switch c in cmd {
	case Cmd_Link_Path:
		if c.insert do unlink_path(d, c.layer, c.path)
		else do link_path(d, c.layer, c.path, c.index)
	case Cmd_Link_Layer:
		if c.insert do unlink_layer(d, c.parent, c.layer)
		else do link_layer(d, c.parent, c.layer, c.index)
	case Cmd_Move_Layer:
		unlink_layer(d, c.to_parent, c.layer)
		link_layer(d, c.from_parent, c.layer, c.from_index)
	case Cmd_Set_Layer_Props:
		layer(d, c.layer).props = c.before
	case Cmd_Set_Settings:
		d.settings = c.before
	case Cmd_Set_Path:
		assign_path(path(d, c.path), c.before)
	case Cmd_Move_Path:
		l := layer(d, c.layer)
		ordered_remove(&l.paths, c.to_index)
		inject_at(&l.paths, c.from_index, c.path)
	case Cmd_Group:
		#reverse for sub in c.cmds do revert_command(d, sub)
	}
}

// Copies `src` into `dst`, keeping dst's own knot array.
@(private)
assign_path :: proc(dst: ^Path, src: Path) {
	knots := dst.knots
	clear(&knots)
	append(&knots, ..src.knots[:])
	dst^ = src
	dst.knots = knots
}
