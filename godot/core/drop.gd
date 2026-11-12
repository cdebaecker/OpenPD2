class_name Drop
extends RefCounted
## Transports and airdrops at the turn start (Pd2.exe 0x44AEA0, rules.airdrop): type-0
## groups on the called point carry the previous group in and the player flies them
## (0x44BAC0: steps 0x44C1B0, flights 0x44D0D0, the drop menu 0x44C7F0), the drops
## (0x44B300 / 0x44B960), types 1 and 7 / 8. RULES.md 5.17.

const W := preload("res://core/world.gd")
const MAP := 72
const ABORT := [0x10000, 0x20000, 0x40000]
const S_MOVE_ROWS := 528


## What the airdrop leaves to the player and the display (rules.DropHooks).
class Hooks extends Strike.Hooks:
	## The transport's next hex (ui_map_click mode 4): a Vector2i, or -2.
	func click(u: int, dests: Array) -> Variant:
		return -2

	## The fly-there question 0x1DC (args: distance, AP, 0): 0 = yes.
	func ask2(msg: int, args: Array) -> int:
		return 1

	## The transport's menu: 0 one by one, 1 all, -2 back.
	func drop_menu(u: int) -> int:
		return 1

	## A passenger (0x44A7E0): one of units, or -2.
	func pick(units: Array) -> int:
		return -2

	## Where passenger k jumps (hexes shown): a Vector2i, or -2.
	func drop_click(k: int, hexes: Array) -> Variant:
		return -2

	## The confirmations 0x1F4 / 0x213: 1 = yes.
	func box(msg: int) -> int:
		return 1

	## A dropped unit lands on b: melee's result 0-3.
	func melee(a: int, b: int) -> int:
		return 1

	func discovered(u: int) -> int:
		return 0


## 0x44AC10(d): [a, b, px, py] for a transport from side d; [] for another d.
static func entry(rng: Pd2Random, d: int) -> Array:
	match d:
		0:
			var a := rng.r16(36) + 18
			return [a, 1, a, 0]
		1:
			if rng.r16(100) > 0x31:
				var v := rng.r16(18) + 1
				return [70 - (v & 1), v, 71 - (v & 1), v]
			var a2 := 70 - rng.r16(18)
			return [a2, 1, a2, 0]
		2:
			var v := rng.r16(36) + 18
			return [70 - (v & 1), v, 71 - (v & 1), v]
		3:
			if rng.r16(100) < 0x32:
				var a := 71 - rng.r16(18)
				return [a, 70, a, 71]
			var v2 := 72 - rng.r16(18)
			return [70 - (v2 & 1), v2, 71 - (v2 & 1), v2]
		4:
			var a := rng.r16(36) + 18
			return [a, 70, a, 71]
		5:
			if rng.r16(100) > 0x31:
				var b := 71 - rng.r16(18)
				return [1, b, 0, b]
			var a2 := rng.r16(18) + 1
			return [a2, 70, a2, 71]
		6:
			var b := rng.r16(36) + 18
			return [1, b, 0, b]
		7:
			if rng.r16(100) < 0x32:
				var b := rng.r16(18) + 1
				return [1, b, 0, b]
			var a2 := rng.r16(18) + 1
			return [a2, 1, a2, 0]
	return []


static func _put_back(w: Pd2World, check_unit: bool) -> void:
	var k: int = w.drop_saved[0]
	var x: int = w.drop_saved[1]
	var y: int = w.drop_saved[2]
	w.setb(k, 9, x)
	w.setb(k, 10, y)
	w.O[x + MAP * y] = (k + 1) & 0xFF
	if w.sb(k, 0x36) > 2 and (k < 0xFE or not check_unit) and Ai.in_view(w, x, y, 0):
		w.setb(k, 0, w.ub(k, 0) | 0x10)


