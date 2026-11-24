class_name RadarView
extends Control
## The flight window (the radar screen, Pd2.exe window DS:0x554FBC) as the battle shows it
## while the flight engine runs (DS:0x50DD44 set): drawn from the import in the game's
## 640 x 400 coordinates --
## - 0x43E510: the background ido_g.pac at (0, 0); the mission's map smap.pac (entry
##   chunk - 1, 360 x 360) at (8, 0x20); the times at (0xF0, 10) and (0x140, 10);
## - 0x43F150 / 0x43FB20: the 15 x 15 grid (DS:0x50DD40, cells of 24 px from (8, 0x20)):
##   a cell shows when a live group is on it (unless its mark has bit 7) or its mark has
##   bit 0; in it, KOMA.DAT's tile 0x19 at the top left, then up to three player groups'
##   counters (group +4) on the second row and the computer's on the third, more than three
##   as one counter (0x15 + type, 0x18 from type 3, 0x14 mixed) and their number;
## - 0x43E9D0: the status list of groups 0-19 (a row of 0x12 px from y 0x1A): number
##   (+4), call sign, type (歩 陸 砲 空 輸), members alive, state (MOVE / BUSY / STAND BY /
##   SHIFT / RETURN);
## - the radio (0x488DE0 / 0x489140 / 0x489390): its talk windows' portraits (Evkao.pac,
##   or Event.pac for the second kind) and the line at the positions of the window code.
## Colours: 0x43E510 sets the window's 16 colours from DS:0x50D6A1 (0x487120, as the sortie
## screen's); KOMA's pixels are colours 0-15 of it.

const W := 640
const H := 400
var battle
var snap := {}:                # the world's state when last drawn (copied on the turn's thread)
	set(v):
		snap = v
		if not v.is_empty():
			_process_grid()
var faces := {}                # talk window slot -> [pac, index, x, y]
var codes := {}                # window group (code >> 4) -> the code shown
var lines := {}                # window group -> [text, x, y, width (chars)]
var wins := {}                 # window group -> its GameWindow (0x489140)
var line_codes := {}           # window group -> the line's code (0x489140's table DS:0x5240C0)
var _label_wins: Array = []
var _label_texts: Array = []
var _tex := {}
var _koma: Array = []
var _top: Control = null       # what the game draws into the DIB over the list's windows
var close_button := false      # 0x43E510(1) (the area map): ido_gb.pac's 戻る at (0x238, 0x180)
var cells := {}                # 0x43F150's cell windows (DS:0x50DD38): Vector2i -> draws


class TopLayer extends Control:
	var rv
	func _draw() -> void:
		rv._draw_top(self)


func _init() -> void:
	size = Vector2(W, H)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_top = TopLayer.new()
	_top.rv = self
	_top.size = size
	_top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_top)


func _redraw() -> void:
	queue_redraw()
	if _top:
		_top.queue_redraw()


func tex(path: String) -> Texture2D:
	if not _tex.has(path):
		var img := Image.load_from_file(path) if FileAccess.file_exists(path) else null
		_tex[path] = ImageTexture.create_from_image(img) if img else null
	return _tex[path]


func koma(t: int) -> Texture2D:
	## KOMA.DAT tile t: 32 bytes, four planes of 8 rows (bit 0, bit 2, bit 1, bit 3 of the
	## colour), the high bit first (0x43FB20)
	if _koma.is_empty():
		var path := "%s/%s/koma.dat" % [GameData.ROOT, battle.campaign]
		var d := FileAccess.get_file_as_bytes(path) if FileAccess.file_exists(path) else PackedByteArray()
		for i in d.size() / 32:
			var img := Image.create(8, 8, false, Image.FORMAT_RGB8)
			for y in 8:
				for x in 8:
					var b := 7 - x
					var v := ((d[32 * i + 24 + y] >> b) & 1) << 3 | ((d[32 * i + 16 + y] >> b) & 1) << 1 \
							| ((d[32 * i + 8 + y] >> b) & 1) << 2 | ((d[32 * i + y] >> b) & 1)
					img.set_pixel(x, y, pal(v))
			_koma.append(ImageTexture.create_from_image(img))
	return _koma[t] if t >= 0 and t < _koma.size() else null


var _pal: Array = []


