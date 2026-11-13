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
	0x41CA70: {"frames": 8, "ms": 50, "entry": 7, "size": 40, "at_missile": true},      # a missile shot down
	# the shooter's (0x40F730 by the record's kind): the sub-entry of the shooter's direction
	# (0x47E440(shooter, target)) at the shooter's hex moved by DIR_OFFSETS; "flash": the
	# sprite drawn after the odd waits, cleared after the even ones; "seq": frames in turn
	0x41EFF0: {"frames": 12, "ms": 33, "entry": "shot", "shooter": true, "flash": true, "size": 32},
	0x41FD60: {"frames": 24, "ms": 17, "entry": "shot", "shooter": true, "flash": true, "size": 32},
	0x418B20: {"frames": 4, "ms": 33, "entry": "shot", "shooter": true, "seq": 4, "size": 32},
	0x41DB00: {"frames": 5, "ms": 33, "entry": "shot", "shooter": true, "seq": 5, "size": 32},
	0x419870: {"frames": 12, "ms": 17, "entry": "shot", "shooter": true, "seq": 4, "size": 32},
	0x41E850: {"frames": 15, "ms": 17, "entry": "shot", "shooter": true, "seq": 5, "size": 32},
	0x41A5B0: {"frames": 4, "ms": 33, "entry": "shot", "shooter": true, "seq": 4, "size": 32},
	# the turn toward the target (0x410020): its waits only (167 ms, then 67 ms)
	0x410020: {"frames": 0, "ms": 67, "first_ms": 167, "turn": true},
}
## the shooter players' offsets by direction (in the bitmap: -0xD21 .. : 8 px, 8 rows)
const DIR_OFFSETS := [Vector2(-8, -8), Vector2(0, -8), Vector2(8, -8), Vector2(16, 0), Vector2(8, 8),
		Vector2(0, 8), Vector2(-8, 8), Vector2(-16, 0)]
var missile_px := Vector2(-1, -1)      # the record's +0x2E / +0x32 (the flight's last point)
var _flight_tex: Texture2D = null
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
	## (for a shooter player x, y is the shooter's hex and sx, sy the target)
	var spec: Dictionary = PLAYERS[player]
	var e: Variant = spec.entry
	if e is String:
		var w: Pd2World = battle.w
		if akind < 0 or akind > 9:
			return PackedByteArray()
		e = w.mem8(ANIM_TABLE + 4 * akind + {"shot": 0, "hit": 2, "miss": 3}[e])
		if e == 0xFF:
			return PackedByteArray()
	var sub := -1
	if spec.get("nested", false) or spec.get("shooter", false):
		sub = direction(x, y, sx, sy)
	var key := [e, sub]
	if _cache.has(key):
		return _cache[key]
	var b := entry_bytes(_pack, int(e))
	if sub >= 0:
		b = entry_bytes(b, sub)
	var size := 0x280 if spec.size == 32 else 1000
	var count := int(spec.get("seq", 1)) if sub >= 0 else int(spec.frames)
	var out := lzss(b.slice(4), size * count)
	_cache[key] = out
	return out


func frame_image(data: PackedByteArray, off: int, size: int, rows := -1) -> Image:
	if rows < 0:
		rows = size
	var row := size / 8
	var plane := row * rows
	var img := Image.create(size, rows, false, Image.FORMAT_RGBA8)
	for y in rows:
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
	if spec.get("turn", false):
		return                          # (the unit's facing is the map's drawing)
	var akind: int = rec[0] if rec.size() > 0 else -1
	var sx: int = rec[1] if rec.size() > 1 else -1
	var sy: int = rec[2] if rec.size() > 2 else -1
	var shooter: bool = spec.get("shooter", false)
	var tx: int = rec[3] if rec.size() > 3 else -1
	var ty: int = rec[4] if rec.size() > 4 else -1
	var d := frames_of(player, akind, x, y, tx, ty) if shooter else frames_of(player, akind, x, y, sx, sy)
	var size: int = spec.size
	var bytes := 0x280 if size == 32 else 1000
	var off := i * bytes
	if spec.get("nested", false):
		off = 0
	elif shooter:
		if spec.get("flash", false):
			if i % 2 == 0:
				clear()                 # (restored after the even waits)
				return
			off = 0
		else:
			off = (i % int(spec.seq)) * bytes
	if d.size() < off + bytes:
		clear()
		return
	_tex = ImageTexture.create_from_image(frame_image(d, off, size))
	if spec.get("at_missile", false) and missile_px.x >= 0:
		_at = Vector2(int(missile_px.x) & ~7, missile_px.y) + Vector2(48, 36)
	else:
		var cx := clampi(x, 1, 0x46)
		var cy := clampi(y, 1, 0x46)
		_at = Vector2(cx * 48 + (cy & 1) * 24 + dx * 8, cy * 36 + dy)
		if shooter:
			_at += DIR_OFFSETS[direction(x, y, tx, ty) & 7]
	queue_redraw()


