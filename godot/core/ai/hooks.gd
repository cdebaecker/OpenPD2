class_name AiHooks
extends RefCounted
## What the rules leave to the game (rules.py AiHooks, EngageHooks, SearchHooks,
## FireHooks, StepHooks in one): steps, melee, unit removal, shots, reloading, reaction
## fire, mine blasts, the player's intercept prompt. The defaults do nothing.


func step(kind: String, x: int, y: int, movemode: int, mm: Move.MoveMap, u := -1) -> int:
	return 0


func melee(u: int, o: int) -> int:        # 0x424490
	return 4


func destroy(k: int) -> void:             # 0x480140
	pass


func fire(u: int, slot: int, x: int, y: int) -> int:   # 0x415D50
	return 0


func reload(u: int) -> int:               # 0x42D140
	return 0


func react(u: int) -> int:                # 0x472410 / 0x472920
	return 0


func mine_blast(x: int, y: int) -> void:
	pass


## the player's "intercept?" prompt: the slot, or -1 to decline
func intercept_choice(t: int, best: int) -> int:
	return -1
