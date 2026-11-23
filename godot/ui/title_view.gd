extends Control
class_name TitleView
## The title's screen (game_mode_loop 0x487D70's "StartWindow", 0x4086A0): a 640 x 400 8-bit
## DIB drawn through its colour table, as the game does. bits holds the pixels' indices (top
## row first), dib the 256 colours, master the copy of entries 10-245 at level 100
## (DS:0x554B28) and level the fade level (DS:0x554F7C: 0 black, 100 normal, 200 white).
## The routines are the game's (RE_NOTES "The title and the opening"):
## - 0x487260 a colour at a level, 0x487120 a window palette, 0x4875D0 the fade, 0x487A20
##   / 0x487990 the levels at once, 0x487500 after a picture's load;
## - 0x40DFE0 / 0x40E2A0 a .pac entry (its colours 26-255 raw into the DIB), 0x4EC170 a .gcp
##   logo (colour + 10, opaque);
## - ui_wait 0x452650 (a right click ends it with 10 when asked);
## - 0x438210 / 0x437AC0 the title's regions DS:0x50D878, their hover outline (0x4380C0 ->
##   0x46C370 mode 4) and the blink on release;
## - the opening 0x4783A0.
## The game's windows over it (0x452A10, 0x451E30, 0x452200) are GameWindows with the DIB's
## colours 10-25.

signal region_picked(i: int)

const W := 640
const H := 400
const FIXED := 0x518478          # 220 colours (B, G, R, 0): DIB 26-245 under the window tables
const REGIONS := 0x50D878        # five regions of 18 B: x0, y0, x1, y1 (int32), type, colour
const SHADER := """
shader_type canvas_item;
uniform sampler2D idx : filter_nearest;
uniform sampler2D pal : filter_nearest;
uniform vec4 lit = vec4(-1.0);   // the hovered word's box (x0, y0, x1, y1), the port's highlight
void fragment() {
	float i = texture(idx, UV).r * 255.0;
	vec3 c = texture(pal, vec2((i + 0.5) / 256.0, 0.5)).rgb;
	vec2 p = floor(UV * vec2(640.0, 400.0));
	if (p.x >= lit.x && p.x < lit.z && p.y >= lit.y && p.y < lit.w
			&& i > 105.5 && i < 109.5)
		c = mix(c, vec3(1.0), 0.45);   // the word's letters (pd2title.pac's 106-109) lit
	COLOR = vec4(c, 1.0);
}
"""

## The hover: the port lights the word's letters (engine-choices "The title's hover"); the
## game's XOR frame (0x4380C0) when classic_outline is set.
static var classic_outline := false
static var logos_done := false   # the logos play once a run (before game_mode_loop's title loop)

var bits := PackedByteArray()
var dib := PackedByteArray()     # 256 x (R, G, B)
var master := PackedByteArray()  # entries 10-245 x (R, G, B) at level 100
var level := 0
var fast := false                # tests and headless runs: no waits, no frames
var holder: Control              # the game's windows over the screen
var regions: Array = []          # [x0, y0, x1, y1, type, colour]
var menu_on := false
var _mat: ShaderMaterial
var _lit := -1                   # the word lit (the port's hover)
var _idx_img: Image
var _idx_tex: ImageTexture
var _pal_img: Image
var _pal_tex: ImageTexture
var _bits_dirty := true
var _pal_dirty := true
var _rclick := false
var _hover := -1
var _drawn := -1                 # the region whose outline is drawn (DS:0x523E08)
var _pressed := false
var _data := PackedByteArray()
var _data_base := 0


func _init() -> void:
	size = Vector2(W, H)
	mouse_filter = Control.MOUSE_FILTER_STOP
	bits.resize(W * H)
	bits.fill(0)
	dib.resize(256 * 3)
	dib.fill(0)
	master.resize(236 * 3)
	master.fill(0)


