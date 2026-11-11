extends SceneTree
## The PD2 campaign's mission scripts in the battle (MissionScripts, run by ui/battle.gd):
## each ported mission is built, its load / init / start scripts run, then a scripted
## path through its own events to an end code. Run one with `-- m02` (PD2 chunk 1 =
## script 2).
##   godot --headless --path engine/godot -s tests/pd2_scripts.gd [-- m02 ...]

var failed := 0


func _init() -> void:
	await process_frame
	var only := OS.get_cmdline_user_args()
	for script in range(2, 11):
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
		b.campaign = "pd2"
		b.mission_index = script - 1
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


## a pocket of u holding n explosives (round 12, warhead 13)
static func arm(w: Pd2World, u: int, n: int) -> int:
	w.setb(u, 0x1B, 0xC)
	w.setb(u, 0x1C, n)
	return 0


func check_m02(b) -> String:
	## the bridges: three charges on bridge 0's points (the bomb rule 0x49C2F0), the turn
	## script's "blow it?" (0xA8) in the computer's turn, the bridge's tiles broken, then
	## the withdraw's end code 0x83 (one bridge of two)
	var w: Pd2World = b.w
	if b.script_no != 2:
		return "script %d" % b.script_no
	if w.ds16(0x50AD95) != 8 or w.ds16(0x50AD97) != 7:
		return "init: camera (%d, %d)" % [w.ds16(0x50AD95), w.ds16(0x50AD97)]
	for i in 0x80:
		if w.mem8(0x51A1E8 + i) != w.mem8(0x51A268 + i):
			return "load: bridge hexes not copied"
	if b.squad.is_empty():
		return "no squad"
	var u: int = b.squad[0]
	arm(w, u, 5)
	for i in 3:
		var x := MissionScripts.static_s16(w, MissionScripts.M02_POINTS + 4 * i)
		var y := MissionScripts.static_s16(w, MissionScripts.M02_POINTS + 4 * i + 2)
		place(w, u, x, y)
		w.setb(u, 0xE, 40)
		b._select(u)
		b._cmd_explosives()
		if w.ds8(0x50AD51 + 2 * i) & 0xF != 1:
			return "charge %d not set (state 0x%X, AP %d)" % [i, w.ds8(0x50AD51 + 2 * i), w.sb(u, 0xE)]
	var laid := 0
	for i in 15:
		if w.bombs[4 * i + 3] in [1, 2, 3] and w.bombs[4 * i + 2] == 0xFF:
			laid += 1
	if laid != 3:
		return "bomb list: %d charges" % laid
	var hx := MissionScripts.static_s16(w, 0x51A1E8)
	var hy := MissionScripts.static_s16(w, 0x51A1EA)
	var want_t := MissionScripts.static_s16(w, 0x51A2E8)
	place(w, u, 30, 30)
	b._end_turn()
	if not w.ds8(0x50AD78) & 0x40:
		return "bridge 0 not blown (0x50AD78 = 0x%X)" % w.ds8(0x50AD78)
	if w.T[hx + 72 * hy] != want_t:
		return "bridge tile (%d, %d) = %d, want %d" % [hx, hy, w.T[hx + 72 * hy], want_t]
	if b.mission_over:
		return "the mission ended in the computer's turn (0x%X)" % w.ds8(0x50ADF2)
	b._withdraw()
	if w.ds8(0x50ADF2) != 0x83:
		return "withdraw end code 0x%X, want 0x83" % w.ds8(0x50ADF2)
	return ""


