extends SceneTree
## The timed explosives (0x480280) in the battle: a bomb with a fuse of 2 beside an enemy
## counts down at the first turn start, goes off at the second (the enemy takes damage
## or is destroyed) and its entry is cleared; then a whole turn runs.

func _init() -> void:
	await process_frame
	var b = load("res://ui/battle.tscn").instantiate()
	b.campaign = "dash"
	b.mission_index = 1
	b.auto_react = true
	root.add_child(b)
	await process_frame
	var w: Pd2World = b.w
	var t := -1
	for k in w.n_units:
		if w.is_enemy(k) and w.active(k) and w.unit_class(k) < 2:
			t = k
			break
	var ok := t != -1
	if ok:
		var p := w.pos(t)
		var cond := w.ub(t, 0xD)
		w.bombs[0] = p.x
		w.bombs[1] = p.y
		w.bombs[2] = 2
		w.bombs[3] = 0xFF
		b._bombs()
		var fuse := w.bombs[2]
		print("first turn start: fuse %d, entry x %d" % [fuse, w.bombs[0]])
		ok = fuse == 1 and w.bombs[0] == p.x
		b._bombs()
		print("second: unit %d condition %d -> %d (destroyed %s), entry x 0x%X" % [t, cond, w.ub(t, 0xD),
			w.ub(t, 0) & 1 != 0, w.bombs[0]])
		ok = ok and w.bombs[0] == 0xFF and (w.ub(t, 0xD) < cond or w.ub(t, 0) & 1)
		b._end_turn()
		print("a whole turn after: fault '%s'" % w.fault)
		ok = ok and w.fault == ""
	print("bomb battle: %s" % ("ok" if ok else "FAILED"))
	quit(0 if ok else 1)
