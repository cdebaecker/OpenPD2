class_name DebriefView
extends Control
## The debrief's screens (0x48FA40) as the game shows them, replayed from the screens the
## (emulated) debrief asked for, in the main window's 640 x 400 --
## - a picture at (0, 0) faded in (0x48F930 to 100), then a click (0x48F900): a cleared
##   mission's M_CLR.pac (entry chunk - 1), m_fail.pac, gameover.pac, single.pac;
## - its RMES texts (clear: the step's two, game over: its one) after the picture is dimmed
##   to 50 (0x48F980(0x32)), each in an unframed window over the whole screen (80 x 40 of
##   16 px, flags 1): they start with 0x0C (the window cleared black) and wait at their '@'
##   and when full;
## - the results (0x495B70) over the dimmed picture: the header DS:0x519AF8 and its rule
##   0x519B34 at (0x40, 0x10) (80 x 1, flags 0, printed without a clear), then a line per
##   pilot from y 0x20 (16 px apart): the given name, the family name at column 0xD, the
##   state at 0x1C (救出 / 帰還 DS:0x519B88 / 0x519B7C, 負傷 0x519BA0 in colour 1, 行方不明
##   0x519B94 in colour 3), the machine (colour 7), at 0x37 破壊 0x519BC4 (colour 1) / 帰還
##   0x519BB0 / 行方不明 0x519BB8; a click.
## `finished` when the last screen is clicked away.

signal finished

const W := 640
const H := 400

var battle
var screens: Array = []         # [kind, data] in the debrief's order
var _pic: Texture2D = null
var _bright := 1.0
var _go := false


func _init() -> void:
	size = Vector2(W, H)
	mouse_filter = Control.MOUSE_FILTER_STOP


func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.pressed:
		accept_event()
		if ev.button_index == MOUSE_BUTTON_RIGHT:
			_skip = true
		for c in get_children():
			if c is GameWindow and c._waiting:
				c.outside(ev.button_index)
				return
		_go = true


var _over: Array = []          # pictures drawn over _pic: [texture, x, y]
var _roll: Variant = null      # [texture, t]: the staff roll
var _skip := false


func _fade(to: float) -> void:
	## 0x48F930 -> 0x4875D0: the palette 5 steps of 100 at a time, 17 ms each (a right click
	## goes straight to the end)
	_skip = false
	if battle._headless():
		_bright = to
		queue_redraw()
		return
	while absf(_bright - to) > 0.001 and is_inside_tree():
		if _skip:
			_bright = to
			break
		_bright = move_toward(_bright, to, 0.05)
		queue_redraw()
		await get_tree().create_timer(0.017).timeout
	queue_redraw()


func _sleep(ms: int) -> void:
	## ui_wait(.., ms, 0): a plain wait, clicks do not end it
	if battle._headless() or not is_inside_tree():
		return
	await get_tree().create_timer(ms / 1000.0).timeout


func _blank() -> void:
	## 0x48F9D0: the screen cleared to colour 0
	_pic = null
	_over = []
	_roll = null
	_card = {}
	_clear_windows()
	queue_redraw()


func _shared(dir: String, i: int) -> Texture2D:
	return _tex("%s/images/%s/%02d.bmp" % [GameData.ROOT, dir, i])


func _credits_pd2() -> void:
	## PD2's credits after the score cards (0x48FA40, step 10): scenes of staff_g.pac, each
	## faded in from black, then staff_p.pac pictures added one by one (no fade), 6 s each,
	## then faded out
	var scenes := [[0, [[0, 0x198, 0x9E], [1, 0x158, 0x9C], [2, 0x150, 0x78]]], [1, [[3, 0x188, 0x90]]],
		[2, [[4, 8, 0x98]]], [3, []], [4, [[5, 0x18, 0x80]]], [5, [["g", 7, 0, 0]]], [6, []]]
	for i in scenes.size():
		var sc: Array = scenes[i]
		await _fade(0.0)
		_blank()
		_pic = _shared("staff_g", sc[0])
		await _fade(1.0)
		await _sleep(6000)
		for e in sc[1]:
			if e[0] is String:
				_over.append([_shared("staff_g", e[1]), e[2], e[3]])
			else:
				_over.append([_shared("staff_p", e[0]), e[1], e[2]])
			queue_redraw()
			await _sleep(6000)