func palette16() -> Array:
	## DS:0x50D6A1's 16 colours (B, G, R, 0), the window's (0x487120 from 0x43E510)
	if _pal.is_empty() and battle and battle.w:
		for i in 16:
			var a := 0x50D6A1 + 4 * i
			_pal.append(Color8(battle.w.mem8(a + 2), battle.w.mem8(a + 1), battle.w.mem8(a)))
	return _pal


func pal(i: int) -> Color:
	var p := palette16()
	if p.is_empty():
		var t: Array = GameData.palette
		return Color8(int(t[i][0]), int(t[i][1]), int(t[i][2])) if i >= 0 and i < t.size() else Color.WHITE
	return p[i] if i >= 0 and i < 16 else Color.WHITE


func text_color(code: int) -> Color:
	## a window's text colour (0x438FE0): the code's high nibble, each channel + 10
	var c := pal((code >> 4) & 0xF)
	return Color8(mini(c.r8 + 10, 255), mini(c.g8 + 10, 255), mini(c.b8 + 10, 255))


## A snapshot of what the window shows, taken on the thread that runs the flight engine.
static func take(w: Pd2World) -> Dictionary:
	var groups := []
	for g in 64:
		var row := []
		for f in 35:
			row.append(Flight.gb(w, g, f))
		groups.append(row)
	var alive := []
	for g in 64:
		alive.append(Flight.group_alive(w, g))
	var orders := []
	for k in w.n_units:
		orders.append(w.ub(k, 6))
	return {"grid": w.grid.duplicate(), "groups": groups, "alive": alive, "orders": orders,
		"turn": w.mission_turn, "d": w.ds_506651}


func _font() -> Font:
	return battle.list_font() if battle else ThemeDB.fallback_font


func _text(t: String, x: float, y: float, code := 0xF0, fs := 12) -> void:
	draw_string(_font(), Vector2(x, y + fs), t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, text_color(code))


func _draw() -> void:
	draw_rect(Rect2(0, 0, W, H), Color.BLACK)
	var root: String = GameData.ROOT
	var bg := tex(root + "/images/ido_g/00.bmp")
	if bg:
		draw_texture(bg, Vector2.ZERO)
	var mi: int = battle.mission_index if battle else 0
	var sm := tex("%s/%s/images/smap/%02d.bmp" % [root, battle.campaign, mi])
	if sm:
		draw_texture(sm, Vector2(8, 0x20))
	if close_button:
		# 0x43E510(1): ido_gb.pac (72 x 16, 戻る) at (0x238, 0x180), its word translated
		var bimg: Image = load("res://ui/game_window.gd").picture_image(root + "/images/ido_gb/00.bmp", "ido_gb")
		if bimg:
			draw_texture(ImageTexture.create_from_image(bimg), Vector2(0x238, 0x180))
			load("res://ui/game_window.gd").draw_picture_words(self, "ido_gb", Vector2(0x238, 0x180))
	if snap.is_empty():
		return
	_labels()
	_draw_grid()
	_draw_list()


func _draw_top(ci: CanvasItem) -> void:
	## over the list's windows (the game draws these into the window's DIB): the radio's
	## portraits (0x488DE0), 0x453CD0's squares, the picks' XORs
	var root: String = GameData.ROOT
	for slot in faces:
		var f: Array = faces[slot]
		var t := tex("%s/images/%s/%02d.bmp" % [root, f[0], f[1]])
		if t:
			ci.draw_texture(t, Vector2(f[2], f[3]))
	if not route.is_empty():
		if route_xor:
			var ops := []
			for q in route:
				ops.append([q.x, q.y, q.x + route_size - 1, q.y + route_size - 1, 2])
			_xor(ops, route_colour, ci)
		else:
			for q in route:
				ci.draw_rect(Rect2(Vector2(q), Vector2(route_size, route_size)), pal(route_colour))
	_draw_pick(ci)


