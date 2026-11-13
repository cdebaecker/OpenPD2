class_name EquipView
extends GameWindow
## The armament screen (0x454E60) as Pd2.exe draws it in its 640 x 400 window (DS:0x554FB0,
## the palette DS:0x50D6A1) --
## - busou_b.pac at (0, 0), busou_g<layout>.pac at (0xA0, 0) (layout: 0 ground, 1 armoured
##   machine +0 & 0xF != 0, 2 air crew +3 = 1), Chara.pac[crew +1] at (0, 0);
## - the pilot's window or the machine's (regions 0 / 1, DS:0x523E74) at (8, 0xF6) 18 x 8 of
##   16 px, pattern DS:0x5156A0, +0x65 0x90: 0x456D50 MES 0x1AC (the names, the levels
##   +0xA .. +0xD as a sign and a hex digit with their ranks, the skills 有 / 無, the AP),
##   0x456FD0 MES 0x1AD (the machine's name DS:0x50C265, +4, +5, melee and +6, the recon
##   range and +7, its penetration and +8; ground machines " ポケット %3dカ所" of +0x17);
## - with a machine: Weapon.pac[machine +0x1B] at (0x128, 0x18) / (0xD0, 0x38) / (0xB8, 8)
##   (air: st<+0x1B>.pac at (0x130, 0xA8)); the slots (ground 0x456230: slots 0-3 that hold a
##   launcher; armoured 0x456960: 0-2; air 0x456600: 0-5) as Arms.pac[launcher +0xD] (ground
##   slots 0-1 of machine 6: + 0x11; ground mirrored for slot 1) or Blanc.pac (ground 2 for
##   machine 6, 6 for machine 3, else 1, slots 2-3: 0; armoured 4, mirrored for slot 1; air
##   3, mirrored for slot 1) and an 11 x 5 (ground) / 11 x 4 window of 8 px with MES 0x1A9 /
##   0x1AB / 0x1AA (the launcher's code, the hand AP, launcher +8's low 5 bits signed, the
##   type letter DS:0x50CBAA[+8 >> 5] and +9 & 7, then range : ground attack : accuracy
##   (+2, "**" for 0xFF) and range : air attack : accuracy (+5)); ground: the loaded round's
##   long code DS:0x50C4E5 when the launcher takes one (+0xB); an empty slot "\x0c";
## - ground: the pockets 0x456C50 at (0xB0 + 0x168 (p & 1), 0xDE + 0x18 (p / 2)) 11 x 1 of
##   8 px, pattern DS:0x5156A8, +0x65 0x8F: the round's long code, "\x0c" when empty, or
##   "%a4FCan't use.%aFF" past machine +0x17;
## - the regions by layout (DS:0x515358 25 / DS:0x515520 9 / DS:0x5155C8 12).

signal pressed(r: int)

const W := 640
const H := 400
const GROUND_SLOTS := [[0x108, 9, 0xA8, 0x24], [0x1C8, 9, 0x220, 0x24], [0xA8, 0x15C, 0xB0, 300], [0x1B8, 0x15C, 0x218, 300]]
const AIR_SLOTS := [[0xA8, 0xCC, 0xA8, 0xA8], [600, 0xCC, 0x220, 0xA8], [0xD8, 0xD0, 0xA8, 0x164],
		[0x228, 0xD0, 0x220, 0x164], [0x108, 0xF8, 0x130, 0x11C], [0x1F8, 0xF8, 0x198, 0x11C]]

var battle: Node
var k := 0                  # the unit (= its crew)
var layout := 0
var info := 0               # DS:0x523E74: 0 the pilot's window, 1 the machine's
var _pal: Array = []


static func make(b: Node) -> EquipView:
	var v := EquipView.new()
	v.battle = b
	v.cols = W / 8
	v.rows = H / 16
	v.lh = 16
	v.framed = false
	v.black = true
	v.waits = false
	return v


func palette16() -> Array:
	if _pal.is_empty():
		for i in 16:
			var a := 0x50D6A1 + 4 * i
			_pal.append(Color8(battle.w.mem8(a + 2), battle.w.mem8(a + 1), battle.w.mem8(a)))
	return _pal


func _win(x: int, y: int, c: int, r: int, h: int, flags: int, pat: String, solid: int) -> GameWindow:
	var gw := GameWindow.new()
	gw.cols = c
	gw.rows = r
	gw.lh = h
	gw.framed = false
	gw.code = ((flags & 3) << 2) | 0x71
	gw.waits = false
	gw.pal16 = palette16()
	if pat != "":
		gw.pattern = GameWindow.ui_data().get("patterns", {}).get(pat, [])
	else:
		gw.black = true
	gw.solid_raw = solid + 10 if solid >= 0 else 0
	gw.mouse_filter = Control.MOUSE_FILTER_IGNORE
	gw.position = Vector2((x >> 3) << 3, y)
	gw._layout()
	add_child(gw)
	return gw


