extends SceneTree
## The battle's saves (Title.battle_menu, 0x4847C0) in play:
## 1. a DASH campaign battle (mission 12 from its SAVEDATA.ORG) started, a turn played (the
##    computer's turn too), then its system menu's SAVE to slot 38: PD2REC37.BIN (head
##    +2 = 1: a save made in a battle, the slot line shows its time), KEMURI37.DAT,
##    MEMBER37.DAT in user://saves.
## 2. the title's continue (0x46D780 "1") of that slot: bit 0x80, then the battle at once
##    (Title.mission_resume): the same mission, units, groups and DS block, the F layer's
##    saved bits and the AI memory back, the player's phase, no briefing nor sortie.
## 3. a unit moved off its place, then the system menu's LOAD of the same slot: the scene
##    is set up again from the save (the unit back).
## 4. the options: entry 2 (アニメ) answered yes flips DS:0x551D29 bit 4; entry 5 answered
##    no leaves bit 13.
## The files are removed after.

const SLOT := 37


var SF


class Answers extends Title.Hooks:
	var sf
	var slots := []

	func slot() -> int:
		return slots.pop_front() if not slots.is_empty() else 0x29

	func save_file(s: int) -> Variant:
		return sf.read("PD2REC%02d.BIN" % s)

	func member_file(s: int) -> Variant:
		return sf.read("MEMBER%02d.DAT" % s)


func find_battle(script, not_id: int) -> Node:
	for n in root.get_children():
		if is_instance_valid(n) and n.get_script() == script and n.get_instance_id() != not_id and not n.is_queued_for_deletion():
			return n
	return null


func _init() -> void:
	await process_frame
	SF = load("res://ui/save_files.gd")
	var ok := true
	for f in ["PD2REC%02d.BIN", "MEMBER%02d.DAT", "KEMURI%02d.DAT"]:
		DirAccess.remove_absolute(SF.DIR.path_join(f % SLOT))
	# 1. DASH mission 12 (chunk 2) in the campaign, a turn, then SAVE
	var b = load("res://ui/battle.tscn").instantiate()
	b.campaign = "dash"
	b.mission_index = 1
	b.auto_react = true
	b.sortie_window = false
	b.plan_window = false
	root.add_child(b)
	await process_frame
	b._end_turn()
	await process_frame
	var w: Pd2World = b.w
	w.F[100] |= 1                       # smoke on a hex (KEMURI keeps bit 0)
	w.memory[5] = 0x21                  # an AI memory entry
	b.menu_answers_scripted = [0, SLOT, 1]    # SAVE, the slot, "overwrite?" yes
	b._cmd_system()
	var img := Debrief.save_image(w)
	var data: Variant = SF.read("PD2REC%02d.BIN" % SLOT)
	var kem: Variant = SF.read("KEMURI%02d.DAT" % SLOT)
	var saved: bool = data != null and kem != null and SF.read("MEMBER%02d.DAT" % SLOT) != null \
		and (data as PackedByteArray)[8 + 2] == 1 and (kem as PackedByteArray).size() == Title.KEMURI_DASH \
		and b.sysmenu_panel == null and not b.mission_over
	var line: String = SF.slot_line(SLOT, 0x519EE8)
	print("saved in battle: %s (turn %d), slot line: %s" % [str(saved), w.mission_turn, line])
	ok = ok and saved and line.find(":") != -1
	var units := w.units.duplicate()
	var groups := w.groups.duplicate()
	var script_no: int = w.script_no
	b.queue_free()
	await process_frame
	# 2. the title's continue: bit 0x80, the battle resumes
	var tw: Pd2World = SF.title_world()
	var hk := Answers.new()
	hk.sf = SF
	hk.slots = [SLOT]
	var res := Title.title_start(tw, "1", hk)
	var cont: bool = res[1] == 0 and res[0] & 0x80 and tw.ds8(0x50AD94) == SLOT + 1
	print("continue: %s (bit 0x80 %s), mission %d" % [str(res), str(res[0] & 0x80 != 0), tw.script_no])
	var r = load("res://ui/battle.tscn").instantiate()
	r.campaign = "pd2" if tw.campaign else "dash"
	r.mission_index = Debrief.chunk(tw) - 1
	r.title_carry = {"image": Debrief.save_image(tw), "script": tw.script_no, "stash": tw.stash,
		"new_campaign": false, "resume": true}
	r.auto_react = true
	r.sortie_window = false
	r.plan_window = false
	root.add_child(r)
	await process_frame
	var rw: Pd2World = r.w
	var same: bool = rw.units == units and rw.groups == groups and rw.script_no == script_no \
		and r.campaign == "dash" and r.mission_index == 1 and rw.phase == 0 and not r.mission_over \
		and rw.F[100] & 1 and rw.memory[5] == 0x21 and rw.ds8(0x50AD94) == 0 and rw.mode_663a == 1 \
		and r.sortie_panel == null
	print("resumed: same units %s, groups %s, smoke %s, memory %s, phase %d, over %s" % [str(rw.units == units),
		str(rw.groups == groups), str(rw.F[100] & 1 != 0), str(rw.memory[5] == 0x21), rw.phase, str(r.mission_over)])
	ok = ok and cont and same
	# 3. a unit moved, then LOAD: the battle set up again from the save
	var u := -1
	for k in 27:
		if rw.active(k):
			u = k
			break
	var moved := false
	if u != -1:
		var p := rw.pos(u)
		rw.setb(u, 9, (p.x + 1) % 70)
		var script = r.get_script()
		var rid: int = r.get_instance_id()
		r.menu_answers_scripted = [1, SLOT, 1]     # LOAD, the slot, "load?" yes
		r._cmd_system()
		await process_frame
		await process_frame
		var l: Node = find_battle(script, rid)
		if l != null:
			var lw: Pd2World = l.w
			moved = lw.pos(u) == p and lw.units == units and lw.F[100] & 1 and not l.mission_over and lw.phase == 0
			print("loaded in battle: unit %d back at %s: %s" % [u, str(p), str(moved)])
			r = l
	ok = ok and moved
	# 4. the options
	var ow: Pd2World = r.w
	var before: int = ow.options
	r.menu_answers_scripted = [2, 1]
	r._cmd_system()
	var anim: bool = ow.options == before ^ 0x10 and r.mission_hooks.options == ow.options
	r.menu_answers_scripted = [5, 0]
	r._cmd_system()
	var kept: bool = ow.options == before ^ 0x10
	print("options: 0x%X -> 0x%X (entry 2 yes: %s, entry 5 no: %s)" % [before, ow.options, str(anim), str(kept)])
	ok = ok and anim and kept
	r.queue_free()
	for f in ["PD2REC%02d.BIN", "MEMBER%02d.DAT", "KEMURI%02d.DAT"]:
		DirAccess.remove_absolute(SF.DIR.path_join(f % SLOT))
	print("battle save flow: %s" % ("ok" if ok else "FAILED"))
	quit(0 if ok else 1)