## 0x44C1B0: one step of a transport (own saved unit DS:0x514D18).
static func move(w: Pd2World, rng: Pd2Random, x: int, y: int, u: int, mode: int, passengers: Variant, hooks: Hooks) -> int:
	if mode == 1:
		if w.drop_saved[0] != -1:
			_put_back(w, true)
			w.drop_saved[0] = -1
		return 0
	var o := w.pos(u)
	var res := 0
	if o != Vector2i(x, y):
		Ai.spend_ap(w, u, 1)
		var prev := Action.move_unit(w, u, x, y)
		w.setb(u, 4, w.ub(u, 4) & 0xCF)
		if w.drop_saved[0] != -1:
			_put_back(w, false)
			w.drop_saved = [-1, 0, 0]
		if prev != -1:
			w.drop_saved = [prev, x, y]
		if mode == 2:
			w.setb(u, 0, w.ub(u, 0) & 0xEF)
		else:
			Strike.reinf_seen(w, u)
		if w.ub(u, 0) & 0x10 and not w.ub(u, 0) & 0x40:
			var cands := Sight.reaction_candidates(w, u, w.ds8(0x50ADF1))
			if not cands.is_empty():
				res = hooks.react(u, cands, false)
				if res in ABORT:
					return res
	if res < 4:
		return 1 if res else 0
	move(w, rng, 0, 0, u, 1, null, hooks)
	if passengers != null:
		var a := drop_all(w, rng, o.x, o.y, passengers, 0, hooks)
		if a in ABORT:
			return a
	return 2


## 0x44D0D0: the transport flies the line to (x, y).
static func fly(w: Pd2World, rng: Pd2Random, x: int, y: int, u: int, passengers: Variant, hooks: Hooks) -> int:
	var p := w.pos(u)
	var pts := Strike.path(w, p.x, p.y, x, y)
	w.setb(u, 0, w.ub(u, 0) & 0xCF)
	var res := 0
	for q in pts:
		if res or q.x == -1:
			break
		res = move(w, rng, q.x, q.y, u, 0, passengers, hooks)
		if res in ABORT:
			return res
	return 0


static func _cost(w: Pd2World, k: int, x: int, y: int) -> int:
	var cat := w.umachine(k, 0) & 15
	return w.terrain[S_MOVE_ROWS + 16 * cat + w.terrain[w.T[x + MAP * y]]]


static func _side(w: Pd2World, k: int) -> int:
	return 3 if w.sb(k, 0x36) > 2 else 0


static func _ok(w: Pd2World, k: int, x: int, y: int, side: int) -> bool:
	if _cost(w, k, x, y) == 0 or w.H[x + MAP * y] <= 0x1D:
		return false
	var o := Strike._occupant(w, x, y)
	return o == -1 or (_side(w, o) != side and w.unit_class(o) < 2)


## 0x44B300: k jumps or is set down on (x, y) (mode 0 jump, 1 auto, 2 set down).
static func drop_unit(w: Pd2World, rng: Pd2Random, k: int, x: int, y: int, mode: int, hooks: Hooks) -> int:
	var side := _side(w, k)
	var cost := _cost(w, k, x, y)
	var o := Strike._occupant(w, x, y)
	var bad := o != -1 and (_side(w, o) == side or w.unit_class(o) > 1)
	bad = bad or cost == 0 or w.H[x + MAP * y] < 0x1E or (mode != 2 and rng.r16(100) < 0x1E)
	if bad:
		var found := false
		var rad := 1
		while not found and rad <= 0x47:
			for h in Ai.spiral(x, y, rad):
				if w.on_map(h.x, h.y) and _ok(w, k, h.x, h.y, side):
					x = h.x
					y = h.y
					found = true
					break
			rad += 1
		if not found:
			if mode != 2:
				hooks.line(0x1F1)
			Action.destroy(w, k)
			return 0
	o = Strike._occupant(w, x, y)
	if o != -1 and _side(w, o) != side:
		hooks.line(0x1BB)
		var res := hooks.melee(k, o)
		while res == 1:
			res = hooks.melee(k, o)
		if res in ABORT:
			return res
		if res == 0:
			Action.destroy(w, o)
		elif res == 2:
			Action.destroy(w, k)
			return 0
		elif res == 3:
			Action.destroy(w, k)
			Action.destroy(w, o)
			return 0
	w.O[x + MAP * y] = (k + 1) & 0xFF
	w.setb(k, 9, x)
	w.setb(k, 10, y)
	var f := rng.r16(6)
	w.setb(k, 4, w.ub(k, 4) & 0xCF)
	w.setb(k, 5, (w.ub(k, 5) & 0xF8) | (f & 7))
	if mode == 0 and not w.is_ace(k) and rng.r16(100) > 0x59:
		hooks.line(0x1F2)
		if rng.r16(10) < 6:
			w.setb(k, 1, (w.ub(k, 1) & 0xDF) | 0x10)
		else:
			w.setb(k, 1, (w.ub(k, 1) & 0xF7) | 4)
	# (70, odd row) off the map: the search reads only inside the layers (defined, emulated)
	for o2 in Action.step_search(w, k, 0):
		if w.sb(o2, 0x36) > 2:
			var res2 := hooks.discovered(o2)
			if res2 in ABORT:
				return res2
	w.setb(k, 0, w.ub(k, 0) | 0x0C)
	return 0