func _ready() -> void:
	var di: Array = GameData.tables("pd2").get("data_image", [])
	if di.size() == 2:
		_data_base = int(di[0])
		_data = di[1]
	_idx_img = Image.create_empty(W, H, false, Image.FORMAT_R8)
	_idx_tex = ImageTexture.create_from_image(_idx_img)
	_pal_img = Image.create_empty(256, 1, false, Image.FORMAT_RGB8)
	_pal_tex = ImageTexture.create_from_image(_pal_img)
	var rect := TextureRect.new()
	rect.texture = _idx_tex
	rect.size = Vector2(W, H)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = SHADER
	mat.shader = sh
	mat.set_shader_parameter("idx", _idx_tex)
	mat.set_shader_parameter("pal", _pal_tex)
	rect.material = mat
	_mat = mat
	add_child(rect)
	holder = Control.new()
	holder.size = Vector2(W, H)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(holder)
	for i in 5:
		var a := REGIONS + 18 * i
		regions.append([_s32(a), _s32(a + 4), _s32(a + 8), _s32(a + 12), _u8(a + 16), _u8(a + 17)])
	regions.append(OPTIONS_REGION)


func _process(_d: float) -> void:
	if _bits_dirty:
		_bits_dirty = false
		_idx_img.set_data(W, H, false, Image.FORMAT_R8, bits)
		_idx_tex.update(_idx_img)
	if _pal_dirty:
		_pal_dirty = false
		_pal_img.set_data(256, 1, false, Image.FORMAT_RGB8, dib)
		_pal_tex.update(_pal_img)


func _u8(a: int) -> int:
	var o := a - _data_base
	return _data[o] if o >= 0 and o < _data.size() else 0


func _s32(a: int) -> int:
	var o := a - _data_base
	return _data.decode_s32(o) if o >= 0 and o + 4 <= _data.size() else 0


func repaint() -> void:
	_bits_dirty = true
	_pal_dirty = true


# --- the colours ----------------------------------------------------------------------------

static func level_channel(v: int, lvl: int) -> int:
	## 0x487260's maths for one channel: min(v x base / 100, 0xF0), then above 100 + (0xF0 - v)
	## x (lvl - 100) / 100 (signed, truncated), still capped at 0xF0
	var base := lvl if lvl < 0x65 else 100
	var add := 0 if lvl < 0x65 else lvl - 100
	var o := mini(v * base / 100, 0xF0)
	if add != 0:
		o = mini(o + int((0xF0 - v) * add / 100.0), 0xF0)
	return o


func colour(e: int, r: int, g: int, b: int, lvl: int) -> void:
	## 0x487260(e, b, r, g, lvl, table): DIB entry e at the level
	dib[3 * e] = level_channel(r, lvl)
	dib[3 * e + 1] = level_channel(g, lvl)
	dib[3 * e + 2] = level_channel(b, lvl)
	_pal_dirty = true


func _from_master(e0: int, e1: int, lvl: int) -> void:
	for e in range(e0, e1 + 1):
		var m := 3 * (e - 10)
		colour(e, master[m], master[m + 1], master[m + 2], lvl)


func win_palette(table: int, lvl: int) -> void:
	## 0x487120(table, lvl): the table's 16 colours (B, G, R, x) into the master's 0-15 and
	## Pd2.exe's fixed 220 (DS:0x518478) into 16-235; DIB entries 10-245 at lvl; level = lvl
	for k in 16:
		var a := table + 4 * k
		master[3 * k] = _u8(a + 2)
		master[3 * k + 1] = _u8(a + 1)
		master[3 * k + 2] = _u8(a)
	for k in 220:
		var a := FIXED + 4 * k
		master[3 * (16 + k)] = _u8(a + 2)
		master[3 * (16 + k) + 1] = _u8(a + 1)
		master[3 * (16 + k) + 2] = _u8(a)
	_from_master(10, 245, lvl)
	level = lvl
	repaint()


