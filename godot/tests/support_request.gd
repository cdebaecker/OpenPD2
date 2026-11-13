extends SceneTree
## The command menu's support request (cmd_support_request 0x4DF680): a type-5 support group
## set up in groups 0-19, its member picked, a slot, a hex and the 0x202 box answered
## (battle.scripted), then the picker cancelled.

func _init() -> void:
	await process_frame
	var b = load("res://ui/battle.tscn").instantiate()
	b.campaign = "dash"
	b.mission_index = 1
	b.auto_react = true
	root.add_child(b)
	await process_frame
	var w: Pd2World = b.w
	var u: int = b.squad[0]
	w.setb(u, 0xE, 30)
	w.crew[16 * w.sb(u, 0xB) + 8] = 0       # (no support skill: 12 AP)
	# a member off the map with a launcher in slot 0 (the squad's second unit's)
	var k := 39
	for f in 55:
		w.setb(k, f, w.ub(b.squad[1], f))
	w.setb(k, 0, 0x0C)
	w.setb(k, 6, 0)
	var s := -1
	for sl in 6:
		if w.launcher_id(k, sl) != -1:
			s = sl
			break
	var g := 19
	for f in 35:
		w.groups[35 * g + f] = 0xFF if f >= 6 and f < 22 else 0
	w.groups[35 * g + 2] = 0x20
	w.groups[35 * g + 5] = 1
	w.groups[35 * g + 6] = k
	w.groups[35 * g + 22] = 10
	w.groups[35 * g + 23] = 10
	w.groups[35 * g + 33] = 0x50
	var rows := Strike.support_units(w)
	var ok: bool = s != -1 and rows.size() >= 1 and rows[-1][0] == k and rows[-1][1] == 0
	var i := rows.size() - 1
	var target := Vector2i(30, 30)
	b.scripted = [i, s, target, true, -2]
	b._select(u)
	var ap0 := w.sb(u, 0xE)
	b._command(u, 6)
	await process_frame
	ok = ok and w.ub(k, 6) == 1 and w.ub(k, 7) == 30 and w.ub(k, 8) == 30 and w.ub(k, 0x35) == s
	ok = ok and w.sb(u, 0xE) == ap0 - 12 and w.F[30 + 72 * 30] & 0x10 != 0 and b.scripted.is_empty()
	print("support request: member %d ordered %s, AP %d -> %d" % [k, w.ub(k, 6) == 1, ap0, w.sb(u, 0xE)])
	# short of AP: ui_not_enough_ap, nothing asked
	w.setb(u, 0xE, 3)
	b.scripted = [0]
	b._command(u, 6)
	ok = ok and b.scripted.size() == 1 and not b.busy
	print("support request: %s" % ok)
	quit(0 if ok else 1)