## 0x44B960: every passenger dropped on a hex of the radius-6 spiral (x and y picked apart).
static func drop_all(w: Pd2World, rng: Pd2Random, x: int, y: int, passengers: Array, mode: int, hooks: Hooks) -> int:
	var s := Ai.spiral(x, y, 6)
	var n := s.size()
	for i in mini(16, passengers.size()):
		var k: int = passengers[i]
		if k == -1:
			continue
		var hx: int = s[rng.r16(n - 1) + 1].x
		var hy: int = s[rng.r16(n - 1) + 1].y
		var res := drop_unit(w, rng, k, hx, hy, mode, hooks)
		if res in ABORT:
			return res
	return 0


## The drop menu's marked hexes for passenger k around transport u.
static func drop_hexes(w: Pd2World, u: int, k: int) -> Array:
	var up := w.pos(u)
	var box := Move.move_box(up.x, up.y, 2)
	var out := []
	for y in range(box[1], box[1] + box[3]):
		for x in range(box[0], box[0] + box[2]):
			if W.hexdist(up.x, up.y, x, y) >= 3:
				continue
			if w.H[x + MAP * y] <= 0x1D or _cost(w, k, x, y) == 0:
				continue
			var o := Strike._occupant(w, x, y)
			if o == -1 or (w.sb(o, 0x36) > 2 and w.unit_class(o) < 2):
				out.append(Vector2i(x, y))
	return out


static func leave(w: Pd2World, rng: Pd2Random, x: int, y: int, u: int, passengers: Variant, hooks: Hooks) -> void:
	if Strike._occupant(w, x, y) == u:
		Action.clear_hex(w, x, y)
	move(w, rng, x, y, u, 1, passengers, hooks)
	w.setb(u, 9, 0xFF)
	w.setb(u, 10, 0xFF)


## 0x44C7F0: the transport's menu; -1 when done (the transport has left), 0 back.
static func drop_menu(w: Pd2World, rng: Pd2Random, u: int, passengers: Array, hooks: Hooks) -> int:
	var done := false
	while not done:
		var c := hooks.drop_menu(u)
		if c in ABORT:
			return c
		if c == 0:
			while not done:
				var left := []
				for k in passengers:
					if k != -1:
						left.append(k)
				var k := hooks.pick(left)
				if k in ABORT:
					return k
				if k == -2:
					break
				var hexes := drop_hexes(w, u, k)
				while true:
					var h: Variant = -2
					if not hexes.is_empty():
						h = hooks.drop_click(k, hexes)
						if h is int and h in ABORT:
							return h
					else:
						hooks.line(0x1F0)
					if h is int:
						break
					if hooks.box(0x1F4) == 1:
						var res := drop_unit(w, rng, k, h.x, h.y, 0, hooks)
						if res in ABORT:
							return res
						var n := 0
						for i in 16:
							if passengers[i] == k:
								passengers[i] = -1
							elif passengers[i] != -1:
								n += 1
						if n == 0:
							done = true
						break
					hexes = drop_hexes(w, u, k)
		elif c == 1:
			if not w.campaign and hooks.box(0x213) != 1:
				return 0
			var p := w.pos(u)
			var res := drop_all(w, rng, p.x, p.y, passengers, 0, hooks)
			if res in ABORT:
				return res
			done = true
		elif c == -2:
			return 0
	var q := w.pos(u)
	leave(w, rng, q.x, q.y, u, passengers, hooks)
	return -1


