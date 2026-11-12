extends SceneTree
## The reaction menu on the threaded computer turn. Mission dash 1 with the squad moved
## next to active enemies; fixed seeds.
## 1. The menu answered "wait and see" through its window must leave the world exactly as the
##    synchronous run whose policy answers "Done" (1).
## 2. Clicking the first unit and its first weapon each time must finish the turn.

const SEED := 4242


func _init() -> void:
	await process_frame
	var a = await _battle(true)
	a.react_policy = func(_m, _t): return 1
	a._end_turn()
	var want: PackedByteArray = a.w.units.duplicate()
	var b = await _battle(false)
	var menus := await _run_threaded(b, "done")
	var same: bool = b.w.units == want and b.rng.state == a.rng.state
	print("threaded == synchronous: %s (menus shown: %d)" % [same, menus])
	var c = await _battle(false)
	var menus2 := await _run_threaded(c, "fire")
	print("clicking units and weapons: turn %d reached, menus shown: %d" % [c.turn, menus2])
	quit(0 if same and c.turn == 2 else 1)


func _battle(auto: bool):
	var b = load("res://ui/battle.tscn").instantiate()
	b.campaign = "dash"
	b.mission_index = 1
	b.auto_react = auto
	b.sortie_window = false
	root.add_child(b)
	await process_frame
	b.rng = Pd2Random.new(SEED)
	b.hooks.rng = b.rng
	# move the squad next to the active enemies
	var w: Pd2World = b.w
	var spots := []
	for e in w.n_units:
		if w.is_enemy(e) and w.active(e):
			var p := w.pos(e)
			for q in Ai.spiral(p.x, p.y, 3):
				if spots.size() < b.squad.size() and Mission._free(w, q.x, q.y) and not q in spots:
					spots.append(q)
	for i in b.squad.size():
		var u: int = b.squad[i]
		var old := w.pos(u)
		w.O[old.x + 72 * old.y] = 0
		w.setb(u, 9, spots[i].x)
		w.setb(u, 10, spots[i].y)
		w.O[spots[i].x + 72 * spots[i].y] = u + 1
	return b


func _run_threaded(b, how: String) -> int:
	## answers the game's windows as they come: the reaction menu (role "reaction") with
	## "wait and see" (1) or its first unit (2); the weapon picker (role "weapon") with its
	## first slot it takes, else a right click (back to the menu); any other question with
	## its first answer
	b._end_turn()
	var menus := 0
	var frames := 0
	var tried := {}
	while b.busy and frames < 20000:
		await process_frame
		frames += 1
		var hold = b.react_panel
		if hold == null or not is_instance_valid(hold) or hold.is_queued_for_deletion():
			continue
		var wins: Array = hold.get_children().filter(func(n): return n.has_method("answer"))
		if wins.is_empty():
			continue
		var gw = wins[-1]
		match gw.role:
			"reaction":
				menus += 1
				gw.answer(1 if how == "done" else 2)
			"weapon":
				var k: int = tried.get(gw.get_instance_id(), 0)
				if k < 4:
					tried[gw.get_instance_id()] = k + 1
					gw.answer(k)                  # a refused slot leaves the picker up
				else:
					gw.answer(-2)
			_:
				gw.answer(0)
		await process_frame
	return menus
