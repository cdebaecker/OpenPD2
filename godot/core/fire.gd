class_name Fire
extends RefCounted
## Fire: hit chance, damage, missile interception, applying a hit (rules.py section
## "fire"; RULES.md section 4). Ported line for line; checked against rules.py fixtures.

const W := preload("res://core/world.gd")

const EFFECTIVENESS := {
	0: [[7, 7, 7, 20, 10, 10, 40, 10, 1, 1, 1, 1, 1, 7, 1, 10],
		[2, 2, 2, 10, 7, 7, 10, 7, 1, 1, 1, 1, 1, 7, 1, 10],
		[2, 2, 2, 10, 7, 7, 10, 7, 1, 1, 1, 1, 1, 7, 1, 10],
		[1, 1, 1, 10, 10, 10, 10, 10, 1, 1, 1, 1, 1, 1, 1, 10],
		[1, 1, 1, 10, 10, 10, 40, 10, 1, 1, 1, 1, 1, 1, 1, 10]],
	1: [[7, 7, 7, 20, 10, 10, 40, 10, 1, 1, 1, 1, 1, 2, 1, 10],
		[2, 2, 2, 10, 7, 7, 10, 7, 1, 1, 1, 1, 1, 2, 1, 10],
		[2, 2, 2, 10, 7, 7, 10, 7, 1, 1, 1, 1, 1, 2, 1, 10],
		[1, 1, 1, 10, 10, 10, 10, 10, 1, 1, 1, 1, 1, 1, 1, 10],
		[1, 1, 1, 10, 10, 10, 40, 10, 1, 1, 1, 1, 1, 1, 1, 10]],
}

const DAMAGE_CLASS := [
	[200, 200, 200, 100, 100, 100, 50, 100, 0, 0, 0, 0, 0, 200, 1, 10],
	[200, 200, 200, 20, 20, 100, 201, 201, 0, 0, 0, 0, 0, 201, 1, 10],
	[200, 200, 200, 201, 100, 201, 201, 201, 0, 0, 0, 0, 0, 200, 1, 10],
	[0, 0, 0, 100, 100, 100, 100, 100, 0, 0, 0, 0, 0, 0, 1, 10],
	[0, 0, 0, 100, 100, 100, 100, 201, 0, 0, 0, 0, 0, 0, 1, 10],
]
const NO_SHOOTER_WARHEAD := 13
const NO_SHOOTER_CREW_BYTE := 302   # unit -1's crew byte (DS:0x506C67) inside the combat records
const MISSILE_KIND := 2
const DECOY_WARHEAD := 12
const INTERCEPTED := 2
const DECOYED := 0
const NOT_STOPPED := 1
const EMP_WARHEAD := 15


static func _aa(mode: int) -> bool:
	return mode == 6 or mode == 10