func _credits_dash() -> void:
	## DASH's credits after the score cards: scenes of staff2_g / staff2_p.pac, each faded in
	## from black, 6 s, faded out; the staff roll (s_roll.pac); then two more scenes
	var scenes := [[["p", 0, 0x110, 0xB8]], [["p", 1, 0x30, 0x3C], ["p", 2, 0x148, 0xCC]], [["g", 0, 0, 0]],
		[["p", 3, 0xC0, 0x55]], [["g", 1, 0, 0]], [["p", 4, 0x30, 0x14], ["p", 5, 0x178, 0xB0], ["p", 6, 0x30, 0x11A]],
		[["g", 2, 0, 0]], "roll", [["g", 3, 0, 0]], [["g", 4, 0, 0]]]
	for sc in scenes:
		await _fade(0.0)
		_blank()
		if sc is String:
			var tex := _shared("s_roll", 0)
			_roll = [tex, 0]
			await _fade(1.0)
			var n := 0x148 + (tex.get_height() - 0x147 if tex else 0)
			for t in n:
				_roll[1] = t
				queue_redraw()
				if battle._headless():
					break
				await get_tree().create_timer(0.010).timeout
			await _sleep(1000)
			continue
		for e in sc:
			_over.append([_shared("staff2_g" if e[0] == "g" else "staff2_p", e[1]), e[2], e[3]])
		await _fade(1.0)
		await _sleep(6000)
	await _fade(0.0)


# --- the new step's screens (0x48FA40 after a cleared mission) ------------------------

var _on_kabe := false


func _pal_kabe() -> Array:
	## the kabe screens' 16 window colours: 0x487120 from DS:0x518F48
	var out := []
	for c in GameWindow.ui_data().get("palettes", {}).get("518F48", []):
		out.append(Color8(int(c[0]), int(c[1]), int(c[2])))
	return out


func _kabe() -> void:
	## kabe0.pac at (0, 0) with the palette DS:0x518F48 (0x40DD20 after 0x487120), faded in
	if _on_kabe:
		return
	_on_kabe = true
	await _fade(0.0)
	_blank()
	_pic = _shared("kabe0", 0)
	await _fade(1.0)


func _note(t: String) -> void:
	## 0x452200: the line framed at ((80 - (len + 2)) / 2 x 8, 0xAA), in colour 4 (%a4F),
	## then a click
	var n := mini(GameWindow.text_cols(t), 76)
	var gw := GameWindow.text_window(((80 - (n + 2)) / 2) * 8, 0xAA, n, 1, 1)
	gw.pal16 = _pal_kabe()
	gw.waits = not battle._headless()
	gw.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(gw)
	if GameWindow.translated(t) and GameWindow.text_cols(t) > 76:
		t = GameWindow.fit(t, 76)
	await gw.print_text("\u0001" + char(0x4F) + t + "\n")
	gw.queue_free()


func _kabe_list(x: int, hy: int, cols: int, hrows: int, head: String, rows: Array) -> void:
	## a framed header window (x, hy) cols x hrows of 16 px (flags 1) and 0x452A10 at (x,
	## 0x80) of the rows, cols columns; its left clicks show it again, a right click ends it
	var pal := _pal_kabe()
	var hd := GameWindow.text_window(x, hy, cols, hrows, 1)
	hd.pal16 = pal
	hd.waits = false
	hd.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hd)
	hd.print_text(head)
	var ic := cols
	for r in rows:
		ic = maxi(ic, GameWindow.text_cols(str(r)))
	var gw := GameWindow.select_window(x, 0x80, ic, 0, 0, rows, ic, [], true)
	gw.pal16 = pal
	gw.role = "debrief_list"
	add_child(gw)
	if not battle._headless():
		while is_inside_tree():
			var v: int = await gw.chosen
			if v == -2:
				break
	gw.queue_free()
	hd.queue_free()