func pal_a20(lvl: int) -> void:
	## 0x487A20(lvl): entries 26-245 at lvl, then 10-25 at 100; level = lvl, no wait
	_from_master(26, 245, lvl)
	_from_master(10, 25, 100)
	level = lvl
	repaint()


func pal_now(lvl: int) -> void:
	## 0x487990(lvl): entries 10-245 at lvl at once; level = lvl
	_from_master(10, 245, lvl)
	level = lvl
	repaint()


func fade(target: int) -> int:
	## 0x4875D0(target): the level in steps of 5 toward target (at most 200, rounded down to
	## 5), entries 10-245 from the master, one 17 ms wait a step (ui_wait(0x11, 1)); a right
	## click jumps to the end. 0, or 10 after a right click.
	var tgt := (target / 5) * 5 if target <= 200 else 200
	if tgt == level:
		return 0
	var step := 5 if level < tgt else -5
	var cur := level
	var last := 0
	while true:
		cur += step
		if cur == tgt:
			break
		_from_master(10, 245, cur)
		repaint()
		last = await wait(0x11, true)
		if last == 10:
			break
	_from_master(10, 245, tgt)
	repaint()
	level = tgt
	return last


func pal16() -> Array:
	## the windows' colours 0-15: DIB entries 10-25 as they are now
	var out := []
	for k in 16:
		var e := 10 + k
		out.append(Color8(dib[3 * e], dib[3 * e + 1], dib[3 * e + 2]))
	return out


# --- the pictures ---------------------------------------------------------------------------

func clear() -> void:
	## every byte of the DIB = 0x0A (window colour 0)
	bits.fill(10)
	_bits_dirty = true


static func read_bmp(path: String) -> Array:
	## an 8-bit BMP of the import: [w, h, indices top row first, its 256 colours (R, G, B)]
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
		var s := off + row * stride
		for x in bw:
			px[y * bw + x] = d[s + x]
	var po := 14 + d.decode_u32(14)
	var pal := PackedByteArray()
	pal.resize(768)
	for i in 256:
		if po + 4 * i + 2 < d.size():
			pal[3 * i] = d[po + 4 * i + 2]
			pal[3 * i + 1] = d[po + 4 * i + 1]
			pal[3 * i + 2] = d[po + 4 * i]
	return [bw, bh, px, pal]


func load_colours(pic: Array) -> void:
	## 0x40DFE0 / 0x40E2A0's palette: BMP colours 26-255 raw into the DIB, then 0x487500: DIB
	## 26-245 into the master's 16-235, entries 10-245 at the current level
	var pal: PackedByteArray = pic[3]
	for e in range(26, 256):
		dib[3 * e] = pal[3 * e]
		dib[3 * e + 1] = pal[3 * e + 1]
		dib[3 * e + 2] = pal[3 * e + 2]
	for e in range(26, 246):
		for c in 3:
			master[3 * (e - 10) + c] = dib[3 * e + c]
	_from_master(10, 245, level)
	_pal_dirty = true


func picture(dir: String, entry: int) -> Array:
	return read_bmp("%s/images/%s/%02d.bmp" % [GameData.ROOT, dir, entry])


func blit(pic: Array, x: int, y: int, transparent := false) -> void:
	## the picture's top-left at (x, y), every byte copied (transparent: not the 0s)
	var pw: int = pic[0]
	var ph: int = pic[1]
	var px: PackedByteArray = pic[2]
	for r in ph:
		var sy := y + r
		if sy < 0 or sy >= H:
			continue
		for c in pw:
			var sx := x + c
			if sx < 0 or sx >= W:
				continue
			var v := px[r * pw + c]
			if transparent and v == 0:
				continue
			bits[sy * W + sx] = v
	_bits_dirty = true


func pac(dir: String, entry: int, x: int, y: int) -> Array:
	## 0x40DD20 / 0x40DFE0(file, entry, x, y): its colours, then its pixels opaque
	var pic := picture(dir, entry)
	if pic.is_empty():
		return pic
	load_colours(pic)
	blit(pic, x, y)
	return pic


