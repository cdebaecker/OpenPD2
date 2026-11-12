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
var scroll := 0

var _cells: Array = []        # [x, y, char, code]
var _col := 0
var _row := 0
var _bar := false
var _waiting := false
var _t := 0.0
var _hover := -1
var _buf := PackedByteArray()
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


func _ix(x: int, y: int) -> int:
	return _buf[y * _w + x] if x >= 0 and y >= 0 and x < _w and y < _h else 0


func _tile(name: String, x: int, y: int, n := 8) -> void:
	var t: Array = ui_data().frame.get(name, [])
	for r in mini(n, t.size()):
		for c in 8:
			_px(x + c, y + r, int(t[r][c]))


func _back(x: int, y: int, w: int, h: int) -> void:
	## 0x4F0860 / 0x4F0C00: the two-row pattern, row 0 at each cell's top
	var b: Array = ui_data().back
	for r in h:
		for c in w:
			_px(x + c, y + r, int(b[r & 1][c & 7]))


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


func _rect(x0: int, y0: int, x1: int, y1: int, mode: int, c: int, type: int) -> void:
	## 0x46C370: type 1 an outline, 2 a fill, 0 a line; mode 0 sets the colour, 4 XORs it
	var put := func(x: int, y: int) -> void:
		_px(x, y, (_ix(x, y) ^ c) if mode == 4 else c)
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
	for ch in t:
		if ch == "\u0001":
			continue
		n += 1 if half_width(ch) else 2
	return n


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


func _texture(buf: PackedByteArray) -> ImageTexture:
	var img := Image.create(_w, _h, false, Image.FORMAT_RGB8)
	var cols_rgb := []
	for i in 16:
		cols_rgb.append(color(i))
	for y in _h:
		for x in _w:
			img.set_pixel(x, y, cols_rgb[buf[y * _w + x]])
	return ImageTexture.create_from_image(img)


func _draw() -> void:
	if _w == 0:
		return
	var buf := _buf
	var xor_on := (_hover >= 0 and _hover < _all_regions.size() and int(_all_regions[_hover][4]) == 1) or (_bar and _waiting)
	if xor_on:
		var keep := _buf.duplicate()
		if _hover >= 0 and _hover < _all_regions.size() and int(_all_regions[_hover][4]) == 1:
			var r: Array = _all_regions[_hover]
			_rect(r[0], r[1], r[2] - 1, r[3] - 1, 4, 0xF, 1)
		if _bar and _waiting:
			var o := _origin()
			var top := (mini(_row, rows - 1) + 1) * lh + o.y - 2     # (the line the wait is on)
			_rect(o.x, top, o.x + cols * 8, top + 1, 4, 0xF, 2)
		buf = _buf
		_buf = keep
		_xtex = _texture(buf)             # (kept: the canvas draws it after _draw returns)
		draw_texture(_xtex, Vector2.ZERO)
		_dirty = true
	else:
		if _dirty or _tex == null:
			_tex = _texture(_buf)
			_dirty = false
		draw_texture(_tex, Vector2.ZERO)
	var o := _origin()
	for c in _cells:
		_draw_char(o.x + c[0] * (lh / 2), o.y + c[1] * lh, c[2], c[3])
	if not items.is_empty():
		for i in mini(items.size(), SCROLL_SHOWN):
			var t: String = str(items[scroll + i]) if scroll + i < items.size() else ""
			var x := 8
			for ch in t:
				if x + (8 if half_width(ch) else 16) > 8 + item_cols * 8:
					break
				_draw_char(x, _hh + 8 + 16 * i, ch, 0x75, 16)
				x += 8 if half_width(ch) else 16


func _draw_char(x: int, y: int, ch: String, c: int, h := -1) -> void:
	if h < 0:
		h = lh
	var px: int = [16, 12, 8, 8][(c >> 2) & 3]
	var col := text_color(c)
	if px == 8 and half_width(ch) and ch.unicode_at(0) < 256:
		_ank_char(x, y + (h - 8) / 2, ch.unicode_at(0), col, (c & 2) != 0)
		return
	var two := not half_width(ch)
	var dy: int = (h % px) / 2 if two else (h % maxi(px / 2, 1)) / 2
	var f := font(px, (c & 1) != 0)
	draw_char(f, Vector2(x, y + dy + f.get_ascent(px)), ch, px, col)


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