func _labels() -> void:
	## 0x43E510's unframed windows (flags 1: 12 px, no pattern): the mission's name
	## (DS:0x50CB4E by DS:0x50CE72) at (0x38, 10), 18 columns; the times (0x453900) at
	## (0xF0, 10) and (0x140, 10), 5 columns
	var want := [SaveFiles.mission_name(battle.script_no) if battle else "", _time(snap.turn, snap.d), _time(snap.turn, 0)]
	if want == _label_texts:
		return
	_label_texts = want
	for l in _label_wins:
		l.queue_free()
	_label_wins = []
	var at := [[0x38, 18], [0xF0, 5], [0x140, 5]]
	for i in 3:
		var gw := GameWindow.new()
		gw.cols = at[i][1]
		gw.rows = 1
		gw.lh = 12
		gw.framed = false
		gw.black = true
		gw.pal16 = palette16()
		gw.code = 0x75
		gw.waits = false
		gw.mouse_filter = Control.MOUSE_FILTER_IGNORE
		gw.position = Vector2(at[i][0], 10)
		gw._layout()
		add_child(gw)
		move_child(gw, 0)
		_label_wins.append(gw)
		gw.print_text(str(want[i]))


func waiting() -> Variant:
	## a radio window waiting for a click, or null
	for g in wins:
		if is_instance_valid(wins[g]) and wins[g]._waiting:
			return wins[g]
	return null


# --- マップ's area map: the window's regions (0x437AC0) and the grid's cells (0x440670) ---

var pick := ""                  # "region" / "cell" while the area map waits, else ""
var pick_cb: Callable           # the answer: a region (0-20) / a cell (Vector2i, or null)
var _hover_r := -1
var _pressed_r := -1
var _region_lit := true          # (the release's blink)
var start_cell := Vector2i(-1, -1)   # 0x440670's param_1: the group's cell, lit first
var _moved := false
var _hover_c := Vector2i(-1, -1)
var fire_cell := Vector2i(-1, -1)   # DS:0x50AD95 / 0x50AD97: not taken


func pick_open(kind: String) -> void:
	pick = kind
	_moved = false
	_hover_r = -1
	_pressed_r = -1
	_hover_c = start_cell if kind == "cell" else Vector2i(-1, -1)
	_redraw()


static func region_at(p: Vector2) -> int:
	## 0x43A570's 21 regions (0x452990(0x15, 400, 0x1A, 12, 12), then each row's y0 0x1A +
	## 0x12 i, y1 + 0xB, type 1): the status list's rows 0-19 (x 400-495), 20 the close
	## button (0x24A, 0x181)-(0x277, 0x18D), type 2; PtInRect over (x0, y0)-(x1 + 1, y1 + 1)
	var x := int(p.x)
	var y := int(p.y)
	for i in 20:
		var y0 := 0x1A + 0x12 * i
		if x >= 400 and x <= 400 + 95 and y >= y0 and y <= y0 + 0xB:
			return i
	if x >= 0x24A and x <= 0x277 and y >= 0x181 and y <= 0x18D:
		return 20
	return -1


static func cell_at(p: Vector2) -> Vector2i:
	## 0x440670: the grid's cells of 24 px over (8, 0x20)-(0x16F, 0x187) (PtInRect)
	if p.x < 8 or p.x >= 0x16F or p.y < 0x20 or p.y >= 0x187:
		return Vector2i(-1, -1)
	return Vector2i((int(p.x) - 8) / 0x18, (int(p.y) - 0x20) / 0x18)


func _pick_input(ev: InputEvent) -> bool:
	if pick == "":
		return false
	accept_event()
	if ev is InputEventMouseMotion:
		if pick == "region":
			_hover_r = region_at(ev.position)
			if _hover_r == -1:
				_pressed_r = -1       # (off every region: the press dropped)
		else:
			var c0 := cell_at(ev.position)
			if c0.x != -1:
				_moved = true
				_hover_c = c0
		_redraw()
	elif ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
		if pick == "region":
			var r := region_at(ev.position)
			if ev.pressed:
				_pressed_r = r
			elif r != -1 and _pressed_r != -1 and not _region_blinking:
				_release_region(r)     # 0x437AC0's 0x202: the region under the pointer
		elif ev.pressed and _moved:
			var c := cell_at(ev.position)
			if c.x != -1 and c != fire_cell and _blink_k < 0:
				_blink(c)
	elif ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_RIGHT and ev.pressed:
		if pick == "cell":
			_answer(null)             # 0x204: 0 (the area map asks a row again)
		# (a right click on the regions: -2, which 0x43A570 ignores)
	return true


var _region_blinking := false