func check_m03(b) -> String:
	## the capture: the search (entry 11) on the target hex (0x33, 0x35), an escape from an
	## exit hex (DS:0x51A418) in the turn script's stage 1, then the withdraw's end code 0x80
	var w: Pd2World = b.w
	if b.script_no != 3:
		return "script %d" % b.script_no
	if w.ds16(0x50AD95) != 5 or w.ds16(0x50AD97) != 0xD or w.ds_506651 != 0xA8:
		return "init"
	for i in 0x38:
		if w.mem8(0x51A418 + i) != w.mem8(0x51A450 + i):
			return "load: exits not copied"
	if b.squad.size() < 2:
		return "squad %d" % b.squad.size()
	var u: int = b.squad[0]
	place(w, u, 0x33, 0x35)
	w.setb(u, 0xE, 30)
	b._select(u)
	b._cmd_mission()
	if not w.ds8(0x50AD7A) & 1 or w.sb(u, 0xE) != 10:
		return "search: flag 0x%X, AP %d" % [w.ds8(0x50AD7A), w.sb(u, 0xE)]
	var c: int = b.squad[1]
	var ex := Vector2i(MissionScripts.static_s16(w, 0x51A418), MissionScripts.static_s16(w, 0x51A41A))
	place(w, c, ex.x, ex.y)
	w.setb(c, 0x34, 0xFF)
	b._end_turn()
	if w.sb(c, 9) != -1:
		return "no escape from %s" % ex
	if b.mission_over:
		return "ended in the turn (0x%X)" % w.ds8(0x50ADF2)
	b._withdraw()
	if w.ds8(0x50ADF2) != 0x80:
		return "withdraw end code 0x%X, want 0x80" % w.ds8(0x50ADF2)
	return ""


func check_m04(b) -> String:
	## a demolition: a charge on site 1 (0x3E, 0x36) with the bomb rule's hook byte 1 and a
	## one-turn fuse goes off at the next turn start, the bomb hook breaks the site's hexes
	## (DS:0x50AD50 bit 0); the withdraw gives 0x82
	var w: Pd2World = b.w
	if b.script_no != 4:
		return "script %d" % b.script_no
	if w.ds16(0x50AD95) != 7 or w.ds_506651 != 0x84:
		return "init"
	var u: int = b.squad[0]
	arm(w, u, 3)
	place(w, u, 0x3E, 0x36)
	w.setb(u, 0xE, 40)
	b._select(u)
	b._cmd_explosives()
	var laid := -1
	for i in 15:
		if w.bombs[4 * i + 3] == 1 and w.bombs[4 * i + 2] == 1:
			laid = i
	if laid == -1:
		return "no charge laid on site 1"
	place(w, u, 30, 30)
	b._end_turn()
	if not w.ds8(0x50AD50) & 1:
		return "site 1 not broken (0x50AD50 0x%X, bomb x %d)" % [w.ds8(0x50AD50), w.bombs[4 * laid]]
	var t0 := MissionScripts.static_s16(w, 0x51A560)
	var t1 := MissionScripts.static_s16(w, 0x51A562)
	if w.H[t0 + 72 * t1] != 0x1E:
		return "site 1 hex (%d, %d) H %d" % [t0, t1, w.H[t0 + 72 * t1]]
	b._withdraw()
	if w.ds8(0x50ADF2) != 0x82:
		return "withdraw end code 0x%X" % w.ds8(0x50ADF2)
	return ""


func check_m05(b) -> String:
	## the sweep: with every computer unit taken out of rows 15-51 the turn script's stage 1
	## ends the mission with 0x80
	var w: Pd2World = b.w
	if b.script_no != 5 or w.ds_506651 != 0x73:
		return "script %d / init" % b.script_no
	for k in w.n_units:
		if w.is_enemy(k) and w.ub(k, 9) != 0xFF and w.sb(k, 10) > 0xE and w.sb(k, 10) < 0x34:
			w.setb(k, 0, w.ub(k, 0) | 1)
	b._end_turn()
	if w.ds8(0x50ADF2) != 0x80 and b.debrief_result == -1:
		return "end code 0x%X" % w.ds8(0x50ADF2)
	return ""


