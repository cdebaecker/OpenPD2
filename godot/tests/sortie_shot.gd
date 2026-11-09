extends SceneTree
## Render the sortie screen before a battle and save it: godot --path engine/godot -s
## tests/sortie_shot.gd -- dash 0 out.png [group to select]

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	await process_frame
	var b = load("res://ui/battle.tscn").instantiate()
	b.campaign = args[0]
	b.mission_index = int(args[1])
	root.add_child(b)
	for i in 10:
		await process_frame
	if args.size() > 3:
		b.sortie_sel = int(args[3])
		b._sortie_draw()
		for i in 5:
			await process_frame
	await RenderingServer.frame_post_draw
	root.get_viewport().get_texture().get_image().save_png(args[2])
	quit(0)