func _acc4(v: int) -> String:
	return battle.wsp("%4s", [GameData.exe_text(battle.campaign, 0x50CBE1)]) if v == 0xFF else battle.wsp("%4d", [v])


func _new_items(data: Array) -> void:
	## the machines (0x519728, rows "%-17s%4d %4d %4d %2d:%1d  %4d0%%": DS:0x50C265, +4 .. +8,
	## +0x18; header DS:0x519780 at (0x98, 0x60) 44 x 1, list 44 columns), the launchers
	## (0x5197B8, "%-14s%3d%4s%%%3d%4s%%%3d %2d:%1d %3d:%2d %c%1d %s %-20s" of DS:0x50BDE5,
	## 0x4508D0, +2's accuracy, 0x450940, +5's, 0x4509B0, the round's +4 : +5, -0x450860 :
	## +8's low 5 bits, DS:0x50CBAA[+8 >> 5] and +9 & 7, ○ / × by +9 bit 3, the first round
	## ("%-20s" or "%-14sx%2d" with its +0); header DS:0x519850 at (0x20, 0x60) 0x47 x 1), the
	## rounds (0x5198A0, "%-14s  %2s%5d%5d%4d:%1d %3d:%2d" of DS:0x50C365, +0 or "--", +1, +2,
	## +4, +5, -(+6 & 0x1F), +7 & 0x1F; header DS:0x5198FC at (0xB0, 0x60) 44 x 1), each
	## after its 0x452200 line
	var w: Pd2World = battle.w
	var camp: String = battle.campaign
	var t: Dictionary = GameData.tables(camp)
	var an: Dictionary = t.get("ammo_names", {})
	if not data[0].is_empty():
		await _kabe()
		await _note(GameData.exe_text(camp, 0x519728))
		var mn: Array = t.get("machine_names", [])
		var rows := []
		for m in data[0]:
			rows.append(battle.wsp(GameData.exe_raw(camp, 0x51975C), [str(mn[m]) if m < mn.size() else "",
				w.machine(m, 4), w.machine(m, 5), w.machine(m, 6), w.machine(m, 7), w.machine(m, 8), w.machine(m, 0x18)]))
		await _kabe_list(0x98, 0x60, 0x2C, 1, GameData.exe_text(camp, 0x519780), rows)
	if not data[1].is_empty():
		await _kabe()
		await _note(GameData.exe_text(camp, 0x5197B8))
		var ln: Dictionary = t.get("launcher_names", {})
		var types := GameData.exe_text(camp, 0x50CBAA)
		var rows := []
		for l in data[1]:
			var a := Pd2World.s8(w.launcher(l, 0xA))
			var hand := w.launcher(l, 7) & 0x1F
			if hand & 0x10:
				hand -= 32
			hand += w.ammo(a, 6) & 0x1F
			var low := w.launcher(l, 8) & 0x1F
			if low & 0x10:
				low -= 32
			var a0 := Pd2World.s8(w.ammo(a, 0))
			var rnd: String = battle.wsp("%-20s", [str(an.get(str(a), ""))]) if a0 < 0 else battle.wsp("%-14sx%2d", [str(an.get(str(a), "")), a0])
			var tc := w.launcher(l, 8) >> 5
			rows.append(battle.wsp(GameData.exe_raw(camp, 0x519818), [str(ln.get(str(l), "")),
				(w.ammo(a, 3) + w.launcher(l, 4)) & 0xFF, _acc4(w.launcher(l, 2)), (w.ammo(a, 1) + w.launcher(l, 3)) & 0xFF,
				_acc4(w.launcher(l, 5)), (w.launcher(l, 6) + w.ammo(a, 2)) & 0xFF, w.ammo(a, 4), w.ammo(a, 5),
				-(hand & 0xFF), low, types.substr(tc, 1) if tc < types.length() else " ", w.launcher(l, 9) & 7,
				GameData.exe_text(camp, 0x519810 if w.launcher(l, 9) & 8 else 0x519814), rnd]))
		await _kabe_list(0x20, 0x60, 0x47, 1, GameData.exe_text(camp, 0x519850), rows)
	if not data[2].is_empty():
		await _kabe()
		await _note(GameData.exe_text(camp, 0x5198A0))
		var rows := []
		for a in data[2]:
			var a0 := Pd2World.s8(w.ammo(a, 0))
			rows.append(battle.wsp(GameData.exe_raw(camp, 0x5198DC), [str(an.get(str(a), "")),
				GameData.exe_text(camp, 0x5198D8) if a0 < 0 else battle.wsp("%2d", [a0]), w.ammo(a, 1), w.ammo(a, 2),
				w.ammo(a, 4), w.ammo(a, 5), -(w.ammo(a, 6) & 0x1F), w.ammo(a, 7) & 0x1F]))
		await _kabe_list(0xB0, 0x60, 0x2C, 1, GameData.exe_text(camp, 0x5198FC), rows)


