extends SceneTree
## The pocket actions in the battle (Pockets, emulated): a DoLL with an empty magazine
## reloads it from a pocket through the fire command's magazine column (the slot menu
## 0x427530 with the picker's entries, the pocket picker 0x4E95C0, 0x427980), swaps a
## half-used one from the machine status window's slot menu (0x427930), then hands a
## pocket's round to the squad member beside it (the pocket menu 0x427FF0, 0x4287A0 with
## its 0x1E8 question). The windows' answers are scripted (battle.scripted).

func _mag_launcher(w: Pd2World) -> int:
	## a magazine launcher (+9 bit 3) taking two round types
	for l in 96:
		if w.launcher(l, 9) & 8 and Pd2World.s8(w.launcher(l, 0xA)) >= 0 and Pd2World.s8(w.launcher(l, 0xB)) >= 0 \
				and w.ammo(Pd2World.s8(w.launcher(l, 0xA)), 7) & 0x1F > 0:
			return l
	return -1


func _init() -> void:
	await process_frame
	var b = load("res://ui/battle.tscn").instantiate()
	b.campaign = "dash"
	b.mission_index = 1
	b.auto_react = true
	root.add_child(b)
	await process_frame
	var w: Pd2World = b.w
	var act := []
	for k in b.squad:
		if w.active(k):
			act.append(k)
	var lid := _mag_launcher(w)
	print("units %s, magazine launcher %d" % [str(act), lid])
	var ok := act.size() >= 2 and lid != -1
	if not ok:
		print("pocket battle: FAILED")
		quit(1)
		return
	var u: int = act[0]
	var v: int = act[1]
	var r0 := Pd2World.s8(w.launcher(lid, 0xA))
	var r1 := Pd2World.s8(w.launcher(lid, 0xB))
	# slot 0: the launcher, fed from pocket 0 (empty magazine); pockets 1-3 hold its rounds
	for s in 6:
		w.setb(u, 0xF + 2 * s, 0xFF)
	w.setb(u, 0xF, lid)
	w.setb(u, 0x10, 0)
	for p in 12:
		w.setb(u, 0x1B + 2 * p, 0xFF)
		w.setb(u, 0x1C + 2 * p, 0)
	w.setb(u, 0x1B, r0)
	w.setb(u, 0x1C, 0)
	w.setb(u, 0x1D, r0)
	w.setb(u, 0x1E, 5)
	w.setb(u, 0x1F, r1)
	w.setb(u, 0x20, 7)
	w.setb(u, 0x21, r0)
	w.setb(u, 0x22, 3)
	w.setb(u, 1, w.ub(u, 1) & 0x3F)
	w.setb(u, 2, w.ub(u, 2) & 0xFC)
	w.setb(u, 0xE, 40)
	b._select(u)
	b.slot = 0
	# 1. the fire command's magazine column: the empty magazine offers only "reload"
	b._set_mode("fire")
	var menu := Pockets.slot_menu(w, u, 0, true)
	var choices := Action.weapon_choices(w, u, 0, 0)
	print("fire mode: weapon picker items %s, slot menu %s" % [str(choices), str(menu)])
	ok = 4 in choices and menu.size() == 1 and menu[0][0] == Pockets.RELOAD
	var ap0 := w.sb(u, 0xE)
	b.scripted = [0, 0]                         # the menu's entry, the picker's first row
	b._cmd_slot_menu()
	print("reload: slot 0 feeds pocket %d, pocket 0 ammo %d, AP %d -> %d" % [w.ub(u, 0x10) & 15,
		w.pocket_ammo(u, 0), ap0, w.sb(u, 0xE)])
	ok = ok and w.ub(u, 0x10) & 15 == 1 and w.pocket_ammo(u, 0) == -1 and w.sb(u, 0xE) == ap0 - menu[0][1]
	# 2. the machine status window's slot menu: a swap keeps the old magazine
	b._set_mode("move")
	menu = Pockets.slot_menu(w, u, 0, false)
	print("slot menu %s" % str(menu))
	ok = ok and menu.size() >= 2 and menu[0][0] == Pockets.SWAP
	ap0 = w.sb(u, 0xE)
	var rows := Pockets.magazine_rows(w, u, 0)
	var want_p: int = rows[0][0] if not rows.is_empty() else -1
	b.scripted = [0, 0]
	b._cmd_slot_menu()
	print("swap: slot 0 feeds pocket %d (want %d), pocket 1 ammo %d, AP %d -> %d" % [w.ub(u, 0x10) & 15, want_p,
		w.pocket_ammo(u, 1), ap0, w.sb(u, 0xE)])
	ok = ok and want_p != -1 and w.ub(u, 0x10) & 15 == want_p and w.pocket_ammo(u, 1) == r0 \
		and w.sb(u, 0xE) == ap0 - menu[0][1]
	# 3. hand pocket 3's round to v, moved beside u
	var up := w.pos(u)
	var spot := Vector2i(-1, -1)
	for d in 6:
		var h := MissionScripts.hex_step(up.x, up.y, d)
		if w.on_map(h.x, h.y) and w.O[h.x + 72 * h.y] == 0:
			spot = h
			break
	var vp := w.pos(v)
	if w.on_map(vp.x, vp.y) and w.O[vp.x + 72 * vp.y] == v + 1:
		w.O[vp.x + 72 * vp.y] = 0
	w.setb(v, 9, spot.x)
	w.setb(v, 10, spot.y)
	w.O[spot.x + 72 * spot.y] = v + 1
	w.H[spot.x + 72 * spot.y] = w.H[up.x + 72 * up.y]
	w.setb(v, 0x36, 0)
	w.setb(v, 0xE, 30)
	for p in 12:
		w.setb(v, 0x1B + 2 * p, 0xFF)
	if w.umachine(v, 0x17) == 0:
		for m in 32:
			if w.machine(m, 0x17) > 0 and w.machine(m, 0) & 15 == w.umachine(v, 0) & 15:
				w.setb(v, 0xC, m)
				break
	var pm := Pockets.pocket_menu(w, u, 3)
	var hi := -1
	for i in pm.size():
		if pm[i][0] == Pockets.HAND_OVER:
			hi = i
	var hap: int = pm[hi][1]
	var uap := w.sb(u, 0xE)
	var vap := w.sb(v, 0xE)
	print("unit %d at %s, capacity %d; pocket menu %s" % [v, str(spot), w.umachine(v, 0x17), str(pm)])
	b.scripted = [3, hi, spot, true]          # the pocket, "hand over", the click, the 0x1E8 box
	b._cmd_pocket_menu()
	var got := -1
	for p in 12:
		if w.pocket_ammo(v, p) == r0 and w.pocket_count(v, p) == 3:
			got = p
	print("handed over: v pocket %d, u pocket 3 ammo %d, AP u %d -> %d, v %d -> %d, marks left %d" % [got,
		w.pocket_ammo(u, 3), uap, w.sb(u, 0xE), vap, w.sb(v, 0xE), MissionScripts.target_mark_at(w, spot.x, spot.y)])
	ok = ok and spot.x != -1 and got == 0 and w.pocket_ammo(u, 3) == -1 and w.sb(u, 0xE) == uap - hap \
		and w.sb(v, 0xE) == vap - hap and MissionScripts.target_mark_at(w, spot.x, spot.y) == 0
	ok = ok and b.scripted.is_empty() and w.fault == ""
	b._end_turn()
	print("a whole turn after: fault '%s'" % w.fault)
	ok = ok and w.fault == ""
	print("pocket battle: %s" % ("ok" if ok else "FAILED"))
	quit(0 if ok else 1)
