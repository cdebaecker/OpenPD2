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
		for c in get_children():
			if c is GameWindow and c._waiting:
				c.outside(ev.button_index)
				return
		_go = true


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
	if _pic:
		draw_texture(_pic, Vector2.ZERO, Color(_bright, _bright, _bright))


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