func _given_family(c: int) -> String:
	var cn: Array = GameData.tables(battle.campaign).crew_names
	var n: int = battle.w.cb(c, 0)
	var nm: Array = cn[n] if n < cn.size() else ["", ""]
	return battle.wsp("%s %s", [nm[0], nm[1] if nm.size() > 1 else ""])


func _recruits(data: Array) -> void:
	## 0x519930's line, then the header DS:0x5199E0 (0x78, 0x50) 47 x 2 and 0x452A10 at (0x78,
	## 0x80), 47 columns: "%-14s %s %s%s %2d " of "given family", 地 / 空 (crew +3), %a4F (+6
	## bits 0 / 1) or %a7F, 不 (+6 bit 0) / 負 (bit 1) / 未 (+5 = 0xFF) / 編, +9; then +0xA,
	## +0xB, +0xC, +0xD each "%2X " ("%2d " below 0); then "%s %s %s %s" of 有 / 無 by +8 bits
	## 0, 1, 2, 3
	var w: Pd2World = battle.w
	var camp: String = battle.campaign
	await _kabe()
	await _note(GameData.exe_text(camp, 0x519930))
	var rows := []
	for c in data:
		var s6 := w.cb(c, 6)
		var st := 0x519968 if s6 & 1 else (0x51996C if s6 & 2 else (0x519974 if w.cb(c, 5) == 0xFF else 0x519970))
		var r: String = battle.wsp(GameData.exe_raw(camp, 0x519980), [_given_family(c),
			GameData.exe_text(camp, 0x51997C if w.cb(c, 3) else 0x519978), "\u0001" + char(0x4F if s6 & 3 else 0x7F),
			GameData.exe_text(camp, st), Pd2World.s8(w.cb(c, 9))])
		for f in [0xA, 0xB, 0xC, 0xD]:
			var v := Pd2World.s8(w.cb(c, f))
			r += ("%2d " % v) if v < 0 else ("%2X " % v)
		var sk := w.cb(c, 8)
		r += battle.wsp("%s %s %s %s", [GameData.exe_text(camp, 0x50CBB3 if sk & 1 else 0x50CBB6),
			GameData.exe_text(camp, 0x50CBB3 if sk & 2 else 0x50CBB6), GameData.exe_text(camp, 0x50CBB3 if sk & 4 else 0x50CBB6),
			GameData.exe_text(camp, 0x50CBB3 if sk & 8 else 0x50CBB6)])
		rows.append(r)
	await _kabe_list(0x78, 0x50, 0x2F, 2, GameData.exe_text(camp, 0x5199E0), rows)