## 0x44BAC0: the player flies transport u with its passengers.
static func control(w: Pd2World, rng: Pd2Random, u: int, passengers: Array, a: int, b: int, hooks: Hooks) -> int:
	for k in mini(254, w.n_units):
		w.setb(k, 0, w.ub(k, 0) & 0xBF)
	var res := move(w, rng, a, b, u, 2, passengers, hooks)
	if res in ABORT:
		return res
	if res:
		return 0
	hooks.panel(u)
	var menu := 0
	var last := Vector2i(-99, -99)
	var guard := 0
	while true:
		var dests := Action.move_destinations(w, u, Move.move_map(w, u, 0))
		if not dests.is_empty():
			var h: Variant = hooks.click(u, dests)
			if h is int and h in ABORT:
				return h
			if not h is int:
				last = h
				var p := w.pos(u)
				if W.hexdist(last.x, last.y, p.x, p.y) == 1:
					res = move(w, rng, last.x, last.y, u, 0, passengers, hooks)
					if res in ABORT:
						return res
				elif Strike._occupant(w, last.x, last.y) == u:   # ui_map_click returns the hex's occupant
					menu = drop_menu(w, rng, u, passengers, hooks)
					if menu in ABORT:
						return menu
				else:
					var ans := hooks.ask2(0x1DC, [W.hexdist(last.x, last.y, p.x, p.y), w.sb(u, 0xE), 0])
					if ans in ABORT:
						return ans
					if ans == 0:
						res = fly(w, rng, last.x, last.y, u, passengers, hooks)
						if res in ABORT:
							return res
		else:
			guard += 1
			if guard > 2:
				if w.safe_hit("H4", "transport %d has AP and nowhere to go (the game loops): its move ends" % u):
					break
				w.fault = "a transport with AP and nowhere to go: the game loops"
				return -1
		if w.ub(u, 0xE) == 0 or w.ub(u, 0) & 1 or menu:
			break
	if w.ub(u, 0xE) == 0:
		if not w.ub(u, 0) & 1:
			hooks.line(0x1F5)
			last = w.pos(u)
			res = drop_all(w, rng, last.x, last.y, passengers, 0, hooks)
			if res in ABORT:
				return res
	elif not w.ub(u, 0) & 1:
		hooks.line(0x1F6)
	if last.x == -99:
		w.fault = "the transport leaves from an unset hex (the game reads its stack)"
		return -1
	leave(w, rng, last.x, last.y, u, passengers, hooks)
	return 0


## Will the airdrop ask the player? A type-0 transport group on the called point, ready.
static func pending(w: Pd2World) -> bool:
	for g in range(1, 64):
		var g2 := Strike.gb(w, g, 2)
		if W.s8(Strike.gb(w, g, 0x16)) == w.fire_point.x and W.s8(Strike.gb(w, g, 0x17)) == w.fire_point.y 				and g2 & 0x30 == 0x20 and not g2 & 0xC0 and Strike.gb(w, g, 0x21) >> 4 == 0 and g2 & 0x0E == 8:
			return true
	return false


