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