func _rmes_window(x: int, y: int, c: int, r: int, ids: Array, pics: Array = []) -> void:
	## an unframed window (flags 1, record +0 = 1: printed over the picture) printing PD2's
	## RMES texts in turn (their 0x0C clears, CR, '@' waits), op2.pac pictures drawn between
	## them ([index, x, y] after each text but the last)
	var gw := _text_window(x, y, c, r, 1, false)
	for i in ids.size():
		var t := GameData.debrief_raw("pd2", int(ids[i]))
		if GameWindow.translated(t):
			t = GameWindow.fit(t.replace("\r", "\n"), c)
		await gw.print_text(SortieView.fmt(t, []))
		if i < pics.size():
			var e: Array = pics[i]
			_over.append([_shared("op2", e[0]), e[1], e[2]])
			queue_redraw()
	gw.queue_free()


func _handover() -> void:
	## PD2's hand-over to DASH (0x48FA40 after step 7): scenes on colour 0 (0x0A), each faded
	## in and out: op2 0 at (8, 0x38) with RMES 0x20 in (0x188, 0x3C) 30 x 15; op2 3 at
	## (0x188, 0) with 0x21 in (0x30, 0xE0) 42 x 9; op2 1 at (0x20, 8) with 0x22 in (0x118,
	## 0xD8) 40 x 10, then op2 2 at (0x118, 0x18) and 0x23, op2 4 at (0x20, 0x10) and 0x24;
	## op2 5 at (0x30, 0), 1 s; op2 6 at (0, 0) with 0x25 in (0, 0x168) 80 x 2
	var scenes := [[[0, 8, 0x38], [0x188, 0x3C, 0x1E, 0xF], [0x20], []],
		[[3, 0x188, 0], [0x30, 0xE0, 0x2A, 9], [0x21], []],
		[[1, 0x20, 8], [0x118, 0xD8, 0x28, 10], [0x22, 0x23, 0x24], [[2, 0x118, 0x18], [4, 0x20, 0x10]]],
		[[5, 0x30, 0], [], [], []],
		[[6, 0, 0], [0, 0x168, 0x50, 2], [0x25], []]]
	for sc in scenes:
		await _fade(0.0)
		_blank()
		var pic: Array = sc[0]
		_over = [[_shared("op2", pic[0]), pic[1], pic[2]]]
		await _fade(1.0)
		if sc[1].is_empty():
			await _sleep(1000)
		else:
			await _rmes_window(sc[1][0], sc[1][1], sc[1][2], sc[1][3], sc[2], sc[3])
	await _fade(0.0)
	_blank()
	_bright = 1.0


func _click() -> void:
	_go = false
	if battle._headless():
		return
	while not _go and is_inside_tree():
		await get_tree().process_frame


func _picture(dir: String, i: int) -> void:
	_pic = null
	var p := "%s/%s/images/%s/%02d.bmp" % [GameData.ROOT, battle.campaign, dir, i]
	if FileAccess.file_exists(p):
		var img := Image.load_from_file(p)
		if img:
			_pic = ImageTexture.create_from_image(img)
	_bright = 1.0
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(0, 0, W, H), Color.BLACK)
	var mod := Color(_bright, _bright, _bright)
	if _pic:
		draw_texture(_pic, Vector2.ZERO, mod)
	for o in _over:
		if o[0]:
			draw_texture(o[0], Vector2(o[1], o[2]), mod)
	if _roll != null and _roll[0]:
		# the staff roll: the picture's top at y 0x16C - t, shown in the band y 0x24 .. 0x16B
		# at x 0xC0 (0x48FA40 copies its rows there every 10 ms)
		var tex: Texture2D = _roll[0]
		var top: int = 0x16C - int(_roll[1])
		var y0 := maxi(top, 0x24)
		var y1 := mini(top + tex.get_height(), 0x16C)
		if y1 > y0:
			draw_texture_rect_region(tex, Rect2(0xC0, y0, tex.get_width(), y1 - y0),
				Rect2(0, y0 - top, tex.get_width(), y1 - y0), mod)
	if not _card.is_empty():
		var c: Color = _card.fill
		for r in CARD_RECTS:
			draw_rect(Rect2(r[0], r[1], r[2] - r[0], r[3] - r[1]), c)
		for p in _card.pics:
			if p[0]:
				draw_texture(p[0], Vector2(p[1], p[2]))