func check_m06(b) -> String:
	## the escort: with 8 taken along (DS:0x50AD6F), a player unit past column 0x44 is asked
	## to leave (0xA6) in stage 1 and leaves, the result nibble (DS:0x50AD71) becomes 2; the
	## withdraw gives 0x80
	var w: Pd2World = b.w
	if b.script_no != 6 or w.ds_506651 != 0xA9:
		return "script %d / init" % b.script_no
	var u: int = b.squad[0]
	place(w, u, 0x45, 30)
	w.set_ds8(0x50AD6F, 8)
	b._end_turn()
	if w.sb(u, 9) != -1:
		return "the unit past column 0x44 did not leave"
	if w.ds8(0x50AD71) & 0xF != 2:
		return "result 0x%X" % w.ds8(0x50AD71)
	if not b.mission_over:
		b._withdraw()
	if w.ds8(0x50ADF2) != 0x80:
		return "end code 0x%X" % w.ds8(0x50ADF2)
	return ""


func check_m07(b) -> String:
	## the search: with the other set noted first (DS:0x50AD6E bit 7) and points 0-3
	## searched, the search on point 4 finds the target (0xA1, bit 0, the finder's crew);
	## the menu's label changes; the withdraw gives 0x83 (the finder not aboard)
	var w: Pd2World = b.w
	if b.script_no != 7 or w.ds_506651 != 0x3B:
		return "script %d / init" % b.script_no
	if MissionScripts.run_menu(w, 0)[1] != 0x51AB38:
		return "menu label"
	# the automatic sortie forms no rescue group 12, so the turn script ended the mission at
	# its first call (no group 12): give it a member and go on
	MissionScripts.set_g(w, 12, 5, 1)
	b.mission_over = false
	w.set_ds8(0x50ADF2, 0)
	w.set_ds8(0x50AD6E, 0x80)
	for j in 4:
		var a := MissionScripts._m07_flag(w, j)
		w.mem_write(a, w.mem8(a) | 1)
	var u: int = b.squad[0]
	place(w, u, MissionScripts.static_s16(w, 0x51A828 + 16), MissionScripts.static_s16(w, 0x51A82A + 16))
	w.setb(u, 0xE, 30)
	b._select(u)
	b._cmd_mission()
	if not w.ds8(0x50AD6E) & 1 or w.ds8(0x50AD6E) >> 1 & 0x1F != w.ub(u, 0xB) & 0x1F:
		return "target not found (0x50AD6E 0x%X, AP %d, busy %s, sel %d, pos %s, menu %s)" % [w.ds8(0x50AD6E), w.sb(u, 0xE), b.busy, b.selected, w.pos(u), MissionScripts.run_menu(w, u)]
	if MissionScripts.run_menu(w, 0)[1] != 0x51AB48:
		return "menu label after the find"
	b._withdraw()
	if w.ds8(0x50ADF2) != 0x83:
		return "withdraw end code 0x%X" % w.ds8(0x50ADF2)
	return ""


func check_m09(b) -> String:
	## the terminals: with three done, the fourth (0x51AFD0's last) completes them (0xA4,
	## DS:0x50AD6E bit 0); the withdraw then gives 0x83 (the enemy still there)
	var w: Pd2World = b.w
	if b.script_no != 9 or w.ds_506651 != 0x7C:
		return "script %d / init" % b.script_no
	b.mission_over = false
	w.set_ds8(0x50ADF2, 0)
	for j in 3:
		MissionScripts.ds_or(w, 0x50AD70 + 2 * j, 1)
	var u: int = b.squad[0]
	place(w, u, MissionScripts.static_s16(w, 0x51AFD0 + 12), MissionScripts.static_s16(w, 0x51AFD2 + 12))
	w.setb(u, 0xE, 30)
	b._select(u)
	b._cmd_mission()
	if not w.ds8(0x50AD6E) & 1:
		return "terminals not done (AP %d)" % w.sb(u, 0xE)
	b._withdraw()
	if w.ds8(0x50ADF2) != 0x83:
		return "withdraw end code 0x%X" % w.ds8(0x50ADF2)
	return ""