## All the terms of the hit chance (0x415B50). Raises nothing; a weapon range of 0 at a
## distance > 0 divides by zero in the game: returns {"error": true} then.
static func hit_terms(w: Pd2World, s: int, t: int, slot: int, mode: int, aim: int, pc98 := false, ranged := true) -> Dictionary:
	var wh := w.warhead(s, slot)
	var t_air := w.unit_class(t) >= 2
	var lid := w.launcher_id(s, slot)
	var acc := w.launcher(lid, 5 if (_aa(mode) or t_air) else 2)
	var s_ace := w.ucrew(s, 0) in W.ACE_NAME_IDS
	var t_ace := w.ucrew(t, 0) in W.ACE_NAME_IDS
	var base := maxi(0, (45 if mode == 1 else 0) + (20 if s_ace else 0) - (20 if t_ace else 0))
	var posture := 0
	if (w.ub(s, 2) >> 2) & 3 == 2:
		posture = -35 if wh == 7 else -15
	var ability := W.s8(w.ucrew(s, 11 if _aa(mode) else 10))
	var skill := 0 if wh == 7 else W.skill_table(ability, 0)
	var height := 0
	var ps := w.pos(s)
	var pt := w.pos(t)
	if not _aa(mode) and not t_air and w.active(t):
		var dh := w.layer(w.H, ps.x, ps.y) - w.layer(w.H, pt.x, pt.y)
		height = -10 if dh < -1 else (-5 if dh == -1 else (0 if dh == 0 else (5 if dh == 1 else 10)))
	if wh == 7:
		height = 0
	var marked := 15 if w.ub(t, 0x34) != 0xFF else 0
	var aim_bonus := marked
	if aim != -1:
		var limit: int
		if aim == 0:
			limit = 4 * (2 if marked else 1)
		elif aim == 1:
			limit = 2 * (2 if marked else 1)
		elif aim == 2:
			limit = 1 * (2 if marked else 1)
		else:
			limit = s if pc98 else t
		if w.sb(t, 0xE) >= limit:
			aim_bonus = 0
		else:
			aim_bonus = marked + (50 if aim == 0 else (20 if aim == 1 else 5))
	var cov := 0
	if not _aa(mode) and not t_air and w.active(t):
		var kind := w.terrain[w.layer(w.T, pt.x, pt.y)]
		cov = w.terrain[608 + 16 * (5 + w.unit_class(t)) + kind]
		if w.ub(t, 0) & 0x20:
			cov = 7 * (w.layer(w.F, pt.x, pt.y) & 1) + 2 * cov
	var defense := W.skill_table(W.s8(w.ucrew(t, 13)), 1)
	var rng_pen := 0
	var dist := W.hexdist(ps.x, ps.y, pt.x, pt.y)
	if dist > 0 and w.active(s) and ranged:   # (Strike.hit has no range term)
		var r := w.weapon_range(s, slot)
		if r == 0:
			if not w.safe_hit("D1", "hit chance: weapon range 0 (the game divides by zero): taken as 1"):
				return {"error": true}
			r = 1
		rng_pen = maxi(0, ((dist - 3) * 10) / r)
	if wh == 7:
		rng_pen = 0
	var eff: int = 1 if wh > 15 else EFFECTIVENESS[1 if w.campaign else 0][w.armour(t)][wh]
	return {"accuracy": acc, "base": base, "posture": posture, "skill": skill, "height": height,
		"aim": aim_bonus, "cover": cov, "defense": defense, "range": rng_pen,
		"effectiveness": eff, "shooter_ace": s_ace, "distance": dist}


## Chance in % before the roll; -1 means "cannot hit" (effectiveness 1).
static func hit_chance(terms: Dictionary) -> int:
	var e: int = terms.effectiveness
	if e == 1:
		return -1
	if e == 2:
		return 98
	var total: int = (terms.accuracy + terms.base + terms.posture + terms.skill + terms.height
		+ terms.aim - terms.cover - terms.defense - terms.range)
	return maxi(15, mini(98, (total * 10) / e))


## The full 0x415B50: the chance if the shot hits, else 0.
static func roll_hit(rng: Pd2Random, terms: Dictionary) -> int:
	var e: int = terms.effectiveness
	if e == 1:
		return 0
	if e == 2:
		return 98 if rng.roll(100) < 98 else 0
	var chance := hit_chance(terms)
	var r := rng.roll(100)
	if terms.shooter_ace and rng.roll(100) < 30:
		return 98
	return chance if r < chance else 0


static func attack_power(w: Pd2World, s: int, slot: int, t: int, mode: int) -> int:   # 0x413540
	var ground := mode == 9 or (not _aa(mode) and (s == -1 or w.unit_class(t) <= 1))
	if ground:
		if s == -1:
			return w.ammo(slot, 1)
		var bonus := (W.s8(w.ucrew(s, 10)) if mode == 3 else (0 if mode == 4
			else w.launcher(w.launcher_id(s, slot), 3)))
		return bonus + w.ammo(w.ammo_id(s, slot), 1)
	var b2 := ((W.s8(w.ucrew(s, 11)) / 2) if mode == 3 else (0 if mode == 4
		else w.launcher(w.launcher_id(s, slot), 6)))
	return b2 + w.ammo(w.ammo_id(s, slot), 2)


static func cover_divisor(w: Pd2World, t: int, dclass: int) -> int:   # 0x413490
	if not w.active(t) or dclass != 200:
		return 1
	var p := w.pos(t)
	var c := w.terrain[608 + 16 * (5 + w.unit_class(t)) + w.terrain[w.layer(w.T, p.x, p.y)]]
	if w.ub(t, 0) & 0x20:
		c *= 2
	c += 7 * (w.layer(w.F, p.x, p.y) & 1)
	return (c + 10) / 10


