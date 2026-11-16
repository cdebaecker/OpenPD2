extends SceneTree
## The armament screen's debug menu (0x4595F0: region 0x12 with Ctrl + Alt held) through the
## battle's windows: the crew list, its first pilot, every question answered yes (scripted
## answers), then a right click. The pilot ends with the four skills (+8 bits 0-3), back
## (+6 bits 0-1 clear) and available now (+4 = 0 when it was later than the step).

func _init() -> void:
	await process_frame
	var gd = root.get_node("GameData")
	var w0 := Mission.build(gd.tables("pd2"), gd.mission("pd2", 0), "pd2", gd.save_image("pd2"),
			Campaign.Hooks.new(), Campaign.CrtRand.new(7), true)
	Debrief.mission_exit(w0, 0x80)
	Debrief.debrief(w0, 0x80, Pd2Random.new(0), Campaign.CrtRand.new(7), Debrief.Hooks.new())
	var b = load("res://ui/battle.tscn").instantiate()
	b.carry = {"image": Debrief.save_image(w0), "script": w0.script_no, "stash": w0.stash}
	b.campaign = "pd2"
	b.mission_index = Debrief.chunk(w0) - 1
	b.plan_window = false
	root.add_child(b)
	for i in 5:
		await process_frame
	var w: Pd2World = b.w
	var ok: bool = b.sortie_panel != null
	b._equip_begin(w.ds[2])
	var rows: Array = Equipment.debug_crew_list(w)
	ok = ok and not rows.is_empty()
	var c: int = rows[0][0]
	w.crew[16 * c + 6] = w.crew[16 * c + 6] | 1           # (injured: the first question comes)
	w.crew[16 * c + 4] = 12 if w.ds16(0x50AD92) < 12 else w.crew[16 * c + 4]   # (0xF: unlisted)
	ok = ok and Equipment.debug_crew_list(w)[0][0] == c
	var later := w.ds16(0x50AD92) < w.crew[16 * c + 4]
	var answers := [0, 0, 1, 1]
	if later:
		answers.append_array([1, 0])
	answers.append(-2)
	b.scripted = answers
	b._equip_debug()
	for i in 200:
		await process_frame
		if b.debug_thread == null:
			break
	var f6: int = w.crew[16 * c + 6]
	var f8: int = w.crew[16 * c + 8]
	var f4: int = w.crew[16 * c + 4]
	print("pilot %d: +6 0x%X, +8 0x%X, +4 %d" % [c, f6, f8, f4])
	ok = ok and b.debug_thread == null and f6 & 3 == 0 and f8 & 0xF == 0xF and (f4 == 0 or not later)
	ok = ok and not b.equip_sess.is_empty()
	# an abort (the menu's -12: -102) closes the armament screen, as 0x454E60 returns it
	b.scripted = [-12]
	b._equip_debug()
	for i in 200:
		await process_frame
		if b.debug_thread == null:
			break
	print("after the abort: screen %s" % ("open" if not b.equip_sess.is_empty() else "closed"))
	ok = ok and b.equip_sess.is_empty()
	print("debug menu: %s" % ("ok" if ok else "FAILED"))
	quit(0 if ok else 1)
