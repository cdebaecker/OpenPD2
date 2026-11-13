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