func _release_region(r: int) -> void:
	## 0x437AC0 on the release: the region blinks twice (off, 50 ms, on, 50 ms), then off,
	## then it is the answer
	_region_blinking = true
	_hover_r = r
	for k in 2:
		_region_lit = false
		_redraw()
		await get_tree().create_timer(0.05).timeout
		_region_lit = true
		_redraw()
		await get_tree().create_timer(0.05).timeout
	_region_lit = false
	_redraw()
	_region_blinking = false
	_region_lit = true
	_answer(r)


var _blink_c := Vector2i(-1, -1)
var _blink_k := -1


func _blink(c: Vector2i) -> void:
	## 0x440670 after a cell's click (0x4409B4): its hover fill off, then for k = 0 .. 15
	## (a 17 ms wait before each odd k) a 1 px frame inset by k XORed in colour 7 while k <
	## 12, the one inset by k - 4 XORed off: squares shrinking with a trail of four; then
	## the cell is the answer
	_hover_c = Vector2i(-1, -1)
	_blink_c = c
	for k in 16:
		if k % 2 == 1:
			var end := Time.get_ticks_msec() + 0x11
			while Time.get_ticks_msec() <= end:
				await get_tree().process_frame
		_blink_k = k
		_redraw()
	_blink_k = -1
	_answer(c)


var route: Array = []          # 0x453CD0's squares drawn so far (Vector2i, the window's DIB)
var route_size := 4
var route_colour := 15
var route_xor := false
static var route_skip := false   # DS:0x523E58: a right click during a route skips the waits from then on


func route_line(p0: Vector2i, p1: Vector2i, step := 4, sz := 4, colour := 15, xor := false, erase := false) -> void:
	## 0x453CD0: over max(|dx|, |dy|) / step steps, the point step x i along the line
	## (_line_step 0x4539A0) filled sz x sz in colour (mode 0 set, 4 XOR: drawn a second
	## time it goes), a 17 ms wait after each unless skipped (DS:0x523E58)
	if not erase:
		route = []
	route_size = sz
	route_colour = colour
	route_xor = xor
	var n := maxi(absi(p1.x - p0.x), absi(p1.y - p0.y)) / step
	for i in n:
		if erase:
			if not route.is_empty():
				route.pop_front()
		else:
			route.append(Ai.line_step(p0.x, p0.y, p1.x, p1.y, step * i))
		_redraw()
		if route_skip:
			continue
		var end := Time.get_ticks_msec() + 0x11
		while Time.get_ticks_msec() <= end and is_inside_tree():
			await get_tree().process_frame


func ping(c: Vector2i) -> void:
	## 0x48BA40: the same shrinking squares at cell c (a script's point: DASH script 13's
	## contacts), its 17 ms waits before each odd k; nothing answered
	_blink_c = c
	for k in 16:
		if k % 2 == 1:
			var end := Time.get_ticks_msec() + 0x11
			while Time.get_ticks_msec() <= end and is_inside_tree():
				await get_tree().process_frame
		_blink_k = k
		_redraw()
	_blink_k = -1
	_redraw()


func _answer(v: Variant) -> void:
	pick = ""
	_hover_r = -1
	_pressed_r = -1
	_hover_c = Vector2i(-1, -1)
	_redraw()
	var cb := pick_cb
	pick_cb = Callable()
	if cb.is_valid():
		cb.call(v)


func _draw_pick(ci: CanvasItem) -> void:
	## 0x4380C0: the hovered region XORed in its colour (+0x11: 15) by its type (+0x10: rows
	## an outline, the close button a fill); 0x440670: the hovered cell's inside XOR 7
	## ((x 0x18 + 9, y 0x18 + 0x21)-(x 0x18 + 0x1F, y 0x18 + 0x37), type 2). XORed over the
	## pictures' own indices (GameWindow.xor_patch)
	## (0x4380C0 passes (x1 - 1, y1 - 1): rows (400, y0)-(494, y0 + 0xA), the close button
	## (0x24A, 0x181)-(0x276, 0x18C))
	if pick == "region" and _hover_r != -1 and _region_lit:
		if _hover_r == 20:
			_xor([[0x24A, 0x181, 0x276, 0x18C, 2]], 15, ci)
		else:
			var ry := 0x1A + 0x12 * _hover_r
			_xor([[400, ry, 494, ry + 0xA, 1]], 15, ci)
	elif _blink_k >= 0:                  # (a cell's click, or a point 0x48BA40)
		var bx := _blink_c.x * 0x18 + 9
		var by := _blink_c.y * 0x18 + 0x21
		var ops := []
		for j in range(maxi(0, _blink_k - 3), mini(11, _blink_k) + 1):
			ops.append([bx + j, by + j, bx + 0x16 - j, by + 0x16 - j, 1])
		if not ops.is_empty():
			_xor_cell(_blink_c, ops, 7, ci)
	elif pick == "cell" and _hover_c.x != -1:
		var cx := _hover_c.x * 0x18 + 9
		var cy := _hover_c.y * 0x18 + 0x21
		_xor_cell(_hover_c, [[cx, cy, cx + 0x16, cy + 0x16, 2]], 7, ci)


