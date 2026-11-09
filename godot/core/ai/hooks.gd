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


## The player's phase (w.phase 0): "mine found!" (0x1A6), in careful mode before any question.
func mine_found(u: int) -> void:
	pass


## The player's phase: clear the mine found? (msg 0x1A3 on a step, 0x1C9 on a path)
func mine_clear(u: int, msg := 0x1A3) -> bool:
	return false


## Destroy the mine by shooting? (0x1A4): null to decline, or the weapon picker's answers
## (mode 3) ending with a slot 0-3 or -2 (no magazine swaps).
func mine_shoot(u: int) -> Variant:
	return null


## The move command's prompts, with the values the game shows: 0x1DC (move along the path?
## [the hex's AP, u's AP, the hex's cover]) and 0x1E4 (melee? [the hex's AP]).
func confirm(msg: int, args: Array) -> bool:
	return true


## melee's own prompt: use the melee weapon in pocket p?
func use_weapon(a: int, p: int) -> bool:
	return true


## the melee's display afterwards (0x40EB70)
func melee_done() -> void:
	pass


## the player's "intercept?" prompt: the slot, or -1 to decline
func intercept_choice(t: int, best: int) -> int:
	return -1
