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


func check_m16(b) -> String:
	## the charges: five times the unit command on (0xE, 7) (20 AP, 了解) completes site 10
	## (DS:0x50AD6E bit 0), five on (0x1C, 0x24) site 11 (DS:0x50AD70); the withdraw then
	## gives 0x80
	var w: Pd2World = b.w
	if b.script_no != 16 or w.ds_506651 != 0x66:
		return "script %d / init" % b.script_no
	b.mission_over = false
	w.set_ds8(0x50ADF2, 0)
	for a in [0x50AD62, 0x50AD64, 0x50AD6E, 0x50AD70, 0x50AD72, 0x50AD74]:
		w.set_ds8(a, 0)
	var u: int = b.squad[0]
	for pos in [Vector2i(0xE, 7), Vector2i(0x1C, 0x24)]:
		for k in 254:                                 # no VTOL or transport in reach
			if k != u and w.on_map(w.sb(k, 9), w.sb(k, 10)) and absi(w.sb(k, 9) - pos.x) < 4 and absi(w.sb(k, 10) - pos.y) < 4:
				Action.take_off_map(w, k)
		place(w, u, pos.x, pos.y)
		for i in 5:
			w.setb(u, 0xE, 30)
			b._select(u)
			b._cmd_mission()
	if not w.ds8(0x50AD6E) & 1 or not w.ds8(0x50AD70) & 1:
		return "sites not charged (0x%X / 0x%X)" % [w.ds8(0x50AD6E), w.ds8(0x50AD70)]
	b._withdraw()
	if w.ds8(0x50ADF2) != 0x80:
		return "withdraw end code 0x%X" % w.ds8(0x50ADF2)
	return ""


func check_m17(b) -> String:
	## the tide: turn 17 -> 18 moves it to level 6 (rows 0x24-0x46 from MAP_CHG.PCK entry 6);
	## the three sites' charges going off set their flags, and the withdraw gives 0x80
	var w: Pd2World = b.w
	if b.script_no != 17 or w.ds_506651 != 0x30:
		return "script %d / init" % b.script_no
	if w.map_chg.size() < 9:
		return "no MAP_CHG.PCK in the import"
	b.mission_over = false
	w.set_ds8(0x50ADF2, 0)
	w.mission_turn = 17
	MissionScripts.run_turn(w, b.rng, 0, b.mission_hooks)
	if w.ds8(0x50AD7C) >> 1 & 0x1F != 6 or w.T[5 + 72 * 0x24] != w.map_chg[6][5]:
		return "tide not at level 6 (0x50AD7C 0x%X)" % w.ds8(0x50AD7C)
	for n in [1, 2, 3]:
		w.bombs[3] = n
		MissionScripts.run_bomb(w, b.rng, 0, b.mission_hooks)
	if not (w.ds8(0x50AD50) & 1 and w.ds8(0x50AD52) & 1 and w.ds8(0x50AD54) & 1):
		return "sites not blown"
	b._withdraw()
	if w.ds8(0x50ADF2) != 0x80:
		return "withdraw end code 0x%X" % w.ds8(0x50ADF2)
	return ""


func check_m18(b) -> String:
	## the crossing: the rescue group 19 landed with the squad on the map and no enemy in
	## the six zones gives 0x80 (the zone counters at DS:0x5242F0 all 0)
	var w: Pd2World = b.w
	if b.script_no != 18 or w.ds_506651 != 0x54:
		return "script %d / init" % b.script_no
	b.mission_over = false
	w.set_ds8(0x50ADF2, 0)
	w.set_ds8(0x50AD5A, 0)
	var u: int = b.squad[0]
	place(w, u, 30, 30)
	w.setb(u, 0xD, 100)
	w.setb(u, 0x36, 0)
	for z in MissionScripts.m18_zone_hexes():
		for h in z:
			var o: int = w.O[h.x + 72 * h.y] - 1
			if o >= 0 and w.sb(o, 0x36) == 3:
				Action.take_off_map(w, o)
	MissionScripts.set_g(w, 0x13, 2, MissionScripts.g(w, 0x13, 2) & 0xCF | 0x20)
	MissionScripts.run_turn(w, b.rng, 1, b.mission_hooks)
	if w.ds8(0x50ADF2) != 0x80:
		return "end code 0x%X" % w.ds8(0x50ADF2)
	return ""


