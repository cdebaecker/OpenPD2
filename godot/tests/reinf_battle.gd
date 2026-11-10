extends SceneTree
## Reinforcements (0x44F2E0) in the battle: a type-6 group on the called point with a
## player unit waiting off the map. The turn start brings it in from the side the group
## comes from (+0x1F) to its destination (status 1; the group gets +0x20 = 4 and +2 bits
## 6-7 = 2). Set to leave (+2 bits 6-7 = 1), it walks out to the edge and leaves the map
## (status from its crew, the group's +2 | 0x30).

func _init() -> void:
	await process_frame
	var b = load("res://ui/battle.tscn").instantiate()
	b.campaign = "pd2"
	b.mission_index = 0
	b.auto_react = true
	root.add_child(b)
	await process_frame
	var w: Pd2World = b.w
	var k := -1
	for u in w.n_units:
		if not w.is_enemy(u) and not w.ub(u, 0) & 1 and not w.active(u) and w.sb(u, 0xC) != -1:
			k = u
			break
	var ok := k != -1
	var g := 15
	if ok:
		for f in 35:
			Strike.setgb(w, g, f, 0)
		for i in 16:
			Strike.setgb(w, g, 6 + i, 0xFF)
		Strike.setgb(w, g, 6, k)
		Strike.setgb(w, g, 5, 1)
		Strike.setgb(w, g, 2, 0x20)
		Strike.setgb(w, g, 0x21, 0x60)
		Strike.setgb(w, g, 0x1F, 2)        # from the right edge
		Strike.setgb(w, g, 0x16, 30)
		Strike.setgb(w, g, 0x17, 30)
		w.fire_point = Vector2i(30, 30)
		w.setb(k, 9, 0xFF)
		w.setb(k, 10, 0xFF)
		var dest := Vector2i(40, 30)
		w.setb(k, 7, dest.x)
		w.setb(k, 8, dest.y)
		var res: int = b._reinforcements()
		var p := w.pos(k)
		print("arrival: result %d, unit %d at %s (destination %s), status %d, group +2 0x%02X +0x20 %d" % [res, k,
			str(p), str(dest), w.sb(k, 0x36), Strike.gb(w, g, 2), Strike.gb(w, g, 0x20)])
		var arrived := w.active(k) and w.sb(k, 0x36) == 1 and Strike.gb(w, g, 2) & 0xC0 == 0x80 and Strike.gb(w, g, 0x20) == 4
		if w.ub(k, 0) & 1:
			arrived = true                 # shot down on the way in: allowed, but no leaving test
			print("  (shot down on the way)")
		ok = res == 0 and arrived and w.fault == ""
		if ok and not w.ub(k, 0) & 1:
			Strike.setgb(w, g, 2, 0x60)
			res = b._reinforcements()
			print("departure: result %d, unit at %s, status %d, group +2 0x%02X" % [res, str(w.pos(k)), w.sb(k, 0x36), Strike.gb(w, g, 2)])
			ok = res == 0 and w.pos(k) == Vector2i(-1, -1) and Strike.gb(w, g, 2) & 0x30 == 0x30
		b._end_turn()
		print("a whole turn after: fault '%s'" % w.fault)
		ok = ok and w.fault == ""
	print("reinforcement battle: %s" % ("ok" if ok else "FAILED"))
	quit(0 if ok else 1)
