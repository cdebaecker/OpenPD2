class_name PlanView
extends Control
## The operation plan's window (0x443F60, Pd2.exe window DS:0x554FA8) drawn from the
## import in the game's 640 x 400 coordinates --
## - its background plan_g.pac at (0, 0), the mission's map SMAP.pac (entry chunk - 1) at
##   (8, 0x20), the mission's name (DS:0x50CB4E by DS:0x50CE72) in the window at (0x38, 10);
## - the nine button regions (0x438210(9), DS:0x514968: pages A-D, the orders, the plans'
##   list, done, the area maps, and the XMS spot at the bottom right), which `pressed`
##   reports;
## - the orders (0x444730): plan_gb.pac at (0x178, 0xF0) while they are open, plan_gc.pac
##   put back after them;
## - a page (the mission's hooks, Plan.view_step): its title (0x188, 0x18) and lines
##   (0x188, 0x38, 28 columns, 16 px a line), its windows and pictures (the mini-map
##   mmap.pac at (0xB0, 0x50) in the frame at (0xA8, 0x48)), and the blink it waits on:
##   points (0x4DD5C0: 7 x 7 at (0xAE + 2x, 0x4E + 2y), the colour by turns with 0 every
##   0x85 ms), a frame (0x4DD7E0 at (0xB0 + 2x, 0x50 + 2y)), a SMAP cell (0x4DD9D0) or two
##   frames (0x4C7DD0); a click goes on (`advanced`);
## - the XMS box (button 8: "XMS : USE" / "XMS : unUSE", DS:0x50CBE4) until a click.
## Colours: the window's palette (0x487120, DS:0x50D6A1).

signal pressed(region: int)
signal advanced
signal maps_nav(k: int)          # the area maps' regions: 0 next, 1 the one before, 2 close
signal order_pressed(i: int)     # the orders' regions (DS:0x514A10): leave, group, name, type, time, target
signal cell_pressed(c: Vector2i) # a cell of the mission's map (8, 0x20) while one is asked

const W := 640
const H := 400
const REGIONS := [Rect2i(0x180, 0x158, 0x46, 0x12), Rect2i(0x1C8, 0x158, 0x47, 0x12),
	Rect2i(0x180, 0x16C, 0x46, 0x12), Rect2i(0x1C8, 0x16C, 0x47, 0x12),
	Rect2i(0x1BC, 0x10C, 0x47, 0x13), Rect2i(0x1C8, 0x144, 0x47, 0x12),
	Rect2i(0x230, 0x164, 0x3F, 0x13), Rect2i(0x228, 0x118, 0x4F, 0x13),
	Rect2i(0x278, 0x18F, 8, 1)]       # DS:0x514968: left, top, right, bottom (inclusive)

var battle
var chunk := 1
var title := ""                 # the mission's name
var page_title := ""
var lines: Array = []           # the page's lines (text)
var views: Array = []           # Plan.view_step's windows and pictures
var blink: Variant = null       # the blink waiting for a click
var orders := ""                # "" none, "open" (plan_gb), "closed" (plan_gc put back)
var note := ""                  # the XMS box's text, until a click
var maps_i := -1                # the area map shown (0x444500), -1 none
var list_win: Variant = null    # the plans' list's text window (0x4442C0) while it prints
var order_fills: Array = []     # the orders' windows filled with the picture table's 0xA0 (0x446320)
var fill_col := Color.BLACK
var asking_cell := false
var cell_frame: Variant = null  # the target cell's frame (0x446320's XOR frame), [x, y]
## 0x444730's regions (type 2): leave, the group, its name, its type, its time, its target
const ORDER_REGIONS := [Rect2i(576, 324, 39, 14), Rect2i(388, 244, 103, 15), Rect2i(492, 244, 131, 15),
	Rect2i(388, 260, 235, 15), Rect2i(388, 276, 159, 15), Rect2i(388, 308, 141, 15)]
