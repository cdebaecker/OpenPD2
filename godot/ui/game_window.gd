class_name GameWindow
extends Control
## The game's text and select windows, drawn from the import in the main window's 640 x 400
## coordinates, as Pd2.exe draws them --
## - a text window (ui_window_create 0x4528B0, printed by ui_window_print 0x438FE0): cols
##   columns of 8 px by rows lines of lh px; framed (+8 px each side: the eight 8 x 8 frame
##   tiles of 0x4F0DB0, DS:0x51FB78) over the background pattern (0x4F0860, DS:0x50C9E8);
##   its text code (byte +0x2C): colour in the high nibble, the font in bits 2-3 (0: 16 px,
##   1: 12 px, 2 / 3: 8 px FONT_ANK.DAT), inverse bit 1, bold bit 0 (0x439900: ＭＳ ゴシック
##   at -16 / -12 / -8, weight 700); a half-width character fills lh / 2 px, a full-width one
##   lh px, the glyph (lh % (h / 2)) / 2 px down; byte 1 + a code changes the colour (and
##   the font unless its bits 2-3 are both set), CR / LF go to the next line, 0x0C clears,
##   '@' waits for a click; a line past the last column wraps, a line past the last row
##   waits for a click and clears (0x439CF0);
## - the click wait (ui_wait_click 0x4399D0): a bar 2 px high under the current line, the
##   window's text width, XOR colour 15, blinking every 200 ms; a left or right click goes on;
## - a select window (the popup builder 0x40C090): a header text window (cols, rows, lh,
##   code) at the top, an item window below it (items of 16 px: up to 10 shown, more with
##   the scroll bar: 3 columns more, its arrows DS:0x5129B8 and thumb 0x453560), click
##   regions (the caller's, then the items: x 8 .. 8 cols + 7, 16 px each), the region
##   under the mouse outlined in XOR colour 15 (0x40BA50 -> 0x409010 -> 0x46C370 mode 4);
##   a right click answers -2 when the caller allows it. `chosen` gives the region's index
##   (the caller's regions first, then nregions + the item's index).
## Colours: the window's DIB palette, colours 0-15 at entries 10-25: the battle's 16
## colours (the import's tactical palette). Text: the code's colour, each channel + 10.
## The font is the system's ＭＳ ゴシック (not shipped; a CJK monospace stands in).

signal chosen(v: int)
signal _go

const SCROLL_SHOWN := 10      # 0x40C090: 12 - 2 (DS:0x50C9F8 = 0)

var cols := 20
var rows := 1
var lh := 16
var framed := true
var code := 0x71              # (flags & 3) << 2 | 0x71
var header := true            # a text window at the top (false: items only)
var items: Array = []         # the item window's lines
var item_cols := 0
var regions: Array = []       # [x0, y0, x1, y1, type (1 outline, 2 fill)] in window pixels
var right_cancel := false
var waits := true             # false: '@' and full windows do not wait (tests)
var black := false            # the inside cleared to colour 0 (no background pattern: DS:0x50C9F0)
var role := ""                # what the window asks (tests): "reaction", "weapon", ...
var pattern: Array = []       # another window pattern (two rows of 8 colours), as given to ui_window_create
var solid_raw := 0            # a solid DIB colour (the record's +0x65 + 10: the pictures' table) for clears
var pal16: Array = []         # the window's 16 colours when not the battle's (e.g. DS:0x50D6A1)
var transparent := false      # printed over what is behind until a clear (a record marked 1 before its first print)
var scroll := 0
var blink_rects: Array = []      # [x0, y0, x1, y1] (inclusive) blinked over the window
var blink_on := false

var _cells: Array = []        # [x, y, char, code]
var _col := 0
var _row := 0
var _bar := false
var _waiting := false
var _t := 0.0
var _hover := -1
var _buf := PackedByteArray()
var _raw := PackedByteArray()     # a picture's own colour index (0: the window's colour in _buf)
static var _pal256: Array = []
var _w := 0
var _h := 0
var _hh := 0                  # the header window's height
var _tex: ImageTexture
var _xtex: ImageTexture
var _dirty := true
var _all_regions: Array = []

static var _ui: Dictionary = {}
static var _ank := PackedByteArray()
static var _fonts := {}


# --- building ---------------------------------------------------------------------

static func text_window(x: int, y: int, c: int, r: int, flags := 1, f := true) -> GameWindow:
	## ui_window_create(framed, x, y, .., cols, rows, 0x10, flags): x rounded down to 8 px
	var gw := GameWindow.new()
	gw.cols = c
	gw.rows = r
	gw.framed = f
	gw.code = ((flags & 3) << 2) | 0x71
	gw.position = Vector2((x >> 3) << 3, y)
	gw._layout()
	return gw


static func select_window(x: int, y: int, head_cols: int, head_rows: int, head_flags: int,
		its: Array, its_cols: int, regs: Array, cancel: bool) -> GameWindow:
	## the popup builder 0x40C090(items, cols, x, y, regions, right-click cancel, header text,
	## header cols, rows, 16, flags); x rounded down to 8 px; the width the larger of the
	## header's and the items' (+3 with the scroll bar)
	var gw := GameWindow.new()
	gw.header = head_rows > 0
	gw.rows = head_rows
	gw.code = ((head_flags & 3) << 2) | 0x71
	gw.items = its
	gw.item_cols = its_cols
	gw.regions = regs
	gw.right_cancel = cancel
	var ic := its_cols + (3 if its.size() > SCROLL_SHOWN else 0)
	gw.cols = maxi(head_cols, ic) if not its.is_empty() else head_cols
	gw.position = Vector2((x >> 3) << 3, y)
	gw._layout()
	return gw


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP


func _layout() -> void:
	var f := 16 if framed else 0
	_hh = rows * lh + f if header else 0
	_w = cols * 8 + f
	_h = _hh
	if not items.is_empty():
		_h += (mini(items.size(), SCROLL_SHOWN) + 1) * 16
	size = Vector2(_w, _h)
	_buf.resize(_w * _h)
	_buf.fill(0)
	_raw.resize(_w * _h)
	_raw.fill(0)
	if header:
		_draw_window(0, 0, cols, rows, lh, framed)
	if not items.is_empty():
		_draw_window(0, _hh, cols, mini(items.size(), SCROLL_SHOWN), 16, true)
	_all_regions = regions.duplicate()
	for i in mini(items.size(), SCROLL_SHOWN):
		_all_regions.append([8, _hh + 8 + 16 * i, cols * 8 + 7 - (3 * 8 if items.size() > SCROLL_SHOWN else 0), _hh + 8 + 16 * i + 16, 1])
	if items.size() > SCROLL_SHOWN:
		var sx := (cols - 3) * 8 + 16
		var sy := _hh + 6
		_all_regions.append([sx, sy, sx + 14, sy + 14, 0])               # up
		_all_regions.append([sx, sy + 0x11, sx + 14, sy + 0x8F, 0])      # the track
		_all_regions.append([sx, sy + 0x90, sx + 14, sy + 0x9E, 0])      # down
		_draw_scroll(sx + 1, sy + 0x11)
	_dirty = true
	queue_redraw()


# --- the index buffer ------------------------------------------------------------

static func ui_data() -> Dictionary:
	if _ui.is_empty():
		var p: String = GameData.ROOT + "/ui.json"
		if FileAccess.file_exists(p):
			_ui = JSON.parse_string(FileAccess.get_file_as_string(p))
		if _ui == null or _ui.is_empty():
			_ui = {"frame": {}, "back": [[0, 0, 0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0, 0, 0]], "scroll": []}
	return _ui


func _px(x: int, y: int, c: int) -> void:
	if x >= 0 and y >= 0 and x < _w and y < _h:
		_buf[y * _w + x] = c & 15
		_raw[y * _w + x] = 0


func _ix(x: int, y: int) -> int:
	return _buf[y * _w + x] if x >= 0 and y >= 0 and x < _w and y < _h else 0


func _tile(name: String, x: int, y: int, n := 8) -> void:
	var t: Array = ui_data().frame.get(name, [])
	for r in mini(n, t.size()):
		for c in 8:
			_px(x + c, y + r, int(t[r][c]))


func _back(x: int, y: int, w: int, h: int) -> void:
	## 0x4F0860 / 0x4F0C00: the two-row pattern, row 0 at each cell's top (a window made
	## without one: DS:0x50C9F0's zeros)
	var b: Array = ui_data().back if not black else [[0, 0, 0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0, 0, 0]]
	if not pattern.is_empty():
		b = pattern
	for r in h:
		for c in w:
			_px(x + c, y + r, int(b[r & 1][c & 7]))
			if solid_raw > 0 and x + c < _w and y + r < _h:
				_raw[(y + r) * _w + x + c] = solid_raw       # a solid colour of the DIB (+0x65)


func _draw_window(x: int, y: int, c: int, r: int, h: int, f: bool) -> void:
	## 0x4F0DB0: the frame's top row, the sides by half lines, the bottom row
	if not f:
		_back(x, y, c * 8, r * h)
		return
	_tile("tl", x, y)
	for i in c:
		_tile("top", x + 8 + 8 * i, y)
	_tile("tr", x + 8 + 8 * c, y)
	var yy := y + 8
	for i in r * 2:
		_tile("left", x, yy, h / 2)
		_back(x + 8, yy, c * 8, h / 2)
		_tile("right", x + 8 + 8 * c, yy, h / 2)
		yy += h / 2
	_tile("bl", x, yy)
	for i in c:
		_tile("bottom", x + 8 + 8 * i, yy)
	_tile("br", x + 8 + 8 * c, yy)


func _dib(x: int, y: int) -> int:
	## the DIB's index at (x, y): a picture's own, or the window's colour + 10
	if x < 0 or y < 0 or x >= _w or y >= _h:
		return 10
	var r := _raw[y * _w + x]
	return r if r != 0 else _buf[y * _w + x] + 10


func _set_dib(x: int, y: int, v: int) -> void:
	v &= 0xFF
	if x < 0 or y < 0 or x >= _w or y >= _h:
		return
	if v >= 10 and v <= 25:
		_buf[y * _w + x] = v - 10
		_raw[y * _w + x] = 0
	else:
		_buf[y * _w + x] = 0
		_raw[y * _w + x] = v


func _rect(x0: int, y0: int, x1: int, y1: int, mode: int, c: int, type: int) -> void:
	## 0x46C370: type 1 an outline, 2 a fill, 0 a line; on the DIB's bytes: mode 0 sets
	## colour + 10, 1 sets 10, 2 / 3 / 4 AND / OR / XOR the byte less 10 with the colour (+ 10
	## again): over a picture its own indices
	var put := func(x: int, y: int) -> void:
		match mode:
			1:
				_set_dib(x, y, 10)
			2:
				_set_dib(x, y, ((_dib(x, y) - 10) & c) + 10)
			3:
				_set_dib(x, y, ((_dib(x, y) - 10) | c) + 10)
			4:
				_set_dib(x, y, (((_dib(x, y) - 10) & 0xFF) ^ c) + 10)
			_:
				_px(x, y, c)
	var ax := mini(x0, x1)
	var bx := maxi(x0, x1)
	var ay := mini(y0, y1)
	var by := maxi(y0, y1)
	match type:
		1:
			for x in range(ax, bx + 1):
				put.call(x, ay)
				put.call(x, by)
			for y in range(ay + 1, by):
				put.call(ax, y)
				put.call(bx, y)
		2:
			for y in range(ay, by + 1):
				for x in range(ax, bx + 1):
					put.call(x, y)
		_:
			var n := maxi(bx - ax, by - ay)
			for i in n + 1:
				var t := float(i) / maxf(n, 1)
				put.call(roundi(lerpf(x0, x1, t)), roundi(lerpf(y0, y1, t)))
	_dirty = true