func _xor_cell(c: Vector2i, ops: Array, col: int, ci: CanvasItem) -> void:
	## the XOR over a cell as drawn: its window's black and counters when it has one (0x46C370
	## mode 4 on the DIB), else the pictures under it
	if not cells.has(c):
		_xor(ops, col, ci)
		return
	var idx := _cell_indices(c)
	var ox := 8 + 24 * c.x
	var oy := 0x20 + 24 * c.y
	for op in ops:
		for yy in range(op[1], op[3] + 1):
			for xx in range(op[0], op[2] + 1):
				var inside: bool = op[4] == 2 or yy == op[1] or yy == op[3] or xx == op[0] or xx == op[2]
				if inside and xx - ox >= 0 and xx - ox < 24 and yy - oy >= 0 and yy - oy < 24:
					var k := (yy - oy) * 24 + xx - ox
					idx[k] = idx[k] ^ col
	var img := Image.create(24, 24, false, Image.FORMAT_RGB8)
	for k in 24 * 24:
		img.set_pixel(k % 24, k / 24, pal(idx[k]))
	ci.draw_texture(ImageTexture.create_from_image(img), Vector2(ox, oy))


func _xor(ops: Array, c: int, ci: CanvasItem = null) -> void:
	var root: String = GameData.ROOT
	var mi: int = battle.mission_index if battle else 0
	var camp: String = battle.campaign if battle else "dash"
	var layers := [[root + "/images/ido_g/00.bmp", 0, 0], ["%s/%s/images/smap/%02d.bmp" % [root, camp, mi], 8, 0x20]]
	var pal16 := []
	for i in 16:
		pal16.append(pal(i))
	var r: Array = load("res://ui/game_window.gd").xor_patch(layers, ops, c, pal16)   # (not static: -s tools compile this before the GameData autoload)
	if not r.is_empty():
		(ci if ci else self).draw_texture(r[0], r[1])


func _gui_input(ev: InputEvent) -> void:
	if _pick_input(ev):
		return
	## the radio's click waits (ui_wait_click): a left or right click anywhere goes on
	if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_RIGHT and not route.is_empty():
		route_skip = true              # (0x453CD0's ui_wait(.., 0x11, 1) answering 10)
	if ev is InputEventMouseButton and ev.pressed:
		var gw: Variant = waiting()
		if gw:
			accept_event()
			gw.outside(ev.button_index)


func _time(t: int, d: int) -> String:
	## 0x453900: "HH:MM" of (t + d) x 5 minutes
	var m := (t + d) * 5
	var h := (m / 60) % 24
	m = m % 60
	return "%02d:%02d" % [h, m]


func _shown(g: int) -> bool:
	var G: Array = snap.groups[g]
	return (g > 11 or g & 1 or G[2] & 0x30) and G[0x16] != 0xFF and snap.alive[g]


func _here(x: int, y: int) -> bool:
	## a group alive on the cell (0x43F150's first two passes: any of the 64)
	for g in 64:
		var G: Array = snap.groups[g]
		if Flight.s8(G[0x16]) >= 0 and snap.alive[g] and Flight.s8(G[0x16]) == x and Flight.s8(G[0x17]) == y:
			return true
	return false


