extends SceneTree
## The debrief's screens (ui/debrief_view.gd) as pictures: godot --path engine/godot -s
## tests/debrief_shot.gd -- pd2 out_prefix [ja|en|fr]
## PD2 mission 1 withdrawn (its scenario hook clears it): the debrief runs; its first
## screens are saved as <prefix>_1.png (the picture), _2.png (its text), _3.png (the second
## text), _4.png (the results), each after a click.

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	await process_frame
	if args.size() > 2:
		root.get_node("GameData").language = args[2]
	var b = load("res://ui/battle.tscn").instantiate()
	b.campaign = args[0]
	b.mission_index = 0
	b.sortie_window = false
	root.add_child(b)
	for i in 10:
		await process_frame
	b._withdraw()
	var dv = null
	for i in 200:
		await process_frame
		for c in b.win_root.get_children() if b.win_root else []:
			if c.has_method("play"):
				dv = c
		if dv:
			break
	if dv == null:
		print("no debrief view")
		quit(1)
		return
	for k in 4:
		for i in 20:
			await process_frame
		await RenderingServer.frame_post_draw
		root.get_viewport().get_texture().get_image().save_png("%s_%d.png" % [args[1], k + 1])
		var waiting = null
		for c in dv.get_children():
			if c.has_method("outside") and c._waiting:
				waiting = c
		if waiting:
			waiting.outside(MOUSE_BUTTON_LEFT)
			for i in 5:
				await process_frame
		dv._go = true
	quit(0)
