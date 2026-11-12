class_name InfoPanel
extends GameWindow
## The battle's info panel (Pd2.exe window "Info", DS:0x554FB8: 0xD0 x 400 at x 0x1B2 of the
## main window), drawn from the import as 0x4830E0 / ui_date_window / 0x466790 draw it --
## - hex_g.pac at (0, 0); the mission's name (DS:0x50CB4E by DS:0x50CE72) "%a7F%s" in an
##   unframed window at (0x30, 3), 18 columns of 12 px lines (flags 1);
## - the time (0x453900 of DS:0x506651 and the turn) and the time passed (0x453900(0,
##   turn)) "%a74%s" at (0x30, 0x18) and (0x98, 0x18), 5 columns;
## - the unit panel (0x466790): none: (8, 0x30)-(199, 0xD3) cleared; a ground unit (class
##   0): the weapons' box (8, 0x90)-(0x57, 0xD3) (black outline, filled colour 7) with
##   0x466DF0's window at (0x10, 0x92) (8 x 8, 8 px font: WMES 0x1C1, the four slots'
##   launcher codes DS:0x50C0E5, then COVER UP / STACK / CARRY or "--------", inverse when
##   concealed / its gear's damage adds to 3 or more (red) / carrying), the face dface.pac
##   (crew +1; 0x24 for the computer's) at (8, 0x30) and the machine datau.pac (machine
##   +0x19) at (0x58, 0x30), or with DS:0x551D29 bit 0x100 and a picture below 7 the
##   damage diagram hidan.pac at (0x58, 0x2C) with its parts XORed (0x467520); any other
##   unit: the box (0x58, 0x30)-(199, 0x8F), its window at (0x60, 0x34) (12 x 11: WMES
##   0x1C0), the face at (8, 0x30), the machine at (8, 0x90).
## The click regions of the screen (0x47BBB0, in this window's pixels): 4 the face (the
## next DoLL), 8-14 the COMMAND buttons (部隊 武装 マップ 撤退 作戦中止 一斉 終了),
## 15 指令書, 16 システム, 22 the weapons' box (the machine status), 23 the picture.

signal region(i: int)

const X := 0x1B2
const REGIONS := {4: [8, 0x30, 0x57, 0x8F, 1], 8: [0x98, 0xE8, 199, 0xFB, 2], 9: [0x98, 0xFC, 199, 0x10F, 2],
	10: [0x98, 0x110, 199, 0x123, 2], 11: [0x98, 0x124, 199, 0x137, 2], 12: [0x98, 0x138, 199, 0x14B, 2],
	13: [0x98, 0x14C, 199, 0x15F, 2], 14: [0x98, 0x160, 199, 0x173, 2], 15: [0x88, 0x178, 199, 0x18B, 2],
	16: [0x49, 0x178, 0x87, 0x18B, 2], 22: [8, 0x90, 0x57, 0xD3, 1], 23: [0x58, 0x30, 199, 0xD3, 0]}

var battle
var unit := -1
var _subs: Array = []


static func make(b) -> InfoPanel:
	var p := InfoPanel.new()
	p.battle = b
	p.cols = 26
	p.rows = 25
	p.lh = 16
	p.framed = false
	p.black = true
	p.position = Vector2(X, 0)
	var ids := []
	for k in REGIONS:
		var r: Array = REGIONS[k]
		p.regions.append([r[0], r[1], r[2] + 1, r[3] + 1, r[4]])
		ids.append(k)
	p._layout()
	p.chosen.connect(func(v: int): if v >= 0 and v < ids.size(): p.region.emit(ids[v]))
	return p


func refresh() -> void:
	## the whole panel again: the picture, the name, the time and the unit
	_buf.fill(0)
	_raw.fill(0)
	blit(GameData.ROOT + "/images/hex_g/00.bmp", 0, 0)
	for s in _subs:
		s.queue_free()
	_subs = []
	if battle == null:
		return
	_sub(0x30, 3, 18, 1, 12, "\u0001" + char(0x7F) + SaveFiles.mission_name(battle.script_no))
	var w: Pd2World = battle.w
	_sub(0x30, 0x18, 5, 1, 12, "\u0001" + char(0x74) + _time(w.mission_turn, w.ds_506651))
	_sub(0x98, 0x18, 5, 1, 12, "\u0001" + char(0x74) + _time(w.mission_turn, 0))
	_unit()
	_dirty = true
	queue_redraw()


