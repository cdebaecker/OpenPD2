class_name AiTurn
extends RefCounted
## The computer's turn (Pd2.exe 0x42A950; rules.ai_turn): the player sight map, the
## strike marks, every order's behaviour in priority order, and groups entering at the
## fire point.

const W := preload("res://core/world.gd")
const MAP := 72
const SIGHT_RADIUS := 14


## 0x42B5C0: which hexes of the window a unit at (x, y) sees: 1 / 0xFF per cell.
static func unit_sight_cells(w: Pd2World, x: int, y: int, x0: int, y0: int, wd: int, ht: int, r := SIGHT_RADIUS, limit := 1) -> PackedByteArray:
	var cells := PackedByteArray()
	cells.resize(wd * ht)
	var h0 := w.layer(w.H, x, y)
	cells[(y - y0) * wd - x0 + x] = 1
	for p in Ai.spiral(x, y, r):
		var d := W.hexdist(x, y, p.x, p.y)
		var i: int = (p.y - y0) * wd - x0 + p.x
		var v := 0xFF
		if d <= r and h0 - w.layer(w.H, p.x, p.y) < 30:
			if d < 3:
				if d == 2:
					var vp := Vector2i(x, y)
					var a := vp
					var c := vp
					var step := 1
					while a == vp or c == vp:
						if a == vp:
							var P := Sight.line_point(2 * x + (y & 1), y, 2 * p.x + (p.y & 1), p.y, step)
							a = Vector2i((P.x + ((~P.y) & P.x & 1)) >> 1, P.y)
						if c == vp:
							var Q := Sight.line_point(2 * x - ((~y) & 1), y, 2 * p.x - ((~p.y) & 1), p.y, step)
							c = Vector2i((Q.x + ((~Q.y) & 1)) >> 1, Q.y)
						step += 1
					if h0 - w.layer(w.H, c.x, c.y) < 2 or h0 - w.layer(w.H, a.x, a.y) < 2:
						v = 1
				else:
					v = 1
			elif Sight.line_of_sight(w, p.x, p.y, x, y, limit, 0) or Sight.line_of_sight(w, p.x, p.y, x, y, limit, 1):
				v = 1
		cells[i] = v
	for i in cells.size():
		if cells[i] == 0:
			cells[i] = 0xFF
	return cells


## 0x42B440: the player sight map the AI reads (3 B a hex).
static func player_sight_map(w: Pd2World) -> PackedByteArray:
	var sight := PackedByteArray()
	sight.resize(3 * MAP * MAP)
	for k in mini(25, w.n_units):
		if not w.active(k) or w.sb(k, 0x36) != 0:
			continue
		var p := w.pos(k)
		var box := Move.move_box(p.x, p.y, SIGHT_RADIUS)
		var wd: int = box[2]
		var ht: int = box[3]
		var cells := unit_sight_cells(w, p.x, p.y, box[0], box[1], wd, ht)
		for ly in ht:
			for lx in wd:
				if cells[ly * wd + lx] == 1:
					var i: int = 3 * (box[0] + lx + MAP * (box[1] + ly))
					if k < 16:
						var m: int = (sight[i] | sight[i + 1] << 8) | 1 << k
						sight[i] = m & 0xFF
						sight[i + 1] = (m >> 8) & 0xFF
					else:
						sight[i + 2] = (sight[i + 2] | 1 << (k - 16)) & 0xFF
	return sight


## 0x483CB0(side): clear and redo the strike marks of side's fire-support groups.
static func refresh_strikes(w: Pd2World, side := 3) -> void:
	for y in MAP:
		for x in MAP:
			if w.on_map(x, y):
				w.F[x + MAP * y] &= 0xEF
	for pass_ in 2:
		var types := [0x50] if pass_ == 0 else [0x30, 0x40]
		var orders := [1, 2] if pass_ == 0 else [1]
		for g in w.groups.size() / 35:
			if Ai.gb(w, g, 22) == 0xFF:
				continue
			for i in 16:
				var k := Ai.gb(w, g, 6 + i)
				if k == 0xFF or w.ub(k, 0) & 1:
					continue
				var st := w.sb(k, 0x36)
				if st < side or st > side + 2 or not (Ai.gb(w, g, 33) & 0xF0) in types:
					continue
				var g2 := Ai.gb(w, g, 2)
				if g2 & 0x30 != 0x20 or g2 & 0xC0 != 0x80 or not w.ub(k, 6) in orders:
					continue
				if w.ub(k, 7) != 0xFF:
					Ai.mark_strike(w, w.ub(k, 7), w.ub(k, 8), k, w.ub(k, 0x35))


## Order 10's first move result when no move was made (rules.AI_TURN_STALE, RULES.md 5.23):
## the slot keeps ai_progress's push of the loop's ESI, or scroll_to's last return address
## (the view following the computer in an alert), or PeekMessageA's (the fire-point loop).
const STALE_FOLLOW := 0x4F4790
const STALE_FIRE_POINT := 0x42ADFB


