class_name Turn
extends RefCounted
## Turn flow: end-of-phase upkeep and the AP refill (rules.py "turn flow").

const W := preload("res://core/world.gd")
const PHASE_PLAYER := 0
const PHASE_ENEMY := 3
const SUPPLY_TILE := 0xFE
const OPTION_TRAINING := 0x20
const OPTION_EASY := 0x02
const TRAINING_ACES := {0: [0, 4, 6, 7], 1: [4, 6, 7]}


## 0x483250, run when a phase ends. Experience goes to w.events as ["grow", unit, ability, n].
static func turn_upkeep(w: Pd2World, rng: Pd2Random, phase: int, options := 0, selected := 0) -> void:
	var camp := 1 if w.campaign else 0
	var n := w.n_units if camp else mini(64, w.n_units)
	for u in n:
		var m := Move.max_ap(w, u)
		if not w.active(u):
			continue
		if m >> 4 >= w.sb(u, 0xE):
			w.events.append(["grow", u, "AP", 2])
		if camp:
			w.setb(u, 0xE, m)
		var p := w.pos(u)
		if w.layer(w.T, p.x, p.y) != SUPPLY_TILE:
			continue
		if camp:
			if phase == PHASE_ENEMY:
				continue
			if w.ub(u, 0xD) < 100:
				w.setb(u, 0xD, w.ub(u, 0xD) + 1)
		elif w.ub(u, 0xD) < 100:
			w.setb(u, 0xD, mini(100, rng.r16(5) + 1 + w.ub(u, 0xD)))
		var leader := w.ucrew(selected, 0)
		if (not camp and phase == PHASE_ENEMY) or not (options & OPTION_TRAINING):
			continue
		if W.s8(leader) in TRAINING_ACES[camp]:
			for ab in ["AP", "ATTACK", "AA", "CC", "DEF"]:
				w.events.append(["grow", u, ab, 5])


## 0x483090: the side whose phase begins gets its AP refilled to the maximum.
static func refill_ap(w: Pd2World, phase: int) -> void:
	for u in w.n_units:
		if (3 if w.is_enemy(u) else 0) == phase:
			w.setb(u, 0xE, Move.max_ap(w, u))


# --- mission_loop's passes (0x436690; rules.py, emulated) --------------------------------

## 0x483490(0): with the campaign flag, F-layer bit 5 cleared on the map; then every active
## unit of the side whose phase it is searches with its movement mode (search_command
## 0x47F500 without its prompt = step_search). The sensor list (DS:0x50AC58) is not ported.
static func recon_pass(w: Pd2World, phase: int) -> Array:
	if w.campaign:
		for y in W.MAP:
			for x in W.MAP:
				if w.on_map(x, y):
					w.F[x + W.MAP * y] &= 0xDF
	var out := []
	for u in w.n_units:
		if (3 if w.is_enemy(u) else 0) == phase and w.active(u):
			out.append_array(Action.step_search(w, u, (w.ub(u, 4) >> 4) & 3))
	Item.sensors_scan(w)                 # the sensor list (0x50AC58), as the game ends 0x483490
	return out


## 0x437370(side): the whole map in side's view (option DS:0x551D29 bit 7).
static func view_all(w: Pd2World, side: int) -> void:
	for y in range(1, 71):
		for x in range(1, 71 - (y & 1)):
			Ai.set_view(w, x, y, side)


## 0x46F590(0): every strike mark (F-layer bit 4) cleared.
static func clear_strikes(w: Pd2World) -> void:
	for y in W.MAP:
		for x in W.MAP:
			if w.on_map(x, y):
				w.F[x + W.MAP * y] &= 0xEF


## 0x483B50: smoke (F-layer bit 0) clears with random(100) < 25 on each hex that has it.
static func smoke_clears(w: Pd2World, rng: Pd2Random) -> void:
	for y in W.MAP:
		for x in W.MAP:
			if w.F[x + W.MAP * y] & 1 and (rng.roll(100) & 0xFFFF) < 25 and w.on_map(x, y):
				w.F[x + W.MAP * y] &= 0xFE


