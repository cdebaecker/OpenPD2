class_name AiTurnHooks
extends AiHooks
## What a behaviour leaves to the game, with the real reload, shots and steps
## (rules.AiTurnHooks). Melee, reactions, unit removal and mine blasts stay hooks.

var w: Pd2World
var easy := false
var rng: Pd2Random


func _init(w_: Pd2World, easy_ := false, rng_: Pd2Random = null) -> void:
	w = w_
	easy = easy_
	rng = rng_


func reload(u: int) -> int:
	return Ai.ai_reload(w, u)


func fire(u: int, slot: int, x: int, y: int) -> int:
	return Action.ai_fire(w, rng, u, slot, x, y, self, easy)


func step(kind: String, x: int, y: int, movemode: int, mm: Move.MoveMap, u := -1) -> int:
	if kind == "walk":
		return Action.ai_walk(w, rng, u, x, y, movemode, mm, self, easy)
	return Action.ai_path(w, rng, u, x, y, movemode, mm, self, easy)