func _mes(id: int, args: Array) -> String:
	return SortieView.fmt(GameData.base_raw(battle.campaign, id, battle.mission_index), args)


func refresh() -> void:
	for c in get_children():
		c.queue_free()
	pal16 = palette16()
	_layout()
	var w: Pd2World = battle.w
	var root: String = GameData.ROOT
	blit("%s/images/busou_g%d/00.bmp" % [root, layout], 0xA0, 0)
	blit(root + "/images/busou_b/00.bmp", 0, 0)
	blit("%s/images/chara/%02d.bmp" % [root, Flight.s8(w.cb(k, 1))], 0, 0)
	var m := Flight.s8(w.ub(k, 0xC))
	if m != -1:
		var pic := w.machine(m, 0x1B)
		match layout:
			0:
				blit("%s/images/weapon/%02d.bmp" % [root, pic], 0x128, 0x18)
				for s in 4:
					if Flight.s8(w.ub(k, 0xF + 2 * s)) != -1:
						_slot_ground(s)
				for p in 6:
					_pocket(p)
			1:
				blit("%s/images/weapon/%02d.bmp" % [root, pic], 0xD0, 0x38)
				for s in 3:
					_slot(s, 0x110, [0xF4, 0x124, 0x154][s], 0xB0, [0xF0, 0x120, 0x150][s], 4, 0x1AB)
			2:
				blit("%s/images/weapon/%02d.bmp" % [root, pic], 0xB8, 8)
				blit("%s/images/st%02d/00.bmp" % [root, pic], 0x130, 0xA8)
				for s in 6:
					var e: Array = AIR_SLOTS[s]
					_slot(s, e[0], e[1], e[2], e[3], 3, 0x1AA)
	if info == 0 or m == -1:
		_pilot()
	else:
		_machine()
	var regs := []
	var doc: Array = GameWindow.ui_data().get("equip_regions", [[], [], []])
	for r in doc[layout] if layout < doc.size() else []:
		regs.append([int(r[0]), int(r[1]), int(r[2]), int(r[3]), int(r[4])])
	regions = regs
	_all_regions = regs
	queue_redraw()


func _acc(v: int) -> String:
	## wsprintf "%2d" of the accuracy, "%2s" of "**" (DS:0x50CBE1) for 0xFF
	return GameData.exe_text(battle.campaign, 0x50CBE1) if v == 0xFF else "%2d" % v


func _slot_args(s: int) -> Array:
	## the slot texts' arguments (0x456230 / 0x456600 / 0x456960)
	var w: Pd2World = battle.w
	var lid := Flight.s8(w.ub(k, 0xF + 2 * s))
	var lc: Dictionary = GameData.tables(battle.campaign).get("launcher_codes", {})
	var b8 := w.launcher(lid, 8)
	var low := b8 & 0x1F
	if low & 0x10:
		low -= 32
	var types := GameData.exe_text(battle.campaign, 0x50CBAA)
	var tc := types.substr(b8 >> 5, 1) if (b8 >> 5) < types.length() else " "
	return [str(lc.get(str(lid), "")), MachineStatus._hand_ap(w, k, s) & 0xFF, low, tc, w.launcher(lid, 9) & 7,
		w.weapon_range(k, s) & 0xFF, Move.final_attack(w, k, s, false) & 0xFF, _acc(w.launcher(lid, 2)),
		w.weapon_range(k, s) & 0xFF, Move.final_attack(w, k, s, true) & 0xFF, _acc(w.launcher(lid, 5))]


func _slot_ground(s: int) -> void:
	## 0x456230
	var w: Pd2World = battle.w
	var e: Array = GROUND_SLOTS[s]
	var m := Flight.s8(w.ub(k, 0xC))
	var tw := _win(e[2], e[3], 0xB, 5, 8, 2, "", -1)
	var lid := Flight.s8(w.ub(k, 0xF + 2 * s))
	if lid == -1:
		var n := 0 if s > 1 else (2 if m == 6 else (6 if m == 3 else 1))
		blit("%s/images/blanc/%02d.bmp" % [GameData.ROOT, n], e[0], e[1], s == 1)
		tw.print_text("\u000c")
		return
	var pic := w.launcher(lid, 0xD) + (0x11 if m == 6 and s < 2 else 0)
	blit("%s/images/arms/%02d.bmp" % [GameData.ROOT, pic], e[0], e[1], s == 1)
	var t := _mes(0x1A9, _slot_args(s))
	if Flight.s8(w.launcher(lid, 0xB)) != -1:
		var al: Array = GameData.tables(battle.campaign).get("ammo_long", [])
		var a := Flight.s8(w.ub(k, 0x1B + 2 * (w.ub(k, 0x10 + 2 * s) & 0xF)))
		t += str(al[a]) if a >= 0 and a < al.size() else ""
	tw.print_text(t)


