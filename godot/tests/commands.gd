extends SceneTree
## The battle's search, conceal, carry and release flows, with their dialogs confirmed.

func _confirm_dialog(b) -> bool:
	for c in b.get_children():
		if c is ConfirmationDialog and not c.is_queued_for_deletion():
			c.confirmed.emit()
			return true
	return false


func _init() -> void:
	await process_frame
	var b = load("res://ui/battle.tscn").instantiate()
	b.campaign = "dash"
	b.mission_index = 1
	b.auto_react = true
	root.add_child(b)
	await process_frame
	var w: Pd2World = b.w
	var a: int = b.squad[0]
	var ok := true
	b._select(a)
	b._cmd_carry_mode()
	ok = ok and b.mode == "carry" and not b.carry_hexes.is_empty()
	var h: Vector2i = b.carry_hexes[0]
	var other := w.O[h.x + 72 * h.y] - 1
	b._cmd_carry_click(h)
	ok = ok and _confirm_dialog(b)
	await process_frame
	var carried := w.ub(a, 0x34) == other and not w.active(other)
	print("carry: %s (unit %d carries %d)" % [carried, a, other])
	b._cmd_carry_mode()
	var rh: Vector2i = b.carry_hexes[0]
	b._cmd_carry_click(rh)
	ok = ok and _confirm_dialog(b)
	await process_frame
	var released := w.ub(a, 0x34) == 0xFF and w.pos(other) == rh and w.O[rh.x + 72 * rh.y] == other + 1
	print("release: %s (at %s)" % [released, rh])
	var ap0 := w.sb(a, 0xE)
	b._cmd_search()
	ok = ok and _confirm_dialog(b)
	await process_frame
	var searched := w.sb(a, 0xE) == ap0 - Action.search_cost(w, a) and (w.ub(a, 4) >> 4) & 3 == 3
	print("search: %s (AP %d -> %d)" % [searched, ap0, w.sb(a, 0xE)])
	b._cmd_conceal()
	ok = ok and _confirm_dialog(b)
	await process_frame
	var concealed := w.ub(a, 0) & 0x20 != 0
	print("conceal: %s" % concealed)
	quit(0 if ok and carried and released and searched and concealed else 1)