func check_m08(b) -> String:
	## the pickup: the call (8 AP, はい, the west quay) sets DS:0x50AD6E bit 0 and the point;
	## the computer's turn surfaces the submarine (DS:0x50AD72 bit 0, the quay's tiles);
	## with units 40-45 destroyed and the squad on the quay, はい to each takes it off the
	## map and the end code is 0x80
	var w: Pd2World = b.w
	if b.script_no != 8 or w.ds_506651 != 0xD3:
		return "script %d / init" % b.script_no
	if not w.ds8(0x50AD4E) & 1:
		return "first call not run"
	if MissionScripts.run_menu(w, 0)[1] != 0x51AEC8:
		return "menu label"
	b.mission_over = false
	w.set_ds8(0x50ADF2, 0)
	var u: int = b.squad[0]
	w.setb(u, 0xE, 30)
	b._select(u)
	b._cmd_mission()
	if not w.ds8(0x50AD6E) & 1 or w.ds8(0x50AD6F) & 0xF != 1:
		return "pickup not asked (0x50AD6E 0x%X, 0x50AD6F 0x%X)" % [w.ds8(0x50AD6E), w.ds8(0x50AD6F)]
	if MissionScripts.run_menu(w, 0)[0] != 0:
		return "menu entry after the call"
	MissionScripts.run_turn(w, b.rng, 0, b.mission_hooks)
	if not w.ds8(0x50AD72) & 1:
		return "submarine not up"
	var a := 0x51ADE8
	if w.H[MissionScripts.static_s16(w, a) + 72 * MissionScripts.static_s16(w, a + 2)] != 0x1E:
		return "quay tiles"
	for k in range(40, 46):
		w.setb(k, 0, w.ub(k, 0) | 1)
	var i := 0
	for k in mini(w.units.size() / 55, 254):
		if w.ub(k, 0xD) and w.sb(k, 0x36) < 3 and w.ub(k, 0) & 4 and w.ub(k, 9) != 0xFF:
			place(w, k, 1 + i % 10, 0x1C + i / 10)
			i += 1
	MissionScripts.run_turn(w, b.rng, 1, b.mission_hooks)
	if w.ds8(0x50ADF2) != 0x80:
		return "end code 0x%X (%d moved)" % [w.ds8(0x50ADF2), i]
	return ""


func check_m10(b) -> String:
	## the last mission: a charge on site 3's first point gives hook byte 3; its bomb hook
	## sets DS:0x50AD54 bit 0 and breaks the site's hexes; the command on the control room
	## hex (0x24, 0x29) with 30 AP ends the mission with 0x80
	var w: Pd2World = b.w
	if b.script_no != 10 or w.ds_506651 != 1:
		return "script %d / init (0x%X)" % [b.script_no, w.ds_506651]
	if MissionScripts.run_menu(w, 0)[1] != 0x51BAC0:
		return "menu label"
	var u: int = b.squad[0]
	var px := MissionScripts.static_s16(w, 0x51B200 + 0x60)
	var py := MissionScripts.static_s16(w, 0x51B202 + 0x60)
	place(w, u, px, py)
	if MissionScripts.run_bomb_rule(w, u, b.mission_hooks) != 3:
		return "bomb rule at (%d, %d)" % [px, py]
	w.bombs[3] = 3
	MissionScripts.run_bomb(w, b.rng, 0, b.mission_hooks)
	var a := 0x51B3E0 + 0xB0 * 2
	if not w.ds8(0x50AD54) & 1 or w.T[MissionScripts.static_s16(w, a) + 72 * MissionScripts.static_s16(w, a + 2)] != w.mem8(a + 4):
		return "site 3 not broken"
	b.mission_over = false
	w.set_ds8(0x50ADF2, 0)
	place(w, u, 0x24, 0x29)
	w.setb(u, 0xE, 30)
	b._select(u)
	b._cmd_mission()
	if w.ds8(0x50ADF2) != 0x80:
		return "end code 0x%X (AP %d, pos %s)" % [w.ds8(0x50ADF2), w.sb(u, 0xE), w.pos(u)]
	return ""
