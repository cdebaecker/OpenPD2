extends SceneTree
## The reaction menu on the threaded computer turn. Mission dash 1 with the squad moved
## next to active enemies; fixed seeds.
## 1. The menu answered "Done" through its buttons must leave the world exactly as the
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
	b._end_turn()
	var menus := 0
	var frames := 0
	while b.busy and frames < 20000:
		await process_frame
		frames += 1
		if b.react_panel != null and b.react_panel.is_inside_tree():
			menus += 1
			var buttons: Array = b.react_panel.find_children("*", "Button", true, false)
			var pick: Button = null
			for btn in buttons:
				if how == "done" and btn.text == "Done":
					pick = btn
				elif how == "fire" and pick == null and not btn.text in ["Done", "Ignore this unit", "Back"]:
					pick = btn
			if pick == null:
				for btn in buttons:
					if btn.text in ["Back", "Done"]:
						pick = btn
						break
			pick.pressed.emit()
			await process_frame
	return menus
