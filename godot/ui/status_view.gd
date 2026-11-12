class_name MachineStatus
## The machine status window's texts and values as Pd2.exe builds them (display only; the
## actions behind its rows are Pockets', emulated) --
## - 0x4E8930: a row per slot with a launcher (WMES 0x1D3, then the round: 0x1D5, an empty
##   magazine slot 0x1CF, an empty one 0x1D0) and per pocket holding rounds no slot uses
##   (0x1D4), under the header 0x1D2;
## - 0x467880 (from the command menu): the pilot's window (0x1E2) and the machine's (0x1E3)
##   beside the damage diagram (hidan.pac by machine +0x19, the broken parts XORed in
##   colour 4 by 0x467520).
## The rows are [text with colour codes, the entry's value: slot 0-3 or 10 + pocket].




static func _acc(v: int) -> Array:
	## an accuracy column: "**" (DS:0x50CBE1) for 0xFF or 100 up, " 0", else two digits
	if v == 0xFF or v > 99:
		return ["exe", 0x50CBE1]
	if v == 0:
		return ["str", " 0"]
	return ["str", "%d%d" % [v / 10, v % 10]]


static func _state(st: int) -> Array:
	## [colour, state text]: 0 ○ (0xF0), 1 △ (0x40), 2 × (0x43) (DS:0x51F6A0 ...), else none
	match st:
		0:
			return [0xF0, 0x51F6B4]
		1:
			return [0x40, 0x51F6B8]
		2:
			return [0x43, 0x51F6BC]
	return [0xF0, 0]


static func rows(b, u: int) -> Array:
	var w: Pd2World = b.w
	var camp: String = b.campaign
	var ln: Dictionary = GameData.tables(camp).get("launcher_names", {})
	var an: Dictionary = GameData.tables(camp).get("ammo_names", {})
	var exe := func(a: int) -> String: return GameData.exe_text(camp, a) if a != 0 else ""
	var acc_s := func(v: int) -> String:
		var r := _acc(v)
		return exe.call(r[1]) if r[0] == "exe" else str(r[1])
	var out := []
	for s in 4:
		var lid := w.launcher_id(u, s)
		if lid == -1:
			continue
		var cnt := w.slot_count(u, s)
		var kind := 3
		var ammo_c := 0xF0
		var ammo_name := ""
		if cnt == 0:
			kind = 4 if w.launcher(lid, 9) & 8 else 5
		elif Pd2World.s8(w.launcher(lid, 11)) != -1:   # takes[1]
			ammo_name = str(an.get(str(w.ammo_id(u, s)), ""))
			var ps := (w.ub(u, 0x1C + 2 * (w.ub(u, 0x10 + 2 * s) & 15)) >> 6) & 3   # 0x47C9C0
			ammo_c = 0xF0 if ps != 2 else 0x40
		var cs := "x%d%d" % [(cnt / 10) % 10, cnt % 10] if cnt > 0 else "x00"
		if cnt == -1:
			cs = exe.call(0x51F6C0)
		var st := _state(w.slot_state(u, s))
		var tail := ""
		match kind:
			3:
				tail = GameWindow.coded(b.text_cells(b.msg_raw(0x1D5), [ammo_c, ammo_name, cs, st[0], exe.call(st[1])]))
			4:
				tail = GameWindow.coded(b.text_cells(b.msg_raw(0x1CF), [0x40, st[0], exe.call(st[1])]))
			5:
				tail = GameWindow.coded(b.text_cells(b.msg_raw(0x1D0), [0x40]))
		var p := w.ub(u, 0x10 + 2 * s) & 15
		var pa := w.pocket_ammo(u, p)
		var head: Array = b.text_cells(b.msg_raw(0x1D3), [0xF0, str(ln.get(str(lid), "")),
				w.weapon_range(u, s) & 0xFF, acc_s.call(w.launcher(lid, 2)), Move.final_attack(w, u, s, false),
				acc_s.call(w.launcher(lid, 5)), Move.final_attack(w, u, s, true),
				w.ammo(pa, 4) if pa != -1 else 0, w.ammo(pa, 5) if pa != -1 else 0,
				-(_hand_ap(w, u, s) & 0xFF), Move.launcher_ap(w, lid),
				GameData.exe_text(camp, 0x50CBAA).substr(w.launcher(lid, 8) >> 5, 1), w.launcher(lid, 9) & 7,
				exe.call(0x51F6B4 if w.launcher(lid, 9) & 8 else 0x51F6BC)])
		out.append([GameWindow.coded(head) + tail, s])
	for p in 12:
		var a := w.pocket_ammo(u, p)
		if a == -1 or w.pocket_count(u, p) == 0:
			continue
		var held := false
		for s in 4:
			if w.launcher_id(u, s) != -1 and (w.ub(u, 0x10 + 2 * s) & 15) == p:
				held = true
		if held:
			continue
		var st := _state(w.pocket_state(u, p))
		out.append([GameWindow.coded(b.text_cells(b.msg_raw(0x1D4), [0xF0, str(an.get(str(a), "")),
				w.ammo(a, 1), w.ammo(a, 2), w.ammo(a, 4), w.ammo(a, 5), -(w.ammo(a, 6) & 0x1F),
				w.ammo(a, 7) & 0x1F, w.pocket_count(u, p), st[0], exe.call(st[1])])), 10 + p])
	return out


