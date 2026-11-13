class_name AnimeView
extends Node2D
## The attacks' and blasts' animations (option 0x10 clear) over the map, as Pd2.exe's
## players draw them into the map's bitmap (RE_NOTES "The animations' players"):
## - ANIME.PCK (import: <campaign>/anime.pck) read as 0x480A90 does: a u32 header size,
##   (offset, size) pairs, the data after the header; an index past the table reads entry
##   0. An entry is a size-prefixed LZSS stream (the face.pac decoder 0x4482D0: a 4 KB ring
##   of zeros, writes from 0xFEE), or for the direction players a pack of its own whose
##   sub-entry (0x47E440: the shooter's direction from the target) is that stream;
## - a 32 x 32 frame is 0x280 bytes: a mask plane then the colour planes (bit 0 at +0x80,
##   1 +0x100, 2 +0x180, 3 +0x200), 4 bytes a row, the high bit first; a 40 x 40 frame 1000
##   bytes (planes at +200, +400, +600, +800, 5 bytes a row); colour = the battle palette;
## - drawn at the cell's corner (0x41FD00 / 0x419810 / 0x418060: x and y clamped to 1-0x46,
##   ((x - 1) x 48 + (y & 1) x 24, (y - 1) x 36) in the bitmap that starts at cell 1, which is
##   the engine's cell origin), the jittering players moved by dx x 8 px and dy rows.
## The players (frames, wait in ms, entry, size): PLAYERS. Frame i is drawn after the wait
## of call i and shows during the next wait; the last one is cleared at once (0x41F680
## restores the map after the loop), as is the picture after a click.

const PLAYERS := {
	0x4200D0: {"frames": 6, "ms": 50, "entry": "hit", "nested": true, "size": 32},     # kind 0 hit
	0x4206D0: {"frames": 12, "ms": 17, "entry": "hit", "nested": true, "size": 32},    # kind 1 hit
	0x4203D0: {"frames": 6, "ms": 50, "entry": "miss", "nested": true, "size": 32},    # kind 0 miss
	0x4209D0: {"frames": 12, "ms": 17, "entry": "miss", "nested": true, "size": 32},   # kinds 1, 2, 5 miss
	0x419BE0: {"frames": 6, "ms": 67, "entry": "hit", "size": 32},                      # kinds 2-8 hit
	0x419E20: {"frames": 6, "ms": 33, "entry": "miss", "size": 32},                     # kinds 3, 4, 6-8 miss
	0x4180C0: {"frames": 8, "ms": 50, "entry": "hit", "size": 32},                      # kind 9
	0x420CD0: {"frames": 8, "ms": 50, "entry": 7, "size": 40},                          # a kill
	0x417410: {"frames": 14, "ms": 33, "entry": 6, "size": 40},                         # anime_bomb
	0x41CA70: {"frames": 8, "ms": 50, "entry": 7, "size": 40},                          # a missile shot down
}
const ANIM_TABLE := 0x512F40

var battle
var _pack := PackedByteArray()
var _cache := {}          # [entry, sub] -> decoded bytes
var _tex: Texture2D = null
var _at := Vector2.ZERO


func load_pack(campaign: String) -> void:
	var p := "%s/%s/anime.pck" % [GameData.ROOT, campaign]
	_pack = FileAccess.get_file_as_bytes(p) if FileAccess.file_exists(p) else PackedByteArray()
	_cache = {}


static func _u32(d: PackedByteArray, o: int) -> int:
	return d.decode_u32(o) if o >= 0 and o + 4 <= d.size() else 0


static func entry_bytes(pack: PackedByteArray, i: int) -> PackedByteArray:
	## 0x480A90's entry i of a pack (a pack's bytes from its header size): the data from
	## the entry's offset to the pack's end
	if pack.size() < 4:
		return PackedByteArray()
	var data := 4 + _u32(pack, 0)
	if data <= 4 + 8 * i + 4:          # an index past the table: entry 0
		i = 0
	var off := data + _u32(pack, 4 + 8 * i)
	return pack.slice(off) if off < pack.size() else PackedByteArray()