static func bmp(path: String) -> Array:
	## an 8-bit DIB of the import (a PAC entry as it is): [width, height, indices top row
	## first], or [] when missing
	if not FileAccess.file_exists(path):
		return []
	var d := FileAccess.get_file_as_bytes(path)
	if d.size() < 54 or d.decode_u16(0) != 0x4D42 or d.decode_u16(28) != 8:
		return []
	var off := d.decode_u32(10)
	var bw := d.decode_s32(18)
	var bh := d.decode_s32(22)
	var top := bh < 0
	bh = absi(bh)
	var stride := (bw + 3) & ~3
	var px := PackedByteArray()
	px.resize(bw * bh)
	for y in bh:
		var row := y if top else bh - 1 - y
		for x in bw:
			px[y * bw + x] = d[off + row * stride + x]
	if _pal256.is_empty():
		# the DIB's palette past the window's colours: Pd2.exe's fixed table DS:0x518478 (entries
		# 26-245, 0x487120), which the pictures carry as they are
		var po := 14 + d.decode_u32(14)
		for i in 256:
			_pal256.append(Color8(d[po + 4 * i + 2], d[po + 4 * i + 1], d[po + 4 * i]) if po + 4 * i + 2 < d.size() else Color.BLACK)
	return [bw, bh, px]


static var _xor_pics := {}