static func _hand_ap(w: Pd2World, u: int, s: int) -> int:
	## 0x4507C0 as Pockets.slot_hand_ap, without its side effects: a round capacity of 0 (an
	## emptied pocket: the game divides by zero showing this window) is taken as 1, the
	## play-safe value (RULES.md 5.23, D5), and nothing is logged or faulted (display only)
	var lid := w.sb(u, 0xF + 2 * s)
	if lid == -1:
		return 0
	var k := w.ub(u, 0x10 + 2 * s) & 15
	var a := w.sb(u, 0x1B + 2 * k)
	var load := w.ammo(a, 6) & 0x1F
	var c := w.ub(u, 0x1C + 2 * k) & 0x3F
	if c & 0x20:
		c -= 64
	var cap := Pd2World.s8(w.ammo(a, 0)) & 0xFFFFFFFF
	if cap == 0:
		cap = 1
	var v := (((c * 200) & 0xFFFFFFFF) / cap * load) & 0xFFFFFFFF
	var lb := (v / 100) & 0xFF
	if load < lb:
		lb = load
	var L := w.launcher(lid, 7) & 0x1F
	return ((L - 32 if L & 0x10 else L) + lb) & 0xFF


static func _rank(w: Pd2World, c: int, f: int, k: int) -> int:
	## 0x4714D0 / 0x4713F0 / 0x471310 / 0x471230 (f = crew +0xD .. +0xA, k = 4 .. 1):
	## 1 when the record is negative, 0 at level 10, else DS:0x50CC4C[level] - DS:0x506B34[13
	## record + k]
	var rec := Pd2World.s8(w.cb(c, 0xF))
	if rec < 0:
		return 1
	var lv := Pd2World.s8(w.cb(c, f))
	if lv == 10:
		return 0
	return Pd2World.s8((w.mem8(0x50CC4C + lv) - w.mem8(0x506B34 + 13 * rec + k)) & 0xFF)


static func pilot_text(b, u: int) -> String:
	## 0x467880's second window: WMES 0x1E2
	var w: Pd2World = b.w
	var c := w.ub(u, 0xB)
	var camp: String = b.campaign
	var nm: Array = b.intercept_names(u)
	var given: String = nm[0]
	var family: String = nm[1]
	if w.is_enemy(u) and not (w.ds8(0x551D29) & 0x40):
		given = ""
		family = ""
	var yes := func(bit: int) -> String: return GameData.exe_text(camp, 0x50CBB3 if w.cb(c, 8) & bit else 0x50CBB6)
	var rec := Pd2World.s8(w.cb(c, 0xF))
	var ap_rank := 1 if rec < 0 else Pd2World.s8((w.mem8(0x50CC11 + Pd2World.s8(w.cb(c, 9))) - w.mem8(0x506B34 + 13 * rec)) & 0xFF)
	var cells: Array = b.text_cells(b.msg_raw(0x1E2), [given, family, Move.max_ap(w, u) & 0xFF, Pd2World.s8(w.cb(c, 9)), ap_rank,
			Pd2World.s8(w.cb(c, 0xA)), _rank(w, c, 0xA, 1), Pd2World.s8(w.cb(c, 0xB)), _rank(w, c, 0xB, 2),
			Pd2World.s8(w.cb(c, 0xC)), _rank(w, c, 0xC, 3), Pd2World.s8(w.cb(c, 0xD)), _rank(w, c, 0xD, 4),
			yes.call(1), yes.call(2), yes.call(4), yes.call(8)])
	return GameWindow.coded(cells)


static func machine_text(b, u: int) -> String:
	## 0x467880's third window: WMES 0x1E3 (the damage coloured: below 50 0x70, 75 up 0x40,
	## else 0xF0)
	var w: Pd2World = b.w
	var m := Pd2World.s8(w.ub(u, 0xC))
	var dmg := 100 - w.ub(u, 0xD)
	var col := 0x70 if dmg < 0x32 else (0x40 if dmg >= 0x4B else 0xF0)
	var mn: Array = GameData.tables(b.campaign).machine_names
	var rr := Sight.recon_range(w, u)
	var cells: Array = b.text_cells(b.msg_raw(0x1E3), [mn[m] if m >= 0 and m < mn.size() else "", col, dmg,
			w.umachine(u, 4), w.umachine(u, 5), Ai.machine_melee_of(w, u), w.umachine(u, 6),
			rr.x, w.umachine(u, 7), rr.y, w.umachine(u, 8)])
	return GameWindow.coded(cells)


static func damage(gw, w: Pd2World, u: int, x := 8, y := 4) -> void:
	## 0x467520: each part's state (1 an outline, 2 a fill) XORed in colour 4 over the diagram
	var p1 := w.ub(u, 1)
	var p2 := w.ub(u, 2)
	var parts := [[p1 & 3, 0x2C, 0xC, 0x44, 0x28], [p1 >> 6, 6, 0x30, 0x1E, 0x54],
			[p2 & 3, 0x4E, 0x30, 0x66, 0x54], [(p2 & 0xC) >> 2, 0x2A, 0x34, 0x42, 0x48],
			[(p1 & 0xC) >> 2, 0xE, 100, 0x26, 0x8C], [(p1 & 0x30) >> 4, 0x46, 100, 0x5E, 0x8C]]
	for q in parts:
		if q[0] == 1 or q[0] == 2:
			gw.xor_rect(x + q[1], y + q[2], x + q[3], y + q[4], 4, q[0])