## The port's OPTIONS (region 5, not the game's): a word under QUIT made of pd2title.pac's
## own letters at half size, between QUIT's foot (y 313) and the KOGADO plate (y 334).
## Each letter is a run of the words' letter colours (106-109) in a word's rows: [x0, x1,
## y0, y1] of START (S 205-217, T 260-271) and OPENING (O 204-216, P 220-230, N 245-257,
## I 261-265).
const OPTIONS_REGION := [200, 316, 264, 331, 1, 11]
const OPTIONS_LETTERS := [[204, 216, 257, 278], [220, 230, 257, 278], [260, 271, 194, 215],
		[261, 265, 257, 278], [204, 216, 257, 278], [245, 257, 257, 278], [205, 217, 194, 215]]


func options_word() -> void:
	## OPTIONS drawn into the DIB at (204, 318): each letter halved (a 2 x 2 block takes its
	## first letter pixel), 2 px apart, a 1 px shadow (index 113) right and below
	var x := 204
	var y := 318
	var glyphs := []
	for l in OPTIONS_LETTERS:
		var gw := (int(l[1]) - int(l[0]) + 2) / 2
		var gh := (int(l[3]) - int(l[2]) + 2) / 2
		var g := PackedByteArray()
		g.resize(gw * gh)
		for dy in gh:
			for dx in gw:
				var v := 0
				for k in 4:
					var sx: int = int(l[0]) + dx * 2 + (k & 1)
					var sy: int = int(l[2]) + dy * 2 + (k >> 1)
					if sx <= int(l[1]) and sy <= int(l[3]):
						var b := bits[sy * W + sx]
						if b >= 106 and b <= 109:
							v = b
							break
				g[dy * gw + dx] = v
		glyphs.append([g, gw, gh])
	for pass_i in 2:                     # the shadows first, then the letters
		var gx := x
		for e in glyphs:
			var g: PackedByteArray = e[0]
			for dy in int(e[2]):
				for dx in int(e[1]):
					var v := g[dy * int(e[1]) + dx]
					if v == 0:
						continue
					var px := gx + dx + (1 - pass_i)
					var py := y + dy + (1 - pass_i)
					bits[py * W + px] = 113 if pass_i == 0 else v
			gx += int(e[1]) + 2
	_bits_dirty = true


func gcp(name: String, x: int, y: int) -> void:
	## 0x4EC170(file, x, y): every pixel of the box, colour + 10 (0x4EC280), opaque; no palette
	var pic := read_bmp("%s/images/logos/%s.bmp" % [GameData.ROOT, name])
	if pic.is_empty():
		return
	var px: PackedByteArray = pic[2]
	for i in px.size():
		px[i] = px[i] + 10
	blit(pic, x, y)


# --- the waits --------------------------------------------------------------------------------

func wait(ms: int, rclick: bool) -> int:
	## ui_wait(ms, rclick) (0x452650): until more than ms have passed; 10 on a right click
	## when asked (a left click never ends it). The mouse's earlier clicks are flushed.
	if fast:
		return 0
	_rclick = false
	var end := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() <= end:
		await get_tree().process_frame
		if rclick and _rclick:
			return 10
	return 0


func frame() -> void:
	## a repaint of the opening's scrolls and wipes: one frame shown
	repaint()
	if not fast:
		await get_tree().process_frame


func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton:
		if ev.button_index == MOUSE_BUTTON_RIGHT and ev.pressed:
			_rclick = true
			if menu_on:
				_set_outline(-1)         # 0x437AC0: a right click clears the outline (-2, ignored)
		elif ev.button_index == MOUSE_BUTTON_LEFT and menu_on:
			if ev.pressed:
				_pressed = true
				var r := _region_at(ev.position)
				if r != -1 and regions[r][4] == 3:
					_pick(r)
			elif _pressed and _hover != -1 and _region_at(ev.position) == _hover:
				_pressed = false
				_release(_hover)
	elif ev is InputEventMouseMotion and menu_on:
		var r := _region_at(ev.position)
		if r != _hover:
			_hover = r
			if r == -1 or regions[r][4] != 3:
				_set_outline(r)