## 0x444500's regions (type 2): next, the one before, close
const MAPS_REGIONS := [Rect2i(0x188, 0x120, 0x2F, 0xF), Rect2i(0x1B8, 0x120, 0x2F, 0xF), Rect2i(0x188, 0x130, 0x5F, 0xF)]
var _on := false
var _t := 0.0
var _tex := {}
var _pal: Array = []


func _init() -> void:
	size = Vector2(W, H)
	mouse_filter = Control.MOUSE_FILTER_STOP


func tex(path: String) -> Texture2D:
	if not _tex.has(path):
		var img := Image.load_from_file(path) if FileAccess.file_exists(path) else null
		_tex[path] = ImageTexture.create_from_image(img) if img else null
	return _tex[path]


func pal(i: int) -> Color:
	## the window's 16 colours (0x487120 from DS:0x50D6A1: B, G, R and a pad each; the
	## drawing codes 0-15 are its palette entries 10-25)
	if _pal.is_empty() and battle and battle.w:
		for k in 16:
			var a := 0x50D6A1 + 4 * k
			_pal.append(Color8(battle.w.mem8(a + 2), battle.w.mem8(a + 1), battle.w.mem8(a)))
	if i >= 0 and i < _pal.size():
		return _pal[i]
	return Color.WHITE


func _process(delta: float) -> void:
	if blink == null:
		return
	_t += delta
	if _t >= 0.133:                      # 0x85 ms
		_t = 0.0
		_on = not _on
		queue_redraw()


func _gui_input(ev: InputEvent) -> void:
	if not (ev is InputEventMouseButton and ev.pressed and ev.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]):
		return
	accept_event()
	if note != "":
		note = ""
		queue_redraw()
		return
	if blink != null:
		advanced.emit()
		return
	var p := Vector2i(ev.position)
	if list_win != null and is_instance_valid(list_win) and list_win._waiting:
		list_win.outside(ev.button_index)
		return
	if orders == "open":
		if asking_cell and ev.button_index == MOUSE_BUTTON_LEFT and p.x >= 8 and p.x < 8 + 360 and p.y >= 0x20 and p.y < 0x20 + 360:
			cell_pressed.emit(Vector2i((p.x - 8) / 24, (p.y - 0x20) / 24))
			return
		for i in ORDER_REGIONS.size():
			var r: Rect2i = ORDER_REGIONS[i]
			if p.x >= r.position.x and p.x <= r.end.x and p.y >= r.position.y and p.y <= r.end.y:
				order_pressed.emit(i)
				return
		return
	if maps_i >= 0:
		for i in MAPS_REGIONS.size():
			var r: Rect2i = MAPS_REGIONS[i]
			if p.x >= r.position.x and p.x <= r.end.x and p.y >= r.position.y and p.y <= r.end.y:
				maps_nav.emit(i)
				return
		return
	for i in REGIONS.size():
		var r: Rect2i = REGIONS[i]
		if p.x >= r.position.x and p.x <= r.end.x and p.y >= r.position.y and p.y <= r.end.y:
			pressed.emit(i)
			return


func _font() -> Font:
	return battle.list_font() if battle else ThemeDB.fallback_font


func _text(t: String, x: float, y: float, fs := 12, c := Color.WHITE) -> void:
	draw_string(_font(), Vector2(x, y + fs), t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, c)


func _frame(x: int, y: int, cols: int, rows: int, lh: int) -> void:
	## a ui_window_create window: its frame around cols x 8 by rows x line-height pixels
	var r := Rect2(x, y, cols * 8 + 16, rows * maxi(lh, 8) + 16)
	draw_rect(r, Color(0, 0, 0, 0.9))
	draw_rect(r, pal(15), false, 1.0)