func _process_grid() -> void:
	## 0x43F150 on a snapshot's grid (the rules clear it after each redraw): a marked cell
	## without bit 0 and with no group loses its window; one without bit 7 and with a group
	## gets one (black); one with bit 0 or 7 and a window is drawn again: tile 0x19 at its top
	## left when groups are there, up to three player groups' counters (+4) on the second
	## row and the computer's on the third, more as one counter (0x15 + type, 0x18 from type
	## 3, 0x14 mixed) and their count ("%2d" at column 1, 8 px font, colour 7). A cell not
	## marked keeps what it shows.
	var grid: PackedByteArray = snap.grid
	for i in 256:
		var mark := grid[i] if i < grid.size() else 0
		var c := Vector2i(i & 15, i >> 4)
		if mark and not mark & 1 and not _here(c.x, c.y):
			cells.erase(c)
	for i in 256:
		var mark := grid[i] if i < grid.size() else 0
		var c := Vector2i(i & 15, i >> 4)
		if mark and not mark & 0x80 and _here(c.x, c.y) and not cells.has(c):
			cells[c] = []
	for i in 256:
		var mark := grid[i] if i < grid.size() else 0
		var c := Vector2i(i & 15, i >> 4)
		if not mark & 0x81 or not cells.has(c):
			continue
		var own := []
		var foe := []
		for g in 64:
			var G: Array = snap.groups[g]
			if Flight.s8(G[0x16]) != c.x or Flight.s8(G[0x17]) != c.y or Flight.s8(G[0x16]) < 0 or not snap.alive[g]:
				continue
			if (g < 20 or G[0x21] & 0xF0 < 0x21) and (g > 11 or g & 1 or G[2] & 0x30):
				own.append(g)
			elif g >= 20 and G[0x21] & 0xF0 > 0x20:
				foe.append(g)
		var ops := []
		if not own.is_empty() or not foe.is_empty():
			ops.append(["tile", 0, 0, 0x19])
		for side in 2:
			var gs: Array = own if side == 0 else foe
			if gs.is_empty():
				continue
			if gs.size() <= 3:
				for k in gs.size():
					ops.append(["tile", 1 + side, k, snap.groups[gs[k]][4]])
			else:
				var types := {}
				for g in gs:
					types[(snap.groups[g][2] >> 1) & 7] = true
				var t := 0x14
				if types.size() == 1:
					# (the game's own counter takes the computer's last type when both are on
					# the cell, and the computer's transports draw tile 0x19: both left out)
					var ty: int = types.keys()[0]
					t = 0x15 + ty if ty < 3 else 0x18
				ops.append(["tile", 1 + side, 0, t])
				ops.append(["num", 1 + side, gs.size()])
		cells[c] = ops


func _draw_grid() -> void:
	for c: Vector2i in cells:
		var cx := 8 + 24 * c.x
		var cy := 0x20 + 24 * c.y
		draw_rect(Rect2(cx, cy, 24, 24), pal(0))
		for op in cells[c]:
			if op[0] == "tile":
				_tile(cx, cy, op[1], op[2], op[3])
			else:
				_ank_text(cx + 8, cy + 8 * int(op[1]), "%2d" % int(op[2]), pal(7))


static var _ank := PackedByteArray()


func _ank_text(x: int, y: int, t: String, col: Color) -> void:
	## the cell window's 8 px font (flags 2: FONT_ANK.DAT)
	if _ank.is_empty():
		var p: String = GameData.ROOT + "/font_ank.dat"
		_ank = FileAccess.get_file_as_bytes(p) if FileAccess.file_exists(p) else PackedByteArray()
	for i in t.length():
		var k := t.unicode_at(i)
		if _ank.size() < (k + 1) * 8:
			continue
		for r in 8:
			var bb := _ank[k * 8 + r]
			for cc in 8:
				if (bb >> (7 - cc)) & 1:
					draw_rect(Rect2(x + 8 * i + cc, y + r, 1, 1), col)


func _cell_indices(c: Vector2i) -> PackedByteArray:
	## a drawn cell's 24 x 24 colour indices (black, its KOMA tiles), for the XORs over it
	var out := PackedByteArray()
	out.resize(24 * 24)
	if _koma_raw.is_empty():
		var path := "%s/%s/koma.dat" % [GameData.ROOT, battle.campaign]
		_koma_raw = FileAccess.get_file_as_bytes(path) if FileAccess.file_exists(path) else PackedByteArray()
	for op in cells[c]:
		if op[0] != "tile":
			continue
		var t: int = op[3]
		if _koma_raw.size() < 32 * (t + 1):
			continue
		for yy in 8:
			for xx in 8:
				var bb := 7 - xx
				var v := ((_koma_raw[32 * t + 24 + yy] >> bb) & 1) << 3 | ((_koma_raw[32 * t + 16 + yy] >> bb) & 1) << 1 \
						| ((_koma_raw[32 * t + 8 + yy] >> bb) & 1) << 2 | ((_koma_raw[32 * t + yy] >> bb) & 1)
				out[(8 * int(op[1]) + yy) * 24 + 8 * int(op[2]) + xx] = v
	for op in cells[c]:
		if op[0] == "num":
			pass                         # (the count's pixels: left out of the XOR's base)
	return out