func check_m20(b) -> String:
	## the dome: the east bulkhead shut from its hex (10 AP), the four sections' charges going
	## off (section 1's ruin from MAP_CHG.PCK entry 0xC, the shut bulkhead blown with it), then
	## the next turn's stage 1 gives 0x80
	var w: Pd2World = b.w
	if b.script_no != 20 or w.ds_506651 != 0x01:
		return "script %d / init" % b.script_no
	if w.map_chg.size() < 0xF:
		return "no MAP_CHG.PCK in the import"
	b.mission_over = false
	w.set_ds8(0x50ADF2, 0)
	var u: int = b.squad[0]
	for j in 5:
		var x := MissionScripts.static_s16(w, 0x51DD28 + 4 * j)
		var y := MissionScripts.static_s16(w, 0x51DD2A + 4 * j)
		var o: int = w.O[x + 72 * y] - 1
		if o >= 0:
			Action.take_off_map(w, o)
	place(w, u, 0x3A, 0x21)
	w.setb(u, 0xE, 20)
	w.set_ds8(0x50AD72, 0)
	MissionScripts.run_command(w, b.rng, u, b.mission_hooks)
	if w.ds8(0x50AD72) & 0x3E != 2 or w.ub(u, 0xE) != 10:
		return "bulkhead not shut (0x%X, %d AP)" % [w.ds8(0x50AD72), w.ub(u, 0xE)]
	for s in 4:
		w.set_ds8(0x50AD7C + 2 * s, 0)
		w.bombs[0] = 10
		w.bombs[1] = 10
		w.bombs[3] = 2 * s + 1
		MissionScripts.run_bomb(w, b.rng, 0, b.mission_hooks)
		if not w.ds8(0x50AD7C + 2 * s) & 0x3E:
			return "section %d not down" % (s + 1)
	var rec: PackedByteArray = w.map_chg[0xC]
	if w.T[rec[0] + 72 * rec[1]] != rec[2] or w.ds8(0x50AD72) & 0x3E != 4:
		return "section 1 ruin / the east bulkhead"
	MissionScripts.run_turn(w, b.rng, 1, b.mission_hooks)
	if w.ds8(0x50ADF2) != 0x80:
		return "end code 0x%X" % w.ds8(0x50ADF2)
	return ""


func check_m19(b) -> String:
	## the survey: the start hook makes machine 0x1F the captured helicopter (machine 0x1D's
	## record), building 2's charge going off breaks it (its tiles) and the withdraw at story
	## step 6 gives 0x80
	var w: Pd2World = b.w
	if b.script_no != 19 or w.ds_506651 != 0xF0:
		return "script %d / init" % b.script_no
	if w.map_chg.size() < 11:
		return "no MAP_CHG.PCK in the import"
	b.mission_over = false
	w.set_ds8(0x50ADF2, 0)
	MissionScripts.run_start(w, b.rng, b.mission_hooks)
	if w.machine(0x1F, 0) != 0x27 or w.machine(0x1F, 0x1A) != 0x18 or w.machine(0x1F, 1) != w.machine(0x1D, 1):
		return "machine 0x1F not the captured helicopter"
	w.bombs[3] = 2
	MissionScripts.run_bomb(w, b.rng, 0, b.mission_hooks)
	if not w.ds8(0x50AD52) & 1 or w.T[0x2E + 72] != 0xE9:
		return "building 2 not blown"
	w.set_ds8(0x50AD6E, 0xC)
	b._withdraw()
	if w.ds8(0x50ADF2) != 0x80:
		return "withdraw end code 0x%X" % w.ds8(0x50ADF2)
	return ""


func check_m21(b) -> String:
	## the base: gate 1's charge going off spends and marks it (tile 2), then with every gate
	## spent and no computer unit left the next turn ends it, 0x80 with the deal made
	var w: Pd2World = b.w
	if b.script_no != 21 or w.ds_506651 != 0x71:
		return "script %d / init" % b.script_no
	b.mission_over = false
	w.set_ds8(0x50ADF2, 0)
	w.bombs[3] = 1
	MissionScripts.run_bomb(w, b.rng, 0, b.mission_hooks)
	var p := MissionScripts.m21_gate(w, 0)
	if w.ds8(0x50AD50) & 0x3F != 0x3D or w.T[p.x + 72 * p.y] != 2:
		return "gate 1 not blown (0x%X)" % w.ds8(0x50AD50)
	for i in 16:
		w.set_ds8(0x50AD50 + 2 * i, 0x3D)
	for k in range(40, 216):
		w.setb(k, 0, w.ub(k, 0) & 0xF3)
	MissionScripts.ds_or(w, 0x50AD4E, 1)
	MissionScripts.ds_or(w, 0x50AD82, 1)
	MissionScripts.run_turn(w, b.rng, 2, b.mission_hooks)
	if w.ds8(0x50ADF2) != 0x80:
		return "end code 0x%X" % w.ds8(0x50ADF2)
	return ""


