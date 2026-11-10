extends SceneTree
## The airdrop (0x44AEA0) in the battle: a transport group (type 0) on the called point
## carries the group before it. With the answers automatic the transport enters from
## its side, opens its menu at once and drops everyone around it (0x44B960), then leaves;
## the passengers land deployed, the carried group's +2 high nibble becomes 0xA.

func _init() -> void:
	await process_frame
	var b = load("res://ui/battle.tscn").instantiate()
	b.campaign = "dash"
	b.mission_index = 1
	b.auto_react = true
	root.add_child(b)
	await process_frame
	var w: Pd2World = b.w
	var tm := -1
	for m in 32:
		if w.machine(m, 9) >= 2:
			tm = m
			break
	var riders := []
	for k in b.squad:
		if w.active(k) and riders.size() < 2:
			riders.append(k)
	var t := -1
	for k in w.n_units:
		if not w.is_enemy(k) and not w.active(k) and not w.ub(k, 0) & 1 and not k in riders:
			t = k
			break
	print("transport machine %d, transport unit %d, passengers %s" % [tm, t, str(riders)])
	var ok := tm != -1 and t != -1 and riders.size() == 2
	if ok:
		var gp := 12
		var gt := 13
		for g in [gp, gt]:
			for f in 35:
				Strike.setgb(w, g, f, 0)
			for i in 16:
				Strike.setgb(w, g, 6 + i, 0xFF)
		for i in riders.size():
			var k: int = riders[i]
			var p := w.pos(k)
			w.O[p.x + 72 * p.y] = 0
			w.setb(k, 9, 0xFF)
			w.setb(k, 10, 0xFF)
			w.setb(k, 0, w.ub(k, 0) & 0xF2)
			w.setb(k, 0xC, w.ub(k, 0xC))
			Strike.setgb(w, gp, 6 + i, k)
		Strike.setgb(w, gp, 5, riders.size())
		w.setb(t, 0xC, tm)
		w.setb(t, 0xD, 100)
		w.setb(t, 9, 0xFF)
		w.setb(t, 10, 0xFF)
		Strike.setgb(w, gt, 6, t)
		Strike.setgb(w, gt, 5, 1)
		Strike.setgb(w, gt, 2, 0x28)
		Strike.setgb(w, gt, 0x21, 0x00)
		Strike.setgb(w, gt, 0x1F, 2)
		w.fire_point = Vector2i(35, 35)
		Strike.setgb(w, gt, 0x16, 35)
		Strike.setgb(w, gt, 0x17, 35)
		# passengers small enough for the capacity
		var res: int = b._airdrop()
		var landed := 0
		for k in riders:
			if w.active(k) and w.ub(k, 0) & 0x0C == 0x0C:
				landed += 1
		print("result %d, landed %d / %d, transport at %s, carried group +2 0x%02X, fault '%s'" % [res, landed,
			riders.size(), str(w.pos(t)), Strike.gb(w, gp, 2), w.fault])
		ok = res == 0 and w.pos(t) == Vector2i(-1, -1) and Strike.gb(w, gp, 2) & 0xF0 == 0xA0 and w.fault == ""
		ok = ok and landed >= 1
		b._end_turn()
		print("a whole turn after: fault '%s'" % w.fault)
		ok = ok and w.fault == ""
	print("drop battle: %s" % ("ok" if ok else "FAILED"))
	quit(0 if ok else 1)
