extends SceneTree
## The strike executor (0x4E37A0) in the battle: two player units are given fire-support
## orders on an enemy's hex, one in an off-map artillery group (type 5) and one in a
## group that flies in (type 3). The player's strikes (0x4E37A0(0), at the turn start)
## fire both: each uses a round, the flier enters from the map's edge, strikes and
## leaves the map, and both groups are reset once all have struck (+2 high nibble 6,
## orders 0). Then a whole turn runs with the strikes in the loop.

func _order_group(w: Pd2World, g: int, typ: int, k: int, x: int, y: int) -> void:
	for f in 35:
		Strike.setgb(w, g, f, 0)
	Strike.setgb(w, g, 2, 0xA0)
	Strike.setgb(w, g, 5, 1)
	for i in 16:
		Strike.setgb(w, g, 6 + i, 0xFF)
	Strike.setgb(w, g, 6, k)
	Strike.setgb(w, g, 0x16, x)
	Strike.setgb(w, g, 0x17, y)
	Strike.setgb(w, g, 0x18, 1)
	Strike.setgb(w, g, 0x19, 1)
	Strike.setgb(w, g, 0x21, typ)


func _armed_slot(w: Pd2World, k: int) -> int:
	for s in 6:
		if w.launcher_id(k, s) != -1 and w.slot_count(k, s) > 0:
			return s
	return -1


func _init() -> void:
	await process_frame
	var b = load("res://ui/battle.tscn").instantiate()
	b.campaign = "pd2"
	b.mission_index = 0
	b.auto_react = true
	root.add_child(b)
	await process_frame
	var w: Pd2World = b.w
	var t := -1
	for k in w.n_units:
		if w.is_enemy(k) and w.active(k):
			t = k
			break
	var strikers := []
	for k in w.n_units:
		if not w.is_enemy(k) and w.sb(k, 0x36) >= 0 and not w.ub(k, 0) & 1 and _armed_slot(w, k) != -1:
			strikers.append(k)
		if strikers.size() == 2:
			break
	print("target %d, strikers %s" % [t, str(strikers)])
	var ok := t != -1 and strikers.size() == 2
	if ok:
		var tp := w.pos(t)
		var plan := [[40, 0x50], [41, 0x30]]
		var before := []
		for i in 2:
			var k: int = strikers[i]
			var s := _armed_slot(w, k)
			_order_group(w, plan[i][0], plan[i][1], k, 60, 60)
			w.setb(k, 6, 1)
			w.setb(k, 7, tp.x)
			w.setb(k, 8, tp.y)
			w.setb(k, 0x35, s)
			if plan[i][1] == 0x30:
				w.setb(k, 9, 0xFF)       # the flier waits off the map
				w.setb(k, 10, 0xFF)
			before.append(w.slot_count(k, s))
		w.fire_point = tp
		w.events = []
		var res: int = b._strikes(0)
		for i in 2:
			var k: int = strikers[i]
			var s := w.ub(k, 0x35)
			var g: int = plan[i][0]
			var used: bool = w.slot_count(k, s) == int(before[i]) - 1
			var reset := Strike.gb(w, g, 2) & 0xF0 == 0x60 and w.ub(k, 6) == 0
			print("striker %d (group %d, type 0x%X): rounds %d -> %d, group +2 0x%02X, order %d, at %s" % [k, g,
				plan[i][1], before[i], w.slot_count(k, s), Strike.gb(w, g, 2), w.ub(k, 6), str(w.pos(k))])
			ok = ok and used and reset
		var grows := w.events.filter(func(e): return e[0] == "grow" and e[2] == "ATTACK")
		print("result %d, ATTACK grows %d, flier off the map: %s, fault '%s'" % [res, grows.size(),
			w.pos(strikers[1]) == Vector2i(-1, -1), w.fault])
		ok = ok and res == 0 and grows.size() >= 2 and w.pos(strikers[1]) == Vector2i(-1, -1) and w.fault == ""
		b._end_turn()
		print("a whole turn after: fault '%s', result %d" % [w.fault, b.last_ai_result])
		ok = ok and w.fault == ""
	print("strike battle: %s" % ("ok" if ok else "FAILED"))
	quit(0 if ok else 1)