func check_m11(b) -> String:
	## the bridges: a charge going off on row 0x24 brings bridge A down (DS:0x50AD56 bit 7),
	## one on row 0x3A bridge B; the withdraw ends it (0x82 without the early breach)
	var w: Pd2World = b.w
	if b.script_no != 11 or w.ds_506651 != 0x47:
		return "script %d / init" % b.script_no
	b.mission_over = false
	w.set_ds8(0x50ADF2, 0)
	w.bombs[1] = 0x24
	MissionScripts.run_bomb(w, b.rng, 0, b.mission_hooks)
	w.bombs[1] = 0x3A
	MissionScripts.run_bomb(w, b.rng, 0, b.mission_hooks)
	if not w.ds8(0x50AD56) & 0x80 or not w.ds8(0x50AD57) & 0xF or not w.ds8(0x50AD5C) & 1:
		return "bridges not down (0x%X 0x%X)" % [w.ds8(0x50AD56), w.ds8(0x50AD57)]
	w.set_ds8(0x50AD60, 0)
	b._withdraw()
	if w.ds8(0x50ADF2) != 0x82:
		return "withdraw end code 0x%X" % w.ds8(0x50ADF2)
	return ""


func check_m22(b) -> String:
	## the rescue: searching building 1 (25 AP, its cell holding crew 5) finds the prisoner
	## (DS:0x50AD50 bit 0) and spends the AP; the withdraw then gives 0x82
	var w: Pd2World = b.w
	if b.script_no != 22 or w.ds_506651 != 0x60:
		return "script %d / init" % b.script_no
	b.mission_over = false
	w.set_ds8(0x50ADF2, 0)
	w.set_ds8(0x50AD50, 5 << 1)
	var pos := Vector2i(MissionScripts.static_s16(w, 0x51EA48), MissionScripts.static_s16(w, 0x51EA4A))
	var u: int = b.squad[0]
	for k in 254:                                     # no VTOL or transport in reach
		if k != u and w.on_map(w.sb(k, 9), w.sb(k, 10)) and absi(w.sb(k, 9) - pos.x) < 4 and absi(w.sb(k, 10) - pos.y) < 4:
			Action.take_off_map(w, k)
	place(w, u, pos.x, pos.y)
	w.setb(u, 0xE, 30)
	MissionScripts.run_command(w, b.rng, u, b.mission_hooks)
	if w.ds8(0x50AD50) != (5 << 1 | 1) or w.sb(u, 0xE) != 5:
		return "building 1 not searched (0x%X, %d AP)" % [w.ds8(0x50AD50), w.sb(u, 0xE)]
	b._withdraw()
	if w.ds8(0x50ADF2) != 0x82:
		return "withdraw end code 0x%X" % w.ds8(0x50ADF2)
	return ""


func check_m13(b) -> String:
	## the exercise: the first call puts the infiltrator 0x2F and its carrier 0x2E in group
	## 19 (DS:0x50AD4E bit 0); the clock's twelfth turn (stage 0) runs out: 0x12E, 0x82
	var w: Pd2World = b.w
	if b.script_no != 13:
		return "script %d" % b.script_no
	b.mission_over = false
	w.set_ds8(0x50ADF2, 0)
	if not w.ds8(0x50AD4E) & 1:
		MissionScripts.run_turn(w, b.rng, 2, b.mission_hooks)
	if not w.ds8(0x50AD4E) & 1 or MissionScripts.g(w, 0x13, 6) != 0x2E or MissionScripts.g(w, 0x13, 7) != 0x2F:
		return "first call (0x%X, group 19 %d / %d)" % [w.ds8(0x50AD4E), MissionScripts.g(w, 0x13, 6), MissionScripts.g(w, 0x13, 7)]
	w.set_ds8(0x50AD4E, 1 | 11 << 1)
	for a in [0x50AD6E, 0x50AD72, 0x50AD7A]:
		w.set_ds8(a, 0)
	MissionScripts.run_turn(w, b.rng, 0, b.mission_hooks)
	if w.ds8(0x50ADF2) != 0x82 or w.ds8(0x50AD4E) >> 1 & 0x1F != 12:
		return "time out: end code 0x%X, clock %d" % [w.ds8(0x50ADF2), w.ds8(0x50AD4E) >> 1 & 0x1F]
	return ""