# --- the score cards (0x468490) ------------------------------------------------------

## the fields cleared in colour 0x9E (the DIB's entry 0xA8: the pictures' table DS:0x518478)
const CARD_RECTS := [[0xF8, 0x68, 0x250, 0x81], [0x100, 0xCE, 0x208, 0x100], [0xF8, 0x10C, 0x240, 0x127],
	[0xF8, 0x134, 0x240, 0x14D], [0xF8, 0x159, 0x240, 0x17B]]
var _card := {}


func _tex(path: String) -> Texture2D:
	if not FileAccess.file_exists(path):
		return null
	var img := Image.load_from_file(path)
	return ImageTexture.create_from_image(img) if img else null


func _marks(pics: Array, n: int, x0: int, y: int, e: int) -> void:
	## a kill count's marks (score_p.pac): 100s entry e, 50s e + 1 (0x40 apart), the 10s one
	## picture e + 6 - tens, 5s e + 6 (0x28 apart, 3 px lower), the ones e + 7 (0x30 apart
	## after 8 px, or from 3 on in two staggered rows 7 px up / 10 px down, 0x28 apart)
	var root: String = GameData.ROOT
	var pic := func(i: int) -> Texture2D: return _tex("%s/images/score_p/%02d.bmp" % [root, i])
	var x := x0
	for _i in n / 100:
		pics.append([pic.call(e), x, y])
		x += 0x40
	var r := n % 100
	for _i in r / 50:
		pics.append([pic.call(e + 1), x, y])
		x += 0x40
	r %= 50
	if r / 10:
		pics.append([pic.call(e + 6 - r / 10), x, y])
		x += 0x40
	r %= 10
	for _i in r / 5:
		pics.append([pic.call(e + 6), x, y + 3])
		x += 0x28
	r %= 5
	if r < 3:
		x += 8
		for _i in r:
			pics.append([pic.call(e + 7), x, y + 3])
			x += 0x30
	else:
		for i in r:
			if i & 1 == 0:
				pics.append([pic.call(e + 7), x, y - 4])
			else:
				pics.append([pic.call(e + 7), x, y + 9])
				x += 0x28


func _marks_first(pics: Array, n: int) -> void:
	## the first row (0x471610's count) from x 0x100: 100s entry 0, 50s 1, 10s 2 (0x20
	## apart, y 0xD6), 5s 3 and the ones 4 (0x18 apart, y 0xD9; from 3 on two rows 0xCE /
	## 0xE8)
	var root: String = GameData.ROOT
	var pic := func(i: int) -> Texture2D: return _tex("%s/images/score_p/%02d.bmp" % [root, i])
	var x := 0x100
	for k in [[n / 100, 0], [(n % 100) / 50, 1], [(n % 50) / 10, 2]]:
		for _i in k[0]:
			pics.append([pic.call(k[1]), x, 0xD6])
			x += 0x20
	for _i in (n % 10) / 5:
		pics.append([pic.call(3), x, 0xD9])
		x += 0x18
	var r := n % 5
	if r < 3:
		for _i in r:
			pics.append([pic.call(4), x, 0xD9])
			x += 0x18
	else:
		for i in r:
			if i & 1 == 0:
				pics.append([pic.call(4), x, 0xCE])
			else:
				pics.append([pic.call(4), x, 0xE8])
				x += 0x18


