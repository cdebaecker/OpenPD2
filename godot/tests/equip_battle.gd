extends SceneTree
## The sortie screen's armament panel in the battle, driven through its buttons: a PD2
## free pilot without a machine takes one from the stock (the stock drops by one), fits
## slot 1 from its list, closes, then joins a group.

func _press(b, button: Variant, answers: Array) -> void:
	b._equip_press(button)
	for a in answers:
		if b.equip_request == null:
			break
		b._equip_answer(a)


func _init() -> void:
	await process_frame
	var b = load("res://ui/battle.tscn").instantiate()
	b.campaign = "pd2"
	b.mission_index = 0
	root.add_child(b)
	for i in 5:
		await process_frame
	var w: Pd2World = b.w
	var ok := b.sortie_panel != null
	var c := -1
	for i in w.crew_pool_n:
		if Flight.s8(w.ub(w.ds[2 + i], 0xC)) == -1:
			c = w.ds[2 + i]
			break
	print("free pilot without a machine: %d" % c)
	ok = ok and c != -1
	if ok:
		b._equip_begin(c)
		var ents: Array = Equipment.machine_list(w, c)
		var j := -1
		for i in ents.size():
			if w.mem8(Equipment.STOCK_MACH + ents[i]):
				j = i
				break
		var m: int = ents[j] if j >= 0 else -1
		var before := w.mem8(Equipment.STOCK_MACH + m) if m >= 0 else 0
		_press(b, "machine", [6 + j])
		var got := Flight.s8(w.ub(c, 0xC))
		print("machine %d (stock %d -> %d)" % [got, before, w.mem8(Equipment.STOCK_MACH + m) if m >= 0 else 0])
		ok = ok and m >= 0 and got == m and w.mem8(Equipment.STOCK_MACH + m) == before - 1
		var slots: Array = Equipment.slot_list(w, c, 0)
		var sj := -1
		for i in slots.size():
			if w.mem8(Equipment.STOCK_LAUN + slots[i][0]) and w.mem8(Equipment.STOCK_AMMO + slots[i][1]):
				sj = i
				break
		if sj >= 0:
			_press(b, ["slot", 0], [0xD + sj])
			print("slot 1: launcher %d" % Flight.s8(w.ub(c, 0xF)))
			ok = ok and Flight.s8(w.ub(c, 0xF)) == slots[sj][0]
		_press(b, "close", [1])
		ok = ok and b.equip_sess.is_empty()
		var g: int = b.sortie_sel
		var code := Campaign.group_join(w, g, c)
		print("joins group %d: code %d" % [g, code])
	quit(0 if ok else 1)
