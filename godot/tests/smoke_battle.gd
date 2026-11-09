extends SceneTree
## Headless smoke test of the sandbox battle: build each mission, drop the squad, run
## two whole turns (the player passes), report what happened.

func _init() -> void:
	var gd = root.get_node_or_null("GameData")
	await process_frame
	gd = root.get_node("GameData")
	var only := OS.get_cmdline_user_args()
	for camp in ["pd2", "dash"]:
		for m in gd.mission_count(camp):
			if not only.is_empty() and not ("%s%d" % [camp, m]) in only:
				continue
			var t0 := Time.get_ticks_msec()
			var scene: PackedScene = load("res://ui/battle.tscn")
			var b = scene.instantiate()
			b.campaign = camp
			b.mission_index = m
			root.add_child(b)
			await process_frame
			var before := []
			for u in b.w.n_units:
				before.append(b.w.pos(u))
			b._end_turn()
			var r1: int = b.last_ai_result
			b._end_turn()
			var orders := {}
			for u in b.w.n_units:
				if b.w.active(u) and b.w.is_enemy(u):
					orders[b.w.ub(u, 3) & 15] = orders.get(b.w.ub(u, 3) & 15, 0) + 1
			var moved := 0
			var active := 0
			for u in b.w.n_units:
				if b.w.active(u) and b.w.is_enemy(u):
					active += 1
					if b.w.pos(u) != before[u]:
						moved += 1
			print("%s m%02d: squad %d, enemy active %d, moved %d, AI 0x%X / 0x%X, orders %s (%d ms)" % [camp, m, b.squad.size(), active, moved, r1, b.last_ai_result, str(orders), Time.get_ticks_msec() - t0])
			b.queue_free()
			await process_frame
	quit(0)
