extends SceneTree
## The info panel's 一斉 (0x429540): its popup answered through the game's window, then the
## all search and the all conceal (their questions answered with their defaults: auto_react).

func _popup(b, role: String):
	for hold in b._win_root().get_children():
		for n in hold.get_children():
			if n.has_method("answer") and n.role == role:
				return n
	return null


func _init() -> void:
	await process_frame
	var b = load("res://ui/battle.tscn").instantiate()
	b.campaign = "dash"
	b.mission_index = 1
	b.auto_react = true
	root.add_child(b)
	await process_frame
	var w: Pd2World = b.w
	var ok := true
	var own := []
	for u in 40:
		if w.ub(u, 0x36) == 0 and w.active(u):
			own.append(u)
	ok = ok and not own.is_empty()
	var ap0 := {}
	for u in own:
		ap0[u] = w.sb(u, 0xE)
	b._panel_region(13)
	var gw = _popup(b, "all")
	ok = ok and gw != null and gw.items.size() == 2
	gw.answer(0)
	await process_frame
	var searched := 0
	for u in own:
		if ap0[u] >= Action.search_cost(w, u):
			searched += 1
			ok = ok and w.sb(u, 0xE) == ap0[u] - Action.search_cost(w, u)
	print("all search: %d of %d units searched" % [searched, own.size()])
	for u in own:
		ap0[u] = w.sb(u, 0xE)
	b._panel_region(13)
	gw = _popup(b, "all")
	ok = ok and gw != null
	gw.answer(1)
	await process_frame
	var hid := 0
	for u in own:
		var cost := 3 if (w.ucrew(u, 8) >> 3) & 1 else 6
		if w.ub(u, 0) & 0x20:
			hid += 1
		elif ap0[u] >= cost:
			ok = false
	print("all conceal: %d of %d units concealed" % [hid, own.size()])
	b._panel_region(13)
	gw = _popup(b, "all")
	ok = ok and gw != null
	gw.answer(-2)                        # a right click closes it
	await process_frame
	ok = ok and _popup(b, "all") == null and not b.busy
	print("all orders: %s" % ok)
	quit(0 if ok else 1)