var _koma_raw := PackedByteArray()


func _tile(cx: int, cy: int, row: int, col: int, t: int) -> void:
	var k := koma(t)
	if k:
		draw_texture(k, Vector2(cx + 8 * col, cy + 8 * row))


const TYPES := [0x514864, 0x51486C, 0x514874, 0x51487C, 0x514884]   # 歩 陸 砲 空 輸 (exe texts)
const MOVE := 0x514888
const BUSY := 0x514890
const STAND_BY := 0x514898
const SHIFT := 0x5148A4
const RETURN := 0x5148AC


func _state(g: int) -> int:
	## 0x43E9D0's state column
	var G: Array = snap.groups[g]
	var b: int = G[2]
	match (b >> 1) & 7:
		0:
			if b & 0x30 == 0x10:
				return MOVE
			if b & 0x30 == 0x20 and b & 0xC0 == 0x80:
				return BUSY
			return 0
		1:
			return 0
		2, 3:
			var m := b & 0x30
			if m == 0x10:
				return MOVE
			if m == 0x20:
				if b & 0xC0 == 0:
					for i in range(4, 0x10):
						var k: int = G[2 + i]
						if k != 0xFF and k < snap.orders.size() and snap.orders[k] != 0 and snap.orders[k] != 3:
							return BUSY
					return STAND_BY
				if b & 0xC0 == 0x40:
					return SHIFT
				return BUSY
			if m == 0x30:
				return RETURN
			return 0
		4:
			var m := b & 0x30
			if m == 0x10:
				return MOVE
			if m == 0x20 and b & 0xC0 == 0:
				return STAND_BY
			if m == 0x30:
				return RETURN
			return 0
	return 0


var _list_wins: Array = []
var _list_texts: Array = []


func _draw_list() -> void:
	## 0x43E9D0: per shown group of 0-19, a row from y 0x1A (0x12 px each): unframed windows
	## of 12 px (flags 1: code 0x75, colour 7) cleared with a zero pattern: "%2d" of +4 at
	## (0x178, y) 2 columns, the call sign at (400, y) 12, the type (歩 陸 砲 空 輸) at (0x1F8,
	## y) 2, "%2d" of the members alive at (0x210, y) 2, the state at (0x228, y) 10
	var want := []
	var y := 0x1A
	for g in 20:
		var G: Array = snap.groups[g]
		if (g & 1 or G[2] & 0x30) and G[0x16] != 0xFF and snap.alive[g]:
			var ty: int = (G[2] >> 1) & 7
			var stt := _state(g)
			want.append([0x178, y, 2, "%2d" % G[4]])
			want.append([400, y, 12, GameData.call_sign(battle.campaign, G[1])])
			want.append([0x1F8, y, 2, GameData.exe_text(battle.campaign, TYPES[ty]) if ty < TYPES.size() else ""])
			want.append([0x210, y, 2, "%2d" % snap.alive[g]])
			want.append([0x228, y, 10, GameData.exe_text(battle.campaign, stt) if stt else ""])
		y += 0x12
	if want == _list_texts:
		return
	_list_texts = want
	for l in _list_wins:
		l.queue_free()
	_list_wins = []
	for e in want:
		var gw := GameWindow.new()
		# (engine-side: a longer translation widens it, by the 12 px font's 6 px half-width
		# letters against the window's 8 px columns)
		gw.cols = maxi(e[2], ceili(GameWindow.text_cols(str(e[3])) * 6 / 8.0))
		gw.wrap_cols = maxi(gw.cols, GameWindow.text_cols(str(e[3])))
		gw.rows = 1
		gw.lh = 12
		gw.framed = false
		gw.black = true
		gw.solid_raw = 0x51               # (0x43E9D0: the record's +0x65 = 0x47: ido_g's green)
		gw.pal16 = palette16()
		gw.code = 0x75
		gw.waits = false
		gw.mouse_filter = Control.MOUSE_FILTER_IGNORE
		gw.position = Vector2(e[0], e[1])
		gw._layout()
		add_child(gw)
		move_child(gw, 0)
		_list_wins.append(gw)
		gw.print_text(str(e[3]))