func _slot(s: int, px: int, py: int, tx: int, ty: int, blank: int, mes_id: int) -> void:
	## 0x456960 (armoured) / 0x456600 (air)
	var w: Pd2World = battle.w
	var tw := _win(tx, ty, 0xB, 4, 8, 2, "", -1)
	var lid := Flight.s8(w.ub(k, 0xF + 2 * s))
	if lid == -1:
		blit("%s/images/blanc/%02d.bmp" % [GameData.ROOT, blank], px, py, s == 1)
		tw.print_text("\u000c")
		return
	blit("%s/images/arms/%02d.bmp" % [GameData.ROOT, w.launcher(lid, 0xD)], px, py)
	tw.print_text(_mes(mes_id, _slot_args(s)))


func _pocket(p: int) -> void:
	## 0x456C50
	var w: Pd2World = battle.w
	var tw := _win(0xB0 + 0x168 * (p & 1), 0xDE + 0x18 * (p / 2), 0xB, 1, 8, 2, "5156A8", 0x8F)
	var m := Flight.s8(w.ub(k, 0xC))
	if p < w.machine(m, 0x17):
		var a := Flight.s8(w.ub(k, 0x1B + 2 * p))
		var al: Array = GameData.tables(battle.campaign).get("ammo_long", [])
		tw.print_text("\u000c" if a == -1 else (str(al[a]) if a < al.size() else ""))
	else:
		tw.print_text(SortieView.fmt("%a4FCan't use.%aFF", []))


func _pilot() -> void:
	## 0x456D50: MES 0x1AC
	var w: Pd2World = battle.w
	var nm: Array = battle.names.crew[w.cb(k, 0)] if w.cb(k, 0) < battle.names.crew.size() else ["", ""]
	var sign := func(f: int) -> String:
		var v := Flight.s8(w.cb(k, f))
		return "-" if v < 0 else (" " if v == 0 else "+")
	var mag := func(f: int) -> int: return absi(Flight.s8(w.cb(k, f)))
	var yes := func(bit: int) -> String: return GameData.exe_text(battle.campaign, 0x50CBB3 if w.cb(k, 8) & bit else 0x50CBB6)
	var rec := Flight.s8(w.cb(k, 0xF))
	var ap_rank := 1 if rec < 0 else Flight.s8((w.mem8(0x50CC11 + Flight.s8(w.cb(k, 9))) - w.mem8(0x506B34 + 13 * rec)) & 0xFF)
	var t := _mes(0x1AC, [str(nm[0]) + " " + str(nm[1] if nm.size() > 1 else ""),
		sign.call(0xA), mag.call(0xA), MachineStatus._rank(w, k, 0xA, 1) & 0xFF,
		sign.call(0xB), mag.call(0xB), MachineStatus._rank(w, k, 0xB, 2) & 0xFF,
		sign.call(0xC), mag.call(0xC), MachineStatus._rank(w, k, 0xC, 3) & 0xFF,
		sign.call(0xD), mag.call(0xD), MachineStatus._rank(w, k, 0xD, 4) & 0xFF,
		yes.call(1), yes.call(2), yes.call(4), yes.call(8),
		Move.max_ap(w, k) & 0xFF, Flight.s8(w.cb(k, 9)), ap_rank & 0xFF])
	_info_win().print_text(t)


func _machine() -> void:
	## 0x456FD0: MES 0x1AD, then a ground machine's pockets
	var w: Pd2World = battle.w
	var m := Flight.s8(w.ub(k, 0xC))
	var mn: Array = GameData.tables(battle.campaign).get("machine_names", [])
	var rr := Sight.recon_range(w, k)
	var t := _mes(0x1AD, [str(mn[m]) if m >= 0 and m < mn.size() else "", w.machine(m, 4), w.machine(m, 5),
		Ai.machine_melee_of(w, k) & 0xFF, w.machine(m, 6), rr.x & 0xFF, w.machine(m, 7), rr.y & 0xFF, w.machine(m, 8)])
	if Pd2World.CLASS_BY_CATEGORY[w.machine(m, 0) & 15] == 0:          # 0x4538A0: a ground machine
		t += GameData.format_text(GameData.exe_raw(battle.campaign, 0x5157A8), [w.machine(m, 0x17)])
	_info_win().print_text(t)


func _info_win() -> GameWindow:
	return _win(8, 0xF6, 0x12, 8, 0x10, 1, "5156A0", 0x90)


func _ready() -> void:
	chosen.connect(func(r: int):
		if r >= 0:
			pressed.emit(r))