func _draw() -> void:
	draw_rect(Rect2(0, 0, W, H), Color.BLACK)
	var root: String = GameData.ROOT
	var bg := tex(root + "/images/plan_g/00.bmp")
	if bg:
		draw_texture(bg, Vector2.ZERO)
	var camp: String = battle.campaign if battle else "dash"
	var sm := tex("%s/%s/images/smap/%02d.bmp" % [root, camp, chunk - 1])
	if sm:
		draw_texture(sm, Vector2(8, 0x20))
	_text(title, 0x38 + 8, 10 + 2)
	if orders != "":
		var o := tex(root + ("/images/plan_gb/00.bmp" if orders == "open" else "/images/plan_gc/00.bmp"))
		if o:
			draw_texture(o, Vector2(0x178, 0xF0))
	for v in views:
		match v[0]:
			"win":
				if v[1] != 0x188:               # the title and text windows are drawn below
					_frame(v[1], v[2], v[3], v[4], v[5])
			"pic":
				var dir: String = str(v[1]).get_basename()
				var t := tex("%s/%s/images/%s/%02d.bmp" % [root, camp, dir, int(v[2])])
				if t == null:
					t = tex("%s/images/%s/%02d.bmp" % [root, dir, int(v[2])])
				if t:
					draw_texture(t, Vector2(v[3], v[4]))
	if page_title != "" or not lines.is_empty():
		# (the title's and the text's windows are plan_g.pac's own frames)
		_text(page_title, 0x188 + 8, 0x18 + 6)
		# 28 columns of 8 px, 16 px a line (a translated line wraps at the window's width)
		# (a long translation takes a smaller size to stay in the window's 11 lines)
		var f := _font()
		var parts := []
		for l in lines:
			parts.append_array(str(l).split("\n"))
		var fs := 11
		while fs > 7:
			var tot := 0.0
			for part in parts:
				tot += f.get_multiline_string_size(part, HORIZONTAL_ALIGNMENT_LEFT, 28 * 8, fs).y
			if tot <= 11 * 16:
				break
			fs -= 1
		var y := 0x38 + 8.0
		for part in parts:
			var sz := f.get_multiline_string_size(part, HORIZONTAL_ALIGNMENT_LEFT, 28 * 8, fs)
			draw_multiline_string(f, Vector2(0x188 + 8, y + fs), part, HORIZONTAL_ALIGNMENT_LEFT, 28 * 8, fs, -1, Color.WHITE)
			y += maxf(sz.y, fs + 2)
	if maps_i >= 0:
		# 0x444500: AMAP.pac entry DS:0x50663D x 4 - 4 + i at (0x30, 0x48)
		var am := tex("%s/%s/images/amap/%02d.bmp" % [root, camp, (chunk - 1) * 4 + maps_i])
		if am:
			draw_texture(am, Vector2(0x30, 0x48))
	for f in order_fills:
		draw_rect(f, fill_col)
	if cell_frame != null:
		# 0x446320: the target cell's frame, XOR 15 (an outer and an inner fill: a 2 px ring)
		var r := Rect2(cell_frame[0] * 24 + 9, cell_frame[1] * 24 + 0x21, 0x17, 0x17)
		draw_rect(r, pal(15), false, 2.0)
	if blink != null and _on:
		_draw_blink(blink)
	if note != "":
		_frame(0xC0, 0xB0, 0x18, 2, 16)
		_text(note, 0xC0 + 8, 0xB0 + 10)


func _draw_blink(b: Array) -> void:
	match b[0]:
		"points":
			var c := pal(int(b[1]))
			var pts: Array = b[2]
			for i in range(0, pts.size() - 1, 2):
				draw_rect(Rect2(0xAE + 2 * int(pts[i]), 0x4E + 2 * int(pts[i + 1]), 7, 7), c)
		"rect":
			draw_rect(Rect2(0xB0 + 2 * b[1], 0x50 + 2 * b[2], 2 * (b[3] - b[1]) + 1, 2 * (b[4] - b[2]) + 1), pal(int(b[5])), false, 1.0)
		"cell":
			draw_rect(Rect2(8 + 24 * b[1], 0x20 + 24 * b[2], 24, 24), pal(15), false, 2.0)
		"rects":
			for q in [[b[1], b[2], b[3], b[4]], [b[5], b[6], b[7], b[8]]]:
				draw_rect(Rect2(0xB0 + 2 * q[0], 0x50 + 2 * q[1], 2 * (q[2] - q[0]) + 1, 2 * (q[3] - q[1]) + 1), pal(int(b[9])), false, 1.0)