func _cards() -> void:
	## 0x468490: for each crew with +4 <= the step (DS:0x50AD8E) and +2 == 0: score_g.pac,
	## the fields cleared, chara.pac and score_n.pac by crew +1 at (0x50, 0x76) / (0xF8,
	## 0x68), the four ratings ("%2x", " 0" for 0: attack (400, 0x80), AA (400, 0x90),
	## defense (0x238, 0x80), melee (0x238, 0x90); 2 x 1 of 16 px), the shots, hits and
	## kills ("%5l" at (0x118 / 0x160 / 0x1B0, 0xB0), 12 px), the hit rate ("%3s.%2s%%",
	## hits x 10000 / shots, at (0x210, 0xB0)), the kills' marks by kind (rows y 0xD6,
	## 0x110, 0x137, 0x160), a click; the combat record is crew +0xF's (13 B: kills 0-3,
	## shots, hits)
	var w: Pd2World = battle.w
	var camp: String = battle.campaign
	var root: String = GameData.ROOT
	var step := w.ds16(0x50AD8E)
	var bg := _tex("%s/%s/images/score_g/00.bmp" % [root, camp])
	var pal := GameWindow.bmp("%s/images/score_p/00.bmp" % root)      # (loads the pictures' table)
	var fill: Color = GameWindow._pal256[0xA8] if GameWindow._pal256.size() > 0xA8 else Color.BLACK
	for c in 64:
		if w.crew[c * 16 + 4] > step or w.crew[c * 16 + 2] != 0:
			continue
		var face := Pd2World.s8(w.crew[c * 16 + 1])
		_pic = bg
		_bright = 1.0
		_clear_windows()
		var pics := [[_tex("%s/images/chara/%02d.bmp" % [root, face]), 0x50, 0x76],
				[_tex("%s/%s/images/score_n/%02d.bmp" % [root, camp, face]), 0xF8, 0x68]]
		var rec := Pd2World.s8(w.crew[c * 16 + 0xF])
		var cb := func(f: int) -> int: return w.combat[13 * rec + f] if rec >= 0 and 13 * rec + f < w.combat.size() else 0
		var shots: int = cb.call(4) | cb.call(5) << 8
		var hits: int = cb.call(6) | cb.call(7) << 8
		var kills := [cb.call(0), cb.call(1), cb.call(2), cb.call(3)]
		_marks_first(pics, kills[0])
		_marks(pics, kills[1], 0xF8, 0x110, 5)
		_marks(pics, kills[2], 0xF8, 0x137, 0xD)
		_marks(pics, kills[3], 0xF8, 0x160, 0x15)
		_card = {"fill": fill, "pics": pics}
		queue_redraw()
		var stat := [[400, 0x80, 0xA], [400, 0x90, 0xB], [0x238, 0x80, 0xD], [0x238, 0x90, 0xC]]
		for st in stat:
			var v := Pd2World.s8(w.crew[c * 16 + st[2]])
			var gw := _text_window(st[0], st[1], 2, 1, 1, false)
			gw.print_text(" 0" if v == 0 else GameData.format_text("%2x", [v]))
		var cnt := [[0x118, shots], [0x160, hits], [0x1B0, kills[0] + kills[1] + kills[2] + kills[3]]]
		for k in cnt:
			var gw := _text_window(k[0], 0xB0, 5, 1, 1, false)
			gw.lh = 12
			gw.print_text("%5d" % k[1])
		var rate := hits * 10000 / shots if shots else 0
		var gw2 := _text_window(0x210, 0xB0, 7, 1, 1, false)
		gw2.print_text("%3d.%02d%%" % [rate / 100, rate % 100])
		await _click()


func _text_window(x: int, y: int, c: int, r: int, flags: int, clear: bool) -> GameWindow:
	var gw := GameWindow.new()
	gw.cols = c
	gw.rows = r
	gw.lh = 16
	gw.framed = false
	gw.black = true
	gw.transparent = not clear
	gw.code = ((flags & 3) << 2) | 0x71
	gw.waits = not battle._headless()
	gw.mouse_filter = Control.MOUSE_FILTER_IGNORE
	gw.position = Vector2(x, y)
	gw._layout()
	add_child(gw)
	return gw


func _clear_windows() -> void:
	for c in get_children():
		c.queue_free()


