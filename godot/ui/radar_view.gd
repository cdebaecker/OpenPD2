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
## Colours: the battle's 16-colour palette (the import's tactical one; KOMA's pixels are
## colours 0-15 of it).

const W := 640
const H := 400
var battle
var snap := {}                 # the world's state when last drawn (copied on the turn's thread)
var faces := {}                # talk window slot -> [pac, index, x, y]
var codes := {}                # window group (code >> 4) -> the code shown
var lines := {}                # window group -> [text, x, y, width (chars)]
var wins := {}                 # window group -> its GameWindow (0x489140)
var _label_wins: Array = []
var _label_texts: Array = []
var _tex := {}
var _koma: Array = []


func _init() -> void:
	size = Vector2(W, H)
	mouse_filter = Control.MOUSE_FILTER_STOP


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


func pal(i: int) -> Color:
	var p: Array = GameData.palette
	if i < 0 or i >= p.size():
		return Color.WHITE
	return Color8(int(p[i][0]), int(p[i][1]), int(p[i][2]))


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
	if snap.is_empty():
		return
	_labels()
	_draw_grid()
	_draw_list()
	for slot in faces:
		var f: Array = faces[slot]
		var t := tex("%s/images/%s/%02d.bmp" % [root, f[0], f[1]])
		if t:
			draw_texture(t, Vector2(f[2], f[3]))


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


func _gui_input(ev: InputEvent) -> void:
	## the radio's click waits (ui_wait_click): a left or right click anywhere goes on
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


func _draw_grid() -> void:
	var grid: PackedByteArray = snap.grid
	for y in 16:
		for x in 16:
			var mark := grid[16 * y + x] if 16 * y + x < grid.size() else 0
			var own := []
			var foe := []
			for g in 64:
				var G: Array = snap.groups[g]
				if Flight.s8(G[0x16]) != x or Flight.s8(G[0x17]) != y or Flight.s8(G[0x16]) < 0 or not snap.alive[g]:
					continue
				if (g < 20 or G[0x21] & 0xF0 < 0x21) and (g > 11 or g & 1 or G[2] & 0x30):
					own.append(g)
				elif g >= 20 and G[0x21] & 0xF0 > 0x20:
					foe.append(g)
			var here := not own.is_empty() or not foe.is_empty()
			if not ((here and not mark & 0x80) or mark & 1):
				continue
			var cx := 8 + 24 * x
			var cy := 0x20 + 24 * y
			draw_rect(Rect2(cx, cy, 24, 24), pal(0))
			if not mark & 0x81 or not here:
				continue
			_tile(cx, cy, 0, 0, 0x19)
			for side in 2:
				var gs: Array = own if side == 0 else foe
				if gs.is_empty():
					continue
				if gs.size() <= 3:
					for i in gs.size():
						_tile(cx, cy, 1 + side, i, snap.groups[gs[i]][4])
				else:
					var types := {}
					for g in gs:
						types[(snap.groups[g][2] >> 1) & 7] = true
					var t := 0x14
					if types.size() == 1:
						var ty: int = types.keys()[0]
						t = 0x15 + ty if ty < 3 else 0x18
					_tile(cx, cy, 1 + side, 0, t)
					_text("%02d" % gs.size(), cx + 8, cy + 8 * (1 + side) - 3, 0xF0, 10)


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


func _draw_list() -> void:
	var y := 0x1A
	for g in 20:
		var G: Array = snap.groups[g]
		if (g & 1 or G[2] & 0x30) and G[0x16] != 0xFF and snap.alive[g]:
			_text("%2d" % G[4], 0x178, y)
			_text(GameData.call_sign(battle.campaign, G[1]), 400, y)
			var ty: int = (G[2] >> 1) & 7
			_text(GameData.exe_text(battle.campaign, TYPES[ty]) if ty < TYPES.size() else "", 0x1F8, y)
			_text("%2d" % snap.alive[g], 0x210, y)
			var stt := _state(g)
			_text(GameData.exe_text(battle.campaign, stt) if stt else "", 0x228, y)
		y += 0x12


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
	queue_redraw()


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
	lines[grp] = [text, x, y, wd]
	if GameWindow.translated(text):
		lines[grp][0] = GameWindow.fit(text, wd)        # (engine-side: a translation wraps at its words)
	# the window (ui_window_create(1, .., x, y, wd, 7, 0x10, flags 1)) is kept for its group
	# and printed into: its 0x0C clears, its '@' waits for a click
	var gw: Variant = wins.get(grp)
	if gw == null or not is_instance_valid(gw):
		gw = GameWindow.text_window(x, y, wd, 7, 1)
		gw.waits = false
		add_child(gw)
		wins[grp] = gw
	queue_redraw()
	return gw


func radio_close(n: int) -> void:
	## 0x489390: window group n's windows (n < 0: all four groups)
	var gs := range(4) if n < 0 else [n]
	for g in gs:
		faces.erase(2 * g)
		faces.erase(2 * g + 1)
		lines.erase(g)
		codes.erase(g)
		if wins.has(g):
			if is_instance_valid(wins[g]):
				wins[g].queue_free()
			wins.erase(g)
	queue_redraw()
