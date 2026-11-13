extends SceneTree
## cmd_fire's options: 0x2000 (範囲内表: WMES 0x1EE, then the enemies in range, 0x4E9AC0)
## and 0x4000 (命中率: WMES 0x211 after a direct-fire click), with an enemy set in range.

func _top(b):
	var hold = b.win_root.get_child(b.win_root.get_child_count() - 1)
	return hold.get_child(hold.get_child_count() - 1)


func _init() -> void:
	await process_frame
	var b = load("res://ui/battle.tscn").instantiate()
	b.campaign = "dash"
	b.mission_index = 1
	b.sortie_window = false
	root.add_child(b)
	for i in 3:
		await process_frame
	var w: Pd2World = b.w
	var u: int = b.squad[0]
	b._select(u)
	w.setb(u, 0xE, 30)
	var ok := true
	# an enemy, spotted, on a free hex next to u
	var e := -1
	for k in w.n_units:
		if w.is_enemy(k) and w.active(k):
			e = k
			break
	var up := w.pos(u)
	var spot := Vector2i(-1, -1)
	for d in 6:
		var n: Vector2i = up + Move.NEIGHBOURS[up.y & 1][d]
		if w.on_map(n.x, n.y) and w.O[n.x + 72 * n.y] == 0:
			spot = n
			break
	ok = ok and e != -1 and spot.x != -1
	Action.move_unit(w, e, spot.x, spot.y)
	w.setb(e, 0, w.ub(e, 0) | 0x10)
	b.options = b.options | 0x2000 | 0x4000
	b._set_mode("fire")
	ok = ok and b.fire_map != null
	b._fire_range_question()
	var box = _top(b)
	box.answer(0)                                  # 了解: the list
	await process_frame
	var lst = _top(b)
	var listed: bool = lst.role == "in_range" and lst.items.size() >= 1 if b.fire_map.cell(spot.x, spot.y) == 1 else true
	ok = ok and b.fire_list and listed
	if lst.role == "in_range":
		lst.answer(-2)
	print("in-range list: %s (%d rows)" % [listed, lst.items.size() if lst.role == "in_range" else 0])
	b._fire_hit_line(u, 0, spot)
	print("hit line: done")
	print("fire options: %s" % ok)
	quit(0 if ok else 1)