# --- the menu's regions (0x438210 / 0x437AC0) ---------------------------------------------------

func _region_at(p: Vector2) -> int:
	## the first region whose x0..x1, y0..y1 (inclusive) hold the point
	for i in regions.size():
		var g: Array = regions[i]
		if p.x >= g[0] and p.x <= g[2] and p.y >= g[1] and p.y <= g[3]:
			return i
	return -1


func outline(i: int) -> void:
	if not classic_outline:
		_light(i)
		return
	_frame(i)


func _light(i: int) -> void:
	## the port's hover: region i's word lit, or none when it is already lit (outline toggles,
	## as the XOR frame does)
	var g: Array = regions[i]
	if g[4] != 1 or _mat == null:
		return
	_lit = -1 if _lit == i else i
	_mat.set_shader_parameter("lit", Vector4(g[0], g[1], g[2], g[3]) if _lit == i else Vector4(-1, -1, -1, -1))


func _frame(i: int) -> void:
	## 0x4380C0 -> 0x46C370(x0, y0, x1 - 1, y1 - 1, mode 4, colour, type): type 1 XORs a
	## 1-pixel frame, each byte ((b - 10) ^ colour) + 10; its corners are XORed twice
	var g: Array = regions[i]
	if g[4] != 1:
		return
	var x0: int = g[0]
	var y0: int = g[1]
	var x1: int = g[2] - 1
	var y1: int = g[3] - 1
	var c: int = g[5]
	var xr := func(x: int, y: int):
		if x >= 0 and x < W and y >= 0 and y < H:
			bits[y * W + x] = (((bits[y * W + x] - 10) ^ c) + 10) & 0xFF
	for y in range(y0, y1 + 1):
		xr.call(x0, y)
		xr.call(x1, y)
	for x in range(x0, x1 + 1):
		xr.call(x, y0)
		xr.call(x, y1)
	_bits_dirty = true


func _set_outline(i: int) -> void:
	if _drawn != -1:
		outline(_drawn)
		_drawn = -1
	if i != -1:
		outline(i)
		_drawn = i


func menu_start() -> void:
	## 0x438210(5, DS:0x50D878): no hover, no press, then the click loop
	_hover = -1
	_drawn = -1
	_pressed = false
	menu_on = true
	var p := get_local_mouse_position()
	var r := _region_at(p)
	if r != -1:
		_hover = r
		_set_outline(r)


func _release(i: int) -> void:
	## the release over the hovered region: a region of a type other than 0 blinks (off, on,
	## off, on, off, 50 ms each step), then its index
	menu_on = false
	if regions[i][4] != 0:
		for k in 4:
			_set_outline(-1 if k % 2 == 0 else i)
			await wait(50, false)
		_set_outline(-1)
	_pick(i)


func _pick(i: int) -> void:
	menu_on = false
	_set_outline(-1)
	_hover = -1
	region_picked.emit(i)


func pick_region(i: int) -> void:
	## tests: the region chosen (as a release over it)
	if menu_on:
		_release(i)


# --- the logos (game_mode_loop, before the title loop) -------------------------------------------