func play() -> void:
	for s in screens:
		var kind: String = s[0]
		var data: Variant = s[1]
		match kind:
			"clear", "fail", "gameover", "single":
				var dir: String = {"clear": "m_clr", "fail": "m_fail", "gameover": "gameover", "single": "single"}[kind]
				_clear_windows()
				_picture(dir, Debrief.chunk(battle.w) - 1 if kind == "clear" else 0)
				await _click()
				if data is Array and not data.is_empty():
					_bright = 0.5
					queue_redraw()
					for id in data:
						var t: String = GameData.debrief_text(battle.campaign, int(id))
						if t == "":
							continue
						_clear_windows()
						var gw := _text_window(0, 0, 0x50, 0x19, 1, true)
						if GameWindow.translated(t):
							t = GameWindow.fit(t, 0x50)
						await gw.print_text(t)
						await _click()
					_clear_windows()
			"ending":
				# (step 10) PD2: the screen cleared, end0.pac faded in, RMES 0x66-0x69 printed
				# in turn in a 31 x 20 window of 16 px (flags 1) over it (its '@' waits), faded
				# out; then (both) the score cards 0x468490 and the credits
				if not (data as Array).is_empty():
					_blank()
					_bright = 0.0
					_pic = _shared("end0", 0)
					await _fade(1.0)
					var gw := _text_window(0, 0, 0x1F, 0x14, 1, false)
					for id in data:
						var t: String = GameData.debrief_text(battle.campaign, int(id))
						if GameWindow.translated(t):
							t = GameWindow.fit(t, 0x1F)
						await gw.print_text(t)
					await _fade(0.0)
					_clear_windows()
				else:
					await _fade(0.0)
				await _cards()
				await _fade(0.0)
				_blank()
				if battle.campaign == "pd2":
					await _credits_pd2()
				else:
					await _credits_dash()
				_bright = 1.0
				_blank()
			"new_items":
				await _new_items(data)
			"recruits":
				await _recruits(data)
			"recovered":
				await _kabe()
				await _note(GameData.format_text(GameData.exe_raw(battle.campaign, 0x519A5C if data[1] else 0x519A84), [_given_family(int(data[0]))]))
			"drop_error":
				await _kabe()
				await _note(GameData.exe_text(battle.campaign, 0x519A40))
			"handover":
				await _handover()
			"results":
				_bright = 0.5
				queue_redraw()
				_clear_windows()
				var hd := _text_window(0x40, 0x10, 0x50, 1, 0, false)
				hd.print_text(GameData.exe_text(battle.campaign, 0x519AF8))
				hd._col = 0
				hd._row = 0
				hd.print_text(GameData.exe_text(battle.campaign, 0x519B34))
				var y := 0x20
				for r in data:
					_result_row(y, r)
					y += 16
				await _click()
				_clear_windows()
	_pic = null
	_card = {}
	queue_redraw()
	finished.emit()


func _result_row(y: int, r: Array) -> void:
	var camp: String = battle.campaign
	var cn: Array = GameData.tables(camp).crew_names
	var c: int = r[0]
	var nm: Array = cn[c] if c < cn.size() else ["", ""]
	var gw := _text_window(0x40, y, 0x50, 1, 0, false)
	gw.print_text(str(nm[0]))
	gw._col = 0xD
	gw.print_text(str(nm[1]))
	gw._col = 0x1C
	var st: int = r[1]
	if st == 0:
		gw.print_text(GameData.exe_text(camp, 0x519B88 if r[3] == 0 else 0x519B7C))
	elif st & 1 == 0:
		gw.code = (gw.code & 0xF) | 0x10
		gw.print_text(GameData.exe_text(camp, 0x519BA0))
	else:
		gw.code = (gw.code & 0xF) | 0x30
		gw.print_text(GameData.exe_text(camp, 0x519B94))
	gw.code = (gw.code & 0xF) | 0x70
	var mn: Array = GameData.tables(camp).machine_names
	var m: int = r[2]
	gw.print_text(str(mn[m]) if m >= 0 and m < mn.size() else "")
	gw._col = 0x37
	if r[3] == 0 or r[4]:
		gw.code = (gw.code & 0xF) | 0x10
		gw.print_text(GameData.exe_text(camp, 0x519BC4))
	elif st == 0:
		gw.print_text(GameData.exe_text(camp, 0x519BB0))
	else:
		gw.print_text(GameData.exe_text(camp, 0x519BB8))