static func xor_patch(layers: Array, ops: Array, c: int, pal16: Array) -> Array:
	## 0x46C370 mode 4 over pictures drawn as textures (the plan's and the flight window's):
	## the DIB's byte under each pixel is the topmost picture's own index (layers: [path, x,
	## y], bottom first; none: 10, the colour 0), XORed as ((v - 10) ^ c) + 10; ops [x0, y0,
	## x1, y1, type] (inclusive; type 1 an outline, 2 a fill) in turn. Returns [texture,
	## position] of the touched pixels (the others transparent), or [] when none.
	var idx := {}
	var lo := Vector2i(1 << 20, 1 << 20)
	var hi := Vector2i(-1, -1)
	for op in ops:
		var ax := mini(int(op[0]), int(op[2]))
		var bx := maxi(int(op[0]), int(op[2]))
		var ay := mini(int(op[1]), int(op[3]))
		var by := maxi(int(op[1]), int(op[3]))
		for y in range(ay, by + 1):
			for x in range(ax, bx + 1):
				if int(op[4]) == 1 and y != ay and y != by and x != ax and x != bx:
					continue
				var k := Vector2i(x, y)
				var v: int = idx[k] if idx.has(k) else _under(layers, x, y)
				idx[k] = ((((v - 10) & 0xFF) ^ c) + 10) & 0xFF
				lo = Vector2i(mini(lo.x, x), mini(lo.y, y))
				hi = Vector2i(maxi(hi.x, x), maxi(hi.y, y))
	if idx.is_empty():
		return []
	var img := Image.create(hi.x - lo.x + 1, hi.y - lo.y + 1, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for k in idx:
		var v: int = idx[k]
		var col: Color
		if v >= 10 and v <= 25:
			col = pal16[v - 10] if v - 10 < pal16.size() else color(v - 10)
		else:
			col = _pal256[v] if v < _pal256.size() else Color.BLACK
		img.set_pixel(k.x - lo.x, k.y - lo.y, col)
	return [ImageTexture.create_from_image(img), Vector2(lo)]


static func _under(layers: Array, x: int, y: int) -> int:
	for i in range(layers.size() - 1, -1, -1):
		var L: Array = layers[i]
		var path: String = L[0]
		if not _xor_pics.has(path):
			_xor_pics[path] = bmp(path)
		var b: Array = _xor_pics[path]
		if b.is_empty():
			continue
		var px := x - int(L[1])
		var py := y - int(L[2])
		if px >= 0 and py >= 0 and px < int(b[0]) and py < int(b[1]):
			return (b[2] as PackedByteArray)[py * int(b[0]) + px]
	return 10


func blit(path: String, x: int, y: int, mirror := false) -> Vector2i:
	## 0x40E410 / 0x40DFE0: a picture's pixels copied as they are into the window's DIB (its
	## indices 10-25 are the window's colours 0-15); mirrored (0x40DFE0 with 1) each row is
	## written right to left from x + width down to x + 1; its size
	var b := bmp(path)
	if b.is_empty():
		return Vector2i.ZERO
	var px: PackedByteArray = b[2]
	for yy in int(b[1]):
		for xx in int(b[0]):
			var v := px[yy * int(b[0]) + xx]
			var dx := x + (int(b[0]) - xx if mirror else xx)
			if v >= 10 and v <= 25:
				_px(dx, y + yy, v - 10)
			elif dx >= 0 and y + yy >= 0 and dx < _w and y + yy < _h:
				_buf[(y + yy) * _w + dx] = 0
				_raw[(y + yy) * _w + dx] = v          # a picture colour (DS:0x518478)
	_dirty = true
	queue_redraw()
	return Vector2i(b[0], b[1])


var overlays: Array = []      # [x0, y0, x1, y1, text, px]: translated labels over a picture's words


func overlay_label(x0: int, y0: int, x1: int, y1: int, text: String, fill: int, px := 12, col := Color.BLACK) -> void:
	## engine-side (not the game's): a picture's Japanese words (x0, y0)-(x1, y1) covered
	## with its face colour (the picture's index fill) and the translation drawn centred
	## in black, ＭＳ ゴシック bold of px (smaller when it would not fit)
	for yy in range(y0, y1 + 1):
		for xx in range(x0, x1 + 1):
			if xx >= 0 and yy >= 0 and xx < _w and yy < _h:
				_buf[yy * _w + xx] = 0
				_raw[yy * _w + xx] = fill
	overlays.append([x0, y0, x1, y1, text, px, col])
	_dirty = true
	queue_redraw()


func overlay_word(x0: int, y0: int, x1: int, y1: int, inks: Array, text: String, col: Color, px := 12) -> void:
	## engine-side: a picture's Japanese word erased, then the translation drawn centred in
	## col. The background is the colours of the 1 px ring around (x0, y0)-(x1, y1); inside,
	## every other pixel (the ink and its shading; inks too) takes the commonest background
	## colour of its row, so striped faces stay striped
	var ring := {}
	for xx in range(x0 - 1, x1 + 2):
		for yy in [y0 - 1, y1 + 1]:
			if xx >= 0 and yy >= 0 and xx < _w and yy < _h:
				ring[_raw[yy * _w + xx]] = true
	for yy in range(y0 - 1, y1 + 2):
		for xx in [x0 - 1, x1 + 1]:
			if xx >= 0 and yy >= 0 and xx < _w and yy < _h:
				ring[_raw[yy * _w + xx]] = true
	for v in inks:
		ring.erase(v)
	for yy in range(maxi(y0, 0), mini(y1 + 1, _h)):
		var counts := {}
		for xx in range(maxi(x0, 0), mini(x1 + 1, _w)):
			var v := _raw[yy * _w + xx]
			if ring.has(v):
				counts[v] = counts.get(v, 0) + 1
		var bg := -1
		var best := -1
		for v in counts:
			if counts[v] > best:
				best = counts[v]
				bg = v
		if bg < 0:
			for v in ring:
				bg = v
				break
		if bg < 0:
			continue
		for xx in range(maxi(x0, 0), mini(x1 + 1, _w)):
			if not ring.has(_raw[yy * _w + xx]):
				_raw[yy * _w + xx] = bg
	overlays.append([x0, y0, x1, y1, text, px, col])
	_dirty = true
	queue_redraw()


## Pictures' Japanese words (engine-side translations, outside Japanese): by picture, its
## words as [x0, y0, x1, y1 (the ink's box in the picture), ink indices, ui.csv key, text
## colour]. Measured from the import's pictures (notes/picture-words.md).
const PICTURE_WORDS := {
	"hensei_g": [[20, 106, 83, 117, [234], "UI_SORTIE_LISTS", Color8(215, 186, 143)],
		[110, 106, 189, 117, [234], "UI_SORTIE_REARM_ALL", Color8(215, 186, 143)],
		[10, 122, 50, 136, [146, 139, 128], "UI_SORTIE_ARMS", Color.WHITE],
		[56, 122, 96, 136, [146, 139, 128], "UI_SORTIE_PILOT", Color.WHITE],
		[110, 122, 150, 136, [146, 139, 128], "UI_SORTIE_GROUND", Color.WHITE],
		[156, 122, 196, 136, [146, 139, 128], "UI_SORTIE_AIR", Color.WHITE],
		[32, 146, 84, 157, [146, 139], "UI_SORTIE_DROP", Color.WHITE],
		[128, 146, 152, 158, [146, 139], "UI_SORTIE_FORM", Color.WHITE],
		[161, 146, 186, 158, [146, 139], "UI_SORTIE_TRANS", Color.WHITE],
		[32, 198, 108, 209, [146, 139], "UI_SORTIE_VEHICLES", Color.WHITE],
		[128, 198, 152, 210, [146, 139], "UI_SORTIE_FORM", Color.WHITE],
		[161, 198, 186, 210, [146, 139], "UI_SORTIE_TRANS", Color.WHITE],
		[32, 250, 109, 261, [146, 139], "UI_SORTIE_AIR_SUPPORT", Color.WHITE],
		[128, 250, 152, 262, [146, 139], "UI_SORTIE_FORM", Color.WHITE],
		[160, 250, 183, 262, [146, 139], "UI_SORTIE_CAPACITY", Color.WHITE],
		[6, 383, 48, 396, [245, 128, 121, 202], "UI_SORTIE_SYSTEM", Color.BLACK],
		[55, 382, 99, 397, [245, 128, 121, 202], "UI_SORTIE_BRIEF", Color.BLACK],
		[107, 382, 150, 397, [245, 128, 121, 202], "UI_SORTIE_PLAN", Color.BLACK],
		[157, 382, 201, 397, [245, 128, 121, 202], "UI_SORTIE_START", Color.BLACK]],
	"busou_b": [[7, 379, 74, 393, [245, 128, 121], "UI_EQUIP_CREW", Color.BLACK],
		[86, 379, 153, 393, [245, 128, 121], "UI_EQUIP_MACHINE", Color.BLACK]],
	"busou_g0": [[206, 349, 272, 360, [245, 128, 121], "UI_EQUIP_CHANGE", Color.BLACK],
		[206, 365, 272, 376, [245, 128, 121], "UI_EQUIP_UNEQUIP", Color.BLACK],
		[204, 381, 236, 392, [245, 128, 121], "UI_EQUIP_OK", Color.BLACK],
		[243, 381, 273, 392, [245, 128, 121], "UI_EQUIP_CANCEL", Color.BLACK]],
	"busou_g1": [[384, 246, 447, 257, [245, 128, 121], "UI_EQUIP_CHANGE", Color.BLACK],
		[384, 266, 447, 277, [245, 128, 121], "UI_EQUIP_UNEQUIP", Color.BLACK],
		[400, 334, 432, 345, [245, 128, 121], "UI_EQUIP_OK", Color.BLACK],
		[401, 354, 431, 365, [245, 128, 121], "UI_EQUIP_CANCEL", Color.BLACK]],
	"busou_g2": [[163, 345, 229, 356, [245, 128, 121], "UI_EQUIP_CHANGE", Color.BLACK],
		[251, 345, 317, 356, [245, 128, 121], "UI_EQUIP_UNEQUIP", Color.BLACK],
		[180, 369, 212, 380, [245, 128, 121], "UI_EQUIP_OK", Color.BLACK],
		[269, 369, 299, 380, [245, 128, 121], "UI_EQUIP_CANCEL", Color.BLACK]],
	"plan_g": [[387, 347, 450, 359, [245, 26], "UI_PLAN_SITUATION", Color.BLACK],
		[459, 347, 523, 359, [245, 26], "UI_PLAN_OBJECTIVE", Color.BLACK],
		[387, 367, 450, 379, [245, 26], "UI_PLAN_ENEMY", Color.BLACK],
		[459, 367, 523, 379, [245, 26], "UI_PLAN_FRIENDLY", Color.BLACK],
		[447, 271, 512, 283, [245, 26], "UI_PLAN_PLAN", Color.BLACK],
		[459, 327, 523, 339, [245, 26], "UI_PLAN_CONFIRM", Color.BLACK],
		[568, 358, 597, 372, [245, 26], "UI_PLAN_SORTIE", Color.BLACK],
		[555, 283, 628, 295, [245, 26], "UI_PLAN_HEIGHT", Color.BLACK]],
	"plan_gc": [[11, 107, 74, 119, [245, 26], "UI_PLAN_SITUATION", Color.BLACK],
		[83, 107, 147, 119, [245, 26], "UI_PLAN_OBJECTIVE", Color.BLACK],
		[11, 127, 74, 139, [245, 26], "UI_PLAN_ENEMY", Color.BLACK],
		[83, 127, 147, 139, [245, 26], "UI_PLAN_FRIENDLY", Color.BLACK],
		[71, 31, 136, 43, [245, 26], "UI_PLAN_PLAN", Color.BLACK],
		[83, 87, 147, 99, [245, 26], "UI_PLAN_CONFIRM", Color.BLACK],
		[192, 118, 221, 132, [245, 26], "UI_PLAN_SORTIE", Color.BLACK],
		[179, 43, 252, 55, [245, 26], "UI_PLAN_HEIGHT", Color.BLACK]],
	"plan_gb": [[28, 86, 91, 97, [214], "UI_PLAN_NOTES", Color8(247, 193, 131)],
		[202, 86, 236, 95, [139, 92], "UI_PLAN_DECIDE", Color8(220, 220, 220)]],
	"amap": [[359, 235, 424, 246, [245], "UI_PLAN_CLOSE", Color.BLACK]],
}


static func picture_image(path: String, pic: String) -> Image:
	## a picture as an Image with its words (PICTURE_WORDS[pic]) erased as overlay_word
	## does, for the views that draw pictures as textures; null when it does not read
	var b: Array = TitleView.read_bmp(path)
	if b.is_empty():
		return null
	var wd: int = b[0]
	var ht: int = b[1]
	var px: PackedByteArray = b[2]
	var pal: PackedByteArray = b[3]
	if GameData.language != "ja":
		for e in PICTURE_WORDS.get(pic, []):
			_erase_word(px, wd, ht, e[0], e[1], e[2], e[3], e[4])
	var rgb := PackedByteArray()
	rgb.resize(wd * ht * 3)
	for i in wd * ht:
		var v := px[i]
		rgb[3 * i] = pal[3 * v]
		rgb[3 * i + 1] = pal[3 * v + 1]
		rgb[3 * i + 2] = pal[3 * v + 2]
	return Image.create_from_data(wd, ht, false, Image.FORMAT_RGB8, rgb)


static func _erase_word(px: PackedByteArray, wd: int, ht: int, x0: int, y0: int, x1: int, y1: int, inks: Array) -> void:
	var ring := {}
	for xx in range(x0 - 1, x1 + 2):
		for yy in [y0 - 1, y1 + 1]:
			if xx >= 0 and yy >= 0 and xx < wd and yy < ht:
				ring[px[yy * wd + xx]] = true
	for yy in range(y0 - 1, y1 + 2):
		for xx in [x0 - 1, x1 + 1]:
			if xx >= 0 and yy >= 0 and xx < wd and yy < ht:
				ring[px[yy * wd + xx]] = true
	for v in inks:
		ring.erase(v)
	for yy in range(maxi(y0, 0), mini(y1 + 1, ht)):
		var counts := {}
		for xx in range(maxi(x0, 0), mini(x1 + 1, wd)):
			var v := px[yy * wd + xx]
			if ring.has(v):
				counts[v] = counts.get(v, 0) + 1
		var bg := -1
		var best := -1
		for v in counts:
			if counts[v] > best:
				best = counts[v]
				bg = v
		if bg < 0:
			for v in ring:
				bg = v
				break
		if bg < 0:
			continue
		for xx in range(maxi(x0, 0), mini(x1 + 1, wd)):
			if not ring.has(px[yy * wd + xx]):
				px[yy * wd + xx] = bg


static func draw_picture_words(ci: CanvasItem, pic: String, at: Vector2) -> void:
	## the translations of pic's words where pic is drawn at `at` (outside Japanese)
	if GameData.language == "ja":
		return
	for e in PICTURE_WORDS.get(pic, []):
		var t := GameData.ui_text(e[5])
		if t != e[5]:
			draw_label(ci, at.x + e[0], at.y + e[1], at.x + e[2], at.y + e[3], t, 12, e[6])


static func draw_label(ci: CanvasItem, x0: float, y0: float, x1: float, y1: float, t: String, px: int, col: Color) -> void:
	## a translated label centred in (x0, y0)-(x1, y1), ＭＳ ゴシック bold, smaller to fit
	var wd := x1 - x0 + 1
	var f := font(px, true)
	while px > 8 and f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x > wd:
		px -= 1
	var sz := f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, px)
	var x := x0 + floorf((wd - sz.x) / 2)
	var y := y0 + floorf((y1 - y0 + 1 - px) / 2) + f.get_ascent(px)
	ci.draw_string(f, Vector2(x, y), t, HORIZONTAL_ALIGNMENT_LEFT, -1, px, col)


