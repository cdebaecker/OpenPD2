extends SceneTree
## The game's windows over a battle, saved as a picture: godot --path engine/godot -s
## tests/window_shot.gd -- pd2 0 out.png prompt|box|line|select [ja|en|fr]
##   prompt: the move's question 0x1DC at the cursor (0x47EBE0); box: the mine's 0x1A3
##   (ui_message_box, kind 0); line: 0x1AE (ui_message_line) with its click wait lit;
##   select: a select window with 12 items (the scroll bar), the second outlined.

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	await process_frame
	if args.size() > 4:
		root.get_node("GameData").language = args[4]
	var b = load("res://ui/battle.tscn").instantiate()
	b.campaign = args[0]
	b.mission_index = int(args[1])
	b.sortie_window = false
	root.add_child(b)
	for i in 5:
		await process_frame
	b.cursor_override = Vector2(260, 220)
	var gw
	match args[3]:
		"prompt":
			gw = b.open_prompt(b.msg(0x1DC, [12, 30, 20]))
			gw._hover = 0
		"box":
			b._open_choice(b.msg(0x1A3), [[root.get_node("GameData").exe_text(b.campaign, 0x510444), true],
					[root.get_node("GameData").exe_text(b.campaign, 0x51044C), false]], "box")
			gw = b.react_panel.get_child(1)
			gw._hover = 0
		"line":
			b.show_line(b.msg(0x1AE, [12]))
			gw = b._line_open.get_child(0)
			gw.waits = true
			gw.print_text("\n")
			gw._waiting = true
			gw._bar = true
		"select":
			var labels := []
			for i in 12:
				labels.append("%s %d" % [root.get_node("GameData").exe_text(b.campaign, 0x514008), i + 1])
			gw = b.open_select(b.ui("UI_PICK_WEAPON"), labels, true)
			gw._hover = 1
	gw.set_process(false)
	gw.queue_redraw()
	for i in 5:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_viewport().get_texture().get_image().save_png(args[2])
	quit(0)