## 0x480BF0, before the computer's turn: AI memory entry k cleared unless unit k is an
## active player-side unit whose remembered hex is on the map and out of the enemy's view.
static func memory_forget(w: Pd2World) -> void:
	for k in 40:
		var m := Ai.mem(w, k)
		if not (w.active(k) and not w.is_enemy(k) and w.on_map(m.x, m.y) and not Ai.in_view(w, m.x, m.y, 3)):
			w.memory[3 * k] = 0xFF
			w.memory[3 * k + 1] = 0xFF
			w.memory[3 * k + 2] = 0xFF


## 0x480C60, at the start of the player's turn: an active, spotted player-side unit in
## the enemy's view is remembered at its hex.
static func memory_record(w: Pd2World) -> void:
	for k in 40:
		var p := w.pos(k)
		if w.active(k) and not w.is_enemy(k) and Ai.in_view(w, p.x, p.y, 3) and w.ub(k, 0) & 0x10:
			w.memory[3 * k] = w.ub(k, 9)
			w.memory[3 * k + 1] = w.ub(k, 10)


## 0x4E0BF0(side), after each side's turn: support groups (state +0x21 3, 4 or 5, +0x16
## set) take a new +2 state from their first member that changes it (rules.support_fire).
static func support_fire(w: Pd2World, side: int) -> void:
	for g in 64:
		var G := 35 * g
		if not (w.groups[G + 5] and (w.groups[G + 0x21] & 0xF0) in [0x30, 0x40, 0x50] and w.groups[G + 0x16] != 0xFF):
			continue
		for i in 16:
			var k := w.groups[G + 6 + i]
			if k == 0xFF or w.ub(k, 0) & 1:
				continue
			var st := w.sb(k, 0x36)
			if st >= side and st <= side + 2:
				if w.ub(k, 6) == 1:
					w.groups[G + 2] = (w.groups[G + 2] & 0xF) | 0xA0
					break
			elif w.groups[G + 0x21] & 0xF0 == 0x50 and w.groups[G + 2] & 0x30 == 0x20 and w.groups[G + 2] & 0xC0 == 0x40:
				w.groups[G + 2] = (w.groups[G + 2] & 0xF) | 0x20
				break


## 0x47D5C0(side): side's view marks cleared on the map (bit 3 player, bit 2 computer).
static func clear_view(w: Pd2World, side: int) -> void:
	var bit := 0x08 if side < 3 else 0x04
	for y in W.MAP:
		for x in W.MAP:
			if w.on_map(x, y):
				w.F[x + W.MAP * y] &= ~bit & 0xFF


## 0x437440: spotted flags cleared; with option bit 7, computer units are set spotted.
static func clear_spotted_all(w: Pd2World, options := 0) -> void:
	for u in w.n_units:
		if options & 0x80 and w.is_enemy(u):
			w.setb(u, 0, w.ub(u, 0) | 0x10)
		else:
			w.setb(u, 0, w.ub(u, 0) & 0xEF)


## 0x4361A0: reacted flags (+0 bit 6) cleared.
static func clear_reacted_all(w: Pd2World) -> void:
	for u in w.n_units:
		w.setb(u, 0, w.ub(u, 0) & 0xBF)


# --- timed explosives (0x480280, the turn start) --------------------------------------

## What the timed explosives leave to the game (rules.BombHooks).
class BombHooks extends RefCounted:
	## A bomb's explosion window opens (0x40F730): true if the animations were turned off.
	func start() -> bool:
		return false

	## One hex's explosion is animated (0x417410): true if the player skipped it.
	func explosion(x: int, y: int) -> bool:
		return false

	## A mine's explosion (0x473330).
	func mine_blast(x: int, y: int) -> void:
		pass

	## The mission's bomb hook (table 0x51F158) for entry i: 0 or an abort code.
	func bomb_hook(i: int) -> int:
		return 0

	## A destroyed unit's animation (0x4103A0 -> 0x420CD0) frame i: true when skipped.
	func anim_frame(player: int, x: int, y: int, i: int, dy: int, dx: int) -> bool:
		return false


