class_name Melee
extends RefCounted
## Melee (Pd2.exe 0x424490, one strike 0x425170; rules.melee / melee_strike;
## RULES.md 3).

const W := preload("res://core/world.gd")
const MELEE_WEAPON_WARHEAD := 11


static func kill_credit(w: Pd2World, killer: int, victim: int) -> void:   # 0x480B10
	var i := W.s8(w.ucrew(killer, 15))
	if i < 0:
		return
	var col: int = Action.KILL_COLUMN.get(w.umachine(victim, 0) & 15, 3)
	var o := Action.STATS_SIZE * i + col
	if w.combat[o] < 0xFF:
		w.combat[o] += 1


## 0x425170: x strikes y once; returns y's condition.
static func strike(w: Pd2World, x: int, y: int, alert := 0, easy := false) -> int:
	var y_enemy := w.sb(y, 0x36) >= 3
	var order := (w.ub(y, 3) >> 4) if alert else (w.ub(y, 3) & 15)
	var dmg: int
	if y_enemy and order == 0xF:
		dmg = 100
	else:
		var mx := Ai.machine_melee_of(w, x)
		var my := Ai.machine_melee_of(w, y)
		if my == 0:
			w.fault = "division by zero (melee value 0)"
			return w.ub(y, 0xD)
		var e := mx * mx / my / 2
		var c := W.s8(w.ucrew(x, 12)) + (1 if w.ucrew(x, 0) == 1 else 0)
		var sq := c * c * (1 if c > 0 else (-1 if c < 0 else 0))
		var a := (100 - sq) * e
		var b := (sq + 100) * e
		var d := (a / 4 + b / 2 + b / 4) / 100
		dmg = d >> 2
		if easy and not y_enemy:
			dmg = d >> 4
		if easy and w.sb(x, 0x36) < 3:
			dmg <<= 2
	if dmg < w.ub(y, 0xD):
		w.setb(y, 0xD, w.ub(y, 0xD) - dmg)
	else:
		w.setb(y, 0xD, 0)
	w.events.append(["grow", x, "CC", 1])
	w.events.append(["grow", y, "DEF", 1])
	return w.ub(y, 0xD)


static func _outcome(w: Pd2World, winner: int, loser: int, credit_victim: int) -> void:
	kill_credit(w, winner, credit_victim)
	w.events.append(["grow", winner, "CC", 4])
	w.events.append(["grow", loser, "DEF", 2])


## 0x424490: a melee between attacker a and defender b. Returns 0 (b destroyed),
## 1 (both stand), 2 (a destroyed), 3 (both). use_weapon(a, pocket) -> bool stands in
## for the player's melee-weapon prompt (invalid Callable: yes).
static func melee(w: Pd2World, rng: Pd2Random, a: int, b: int, alert := 0, easy := false, use_weapon := Callable()) -> int:
	var b_n := 4
	var k := -1
	for p in 12:
		var am := w.pocket_ammo(a, p)
		if w.ammo(am, 8) & 15 == MELEE_WEAPON_WARHEAD and w.pocket_state(a, p) != 2 and w.pocket_count(a, p) != 0:
			k = p
			break
	if k != -1:
		var use := true
		if w.sb(a, 0x36) < 3 and use_weapon.is_valid():
			use = use_weapon.call(a, k)
		if use:
			b_n = 3
			var n := w.pocket_count(a, k) - 1
			w.setb(a, 0x1C + 2 * k, (w.ub(a, 0x1C + 2 * k) & 0xC0) | (n & 0x3F))
		if w.pocket_count(a, k) == 0:
			w.setb(a, 0x1B + 2 * k, 0xFF)
	var a_n := 3 if (w.ub(a, 1) & 0xC0) == 0x80 else 4
	if w.ub(a, 2) & 3 == 2:
		a_n -= 1
	if w.ub(b, 1) & 0xC0 == 0x80:
		b_n -= 1
	if w.ub(b, 2) & 3 == 2:
		b_n -= 1
	if w.ucrew(a, 0) == 1 and b_n != 0 and rng.r16(100) < 40:
		b_n -= 1
	if strike(w, a, b, alert, easy) == 0:
		_outcome(w, a, b, b)
		return 0
	a_n -= 1
	var rounds := 0
	while true:
		if rng.r16(100) < 50:
			if a_n == 0 or strike(w, a, b, alert, easy) != 0:
				a_n -= 1
				if b_n != 0:
					strike(w, b, a, alert, easy)
					b_n -= 1
		else:
			if b_n == 0 or strike(w, b, a, alert, easy) != 0:
				b_n -= 1
				if a_n != 0:
					strike(w, a, b, alert, easy)
					a_n -= 1
		if not (w.ub(a, 0xD) != 0 and w.ub(b, 0xD) != 0):
			break
		rounds += 1
		if rounds >= 3:
			break
	if w.ub(a, 0xD) != 0 and w.ub(b, 0xD) != 0 and b_n != 0:
		strike(w, b, a, alert, easy)
	if w.ub(a, 0xD) != 0:
		if w.ub(b, 0xD) == 0:
			_outcome(w, a, b, b)
			return 0
		return 1
	if w.ub(b, 0xD) != 0:
		_outcome(w, b, a, b)
		return 2
	kill_credit(w, b, a)
	kill_credit(w, a, b)
	for ev in [[a, "CC", 4], [b, "CC", 4], [a, "DEF", 2], [b, "DEF", 2]]:
		w.events.append(["grow", ev[0], ev[1], ev[2]])
	return 3