# --- the radio's windows -------------------------------------------------------------

func radio_face(a: int, code: int, b: int) -> void:
	## 0x488DE0: a talk window for window group code >> 4: a different code shown in the
	## group closes its windows first; the position by the code's kind (code & 0xF0) and
	## number (10 / 11), b (codes 0x10 / 0x20 only; else a) picking the second slot
	var grp := (code >> 4) & 0xF
	if codes.get(grp, 0) != code and codes.get(grp, 0) != 0:
		radio_close(grp)
	var kind := code & 0xF0
	var n := code & 0xF
	var second := 0
	var x := a
	var y := a
	if kind != 0x10 and kind != 0x20:
		b = a
	var hit := true
	match kind:
		0:
			if n == 10:
				x = 0x1F8
				y = 8
			elif n == 0xB:
				x = 0x178
				y = 0x108
			else:
				hit = false
		0x10:
			if n == 10:
				if b == 0:
					x = 0x178
					y = 8
				else:
					x = 0x1F8
					y = 8
					second = 1
			elif n == 0xB:
				if b != 0:
					x = 0x1F8
					y = 0x88
					second = 1
				else:
					x = 0x178
					y = 0x88
			else:
				hit = false
		0x20:
			if n == 10 and b == 0:
				x = 0x1F8
				y = 8
			elif n == 0xB and b == 0:
				x = 0x178
				y = 0x108
			elif n == 10 or n == 0xB:
				x = 0x178
				y = 0x88
				second = 1
			else:
				hit = false
		0x30:
			second = 1
			if n == 10:
				x = 0x178
				y = 8
			elif n == 0xB:
				x = 0x178
				y = 0x88
			else:
				hit = false
		_:
			hit = false
	if not hit:
		x = a
		y = a
	codes[grp] = code
	faces[second + grp * 2] = ["event" if second else "evkao", a, x, y]
	_redraw()


func radio_say(text: String, code: int) -> Variant:
	## 0x489140: the line's window for the code's group (width 14 or 30 characters, 7 lines)
	var grp := (code >> 4) & 0xF
	var kind := code & 0xF0
	var n := code & 0xF
	var x := code
	var y := code
	var wd := code
	match kind:
		0, 0x20:
			if n == 10:
				x = 0x178; y = 8; wd = 0xE
			elif n == 0xB:
				x = 0x1F8; y = 0x108; wd = 0xE
		0x10:
			if n == 10:
				x = 0x178; y = 0x88; wd = 0xE
			elif n == 0xB:
				x = 0x178; y = 0x108; wd = 0xE
		0x30:
			if n == 10:
				x = 0x178; y = 0x88; wd = 0x1E
			elif n == 0xB:
				x = 0x178; y = 0x108; wd = 0x1E
	if line_codes.get(grp, 0) != 0 and line_codes[grp] != code:
		radio_close(grp)                # (another code in the group: its windows closed first)
	line_codes[grp] = code
	lines[grp] = [text, x, y, wd]
	if GameWindow.translated(text):
		lines[grp][0] = GameWindow.fit(text, wd)        # (engine-side: a translation wraps at its words)
	# the window (ui_window_create(1, .., x, y, wd, 7, 0x10, flags 1)) is kept for its group
	# and printed into: its 0x0C clears, its '@' waits for a click
	var gw: Variant = wins.get(grp)
	if gw == null or not is_instance_valid(gw):
		gw = GameWindow.text_window(x, y, wd, 7, 1)
		gw.pal16 = palette16()
		gw.waits = false
		add_child(gw)
		wins[grp] = gw
	_redraw()
	return gw


func radio_close(n: int) -> void:
	## 0x489390: window group n's windows (n < 0: all four groups)
	var gs := range(4) if n < 0 else [n]
	for g in gs:
		faces.erase(2 * g)
		faces.erase(2 * g + 1)
		lines.erase(g)
		codes.erase(g)
		line_codes.erase(g)
		if wins.has(g):
			if is_instance_valid(wins[g]):
				wins[g].queue_free()
			wins.erase(g)
	_redraw()
