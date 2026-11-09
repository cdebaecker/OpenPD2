extends SceneTree
## Render the sandbox battle and save a screenshot: godot --path engine/godot -s tests/screenshot.gd -- dash 1 out.png

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var camp: String = args[0] if args.size() > 0 else "dash"
	var m := int(args[1]) if args.size() > 1 else 0
	var out: String = args[2] if args.size() > 2 else "user://shot.png"
	await process_frame
	var b = load("res://ui/battle.tscn").instantiate()
	b.campaign = camp
	b.mission_index = m
	b.auto_react = true
	root.add_child(b)
	for i in 10:
		await process_frame
	if args.size() > 3:
		b._end_turn()
		for i in 5:
			await process_frame
	await RenderingServer.frame_post_draw
	root.get_viewport().get_texture().get_image().save_png(out)
	print("saved ", out)
	quit(0)