func translate_picture(pic: String, ox: int, oy: int) -> void:
	## the picture's words (PICTURE_WORDS) at its place (ox, oy) in the window, outside
	## Japanese
	if GameData.language == "ja":
		return
	for e in PICTURE_WORDS.get(pic, []):
		var t := GameData.ui_text(e[5])
		if t != e[5]:
			overlay_word(ox + e[0], oy + e[1], ox + e[2], oy + e[3], e[4], t, e[6], 12)


func _draw_overlays() -> void:
	for o in overlays:
		var t: String = o[4]
		var px: int = o[5]
		if px == 8:
			# the 8 px font (FONT_ANK.DAT), as the windows' 8 px text
			var x8 := int(o[0]) + (int(o[2]) - int(o[0]) + 1 - 8 * t.length()) / 2
			for i in t.length():
				_ank_char(x8 + 8 * i, int(o[1]) + (int(o[3]) - int(o[1]) + 1 - 8) / 2, ank_code(t[i]), o[6], false)
			continue
		var wd: int = int(o[2]) - int(o[0]) + 1
		var f := font(px, true)
		while px > 8 and f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x > wd:
			px -= 1
		var sz := f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, px)
		var x := int(o[0]) + int((wd - sz.x) / 2)
		var y := int(o[1]) + int((int(o[3]) - int(o[1]) + 1 - px) / 2) + int(f.get_ascent(px))
		draw_string(f, Vector2(x, y), t, HORIZONTAL_ALIGNMENT_LEFT, -1, px, o[6])


