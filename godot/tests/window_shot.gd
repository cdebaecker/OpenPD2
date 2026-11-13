extends SceneTree
## The game's windows over a battle, saved as a picture: godot --path engine/godot -s
## tests/window_shot.gd -- pd2 0 out.png prompt|box|line|select|status|menu|weapon|reaction|command|units|arms [ja|en|fr]
##   prompt: the move's question 0x1DC at the cursor (0x47EBE0); box: the mine's 0x1A3
##   (ui_message_box, kind 0); line: 0x1AE (ui_message_line) with its click wait lit;
##   select: a select window with 12 items (the scroll bar), the second outlined;
##   weapon: the first DoLL's weapon picker in mode 0 (0x4E7EE0) with 3 AP;
##   reaction: the reaction menu (0x4730E0) for three DoLLs;
##   command: the first DoLL's command menu (0x4EE8D0);
##   menu: the first DoLL's slot menu at the cursor (0x427530);
##   status: the machine status window (0x4E8930 / 0x467880) of the first active DoLL.

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
		"status":
			var u: int = b.squad[0]
			for k in b.squad:
				if b.w.active(k):
					u = k
					break
			b.w.setb(u, 1, (b.w.ub(u, 1) & 0xF0) | 0x01 | 0x08)      # head outlined, a gear filled
			gw = b.open_status(u, load("res://ui/status_view.gd").rows(b, u))
			gw._hover = 0
		"menu":
			var u: int = b.squad[0]
			var opts := []
			for e in load("res://core/pockets.gd").slot_menu(b.w, u, 0, false):
				opts.append(b.pocket_action_text(e[0], e[1]))
			gw = b.open_menu(opts)
			gw._hover = 0
		"weapon":
			var u: int = b.squad[0]
			b.w.setb(u, 0xE, 3)                               # short of AP: the AP column refused
			gw = b.open_weapon_picker(u, 0, 0)
			gw._hover = 0
		"reaction":
			var e := -1
			for k in b.w.n_units:
				if b.w.is_enemy(k) and b.w.active(k):
					e = k
					break
			b._show_reaction_units(b.squad.slice(0, 3), e, 5)
			gw = b.react_panel.get_child(0)
			gw._hover = 2
		"units":
			var u0: int = b.squad[0]
			b.info_panel.readouts(b.w.pos(u0).x, b.w.pos(u0).y, u0)      # (the hover's read-outs)
			b._units_list()
			gw = b.win_root.get_child(b.win_root.get_child_count() - 1).get_child(0)
			gw._hover = 1
		"arms":
			b._arms_list(1)
			gw = b.win_root.get_child(b.win_root.get_child_count() - 1).get_child(0)
			gw._hover = 0
		"command":
			var u: int = b.squad[0]
			b.open_command_menu(u)
			gw = b.win_root.get_child(b.win_root.get_child_count() - 1).get_child(0)
			gw._hover = 3
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