## Damage of one hit (0x413A90). s may be -1 (no shooting unit; slot is then an ammo id).
static func fire_damage(w: Pd2World, rng: Pd2Random, s: int, slot: int, t: int, mode: int, easy := false) -> int:
	var wh := NO_SHOOTER_WARHEAD if s == -1 else w.warhead(s, slot)
	var dclass: int = DAMAGE_CLASS[w.armour(t)][wh]
	var a := attack_power(w, s, slot, t, mode)
	if a == 0:
		return 0
	var div := cover_divisor(w, t, dclass)
	var arm := w.umachine(t, 5 if (s != -1 and w.unit_class(s) > 1) else 4)
	var crew_def := W.s8(w.ucrew(t, 13))
	var dmg: int
	if dclass == 200:
		var n := (((a - crew_def) / div) * (100 - arm)) / 100
		dmg = (rng.r16(n) + rng.r16(n) + rng.r16(n)) / 2
	else:
		if dclass == 201 and s == -1:
			a = a / 2
		var v := ((a - crew_def) * (100 - arm) * dclass) / 10000
		var spread := mini(10, maxi(2, v / 4))
		dmg = maxi(1, rng.r16(spread) + v - spread / 2 + 1)
	var enemy := w.sb(t, 0x36) >= 3
	var cond := w.ub(t, 0xD)
	if cond < 11:
		dmg = dmg * 2 if enemy else dmg / 2
	elif cond < 21:
		dmg = (dmg * 3) / 2 if enemy else (dmg * 8) / 10
	if not enemy and easy:
		dmg >>= 4
	return dmg if dmg > 0 else 1


## Slots 0-3 the target can intercept with, best first; -1 if none.
static func intercept_candidates(w: Pd2World, t: int) -> int:
	var best := -1
	var best_score := 0
	var any_ := false
	for k in 4:
		if k >= 2 and (w.ub(t, 1) & 0xC0) == 0x80 and (w.ub(t, 2) & 3) == 2:
			continue
		var lid := w.launcher_id(t, k)
		if lid == -1 or w.slot_state(t, k) == 2:
			continue
		var kind := w.launcher(lid, 8) >> 5
		if kind == 2 or kind == 3 or w.slot_count(t, k) == 0:
			continue
		var aa := w.ammo(w.ammo_id(t, k), 2)
		if aa <= 0:
			continue
		any_ = true
		if aa + kind > best_score:
			best = k
			best_score = aa + kind
	return best if any_ else -1


## Target t reacts to a missile from s (0x4149F0). player_choice(t, best) -> slot or -1
## stands in for the player's prompt. Returns INTERCEPTED, DECOYED or NOT_STOPPED.
static func intercept(w: Pd2World, rng: Pd2Random, s: int, slot: int, t: int, player_choice := Callable()) -> int:
	var result := NOT_STOPPED
	var chosen := -1
	if w.unit_class(t) == 0:
		var best := intercept_candidates(w, t)
		if best != -1:
			if w.is_enemy(t):
				chosen = best
			elif player_choice.is_valid():
				chosen = player_choice.call(t, best)
	var shot_down := false
	if chosen != -1:
		w.set_slot_count(t, chosen, w.slot_count(t, chosen) - 1)
		var aa := W.s8(w.ucrew(t, 11))
		var sq := aa * aa
		var lid := w.launcher_id(t, chosen)
		var p_track := maxi(15, mini(100, w.launcher(lid, 5) + sq))
		var p_kill := maxi(15, mini(100, sq + ((w.launcher(lid, 6) + w.ammo(w.ammo_id(t, chosen), 2)) & 0xFF)))
		if w.is_ace(t) and rng.r16(100) < 50:
			p_track += 30
			p_kill += 30
		if rng.r16(100) < p_track and rng.r16(100) < p_kill:
			result = INTERCEPTED
			shot_down = true
			w.events.append(["grow", t, "AA", 1])
	if not shot_down:
		var decoy := -1
		for k in 12:
			var a := w.pocket_ammo(t, k)
			if (a != -1 and w.ammo(a, 8) & 15 == DECOY_WARHEAD and w.pocket_count(t, k) != 0
					and w.pocket_state(t, k) != 2):
				decoy = k
		if decoy != -1:
			var n := w.pocket_count(t, decoy) - 1
			w.setb(t, 0x1C + 2 * decoy, (w.ub(t, 0x1C + 2 * decoy) & 0xC0) | (n & 0x3F))
			if n == 0:
				w.setb(t, 0x1B + 2 * decoy, 0xFF)
			result = DECOYED
	return result


static func _bump(rng: Pd2Random, v: int) -> int:
	if v == 0:
		return 1
	if v == 1 and rng.r16(100) < 50:
		return 2
	return v


static func _set2(w: Pd2World, u: int, i: int, shift: int, v: int) -> void:
	w.setb(u, i, (w.ub(u, i) & ~(3 << shift) & 0xFF) | (v << shift))


