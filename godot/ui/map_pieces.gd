class_name MapPieces
## The map window's pieces as Pd2.exe draws them into a hex's 48 x 36 cell (redraw_hex,
## 0x4F17F0), as textures from the import (units.json, map_pieces.json) --
## - out of view (in_view(x, y, 0) false) the tile is drawn through the mask 0x55: every
##   other pixel column (0, 2, 4 ..) black (0x48D0E0);
## - a target mark (the F layer's mark): the hex outline DS:0x518CE8 (47 rows of 48 px from
##   the cell's top) in colour 6 (0x48EBA0);
## - smoke: KIRI.SLD (36 x 48, a mask and three planes) over the tile (0x48DA10);
## - a unit (0x4F17F0): its sprite (get_unit_addr 0x4F1390: machine kind (+26) picks MUNIT
##   below 8, TUNIT below 0x19 (PD2 0x18), else HUNIT; facing +5 & 7 the 0x200 block: 32 x
##   32, a mask plane and planes for bits 0, 1, 2) at (8, 4) (0x48DE90); 100 - condition
##   in the small digits (4 x 5, opaque on colour 0; DS:0x518CA8, 0x48E640: two to an 8 px
##   column) or with option 0x1000 the large ones (8 x 7, DS:0x518C60, 0x48E480) at (8, 8),
##   coloured 7 below 50, 15 below 75, else 4 (0x4F1780); the computer's units stop there
##   (unless option 8); the AP at (8, 28) in colour 7 (4 when spotted and option 0x80);
##   concealed / carrying the icons DS:0x518CE0 (8 x 5, high / low nibble) in colour 4 at
##   (32, 28) (0x48E800); a computer's unit is drawn only when spotted (+0 bit 0x10) or
##   with option 0x40;
## - with option 0x8000 (DASH) a mine (the F layer's bit 7) and a strike's mark (12 x 16,
##   DS:0x518E08 + 0x60 k: mask and planes 0-2) at (24, 8) / (24, 10) (0x48ECA0).
## Colours: the battle's 16 (the import's tactical palette).

static var _doc := {}
static var _units := {}
static var _tex := {}


static func doc() -> Dictionary:
	if _doc.is_empty():
		var p: String = GameData.ROOT + "/map_pieces.json"
		if FileAccess.file_exists(p):
			var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(p))
			for k in d:
				_doc[k] = Marshalls.base64_to_raw(d[k])
	return _doc


static func units(camp: String) -> Dictionary:
	if not _units.has(camp):
		var p := "%s/%s/units.json" % [GameData.ROOT, camp]
		var d := {}
		if FileAccess.file_exists(p):
			var j: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(p))
			for k in ["m", "t", "h"]:
				d[k] = j.get(k, []).map(func(e): return Marshalls.base64_to_raw(e))
			d["kiri"] = Marshalls.base64_to_raw(j.get("kiri", ""))
		_units[camp] = d
	return _units[camp]


static func col(i: int) -> Color:
	var p: Array = GameData.palette
	return Color8(int(p[i][0]), int(p[i][1]), int(p[i][2])) if i >= 0 and i < p.size() else Color.WHITE


static func _img(w: int, h: int) -> Image:
	return Image.create(w, h, false, Image.FORMAT_RGBA8)


static func sprite(camp: String, kind: int, facing: int) -> Texture2D:
	## the sprite of machine kind `kind` facing `facing` (0x48DE90's planes: mask, bit 0,
	## bit 1, bit 2; 32 rows of 4 bytes each)
	var key := "s/%s/%d/%d" % [camp, kind, facing]
	if _tex.has(key):
		return _tex[key]
	var u := units(camp)
	var lim := 0x19 if camp == "dash" else 0x18
	var blk := PackedByteArray()
	if kind < 8:
		blk = u.m[kind] if kind < u.get("m", []).size() else PackedByteArray()
	elif kind < lim:
		blk = u.t[kind - 8] if kind - 8 < u.get("t", []).size() else PackedByteArray()
	elif kind - lim < u.get("h", []).size():
		blk = u.h[kind - lim]
	var t: Texture2D = null
	var o := (facing & 7) * 0x200
	if blk.size() >= o + 0x200:
		var img := _img(32, 32)
		for y in 32:
			for x in 32:
				var b := y * 4 + x / 8
				var bit := 0x80 >> (x & 7)
				if blk[o + b] & bit:
					var v := (1 if blk[o + 0x80 + b] & bit else 0) | (2 if blk[o + 0x100 + b] & bit else 0) | (4 if blk[o + 0x180 + b] & bit else 0)
					img.set_pixel(x, y, col(v))
		t = ImageTexture.create_from_image(img)
	_tex[key] = t
	return t