## The end of the explosion animation 0x417410 (unless option bit 0x10): a unit at
## condition 0 on the hex has the hex emptied.
static func explosion_clear(w: Pd2World, x: int, y: int, options := 0) -> void:
	if options & 0x10:
		return
	var o := w.O[x + 72 * y] - 1
	if o != -1 and w.ub(o, 0xD) == 0:
		Action.clear_hex(w, x, y)


## 0x4103A0 -> 0x420CD0 at (x, y) (Action.anim_kill): with a unit there, its frames, then its
## hex emptied (skipped or not).
static func _kill_anim(w: Pd2World, hooks: BombHooks, x: int, y: int) -> void:
	var o := w.O[x + 72 * y] - 1 if x >= 0 and x < 72 and y >= 0 and y < 72 else -1
	if o == -1:
		return
	for i in 8:
		if hooks.anim_frame(0x420CD0, x, y, i, 0, 0):
			break
	var p := w.pos(o)
	Action.anim_clear_hex(w, p.x, p.y)


## 0x480280: the 15 timed explosives count down; one at 0 goes off over its hex and the
## six around it (rules.timed_explosives). options: DS:0x551D29.
static func timed_explosives(w: Pd2World, rng: Pd2Random, hooks: BombHooks = null, options := 0) -> int:
	if hooks == null:
		hooks = BombHooks.new()
	var easy := options & 2 != 0
	var anims := options & 0x10 == 0     # 0x4103A0 for a unit the blast destroys (rules.timed_explosives)
	var skip := false
	var b := w.bombs
	for i in 15:
		var x := W.s8(b[4 * i])
		var y := W.s8(b[4 * i + 1])
		if x == -1 or not w.on_map(x, y) or W.s8(b[4 * i + 2]) < 1:
			if x == 0 or x > 0x47:
				b[4 * i] = 0xFF
		else:
			b[4 * i + 2] = (b[4 * i + 2] - 1) & 0xFF
		if not (w.on_map(x, y) and b[4 * i + 2] == 0):
			continue
		if not skip:
			skip = hooks.start()
		var tgt := Vector2i(x, y)
		var hx := x
		var hy := y
		for j in 7:
			if w.on_map(hx, hy):
				if not skip:
					skip = hooks.explosion(hx, hy)
					explosion_clear(w, hx, hy, options)
				var o := w.O[hx + 72 * hy] - 1
				if o != -1:
					var dmg := Fire.fire_damage(w, rng, -1, 12, o, 4, easy)
					if anims and w.ub(o, 0xD) - dmg < 1:
						tgt = Vector2i(hx, hy)
						_kill_anim(w, hooks, hx, hy)
					if dmg and Fire.apply_hit(w, rng, o, dmg, -1, 12, easy) == "destroyed":
						Action.destroy(w, o)
				if not w.campaign and Action.mine_at(w, hx, hy):
					if not skip:
						hooks.mine_blast(hx, hy)
						explosion_clear(w, hx, hy, options)
					w.F[hx + 72 * hy] &= 0x3F
					if o != -1 and w.active(o) and w.unit_class(o) < 2:
						var dmg2 := Fire.fire_damage(w, rng, -1, 12, o, 4, easy)
						if anims and w.ub(o, 0xD) - dmg2 < 1:
							_kill_anim(w, hooks, tgt.x, tgt.y)    # (the record's last target)
						if Fire.apply_hit(w, rng, o, dmg2, -1, 12, easy) == "destroyed":
							Action.destroy(w, o)
			if j < 6:
				var d: Vector2i = Move.NEIGHBOURS[y & 1][j]
				hx = x + d.x
				hy = y + d.y
		if b[4 * i + 3] != 0xFF:
			var res := hooks.bomb_hook(i)
			if res in [0x10000, 0x20000, 0x40000]:
				w.bombs = b
				return res
		b[4 * i] = 0xFF
	w.bombs = b
	return 0