func xor_rect(x0: int, y0: int, x1: int, y1: int, c: int, type: int) -> void:
	## 0x46C370 mode 4 on the window (a damaged part, 0x467520)
	_rect(x0, y0, x1, y1, 4, c, type)
	queue_redraw()


func _draw_scroll(x: int, y: int) -> void:
	## 0x40B6D0: the arrows' and track's shapes (DS:0x5129B8: x0, y0, x1, y1, colour, type)
	## at (x - 1, y - 0x11), then the thumb (0x453560) over the track
	for e in ui_data().get("scroll", []):
		if int(e[0]) < 0:
			continue
		_rect(int(e[0]) + x - 1, int(e[1]) + y - 0x11, int(e[2]) + x - 1, int(e[3]) + y - 0x11, 0, int(e[4]), int(e[5]))
	_thumb(x, y, x + 12, y + 0x8F - 0x11 - 2, items.size(), scroll, scroll + 9)


func _thumb(x0: int, y0: int, x1: int, y1: int, total: int, first: int, last: int) -> void:
	## 0x453560(x0, y0, x1, y1, the count, the first and last shown)
	if total < last or last <= first:
		_rect(x0, y0, x1, y1 - 1, 0, 7, 2)
		_rect(x1, y0, x1, y1 - 1, 0, 8, 0)
		_rect(x1, y1 - 1, x0, y1 - 1, 0, 8, 0)
		_rect(x0, y1 - 1, x0, y0, 0, 15, 0)
		_rect(x0, y0, x1, y0, 0, 15, 0)
		return
	var n := total - 1
	last = mini(last, n)
	var span := y1 - y0 + 1
	var top := (span * 100 / total) * first / 100 + y0
	var bot := (span - (n - last) * span / n) + y0
	if first > 0:
		_rect(x0, y0, x1, top - 1, 0, 0xD, 1)
		_rect(x0 + 1, y0 + 1, x1 - 1, top - 1, 0, 0xD, 1)
		_rect(x0 + 2, y0 + 2, x1 - 2, top - 1, 0, 0, 2)
	if last < n:
		_rect(x0, bot + 1, x1, y1 - 1, 0, 0xD, 1)
		_rect(x0 + 1, bot + 1, x1 - 1, y1 - 2, 0, 0xD, 1)
		_rect(x0 + 2, bot + 1, x1 - 2, y1 - 3, 0, 0, 2)
	_rect(x0, top, x1, bot - 1, 0, 7, 2)
	_rect(x1, top, x1, bot - 1, 0, 8, 0)
	_rect(x1, bot - 1, x0, bot - 1, 0, 8, 0)
	_rect(x0, bot - 1, x0, top, 0, 15, 0)
	_rect(x0, top, x1, top, 0, 15, 0)


# --- text -------------------------------------------------------------------------

static func half_width(ch: String) -> bool:
	return GameData._single_byte(ch.unicode_at(0))


static func font(px: int, bold: bool) -> Font:
	var k := px * 2 + int(bold)
	if not _fonts.has(k):
		var f := SystemFont.new()
		f.font_names = PackedStringArray(["MS Gothic", "ＭＳ ゴシック", "Noto Sans Mono CJK JP", "Noto Sans CJK JP", "monospace"])
		f.antialiasing = TextServer.FONT_ANTIALIASING_NONE
		f.hinting = TextServer.HINTING_NORMAL
		f.font_weight = 700 if bold else 400
		f.allow_system_fallback = true
		_fonts[k] = f
	return _fonts[k]


static func text_cols(t: String) -> int:
	## the text's width in columns (Shift-JIS bytes: lstrlenA)
	var n := 0
	var skip := false
	for ch in t:
		if skip:
			skip = false
			continue
		if ch == "\u0001":
			skip = true                 # a colour code: byte 1 and its value
			continue
		n += 1 if half_width(ch) else 2
	return n


static func coded(cells: Array) -> String:
	## [[text, code]] (the battle's text_cells) as the printer's text: byte 1 + the code
	## before each part (0xFF: none)
	var t := ""
	for c in cells:
		if int(c[1]) != 0xFF:
			t += "\u0001" + char(int(c[1]))
		t += str(c[0])
	return t