## 0x42B990
static func dispatch(w: Pd2World, rng: Pd2Random, k: int, order: int, sight: PackedByteArray, hooks: AiTurnHooks, alert: int, stale: Variant = null) -> int:
	if order < 1 or order > 11:
		return 0
	var res := AiBehaviours.run(order, w, rng, k, sight, hooks, alert, stale)
	if res == Ai.UNDEFINED:
		return res
	return res if res in Ai.AI_ABORT else 0


static func _ok(w: Pd2World, x: int, y: int, cls: int) -> bool:
	return w.on_map(x, y) and w.O[x + MAP * y] - 1 == -1 and (cls == 3 or w.H[x + MAP * y] > 29)


static func enter_hex(w: Pd2World, k: int, cls: int) -> bool:
	var x := w.sb(k, 9)
	var y := w.sb(k, 10)
	var spot := Vector2i(-999, -999)
	if w.O[x + MAP * y] - 1 == -1 and (cls == 3 or w.H[x + MAP * y] > 29):
		spot = Vector2i(x, y)
	else:
		if x == 1 or x == 0x45 or x == 0x46:
			if _ok(w, x, y - 1, cls):
				spot = Vector2i(x, y - 1)
			elif _ok(w, x, y + 1, cls):
				spot = Vector2i(x, y + 1)
		if spot.x == -999 and (y == 1 or y == 0x46):
			if _ok(w, x - 1, y, cls):
				spot = Vector2i(x - 1, y)
			elif _ok(w, x + 1, y, cls):
				spot = Vector2i(x + 1, y)
	if spot.x == -999:
		return false
	w.setb(k, 0, w.ub(k, 0) | 0x0C)
	w.setb(k, 9, spot.x)
	w.setb(k, 10, spot.y)
	w.O[spot.x + MAP * spot.y] = (k + 1) & 0xFF
	return true


static func _nib(b: int, alert: int) -> int:
	return b >> 4 if alert else b & 15


## 0x42A950. Returns 0, a UI abort code, or Ai.UNDEFINED.
## A behaviour can reach a case the game leaves undefined (it reads an uninitialised
## local; rules.py raises AiUndefined). strict (as rules.ai_turn) stops the turn there;
## otherwise that unit's behaviour just ends and the turn goes on, which is what the
## engine does in play. `undefined` collects the units it happened to.
static func run(w: Pd2World, rng: Pd2Random, hooks: AiTurnHooks = null, alert := 0, strict := true, undefined: Array = []) -> int:
	if hooks == null:
		hooks = AiTurnHooks.new(w)
	if hooks.rng == null:
		hooks.rng = rng
	# player_sight_map (0x42B440): 0x42B2A0, then ai_progress per own active unit (display)
	hooks.progress_reset()
	for k in mini(0x28, w.n_units):
		if w.active(k) and w.sb(k, 0x36) == 0:       # (is_enemy == 0)
			hooks.progress()
	var sight := player_sight_map(w)
	refresh_strikes(w, 3)
	hooks.progress_reset()                   # 0x42B2A0 again
	var esi := 0                # the loop's ESI (0x42AB03); ai_progress pushes it into order 10's move result
	for order in AiBehaviours.ORDER_PRIORITY:
		for k in w.n_units:
			if w.sb(k, 0x36) > 2 and w.active(k):
				hooks.progress()                 # ai_progress, before each unit of each pass
				var stale: Variant = esi
				if alert:
					esi = order         # 0x42ABD9
				if _nib(w.ub(k, 3), alert) != order:
					continue
				if alert and hooks.follow:
					stale = STALE_FOLLOW
				var res := dispatch(w, rng, k, order, sight, hooks, alert, stale)
				esi = 0
				if res == Ai.UNDEFINED:
					undefined.append(k)
					if strict:
						return res
				elif res in Ai.AI_ABORT:
					return res
	var fx := w.fire_point.x
	var fy := w.fire_point.y
	for g in w.groups.size() / 35:
		if not (Ai.gb(w, g, 5) and W.s8(Ai.gb(w, g, 22)) == fx and W.s8(Ai.gb(w, g, 23)) == fy
				and Ai.gb(w, g, 33) & 0xF0 == 0xF0 and Ai.gb(w, g, 2) & 0x30 == 0x20):
			continue
		var cls := w.unit_class(g)
		for i in 16:
			var k := Ai.gb(w, g, 6 + i)
			if k == 0xFF:
				continue
			if w.sb(k, 0x36) < 3:
				break
			if w.ub(k, 0) & 9 or not w.on_map(w.sb(k, 9), w.sb(k, 10)):
				continue
			if not enter_hex(w, k, cls):
				continue
			var res2 := dispatch(w, rng, k, _nib(w.ub(k, 3), alert), sight, hooks, alert, STALE_FIRE_POINT)
			if res2 == Ai.UNDEFINED:
				undefined.append(k)
				if strict:
					return res2
			elif res2 in Ai.AI_ABORT:
				return res2
	return 0
