package core

// Generational object pool. Handles stay safe after removal: a stale handle
// fails its generation check and resolves to nil instead of the wrong object.
// Pointers returned by pool_get are invalidated by pool_add; handles are not.

Handle :: struct {
	index: u32,
	gen:   u32, // 0 is never a live generation, so Handle{} is the nil handle
}

Pool_Slot :: struct($T: typeid) {
	gen:   u32,
	alive: bool,
	value: T,
}

Pool :: struct($T: typeid) {
	slots: [dynamic]Pool_Slot(T),
	free:  [dynamic]u32,
}

pool_add :: proc(p: ^Pool($T), value: T) -> Handle {
	if len(p.free) > 0 {
		index := pop(&p.free)
		slot := &p.slots[index]
		slot.alive = true
		slot.value = value
		return {index, slot.gen}
	}
	append(&p.slots, Pool_Slot(T){gen = 1, alive = true, value = value})
	return {u32(len(p.slots) - 1), 1}
}

pool_get :: proc(p: ^Pool($T), h: Handle) -> ^T {
	if int(h.index) >= len(p.slots) do return nil
	slot := &p.slots[h.index]
	if !slot.alive || slot.gen != h.gen || h.gen == 0 do return nil
	return &slot.value
}

pool_remove :: proc(p: ^Pool($T), h: Handle) {
	if pool_get(p, h) == nil do return
	slot := &p.slots[h.index]
	slot.alive = false
	slot.value = {}
	slot.gen += 1
	if slot.gen == 0 do slot.gen = 1
	append(&p.free, h.index)
}

pool_destroy :: proc(p: ^Pool($T)) {
	delete(p.slots)
	delete(p.free)
	p^ = {}
}