static func translated(t: String) -> bool:
	## a translation (Latin letters), laid out by the engine; the Japanese texts are printed
	## as they are
	for ch in t:
		var u := ch.unicode_at(0)
		if (u >= 0x41 and u <= 0x5A) or (u >= 0x61 and u <= 0x7A):
			return true
	return false


static func centred(t: String, c: int) -> String:
	## t centred in c columns (spaces on both sides)
	var n := text_cols(t)
	if n >= c:
		return t
	var l := (c - n) / 2
	return " ".repeat(l) + t + " ".repeat(c - n - l)


static func fit(t: String, c: int) -> String:
	## engine-side fit for the translations: a line longer than the window breaks at its
	## last space that fits (the game's own wrap breaks anywhere, which suits Japanese)
	## (the translations write the Japanese line breaks as two spaces: a too long line breaks
	## first at two spaces before a letter, then at its words)
	var out := []
	var src := []
	var cut := RegEx.create_from_string("  +(?=[^\\s\\d])")
	for line in t.replace("\r", "\n").split("\n"):
		if text_cols(line) <= c:
			src.append(line)
			continue
		var last := 0
		for m in cut.search_all(line):
			src.append(line.substr(last, m.get_start() - last))
			last = m.get_end()
		src.append(line.substr(last))
	for line: String in src:
		if line.find(" ") == -1 or text_cols(line) <= c:
			out.append(line)
			continue
		var cur := ""
		for word in line.split(" "):
			var cand: String = word if cur == "" else cur + " " + word
			if cur != "" and text_cols(cand) > c:
				out.append(cur)
				cur = word
			else:
				cur = cand
		out.append(cur)
	return "\n".join(out)


func _origin() -> Vector2i:
	return Vector2i(8, 8) if framed else Vector2i.ZERO


func clear() -> void:
	## 0x0C / a full window: the background again, the first line
	_cells = []
	_col = 0
	_row = 0
	_bar = false
	transparent = false
	if header:
		_draw_window(0, 0, cols, rows, lh, framed)
	queue_redraw()


func _newline() -> bool:
	## 0x439CF0: the next line, or (past the last) a click and a clear; true when it waits
	_col = 0
	_row += 1
	return _row >= rows


func print_text(t: String) -> void:
	## ui_window_print: a coroutine (await it); waits for clicks where the text asks
	var i := 0
	while i < t.length():
		var ch := t[i]
		i += 1
		match ch:
			"\u0001":
				if i < t.length():
					var p := t.unicode_at(i)
					i += 1
					var nc := (code & 0x0F) | (p & 0xF0)
					if (p & 0xC) != 0xC:
						nc = (nc & ~0xF) | (p & 0xF)
					code = nc
			"\n", "\r":
				if _newline():
					await _wait()
					clear()
			"\u000c":
				clear()
			"@":
				await _wait()
			_:
				var two := not half_width(ch)
				if _col + (2 if two else 1) > cols:
					if _newline():
						await _wait()
						clear()
				_cells.append([_col, _row, ch, code])
				_col += 2 if two else 1
	queue_redraw()


func _wait() -> void:
	queue_redraw()
	if not waits:
		return
	_waiting = true
	_t = 0.0
	await _go
	_waiting = false
	_bar = false
	queue_redraw()


func _process(delta: float) -> void:
	if not _waiting:
		return
	_t += delta
	if _t >= 0.2:
		_t = 0.0
		_bar = not _bar
		queue_redraw()


# --- input ------------------------------------------------------------------------

func _region_at(p: Vector2) -> int:
	for i in _all_regions.size():
		var r: Array = _all_regions[i]
		if p.x >= r[0] and p.x <= r[2] and p.y >= r[1] and p.y <= r[3]:
			return i
	return -1


func answer(v: int) -> void:
	## as a click on region v would (tests)
	chosen.emit(v)


func outside(button: int) -> void:
	## a click outside the window: a wait goes on; a right click cancels where allowed
	if _waiting:
		_go.emit()
	elif button == MOUSE_BUTTON_RIGHT and right_cancel:
		chosen.emit(-2)


func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseMotion:
		var h := _region_at(ev.position)
		if h != _hover:
			_hover = h
			queue_redraw()
		return
	if not (ev is InputEventMouseButton and ev.pressed):
		return
	if ev.button_index != MOUSE_BUTTON_LEFT and ev.button_index != MOUSE_BUTTON_RIGHT:
		return
	accept_event()
	if _waiting:
		_go.emit()
		return
	if ev.button_index == MOUSE_BUTTON_RIGHT:
		if right_cancel:
			chosen.emit(-2)
		return
	var r := _region_at(ev.position)
	if r < 0:
		return
	var nshown := mini(items.size(), SCROLL_SHOWN)
	if r < regions.size():
		chosen.emit(r)
	elif r < regions.size() + nshown:
		chosen.emit(r + scroll)
	else:
		var k := r - regions.size() - nshown            # 0 up, 1 the track, 2 down (0x452A10)
		if k == 0 and scroll > 0:
			scroll -= 1
		elif k == 1:
			var ry := int(ev.position.y) - (_hh + 6 + 0x11 + 1)
			scroll = clampi(items.size() * ry >> 7, 0, items.size() - SCROLL_SHOWN)
		elif k == 2 and scroll + SCROLL_SHOWN < items.size():
			scroll += 1
		_layout()


# --- drawing ----------------------------------------------------------------------

static func color(i: int) -> Color:
	var p: Array = GameData.palette
	if i < 0 or i >= p.size():
		return Color.WHITE
	return Color8(int(p[i][0]), int(p[i][1]), int(p[i][2]))


static func text_color(c: int) -> Color:
	## 0x438FE0: SetTextColor from the code's high nibble, each channel + 10
	var k := color((c >> 4) & 15)
	return Color8(mini(k.r8 + 10, 255), mini(k.g8 + 10, 255), mini(k.b8 + 10, 255))


