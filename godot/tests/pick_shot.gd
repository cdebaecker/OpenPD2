extends SceneTree
## The new campaign's pilot choice (0x422050) as a picture: godot --path engine/godot -s
## tests/pick_shot.gd -- pd2|dash out.png [ja|en|fr]
## The campaign's first mission starts with the choice (not headless, the windows up); the
## first row is picked (its question answered yes), the picture taken, then the rest filled
## at random (a right click, yes) so the battle goes on. Exits 1 when no window came up.

func _win(b):
	for _n in 400:
		await process_frame
		var h = b.react_panel
		if h != null and is_instance_valid(h) and not h.is_queued_for_deletion():
			var ws: Array = h.get_children().filter(func(n): return n.has_method("answer"))
			if not ws.is_empty():
				return ws[-1]
	return null


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	await process_frame
	if args.size() > 2:
		root.get_node("GameData").language = args[2]
	var b = load("res://ui/battle.tscn").instantiate()
	b.campaign = args[0]
	b.mission_index = 0
	root.add_child(b)
	var gw = await _win(b)
	if gw == null:
		quit(1)
		return
	gw.answer(9)                                   # the first row
	var box = await _win(b)
	box.answer(0)                                  # "choose this member": yes
	gw = await _win(b)
	gw._hover = 3
	gw.queue_redraw()
	for i in 5:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_viewport().get_texture().get_image().save_png(args[1])
	gw.answer(-2)                                  # done / fill at random
	box = await _win(b)
	box.answer(0)
	for i in 30:
		await process_frame
	quit(0)