static func _time(t: int, d: int) -> String:
	## 0x453900: "HH:MM" of (t + d) x 5 minutes
	var m := (t + d) * 5
	return "%02d:%02d" % [(m / 60) % 24, m % 60]


func _sub(x: int, y: int, c: int, r: int, h: int, t: String) -> GameWindow:
	## an unframed window printed into the panel (black inside: no pattern given), flags 1
	var gw := GameWindow.new()
	gw.cols = c
	gw.rows = r
	gw.lh = h
	gw.framed = false
	gw.black = true
	gw.code = 0x75
	gw.waits = false
	gw.mouse_filter = Control.MOUSE_FILTER_IGNORE
	gw.position = Vector2(x, y)
	gw._layout()
	add_child(gw)
	_subs.append(gw)
	gw.print_text(t)
	return gw


func _unit() -> void:
	var w: Pd2World = battle.w
	var u := unit
	if u < 0 or u > 0xFD:
		_rect(8, 0x30, 199, 0xD3, 1, 0xF, 2)
		return
	var root: String = GameData.ROOT
	var camp: String = battle.campaign
	var face := 0x24
	if not w.is_enemy(u):
		face = 1 if Pd2World.s8(w.ub(u, 0xB)) < 0 else Pd2World.s8(w.ucrew(u, 1))
	var pic := w.umachine(u, 0x19)
	if w.unit_class(u) == 0:
		_rect(8, 0x90, 0x57, 0xD3, 1, 0xF, 1)
		_rect(9, 0x91, 0x56, 0xD2, 0, 7, 2)
		_weapons(0x10, 0x92, 8, 8, 0x1C1)
		if not w.is_enemy(u) and (battle.options & 0x100) and pic < 7:
			blit("%s/images/dface/%02d.bmp" % [root, face], 8, 0x30)
			blit("%s/images/hidan/%02d.bmp" % [root, pic], 0x58, 0x2C)
			MachineStatus.damage(self, w, u, 0x58, 0x2C)
		else:
			blit("%s/%s/images/datau/%02d.bmp" % [root, camp, pic], 0x58, 0x30)
			blit("%s/images/dface/%02d.bmp" % [root, face], 8, 0x30)
	else:
		_rect(0x58, 0x30, 199, 0x8F, 1, 0xF, 1)
		_rect(0x59, 0x31, 0xC6, 0x8E, 0, 7, 2)
		_weapons(0x60, 0x34, 12, 11, 0x1C0)
		blit("%s/%s/images/datau/%02d.bmp" % [root, camp, pic], 8, 0x90)
		blit("%s/images/dface/%02d.bmp" % [root, face], 8, 0x30)


func _weapons(x: int, y: int, c: int, r: int, id: int) -> void:
	## 0x466DF0: the slots' launcher codes, COVER UP (concealed, +0 bit 0x20), STACK (the
	## gear's damage +1 bits 2-3 + bits 4-5 at 3 or more: red) and CARRY (+0x34), each
	## inverse when it holds (8 px font)
	var w: Pd2World = battle.w
	var u := unit
	var lc: Dictionary = GameData.tables(battle.campaign).get("launcher_codes", {})
	var blank := GameData.exe_text(battle.campaign, 0x516F48)
	var dash := GameData.exe_text(battle.campaign, 0x516F30)
	var args := []
	for s in 4:
		var lid := w.launcher_id(u, s)
		args.append(str(lc.get(str(lid), "")) if lid != -1 else blank)
	var cov := (w.ub(u, 0) & 0x20) != 0
	args.append(0xB if cov else 9)
	args.append(GameData.exe_text(battle.campaign, 0x516F54) if cov else dash)
	var gear := ((w.ub(u, 1) >> 2) & 3) + ((w.ub(u, 1) >> 4) & 3)
	args.append(0x4B if gear >= 3 else 9)
	args.append(GameData.exe_text(battle.campaign, 0x516F60) if gear >= 3 else dash)
	var car := w.ub(u, 0x34) != 0xFF
	args.append(0xB if car else 9)
	args.append(GameData.exe_text(battle.campaign, 0x516F6C) if car else dash)
	var gw := _sub(x, y, c, r, 8, "")
	gw.black = false
	gw.code = 0x79
	gw._layout()
	gw._buf.fill(7)
	gw.print_text(GameWindow.coded(battle.text_cells(battle.msg_codes(id), args)))