func colour(i: int) -> Color:
	## the window's colour i: its own palette's when it has one (pal16)
	if pal16.size() == 16:
		return pal16[i & 15]
	return color(i)


func _texture(buf: PackedByteArray) -> ImageTexture:
	var img := Image.create(_w, _h, false, Image.FORMAT_RGB8)
	var cols_rgb := []
	for i in 16:
		cols_rgb.append(colour(i))
	for y in _h:
		for x in _w:
			var r := _raw[y * _w + x]
			img.set_pixel(x, y, _pal256[r] if r != 0 and r < _pal256.size() else cols_rgb[buf[y * _w + x]])
	return ImageTexture.create_from_image(img)


func _draw() -> void:
	if _w == 0:
		return
	var buf := _buf
	var lit := _hover >= 0 and _hover < _all_regions.size() and int(_all_regions[_hover][4]) in [1, 2]
	var blinks := blink_on and not blink_rects.is_empty()
	var xor_on := lit or (_bar and _waiting) or blinks
	if xor_on:
		var keep := _buf.duplicate()
		var keep_raw := _raw.duplicate()
		if blinks:
			# a blink's rects (0x445750: XOR colour 15 fills toggled every 0x85 ms)
			for r in blink_rects:
				_rect(r[0], r[1], r[2], r[3], 4, 0xF, 2)
		if lit:
			# 0x409010: the region outlined (type 1) or filled (type 2) in XOR 15
			var r: Array = _all_regions[_hover]
			_rect(r[0], r[1], r[2] - 1, r[3] - 1, 4, 0xF, int(r[4]))
		if _bar and _waiting:
			var o := _origin()
			var top := (mini(_row, rows - 1) + 1) * lh + o.y - 2     # (the line the wait is on)
			_rect(o.x, top, o.x + cols * 8, top + 1, 4, 0xF, 2)
		buf = _buf
		_xtex = _texture(buf)             # (kept: the canvas draws it after _draw returns)
		_buf = keep
		_raw = keep_raw
		if not transparent or lit or _bar:
			draw_texture(_xtex, Vector2.ZERO)
		_dirty = true
	else:
		if _dirty or _tex == null:
			_tex = _texture(_buf)
			_dirty = false
		if not transparent:
			draw_texture(_tex, Vector2.ZERO)
	var o := _origin()
	for c in _cells:
		# (the 8 px font's half-width characters, FONT_ANK, step 8 px a column; TextOut's lh / 2)
		var ank: bool = ((int(c[3]) >> 2) & 3) >= 2 and half_width(c[2]) and ank_code(str(c[2])) >= 0
		_draw_char(o.x + c[0] * (8 if ank else lh / 2), o.y + c[1] * lh, c[2], c[3])
	if not items.is_empty():
		# the items printed in turn into the item window ("%0Ns": cut and padded to the item
		# columns, colour codes kept and carried from one item to the next; flags 1: 12 px)
		var ic := 0x75
		for i in mini(items.size(), SCROLL_SHOWN):
			var t: String = str(items[scroll + i]) if scroll + i < items.size() else ""
			var x := 8
			var k := 0
			while k < t.length():
				var ch := t[k]
				k += 1
				if ch == "\u0001":
					if k < t.length():
						var p := t.unicode_at(k)
						k += 1
						var nc := (ic & 0x0F) | (p & 0xF0)
						if (p & 0xC) != 0xC:
							nc = (nc & ~0xF) | (p & 0xF)
						ic = nc
					continue
				if x + (8 if half_width(ch) else 16) > 8 + item_cols * 8:
					continue
				_draw_char(x, _hh + 8 + 16 * i, ch, ic, 16)
				x += 8 if half_width(ch) else 16
	if not overlays.is_empty():
		_draw_overlays()


func _draw_char(x: int, y: int, ch: String, c: int, h := -1) -> void:
	if h < 0:
		h = lh
	var px: int = [16, 12, 8, 8][(c >> 2) & 3]
	var k := colour((c >> 4) & 15)
	var col := Color8(mini(k.r8 + 10, 255), mini(k.g8 + 10, 255), mini(k.b8 + 10, 255))
	if px == 8 and half_width(ch) and ank_code(ch) >= 0:
		_ank_char(x, y + (h - 8) / 2, ank_code(ch), col, (c & 2) != 0)
		return
	var two := not half_width(ch)
	var dy: int = (h % px) / 2 if two else (h % maxi(px / 2, 1)) / 2
	var f := font(px, (c & 1) != 0)
	draw_char(f, Vector2(x, y + dy + f.get_ascent(px)), ch, px, col)


static func ank_code(ch: String) -> int:
	## the character's single-byte Shift-JIS code (FONT_ANK.DAT's index): ASCII, and the
	## half-width kana U+FF61-U+FF9F at 0xA1-0xDF; -1 otherwise
	var u := ch.unicode_at(0)
	if u < 256:
		return u
	if u >= 0xFF61 and u <= 0xFF9F:
		return u - 0xFF61 + 0xA1
	return -1


func _ank_char(x: int, y: int, k: int, col: Color, inverse: bool) -> void:
	## FONT_ANK.DAT: 8 bytes a character, the high bit at the left (0x438FE0's 8 px path)
	if _ank.is_empty():
		var p: String = GameData.ROOT + "/font_ank.dat"
		_ank = FileAccess.get_file_as_bytes(p) if FileAccess.file_exists(p) else PackedByteArray()
	if _ank.size() < (k + 1) * 8:
		return
	for r in 8:
		var b := _ank[k * 8 + r]
		if inverse:
			b = ~b & 0xFF
		for c in 8:
			if (b >> (7 - c)) & 1:
				draw_rect(Rect2(x + c, y + r, 1, 1), col)