static func _pair_bump(rng: Pd2Random, v: int) -> int:
	return 1 if v == 0 else ((v + 1) & 3 if rng.r16(100) < 50 else v)


## 0x414310: damage the movement gear.
static func damage_pair(w: Pd2World, rng: Pd2Random, t: int) -> void:
	var r1 := w.ub(t, 1)
	var a := (r1 >> 2) & 3
	var b := (r1 >> 4) & 3
	if a == 2 or b == 2:
		return
	if a == b and a < 2:
		if rng.r16(2):
			_set2(w, t, 1, 2, _pair_bump(rng, a))
		else:
			_set2(w, t, 1, 4, _pair_bump(rng, b))
	elif a > b:
		_set2(w, t, 1, 4, _pair_bump(rng, b))
	else:
		_set2(w, t, 1, 2, _pair_bump(rng, a))


## Apply dmg to t (0x413D90) and roll critical part damage. Returns "destroyed" or "damaged".
static func apply_hit(w: Pd2World, rng: Pd2Random, t: int, dmg: int, s: int, slot: int, easy := false, pc98 := false) -> String:
	var cls := w.unit_class(t)
	if w.ub(t, 0xD) <= dmg:
		w.setb(t, 0xD, 0)
		w.setb(t, 0, w.ub(t, 0) | 1)
		return "destroyed"
	if pc98 and s != -1 and w.warhead(s, slot) == EMP_WARHEAD:
		if (w.ub(t, 2) >> 4) & 3 == 0:
			w.setb(t, 2, (w.ub(t, 2) & 0x3F) | ((w.ub(t, 1) & 3) << 6))
		w.setb(t, 1, (w.ub(t, 1) & 0xFC) | 2)
		w.setb(t, 2, (w.ub(t, 2) & 0xCF) | 0x30)
	if cls <= 1 and s == -1 and slot == 12:
		damage_pair(w, rng, t)
	if not (w.ub(t, 0) & 0x10):
		var hide := (w.cover(t) + 10) * (2 if w.ub(t, 0) & 0x20 else 1) * (2 if w.ucrew(t, 8) & 8 else 1)
		var p := w.pos(t)
		hide += 30 if w.layer(w.F, p.x, p.y) & 1 else 0
		if rng.r16(70) >= hide:
			w.setb(t, 0, w.ub(t, 0) | 0x10)
	w.setb(t, 0xD, w.ub(t, 0xD) - dmg)
	if dmg <= 10 and rng.r16(100) < 100 - dmg:
		return "damaged"
	if not w.is_enemy(t) and easy:
		return "damaged"
	var s_ace: bool
	if s != -1:
		s_ace = w.is_ace(s)
	else:                       # the game reads "unit -1": its crew byte is combat-record byte 302
		s_ace = w.crew_memory(W.s8(w.combat[NO_SHOOTER_CREW_BYTE]), 0) in W.ACE_NAME_IDS
	var count := 1
	var wh := NO_SHOOTER_WARHEAD if s == -1 else w.warhead(s, slot)
	if DAMAGE_CLASS[w.armour(t)][wh] != 200:
		if rng.r16(100) < 10 or (s_ace and rng.r16(100) < 60):
			count = 3
	if w.is_ace(t) and rng.r16(100) < 20:
		return "damaged"
	for i in count:
		var k := rng.r16(13)
		if k == 0:
			_set2(w, t, 1, 0, _bump(rng, w.ub(t, 1) & 3))
		elif k == 1:
			if cls != 3:
				damage_pair(w, rng, t)
		elif k <= 5:
			if cls != 3 and w.launcher_id(t, k - 2) != -1:
				var st := w.slot_state(t, k - 2)
				if st < 2:
					_set2(w, t, 0x10 + 2 * (k - 2), 4, _bump(rng, st))
		elif k <= 9:
			var p2 := k - 6
			if w.pocket_ammo(t, p2) != -1:
				var st2 := w.pocket_state(t, p2)
				if st2 < 2:
					_set2(w, t, 0x1C + 2 * p2, 6, _bump(rng, st2))
		elif k == 10:
			if cls == 0:
				_set2(w, t, 1, 6, _bump(rng, w.ub(t, 1) >> 6))
		elif k == 11:
			if cls == 0:
				_set2(w, t, 2, 0, _bump(rng, w.ub(t, 2) & 3))
		else:
			_set2(w, t, 2, 2, _bump(rng, (w.ub(t, 2) >> 2) & 3))
	return "damaged"
