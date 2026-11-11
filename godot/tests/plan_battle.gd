extends SceneTree
## The mission start's flow (0x416CF0): the mission load, the briefing (0x4DD2F0: the
## SCN_MIS record and the mission's init), the operation plan (0x443F60) with its pages and
## orders driven through the panel's buttons, done, then the sortie screen, and its start
## (DS:0x50AD94 and the mission turn cleared). godot --headless --path engine/godot -s
## tests/plan_battle.gd


func buttons(n: Node, out: Array) -> Array:
	if n is Button:
		out.append(n)
	for c in n.get_children():
		buttons(c, out)
	return out


func press(b: Node, text: String) -> bool:
	for btn in buttons(b.plan_panel, []):
		if btn.text == text and not btn.disabled and not btn.is_queued_for_deletion():
			btn.pressed.emit()
			return true
	print("  no button '%s'" % text)
	return false


func _init() -> void:
	await process_frame
	var ok := true
	var b = load("res://ui/battle.tscn").instantiate()
	b.campaign = "pd2"
	b.mission_index = 1                   # PD2 mission 2 (script 2): types 0-3 for groups 0-5
	root.add_child(b)
	for i in 5:
		await process_frame
	var w: Pd2World = b.w
	var doc: Dictionary = root.get_node("/root/GameData").mission("pd2", 1)
	# the briefing: the record loaded, the mission's init run (m02_init), the loop's state
	var brief: bool = w.scenario == doc.record.slice(0, 0x1C6) and b.brief_code == 0 and w.mode_663a == 0
	print("briefing: record %s, code %d" % [str(w.scenario == doc.record.slice(0, 0x1C6)), b.brief_code])
	ok = ok and brief
	# the plan is up, the sortie not yet
	var up: bool = b.plan_panel != null and b.sortie_panel == null
	print("plan up before the sortie: %s" % str(up))
	ok = ok and up
	# its pages: each of A-D has lines (the mission's hooks, MES 0x121 ..)
	for k in 4:
		var lines: Array = Plan.page(w, k)
		var text := ""
		for it in lines:
			if it[0] >= 0:
				text += b.plan_line(it)
		print("page %d: %d lines, %d chars" % [k, lines.size(), text.length()])
		ok = ok and lines.size() > 0 and text.length() > 0
		ok = ok and press(b, b.plan_exe(Plan.PAGE_TITLES[k]))
	# the orders: group 0 to type 1 (kind 2, a site), then its site; type 0 (kind 1), a direction
	ok = ok and press(b, b.plan_exe(Plan.ORDERS_TITLE))
	var names: Array = b.plan_choices(Plan.TYPE_NAMES)
	ok = ok and press(b, b.ui("UI_PLAN_TYPE"))
	ok = ok and press(b, names[w.scenario[Plan.entry(1)]])
	var e1 := Plan.entry(1)
	var sites := Plan.sites(w, Plan.SITES_A)
	var t_ok: bool = Flight.gb(w, 0, 0x21) == ((w.scenario[e1 + 0x1B] << 4) | 1) and \
		Flight.gb(w, 0, 0x1D) == w.scenario[e1 + 0x16] and \
		(sites.is_empty() or Flight.gb(w, 0, 0x1F) == sites[0])
	print("type 1: +0x21 0x%X, +0x1D %d, +0x1F %d (sites %s)" % [Flight.gb(w, 0, 0x21), Flight.gb(w, 0, 0x1D),
		Flight.gb(w, 0, 0x1F), str(sites)])
	ok = ok and t_ok
	if sites.size() > 1:
		var site_names: Array = b.plan_choices(Plan.SITE_NAMES)
		ok = ok and press(b, b.ui("UI_PLAN_TARGET"))
		ok = ok and press(b, site_names[sites[1]])
		ok = ok and press(b, b.ui("UI_YES"))
		print("site: +0x1F %d want %d" % [Flight.gb(w, 0, 0x1F), sites[1]])
		ok = ok and Flight.gb(w, 0, 0x1F) == sites[1]
	ok = ok and press(b, b.ui("UI_PLAN_TYPE"))
	ok = ok and press(b, names[w.scenario[Plan.entry(0)]])
	ok = ok and press(b, b.ui("UI_PLAN_TARGET"))
	var dirs: Array = b.plan_choices(Plan.DIRECTIONS)
	ok = ok and press(b, dirs[3].strip_edges())
	print("type 0: +0x21 0x%X, direction +0x1F %d" % [Flight.gb(w, 0, 0x21), Flight.gb(w, 0, 0x1F)])
	ok = ok and Flight.gb(w, 0, 0x21) & 15 == 0 and Flight.gb(w, 0, 0x1F) == 3
	# the time: the type's second time
	ok = ok and press(b, b.ui("UI_PLAN_TIME"))
	var tt := Plan.times(w, 0)
	ok = ok and press(b, b.plan_time(tt[0] + 1))
	print("time: +0x1D %d want %d" % [Flight.gb(w, 0, 0x1D), tt[0] + 1])
	ok = ok and Flight.gb(w, 0, 0x1D) == tt[0] + 1
	# leave the orders: mission 2's objective (0x10A while no group 0 / 2 / 4 has type 2 or 3)
	ok = ok and press(b, b.ui("UI_PLAN_LEAVE"))
	var m := Plan.objective(w)
	if m >= 0:
		var labels: Array = b.plan_choices(Plan.OBJECTIVE_BUTTONS)
		print("objective 0x%X asked: %s" % [m, b.mes(m + 0x20).left(40)])
		ok = ok and press(b, labels[0])
	ok = ok and b.plan_st.mode == "page"
	ok = ok and press(b, b.plan_exe(Plan.LIST_TITLE))
	ok = ok and press(b, b.ui("UI_PLAN_DONE"))
	for i in 3:
		await process_frame
	var sortie_up: bool = b.plan_panel == null and b.sortie_panel != null
	print("done: the sortie screen up %s" % str(sortie_up))
	ok = ok and sortie_up
	# the sortie's start (0x416CF0's round with the sortie's 0)
	var r := Plan.pre_battle_round(w, b.brief_code, b.plan_code, 0)
	print("round: %s, DS:0x50AD94 %d" % [str(r), w.ds8(0x50AD94)])
	ok = ok and r == [0x80, true, true] and w.ds8(0x50AD94) == 0 and w.mission_turn == 0
	print("plan flow: %s" % ("ok" if ok else "FAILED"))
	quit(0 if ok else 1)
