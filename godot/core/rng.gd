class_name Pd2Random
extends RefCounted
## The game's 16-bit generator (Pd2.exe 0x48F800; state word DS:0x50AD90).
## call(n) returns 0..n-1; n = 0xFFFF returns the raw new state. rules.Random.

var state: int


func _init(s: int = 0) -> void:
	state = s & 0xFFFF


func next_raw() -> int:
	var s := state
	var eax := ((s & 0xFF) << 8) | ((s >> 8) & 0xFF)
	var esi := eax
	for i in 4:
		var ecx := (eax << 15) & 0xFFFFFFFF
		eax = (eax & 0xFFFF0000) | ((eax & 0xFFFF) >> 1)
		eax |= ecx
	var bit := (eax >> 8) & 1
	var rot := ((esi << 1) | ((esi & 0xFFFF) >> 15)) & 0xFFFFFFFF
	var out := bit ^ rot
	state = out & 0xFFFF
	return out


func roll(n: int) -> int:
	var raw := next_raw()
	var n1 := (n + 1) & 0xFFFF
	if n1 == 0:
		return raw
	var div := (n1 - 1) & 0xFFFF
	if div == 0:
		return 0
	return (raw & 0xFFFF) % div


## rng(n) & 0xFFFF: what most callers keep.
func r16(n: int) -> int:
	return roll(n) & 0xFFFF