static func hexmark() -> Texture2D:
	if not _tex.has("hex"):
		var d: PackedByteArray = doc().get("hexmark", PackedByteArray())
		var img := _img(48, 47)
		for y in 47:
			for x in 48:
				if d.size() >= 282 and d[y * 6 + x / 8] & (0x80 >> (x & 7)):
					img.set_pixel(x, y, col(6))
		_tex["hex"] = ImageTexture.create_from_image(img)
	return _tex["hex"]


static func stripes() -> Texture2D:
	## out of view: the tile's even pixel columns black (mask 0x55)
	if not _tex.has("stripes"):
		var img := _img(48, 36)
		for y in 36:
			for x in range(0, 48, 2):
				img.set_pixel(x, y, Color.BLACK)
		_tex["stripes"] = ImageTexture.create_from_image(img)
	return _tex["stripes"]


static func smoke(camp: String) -> Texture2D:
	var key := "kiri/" + camp
	if not _tex.has(key):
		var k: PackedByteArray = units(camp).get("kiri", PackedByteArray())
		var img := _img(48, 36)
		if k.size() >= 0x360:
			for y in 36:
				for x in 48:
					var b := y * 6 + x / 8
					var bit := 0x80 >> (x & 7)
					if k[b] & bit:
						var v := (1 if k[0xD8 + b] & bit else 0) | (2 if k[0x1B0 + b] & bit else 0) | (4 if k[0x288 + b] & bit else 0)
						img.set_pixel(x, y, col(v))
		_tex[key] = ImageTexture.create_from_image(img)
	return _tex[key]


static func mark(kind: int) -> Texture2D:
	## a mine (0) or a strike (1): 12 rows of 16 px, the mask at -0x18, planes 0 / +0x18 / +0x30
	var key := "mark/%d" % kind
	if not _tex.has(key):
		var d: PackedByteArray = doc().get("marks", PackedByteArray())
		var img := _img(16, 12)
		var o := 0x18 + 0x60 * kind
		if d.size() >= o + 0x48:
			for y in 12:
				for x in 16:
					var b := y * 2 + x / 8
					var bit := 0x80 >> (x & 7)
					if d[o - 0x18 + b] & bit:
						var v := (1 if d[o + b] & bit else 0) | (2 if d[o + 0x18 + b] & bit else 0) | (4 if d[o + 0x30 + b] & bit else 0)
						img.set_pixel(x, y, col(v))
		_tex[key] = ImageTexture.create_from_image(img)
	return _tex[key]


static func number(ci: CanvasItem, at: Vector2, value: int, colour: int, large: bool) -> void:
	## 0x4F4B70: the digits from the most significant, small ones 4 px apart (opaque on
	## colour 0), large ones 8 px apart (only their set bits)
	var s := str(maxi(value & 0xFFFF, 0))
	var d: PackedByteArray = doc().get("digits_large" if large else "digits", PackedByteArray())
	for i in s.length():
		var n := s.unicode_at(i) - 48
		if large:
			for r in 7:
				var b := d[n * 7 + r] if d.size() > n * 7 + r else 0
				for x in 8:
					if b & (0x80 >> x):
						ci.draw_rect(Rect2(at.x + 8 * i + x, at.y + r, 1, 1), col(colour))
		else:
			ci.draw_rect(Rect2(at.x + 4 * i, at.y, 4, 5), col(0))
			for r in 5:
				var b := d[n * 5 + r] if d.size() > n * 5 + r else 0
				for x in 4:
					if b & (0x80 >> x):
						ci.draw_rect(Rect2(at.x + 4 * i + x, at.y + r, 1, 1), col(colour))


static func icons(ci: CanvasItem, at: Vector2, which: int) -> void:
	## 0x48E800: bit 1 carrying (the low nibble), bit 2 concealed (the high), colour 4
	var d: PackedByteArray = doc().get("icons", PackedByteArray())
	var m := (0x0F if which & 1 else 0) | (0xF0 if which & 2 else 0)
	for r in mini(5, d.size()):
		var b := d[r] & m
		for x in 8:
			if b & (0x80 >> x):
				ci.draw_rect(Rect2(at.x + x, at.y + r, 1, 1), col(4))