func logos() -> int:
	## KOGADO / USAGI, then DETACH lit in five rounds with title1.wav after each; then white
	## (RE_NOTES "The title and the opening"). Returns after the fade to 200.
	win_palette(0x50D7AC, 0)
	gcp("kogado", 0xE0, 0xAA)
	gcp("usagi", 0x118, 0xEC)
	var r := await fade(100)
	if r != 10:
		r = await wait(2000, true)
		if r != 10:
			r = await fade(0)
	clear()
	gcp("detach", 0x18, 0xA8)
	win_palette(0x50D7EC, 0)
	# the five rounds: entries 11 + 3n .. 13 + 3n from white (15 a channel) to the table's
	# (DS:0x50D7F1 on), t + (15 - t) x k / 100 for k = 100, 95 .. 0, the DIB only
	for n in 5:
		var k := 100
		while k >= 0:
			for j in 3:
				var e := 11 + 3 * n + j
				var a := 0x50D7EC + 4 * (1 + 3 * n + j)
				var rgb := [_u8(a + 2), _u8(a + 1), _u8(a)]
				for ch in 3:
					var t: int = rgb[ch]
					dib[3 * e + ch] = (t + int((15 - t) * k / 100.0)) & 0xFF
			_pal_dirty = true
			if r != 10:
				repaint()
				r = await wait(0x11, true)
				if r == 10:
					break
			k -= 5
		GameAudio.wave("title1")             # 0x40D440(0, 1): after every round
		if r == 10:
			break
		repaint()
		r = await wait(0xA6, true)
		if r == 10:
			break
	repaint()
	win_palette(0x50D7EC, 100)
	if r != 10:
		await wait(1000, true)
	await fade(200)
	logos_done = true
	return 0


# --- the opening (0x4783A0) -------------------------------------------------------------------

func opening() -> int:
	## the title's entry 3: music_start(12), the names, pictures, scrolled texts and wipes,
	## the eyes, Yao, the legs and Selma; every wait ignores clicks (a right click only ends a
	## fade); a fade to white at the end. 0.
	await fade(0)
	clear()
	GameAudio.music_start(12)
	pac("op_name", 0, 0xF8, 0xA8)
	await fade(100)
	repaint()
	await wait(1000, false)
	pac("op_name", 1, 0x108, 200)
	repaint()
	await wait(1500, false)
	await fade(0)
	pac("op_wai", 4, 0, 0x24)
	await fade(100)
	repaint()
	await wait(1500, false)
	for e in [[2, 0x1E8, 0x98], [3, 0x1D8, 0xD0]]:
		pac("op_name", e[0], e[1], e[2])
		repaint()
		await wait(1500, false)
	await _scroll(4, 0x110, 0, 0x24 * 4, 0, 0x110)          # scroll A
	await _wipe(1, 0, false)
	await wait(2000, false)
	await fade(0)
	clear()
	pac("op_wai", 5, 0xD8, 0x24)
	await fade(100)
	repaint()
	await wait(1500, false)
	for e in [[4, 8, 0xA8], [5, 8, 0xC0]]:
		pac("op_name", e[0], e[1], e[2])
		repaint()
		await wait(1500, false)
	await _scroll(5, 0, 0xD8, 0x26 * 4, 2, 0xE0)             # scroll B
	await _wipe(2, 0xD8, true)
	repaint()
	await wait(2000, false)
	await fade(0)
	clear()
	pac("op_wai", 3, 0, 0x24)
	await fade(100)
	repaint()
	await wait(2000, false)
	for e in [[6, 0x210, 0xA8], [7, 0x1B0, 0xC0]]:
		pac("op_name", e[0], e[1], e[2])
		repaint()
		await wait(2000, false)
	await _scroll(3, 0x110, 0, 0x24 * 4, 1, 0x110)          # scroll C
	pac("op_name", 8, 0x1B0, 0xC0)
	repaint()
	await wait(2000, false)
	await _wipe(0, 0, false)
	repaint()
	await wait(2000, false)
	for i in 5:
		pac("op_eye", i, 0x70, 0x81)
		repaint()
		await wait(100, false)
	await wait(1000, false)
	pac("op_name", 9, 0x1B0, 0xC0)
	repaint()
	await wait(2000, false)
	await fade(0)
	clear()
	pac("op_yao", 0, 0, 0x14)
	await fade(100)
	repaint()
	await wait(1000, false)
	await fade(0)
	clear()
	pac("op_ashi", 0, 0x98, 0)
	pal_now(100)
	repaint()
	await wait(1000, false)
	for e in [[1, 0x1E0, 0], [2, 0, 0xAB], [3, 0x150, 0xDE], [4, 0x140, 0], [5, 0x80, 0xB9], [6, 0x128, 0x39]]:
		pac("op_ashi", e[0], e[1], e[2])
		repaint()
		await wait(1000, false)
	pac("op_ashi", 7, 0, 0)
	repaint()
	await wait(4000, false)
	await fade(0)
	clear()
	pac("op_selma", 0, 0, 0)
	await fade(100)
	repaint()
	await wait(1000, false)
	for e in [[10, 0x30, 0xA8], [11, 0x30, 0xC8], [12, 0x30, 0xC8]]:
		pac("op_name", e[0], e[1], e[2])
		repaint()
		await wait(2000, false)
	await fade(0)
	clear()
	pac("op_selma", 1, 0, 0)
	await fade(100)
	repaint()
	await wait(1000, false)
	for e in [[13, 0x1C0, 0xA8], [14, 0x198, 0xC8]]:
		pac("op_name", e[0], e[1], e[2])
		repaint()
		await wait(2000, false)
	await fade(200)
	return 0


