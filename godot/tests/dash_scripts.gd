extends SceneTree
## The DASH campaign's mission scripts in the battle (MissionScripts, run by ui/battle.gd):
## each ported mission is built, its load / init / start scripts run, then a scripted
## path through its own events to an end code. Run one with `-- m12` (DASH chunk 1 =
## script 12).
##   godot --headless --path engine/godot -s tests/dash_scripts.gd [-- m12 ...]

var failed := 0


func _init() -> void:
	await process_frame
	var only := OS.get_cmdline_user_args()
	for script in range(11, 23):
		var name := "m%02d" % script
		if not only.is_empty() and not name in only:
			continue
		if not MissionScripts.has_scripts(script):
			print("%s: not ported" % name)
			continue
		if not has_method("check_" + name):
			print("%s: no check" % name)
			continue
		var b = load("res://ui/battle.tscn").instantiate()
		b.campaign = "dash"
		b.mission_index = script - 11
		b.auto_react = true
		root.add_child(b)
		await process_frame
		var err: String = call("check_" + name, b)
		print("%s: %s" % [name, "ok" if err == "" else err])
		if err != "":
			failed += 1
		b.queue_free()
		await process_frame
	quit(1 if failed else 0)


static func place(w: Pd2World, u: int, x: int, y: int) -> void:
	var p := w.pos(u)
	if w.on_map(p.x, p.y) and w.O[p.x + 72 * p.y] == u + 1:
		w.O[p.x + 72 * p.y] = 0
	w.setb(u, 9, x)
	w.setb(u, 10, y)
	w.setb(u, 0, w.ub(u, 0) | 0xC)
	w.O[x + 72 * y] = u + 1


func check_m12(b) -> String:
	## the sappers: site 1's charge laid (DS:0x50AD50 stage 1, fuse 1) goes off after the
	## player's turn (live blast: the site's tiles, stage 2); then the enemy's retreat past
	## its sixth turn with player units on the map wins (DS:0x50AD81 nibble 1, 0x80)
	var w: Pd2World = b.w
	if b.script_no != 12 or w.ds_506651 != 0x36:
		return "script %d / init" % b.script_no
	if not w.ds8(0x50AD4E) & 1:
		return "first call not run"
	b.mission_over = false
	w.set_ds8(0x50ADF2, 0)
	w.set_ds8(0x50AD76, 0)
	w.set_ds8(0x50AD50, 2)
	w.set_ds8(0x50AD51, 1)
	MissionScripts.run_turn(w, b.rng, 1, b.mission_hooks)
	if w.fault != "":
		return "fault %s" % w.fault
	var x := MissionScripts.static_s16(w, 0x51C128)
	var y := MissionScripts.static_s16(w, 0x51C12A)
	if w.ds8(0x50AD50) >> 1 & 0x1F != 2 or w.T[x + 72 * y] != MissionScripts.static_s16(w, 0x51C308) & 0xFF:
		return "site 1 not blown (0x50AD50 0x%X)" % w.ds8(0x50AD50)
	w.set_ds8(0x50ADF2, 0)
	w.set_ds8(0x50AD76, 0x0D)
	MissionScripts.run_turn(w, b.rng, 1, b.mission_hooks)
	if w.ds8(0x50ADF2) != 0x80 or w.ds8(0x50AD81) & 0xF != 1:
		return "end code 0x%X" % w.ds8(0x50ADF2)
	return ""


func check_m14(b) -> String:
	## the reserve: past turn 15 with nobody lost, five waiting crews (+4 = 3) are called up
	## into groups 2-5 (DS:0x50AD8C bit 0); then the enemy's retreat past its sixth turn with
	## group 0 on the map wins (0x80)
	var w: Pd2World = b.w
	if b.script_no != 14 or w.ds_506651 != 0x5A:
		return "script %d / init" % b.script_no
	b.mission_over = false
	w.set_ds8(0x50ADF2, 0)
	w.set_ds8(0x50AD8C, 0)
	w.set_ds8(0x50AD76, 0)
	w.mission_turn = 15
	for k in 254:
		if w.sb(k, 0x36) < 3 and w.ub(k, 0) & 8 and (w.ub(k, 0xD) == 0 or w.ub(k, 0) & 1):
			w.setb(k, 0, w.ub(k, 0) & 0xF7)
	var u: int = b.squad[0]
	place(w, u, 20, 20)
	w.setb(u, 0xD, 100)
	w.setb(u, 0x36, 0)
	MissionScripts.set_g(w, 0, 6, u)
	MissionScripts.set_g(w, 0, 5, 1)
	var waiting := [40, 41, 42, 43, 44]
	for i in waiting.size():
		var q: int = waiting[i] * Pd2World.CREW
		w.crew[q + 4] = 3
		w.crew[q + 2] = 0
		w.crew[q + 3] = 1 if i >= 3 else 0
	for c in 64:
		if not c in waiting and w.crew[c * Pd2World.CREW + 4] == 3:
			w.crew[c * Pd2World.CREW + 4] = 0
	MissionScripts.run_turn(w, b.rng, 0, b.mission_hooks)
	if not w.ds8(0x50AD8C) & 1 or MissionScripts.g(w, 2, 5) != 3 or MissionScripts.g(w, 3, 5) != 2:
		return "reserve not called up (0x50AD8C 0x%X, groups 2 / 3: %d / %d)" % [w.ds8(0x50AD8C), MissionScripts.g(w, 2, 5), MissionScripts.g(w, 3, 5)]
	w.set_ds8(0x50AD76, 0x0D)
	MissionScripts.run_turn(w, b.rng, 1, b.mission_hooks)
	if w.ds8(0x50ADF2) != 0x80:
		return "end code 0x%X" % w.ds8(0x50ADF2)
	return ""


func check_m15(b) -> String:
	## the escorts: the unit command off the gates (10 AP, 了解) calls them (DS:0x50AD68 bit
	## 0, units 27-30 +0x36 = 0); the four of them reaching column 1 leave the map (bits
	## 1-5 count 4) and the end code is 0x80
	var w: Pd2World = b.w
	if b.script_no != 15 or w.ds_506651 != 0x54:
		return "script %d / init" % b.script_no
	if not w.ds8(0x50AD4E) & 1:
		return "first call not run"
	b.mission_over = false
	w.set_ds8(0x50ADF2, 0)
	w.set_ds8(0x50AD68, 0)
	var u: int = b.squad[0]
	place(w, u, 30, 30)
	w.setb(u, 0xE, 30)
	b._select(u)
	b._cmd_mission()
	if not w.ds8(0x50AD68) & 1 or w.ub(27, 0x36) != 0:
		return "escorts not called (0x50AD68 0x%X)" % w.ds8(0x50AD68)
	for k in range(27, 31):
		place(w, k, 1, 10 + 2 * (k - 27))
	MissionScripts.run_turn(w, b.rng, 1, b.mission_hooks)
	if w.ds8(0x50AD68) & 0x3E != 8 or w.ds8(0x50ADF2) != 0x80:
		return "end code 0x%X (escorts %d)" % [w.ds8(0x50ADF2), w.ds8(0x50AD68) >> 1 & 0x1F]
	return ""
