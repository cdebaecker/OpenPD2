extends SceneTree
## The info panel's マップ (0x43A3E0: the area map retargeting a group, the height map) and
## 指令書 (0x43BA20 with WMES 0x1A2), their windows answered as a player would.

func _top(b):
	var hold = b.win_root.get_child(b.win_root.get_child_count() - 1)
	return hold.get_child(hold.get_child_count() - 1)


func _init() -> void:
	await process_frame
	var b = load("res://ui/battle.tscn").instantiate()
	b.campaign = "dash"
	b.mission_index = 1
	b.auto_react = true
	b.sortie_window = false
	root.add_child(b)
	await process_frame
	var w: Pd2World = b.w
	var ok := true
	# a group the area map takes: group 3 standing by at (5, 5) with a live member
	var g := 3
	var k: int = b.squad[0]
	for f in 35:
		w.groups[35 * g + f] = 0xFF if f >= 6 and f < 22 else 0
	w.groups[35 * g + 2] = 0x20
	w.groups[35 * g + 5] = 1
	w.groups[35 * g + 6] = k
	w.groups[35 * g + 22] = 5
	w.groups[35 * g + 23] = 5
	w.setb(k, 6, 0)
	w.set_ds16(0x50AD95, 0)
	w.set_ds16(0x50AD97, 0)
	ok = ok and Flight.area_map_group_ok(w, g)
	b._panel_region(10)
	var pop = _top(b)
	ok = ok and pop.role == "map" and pop.items.size() == 2
	b.scripted = [g, Vector2i(9, 2), 0, 20]     # the row, the cell, 実行, close
	pop.answer(0)
	await process_frame
	ok = ok and w.groups[35 * g + 26] == 9 and w.groups[35 * g + 27] == 2 \
			and w.groups[35 * g + 2] & 0x30 == 0x10 and b.scripted.is_empty() and not b.busy
	print("area map: group %d to (%d, %d), +2 0x%X" % [g, w.groups[35 * g + 26], w.groups[35 * g + 27], w.groups[35 * g + 2]])
	# the height map from each corner: its two clicks, then the window closes
	for d in 4:
		b._panel_region(10)
		_top(b).answer(1)
		await process_frame
		var hp = _top(b)
		ok = ok and hp.role == "height" and hp.items.size() == 4
		hp.answer(d)
		await process_frame
		var hm = _top(b)
		ok = ok and hm.role == "height_map" and b.busy
		hm.outside(MOUSE_BUTTON_LEFT)
		await process_frame
		hm.outside(MOUSE_BUTTON_LEFT)
		for i in 2:
			await process_frame
		ok = ok and not b.busy and (not is_instance_valid(hm) or hm.is_queued_for_deletion())
	print("height map: %s" % ok)
	# 指令書: WMES 0x1A2, clicked through
	b._panel_region(15)
	var od = _top(b)
	ok = ok and od.role == "orders"
	for i in 6:
		if not b.busy:
			break
		od.outside(MOUSE_BUTTON_LEFT)
		await process_frame
	ok = ok and not b.busy
	print("map buttons: %s" % ok)
	quit(0 if ok else 1)
