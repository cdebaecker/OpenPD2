extends SceneTree
## Render the sortie screen before a battle and save it: godot --path engine/godot -s
## tests/sortie_shot.gd -- dash 0 out.png [group to select] [panel]
## panel: "roster" (the pilot roster), "bulk" (the bulk menu's scopes), "machine" (the
## first member's armament screen with its machine list), "template" (its template
## menu's recall list, with a register made first in a scratch reg_unit).

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	await process_frame
	var b = load("res://ui/battle.tscn").instantiate()
	b.campaign = args[0]
	b.mission_index = int(args[1])
	b.plan_window = false               # the operation plan pressed done at once
	root.add_child(b)
	for i in 10:
		await process_frame
	if args.size() > 3 and int(args[3]) >= 0:
		b.sortie_sel = int(args[3])
		b._sortie_draw()
	var panel := args[4] if args.size() > 4 else ""
	match panel:
		"roster":
			b._sortie_press(["roster"])
		"bulk":
			b._sortie_press(["bulk", 0])
		"machine", "template":
			var k: int = b.w.ds[2] if b.w.crew_pool_n else 0      # the first free pilot
			for g in 20:
				var m0 := Flight.s8(b.w.ub(Flight.gb(b.w, g, 6), 0xC)) if Flight.gb(b.w, g, 5) else -1
				if m0 >= 0 and m0 <= 6:
					k = Flight.gb(b.w, g, 6)
					break
			b._equip_begin(k)
			if panel == "machine":
				b._equip_press("machine")
			else:
				Equipment.template_save(b.w, k, 0)     # a register to recall (not written to disk)
				b.w.remove_meta("reg_unit_written")
				b._equip_press("menu")
				b._equip_answer(1)
				b._equip_answer(0)
	for i in 5:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_viewport().get_texture().get_image().save_png(args[2])
	quit(0)