# --- the missile's flight (0x410160 -> 0x41B320, kind 8, no waits) -----------------------

static func line_point(x1: int, y1: int, x2: int, y2: int, i: int) -> Vector2i:
	## 0x4DE4A0: point i along (x1, y1)-(x2, y2), the longer axis a unit a step
	var dx := x2 - x1
	var dy := y2 - y1
	var sx := 1 if dx >= 0 else -1
	var sy := 1 if dy >= 0 else -1
	dx = absi(dx)
	dy = absi(dy)
	if dy == 0:
		return Vector2i(sx * i + x1, y1)
	if dx == 0:
		return Vector2i(x1, sy * i + y1)
	if dx < dy:
		return Vector2i((((dx * i * 100) / dy) * sx) / 100 + x1, sy * i + y1)
	return Vector2i(sx * i + x1, (((dy * i * 100) / dx) * sy) / 100 + y1)


static func corner(x: int, y: int) -> Vector2i:
	## 0x41FD00's cell corner in the bitmap's pixels (x, y clamped to 1-0x46)
	var cx := clampi(x, 1, 0x46)
	var cy := clampi(y, 1, 0x46)
	return Vector2i((cx - 1) * 48 + (cy & 1) * 24, (cy - 1) * 36)


func flight_points(rec: Array, stage: int) -> Array:
	## the steps 0x41B320 draws for a stage (the shooter seen and in the same view: from its
	## cell's corner to the target's; n the longer axis): 0: 1 .. n/4 + n%4, 1: .. n/2 + n%4,
	## 2: .. n/4 + n/2 + n%4, 3: .. n. Engine-side: an unseen or off-map shooter (the game
	## starts at its view's edge) starts 6 cells above the target.
	var w: Pd2World = battle.w
	var t := corner(int(rec[3]), int(rec[4]))
	var s := t - Vector2i(0, 6 * 36)
	var k: int = rec[5] if rec.size() > 5 else -1
	if int(rec[1]) != -1 and k >= 0 and not (w.is_enemy(k) and not w.ub(k, 0) & 0x10):
		s = corner(int(rec[1]), int(rec[2]))
	var n := maxi(absi(t.x - s.x), absi(t.y - s.y))
	var q := n >> 2
	var h := n >> 1
	var r := n & 3
	var spans := [[1, q + r], [q + r, h + r], [r + h, q + r + h], [q + h + r, n]]
	var out := []
	if stage >= 0 and stage < 4:
		for i in range(spans[stage][0], spans[stage][1] + 1):
			out.append(line_point(s.x, s.y, t.x, t.y, i))
	return out


func flight_sprite(rec: Array) -> Texture2D:
	## the record's +2 entry (kind 8: entry 8), sub-entry the direction & 3: 24 x 24, mask and
	## four planes of 3 bytes a row (0x168 bytes)
	var w: Pd2World = battle.w
	var akind: int = rec[0]
	var e := w.mem8(ANIM_TABLE + 4 * akind + 1)
	if e == 0:
		return null
	var d := direction(int(rec[1]), int(rec[2]), int(rec[3]), int(rec[4])) if int(rec[1]) != -1 else 0
	var key := ["flight", e, d & 3]
	if not _cache.has(key):
		var b := entry_bytes(entry_bytes(_pack, e), d & 3)
		_cache[key] = lzss(b.slice(4), 0x168)
	var data: PackedByteArray = _cache[key]
	if data.size() < 0x168:
		return null
	return ImageTexture.create_from_image(frame_image(data, 0, 24, 24))


func show_missile(p: Vector2i, tex: Texture2D) -> void:
	missile_px = Vector2(p)
	_flight_tex = tex
	queue_redraw()


func clear_missile() -> void:
	_flight_tex = null
	queue_redraw()


func clear() -> void:
	_tex = null
	queue_redraw()


func _draw() -> void:
	if _tex:
		draw_texture(_tex, _at)
	if _flight_tex and missile_px.x >= 0:
		draw_texture(_flight_tex, missile_px + Vector2(48, 36))
