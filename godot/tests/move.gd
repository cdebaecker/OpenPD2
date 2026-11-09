extends SceneTree
## The battle's move command, threaded as in play: a careful step onto a mine (the clear
## dialog answered yes), then a melee with a spotted enemy (the prompts answered yes).

var b


func _answer(i: int) -> bool:
	## press button i of the question panel once it is up
	for _n in 200:
		await process_frame
		if b.react_panel != null and is_instance_valid(b.react_panel):
			var btns: Array = b.react_panel.find_children("*", "Button", true, false)
			if btns.size() > i:
				btns[i].pressed.emit()
				return true
	return false


func _idle() -> bool:
	for _n in 400:
		await process_frame
		if not b.busy:
			return true
	return false


func _init() -> void:
	await process_frame
	b = load("res://ui/battle.tscn").instantiate()
	b.campaign = "dash"
	b.mission_index = 1
	root.add_child(b)
	await process_frame
	var w: Pd2World = b.w
	var a: int = b.squad[0]
	var ok := true
	b._select(a)
	w.setb(a, 0xE, 30)
	w.set_ucrew(a, 8, w.ucrew(a, 8) | 2)              # engineering skill
	b._set_move_mode(2)
	var p := w.pos(a)
	var h := Vector2i(-1, -1)
	for v in b.move_dests:
		if Pd2World.hexdist(p.x, p.y, v.x, v.y) == 1 and w.O[v.x + 72 * v.y] == 0 and absi(w.H[v.x + 72 * v.y] - w.H[p.x + 72 * p.y]) < 2:
			h = v
			break
	ok = ok and h.x != -1
	w.F[h.x + 72 * h.y] |= 0x80                     # an enemy mine there
	var ap0 := w.sb(a, 0xE)
	b._cmd_move(h)
	ok = ok and await _answer(0)                    # clear it: yes
	ok = ok and await _idle()
	var cleared := w.pos(a) == h and w.F[h.x + 72 * h.y] & 0x80 == 0 and w.sb(a, 0xE) < ap0 - 3
	print("mine cleared: %s (AP %d -> %d)" % [cleared, ap0, w.sb(a, 0xE)])
	# a spotted enemy next to the unit: melee
	var e := -1
	for k in range(40, w.n_units):
		if w.active(k) and w.is_enemy(k):
			e = k
			break
	p = w.pos(a)
	var t := Vector2i(-1, -1)
	for v in b.move_dests:
		if Pd2World.hexdist(p.x, p.y, v.x, v.y) == 1 and w.O[v.x + 72 * v.y] == 0 and absi(w.H[v.x + 72 * v.y] - w.H[p.x + 72 * p.y]) < 2:
			t = v
			break
	var ep := w.pos(e)
	w.O[ep.x + 72 * ep.y] = 0
	w.setb(e, 9, t.x)
	w.setb(e, 10, t.y)
	w.O[t.x + 72 * t.y] = e + 1
	w.setb(e, 0, w.ub(e, 0) | 0x10)
	b._update_move_map()
	ok = ok and t in b.move_dests and Action.move_click(w, a, t.x, t.y, b.mm)[0] == "melee"
	b._cmd_move(t)
	ok = ok and await _answer(0)                    # melee: yes
	if b.busy:
		await _answer(0)                            # the melee weapon, if it has one
	ok = ok and await _idle()
	var fought := not w.active(e) or not w.active(a) or w.pos(a) != t
	print("melee: %s (attacker %s, defender %s)" % [fought, w.active(a), w.active(e)])
	quit(0 if ok and cleared and fought else 1)