## 0x44AEA0, at the turn start: the groups on the called point, by type.
static func airdrop(w: Pd2World, rng: Pd2Random, hooks: Hooks = null) -> int:
	if hooks == null:
		hooks = Hooks.new()
	var fx := w.fire_point.x
	var fy := w.fire_point.y
	for g in 64:
		var g2 := Strike.gb(w, g, 2)
		if W.s8(Strike.gb(w, g, 0x16)) != fx or W.s8(Strike.gb(w, g, 0x17)) != fy or g2 & 0x30 != 0x20 or g2 & 0xC0:
			continue
		var typ := Strike.gb(w, g, 0x21) >> 4
		if (typ == 0 or typ == 1) and g2 & 0x0E == 8 and g == 0:
			w.fault = "group 0 carries \"group -1\": the end of the unit table"
			return -1
		if typ == 0:
			if g2 & 0x0E != 8:
				continue
			var i := 0
			var last := Vector2i(-1, -1)
			while i < 16:
				var c := Strike.gb(w, g, 6 + i)
				if c == 0xFF:
					i += 1
					continue
				var cap := w.umachine(c, 9)
				var load := 0
				var n := 0
				var passengers := []
				for j in 16:
					var p := Strike.gb(w, g - 1, 6 + j)
					if p == 0xFF or w.ub(p, 0) & 9:
						passengers.append(-1)
						continue
					load += w.umachine(p, 0xA)
					if cap < load:
						passengers.append(-1)
					else:
						passengers.append(p)
						n += 1
				if n == 0:
					break
				if last == Vector2i(i, c) and (w.ub(c, 0xD) == 0 or w.ub(c, 0) & 1):
					if w.safe_hit("H5", "airdrop: transport %d stays in its slot (the game loops): next slot" % c):
						i += 1
						continue
					w.fault = "the game loops on this transport forever"
					return -1
				last = Vector2i(i, c)
				var e := entry(rng, W.s8(Strike.gb(w, g, 0x1F)))
				if e.is_empty():
					w.fault = "a transport side outside 0-7 (the game reads its stack)"
					return -1
				var a := maxi(e[0], 1)
				var b := maxi(e[1], 1)
				if b > 69:
					b = 70
				a = mini(a, 70 - (b & 1))
				w.setb(c, 9, e[2])
				w.setb(c, 10, e[3])
				hooks.line(0x1F7, [["name", Strike.gb(w, g - 1, 0)], ["sign", Strike.gb(w, g - 1, 1)]])
				w.setb(c, 0xE, Move.max_ap(w, c))
				var res := control(w, rng, c, passengers, a, b, hooks)
				if res in ABORT:
					return res
				if w.fault != "":
					return -1
				if w.ub(c, 0xD) == 0 or w.ub(c, 0) & 1:
					continue
				i += 1
			Strike.setgb(w, g - 1, 2, Strike.gb(w, g - 1, 2) & 0xF | 0xA0)
			Strike.setgb(w, g - 1, 0x16, Strike.gb(w, g, 0x16))
			Strike.setgb(w, g - 1, 0x17, Strike.gb(w, g, 0x17))
			Ai.group_retarget(w, g, -1, 0)
			Strike.setgb(w, g, 2, Strike.gb(w, g, 2) | 0x30)
		elif typ == 1:
			if g2 & 0x0E != 8:
				continue
			var lst := []
			var hx := -1
			var hy := -1
			for j in 16:
				var p := Strike.gb(w, g - 1, 6 + j)
				if p != 0xFF and not w.ub(p, 0) & 9:
					var pp := w.pos(p)
					if w.on_map(pp.x, pp.y):
						hx = pp.x
						hy = pp.y
					lst.append(p)
				else:
					lst.append(-1)
			if hx != -1:
				var res := drop_all(w, rng, hx, hy, lst, 1, hooks)
				if res in ABORT:
					return res
			Strike.setgb(w, g - 1, 2, Strike.gb(w, g - 1, 2) & 0xF | 0xA0)
			Strike.setgb(w, g - 1, 0x16, fx)
			Strike.setgb(w, g - 1, 0x17, fy)
			Ai.group_retarget(w, g, -1, 0)
			Strike.setgb(w, g, 2, Strike.gb(w, g, 2) | 0x30)
		elif typ == 7 or typ == 8:
			for j in 16:
				var k := Strike.gb(w, g, 6 + j)
				if k != 0xFF and not w.ub(k, 0) & 9:
					var kp := w.pos(k)
					if w.on_map(kp.x, kp.y):
						var res := drop_unit(w, rng, k, kp.x, kp.y, 2, hooks)
						if res in ABORT:
							return res
			Strike.setgb(w, g, 0x16, fx)
			Strike.setgb(w, g, 0x17, fy)
			Strike.setgb(w, g, 2, Strike.gb(w, g, 2) & 0xF | 0xA0)
	return 0
