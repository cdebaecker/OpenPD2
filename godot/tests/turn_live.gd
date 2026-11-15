extends SceneTree
## The computer's turn drawn as it plays (windowed run; headless runs skip the waits).
## Mission dash 1 with the squad next to the active enemies, fixed seed, the reactions
## answered "wait and see": the threaded turn must leave the world as the synchronous run,
## its spotted steps must be shown (hooks.shown: a 0x21 ms wait each, the overlay drawn from
## the parked copy), and the turn must end.
## godot --path engine/godot -s tests/turn_live.gd [-- out.png]

const SEED := 4242


func _init() -> void:
	await process_frame
	var out := ""
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		out = args[0]
	var a = await _battle(true)
	if a._headless():
		print("turn live: headless, the waits are off (run it windowed)")
		quit(0)
		return
	a.react_policy = func(_m, _t): return 1
	a.options = a.options | 0x10              # (the animations draw random numbers: off in both)
	a.hooks.anims = false
	a._end_turn()
	var want: PackedByteArray = a.w.units.duplicate()
	a.queue_free()
	var b = await _battle(false)
	b.options = b.options | 0x10              # (the attacks' animations off: steps only)
	b.hooks.anims = false
	b._end_turn()
	var frames := 0
	var drawn_during := 0
	var shot := false
	var t0 := Time.get_ticks_msec()
	while b.busy and frames < 40000:
		await process_frame
		frames += 1
		if b.ai_running and b.view_w != null:
			drawn_during += 1
			if out != "" and not shot and b.steps_shown >= 3:
				shot = true
				await RenderingServer.frame_post_draw
				root.get_texture().get_image().save_png(out)
				print("saved %s" % out)
		var hold = b.react_panel
		if hold == null or not is_instance_valid(hold) or hold.is_queued_for_deletion():
			continue
		var wins: Array = hold.get_children().filter(func(n): return n.has_method("answer"))
		if wins.is_empty():
			continue
		var gw = wins[-1]
		gw.answer(1 if gw.role == "reaction" else 0)
	var ms := Time.get_ticks_msec() - t0
	var same: bool = b.w.units == want
	print("threaded == synchronous: %s; steps shown %d; frames drawn from the copy %d; %d ms; turn %d"
			% [same, b.steps_shown, drawn_during, ms, b.turn])
	var ok: bool = same and b.turn == 2 and b.steps_shown > 0 and drawn_during > 0 and ms >= b.steps_shown * 0x21
	print("turn live: %s" % ok)
	quit(0 if ok else 1)


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