static func lzss(src: PackedByteArray, n: int) -> PackedByteArray:
	## 0x4482D0: n bytes from the stream (flags LSB first: 1 a literal; 0 two bytes, the
	## ring position (12 bits) and a length of + 3), a ring of 4096 zeros written from 0xFEE
	var ring := PackedByteArray()
	ring.resize(4096)
	var r := 0xFEE
	var out := PackedByteArray()
	var i := 0
	var flags := 0
	while out.size() < n and i < src.size():
		flags >>= 1
		if not flags & 0x100:
			flags = src[i] | 0xFF00
			i += 1
			if i >= src.size():
				break
		if flags & 1:
			var c := src[i]
			i += 1
			out.append(c)
			ring[r] = c
			r = (r + 1) & 0xFFF
		else:
			if i + 1 >= src.size():
				break
			var lo := src[i]
			var hi := src[i + 1]
			i += 2
			var pos := lo | ((hi & 0xF0) << 4)
			for k in (hi & 0x0F) + 3:
				var c2 := ring[(pos + k) & 0xFFF]
				out.append(c2)
				ring[r] = c2
				r = (r + 1) & 0xFFF
	return out


static func direction(tx: int, ty: int, sx: int, sy: int) -> int:
	## 0x47E440(target, shooter): 5 / 1 straight down / up (mostly vertical, 2+ rows away),
	## else ai_direction's 0 -> 0, 1-3 -> 2-4, 4-5 -> 6-7 (-1 -> 0)
	var dv := sy - ty
	var ay := absi(dv)
	var ax := absi(sx - tx)
	if ax < ay and ay > 1:
		if ((ax * 0x14 - (dv & 1)) * 5) / ay < 0x19:     # (C's division: toward zero, as GDScript's)
			return 5 if dv >= 0 else 1
	var d := Ai.ai_direction(tx, ty, sx, sy)
	if d != 0:
		d += 1
		if d > 4:
			d += 1
	return d


func frames_of(player: int, akind: int, x: int, y: int, sx: int, sy: int) -> PackedByteArray:
	var spec: Dictionary = PLAYERS[player]
	var e: Variant = spec.entry
	if e is String:
		var w: Pd2World = battle.w
		if akind < 0 or akind > 9:
			return PackedByteArray()
		e = w.mem8(ANIM_TABLE + 4 * akind + (2 if e == "hit" else 3))
		if e == 0xFF:
			return PackedByteArray()
	var sub := -1
	if spec.get("nested", false):
		sub = direction(x, y, sx, sy)
	var key := [e, sub]
	if _cache.has(key):
		return _cache[key]
	var b := entry_bytes(_pack, int(e))
	if sub >= 0:
		b = entry_bytes(b, sub)
	var size := 0x280 if spec.size == 32 else 1000
	var out := lzss(b.slice(4), size * (1 if sub >= 0 else int(spec.frames)))
	_cache[key] = out
	return out


func frame_image(data: PackedByteArray, off: int, size: int) -> Image:
	var row := size / 8
	var plane := row * size
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		for bx in row:
			var o := off + y * row + bx
			if o + 4 * plane >= data.size():
				continue
			var m := data[o]
			for b in 8:
				var bit := 0x80 >> b
				if not m & bit:
					continue
				var c := (1 if data[o + plane] & bit else 0) | (2 if data[o + 2 * plane] & bit else 0) \
						| (4 if data[o + 3 * plane] & bit else 0) | (8 if data[o + 4 * plane] & bit else 0)
				img.set_pixel(bx * 8 + b, y, GameWindow.color(c))
	return img


func show_frame(player: int, rec: Array, x: int, y: int, i: int, dy: int, dx: int) -> void:
	## frame i of the player at (x, y) (rec: the record's kind and the shooter's hex)
	var spec: Dictionary = PLAYERS.get(player, {})
	if spec.is_empty():
		clear()
		return
	var akind: int = rec[0] if rec.size() > 0 else -1
	var sx: int = rec[1] if rec.size() > 1 else -1
	var sy: int = rec[2] if rec.size() > 2 else -1
	var d := frames_of(player, akind, x, y, sx, sy)
	var size: int = spec.size
	var bytes := 0x280 if size == 32 else 1000
	var off := 0 if spec.get("nested", false) else i * bytes
	if d.size() < off + bytes:
		clear()
		return
	_tex = ImageTexture.create_from_image(frame_image(d, off, size))
	var cx := clampi(x, 1, 0x46)
	var cy := clampi(y, 1, 0x46)
	_at = Vector2(cx * 48 + (cy & 1) * 24 + dx * 8, cy * 36 + dy)
	queue_redraw()


func clear() -> void:
	_tex = null
	queue_redraw()


func _draw() -> void:
	if _tex:
		draw_texture(_tex, _at)
