extends SceneTree
## Render the counter-battery pickers (0x4E3230's unit list, 0x4E0450's weapon list) as
## the battle draws them, for the player's units of a battle, and save them:
## godot --path engine/godot -s tests/cb_shot.gd -- dash 0 units.png weapons.png
## Prints the rows and which are refused (not standing by; a weapon out of range, without
## rounds, broken ..); exits 1 when a list comes out empty.

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	await process_frame
	var b = load("res://ui/battle.tscn").instantiate()
	b.campaign = args[0]
	b.mission_index = int(args[1])
	b.sortie_window = false
	root.add_child(b)
	for i in 10:
		await process_frame
	var w: Pd2World = b.w
	var units := []
	for k in w.n_units:
		if not w.is_enemy(k) and w.launcher_id(k, 0) != -1 and units.size() < 6:
			units.append(k)
	var rows: Array = b.cb_unit_rows(units)
	for r in rows:
		print("unit row%s: %s" % [" (refused)" if r.refused else "", "".join(r.cells.map(func(c): return c[0]))])
	b._open_table(b.ui("UI_PICK_SUPPORT"), [], rows, -2)
	for i in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_viewport().get_texture().get_image().save_png(args[2])
	var ok := not rows.is_empty()
	if not units.is_empty():
		var k: int = units[0]
		var srows: Array = b.cb_slot_rows(k, Ai.unit_group(w, k), -1)
		for r in srows:
			print("slot row%s: %s" % [" (refused)" if r.refused else "", "".join(r.cells.map(func(c): return c[0]))])
		b._open_table(b.ui("UI_PICK_WEAPON"), b.text_cells(b.msg_raw(0x1C5), []), srows, -2)
		for i in 4:
			await process_frame
		await RenderingServer.frame_post_draw
		root.get_viewport().get_texture().get_image().save_png(args[3])
		ok = ok and srows.size() == 6
	quit(0 if ok else 1)