func _buffer(dir: String, entry: int) -> Array:
	## 0x40E2A0: a picture into a buffer, its colours loaded (the same as on screen here)
	var pic := picture(dir, entry)
	if not pic.is_empty():
		load_colours(pic)
	return pic


func _scroll(wai: int, src_x: int, dst_x: int, bg_w: int, moji: int, text_x: int) -> void:
	## the scrolls (0x4786CB, 0x478EBA, 0x4796B2): op_moji[moji] (144 px wide, its 0s not
	## drawn) rises from y 364 into the band y 36-363 over op_wai[wai]'s column (bg_w px from
	## its column src_x, put back at x dst_x + src_x each frame); then it runs through and
	## leaves at the top, and the background alone ends it
	var bg := _buffer("op_wai", wai)
	var txt := _buffer("op_moji", moji)
	if bg.is_empty() or txt.is_empty():
		return
	var tw: int = txt[0]
	var th: int = txt[1]
	var tp: PackedByteArray = txt[2]
	var restore := func():
		var bw: int = bg[0]
		var bp: PackedByteArray = bg[2]
		for r in 328:
			for c in bg_w:
				var sx := src_x + c
				if sx < bw:
					bits[(0x24 + r) * W + dst_x + src_x + c] = bp[r * bw + sx]
	var put := func(row: int, y: int):
		if row < 0 or row >= th or y < 0 or y >= H:
			return
		for c in tw:
			var v := tp[row * tw + c]
			if v != 0:
				bits[y * W + text_x + c] = v
	var t := 0
	while t < 0x148:                                  # the text rises
		restore.call()
		for row in t:
			put.call(row, 364 - t + row)
		await frame()
		t += 4
	var u := 0
	while u < th - 0x147:                             # through the band
		restore.call()
		for r in 328:
			put.call(u + r, 36 + r)
		await frame()
		u += 4
	await frame()
	var c := 0x148
	while c > 0:                                      # and out at the top
		var i := (328 - c) / 4
		restore.call()
		for r in c:
			put.call(th - 328 + 4 * i + r, 36 + r)
		await frame()
		c -= 4
	restore.call()
	await frame()


func _wipe(wai: int, x: int, right_to_left: bool) -> void:
	## the wipes: op_wai[wai] (424 x 328 at (x, 0x24)) a 4 px column at a time, each with a
	## 10 ms wait; left to right from column 0, or right to left from its last
	var pic := _buffer("op_wai", wai)
	if pic.is_empty():
		return
	var pw: int = pic[0]
	var px: PackedByteArray = pic[2]
	var c := 0
	while c < pw:
		var col := pw - c - 4 if right_to_left else c
		for r in 328:
			for k in 4:
				if col + k < pw:
					bits[(0x24 + r) * W + x + col + k] = px[r * pw + col + k]
		await frame()
		await wait(10, false)
		c += 4
