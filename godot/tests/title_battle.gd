extends SceneTree
## The title's starts into DASH (Title, as ui/boot.gd runs them) and the chain after them:
## 1. the scenario select (0x46D780 "2") of DASH's mission 12 with its SAVEDATA.ORG: a single
##    mission (mode 2); its debrief goes back to the title, as the game's does.
## 2. PD2's campaign handing over to DASH (step 7's mission 6 cleared: the end code 0x80, as
##    its scripts set it, then the debrief), DASH's mission 12's sortie saved (0x497F60: PD2REC40.BIN, MEMBER40.DAT in user://saves, removed after).
## 3. the continue (0x46D780 "1") of that save: DASH's mission 12 again, in the campaign;
##    cleared, its debrief chains on to step 2 (mission 14), which starts.
## 4. the rescue mission (0x46D780 "3") on the same save: no crew is missing (0x5175C8).

const SLOT := 39                      # the file names count from 0: slot 40 is PD2REC39.BIN


var SF                              # ui/save_files.gd, loaded once the autoloads are up


class Answers extends Title.Hooks:
	var sf
	var picks := []
	var slots := []
	var log := []

	func box(text: Variant) -> int:
		log.append(["box", text])
		return 0

	func pick(kind: String, items: Array) -> int:
		log.append(["pick", kind, items])
		return picks.pop_front() if not picks.is_empty() else -2

	var gd

	func savedata_org(flag: int) -> Variant:
		var img: Array = gd.save_image("pd2" if flag else "dash")
		var out := Title.magic()
		out.append_array(img[1])
		return out

	func saves() -> int:
		return 0

	func slot() -> int:
		return slots.pop_front() if not slots.is_empty() else 0x29

	func save_file(s: int) -> Variant:
		return sf.read("PD2REC%02d.BIN" % s)

	func member_file(s: int) -> Variant:
		return sf.read("MEMBER%02d.DAT" % s)


func battle(w: Pd2World, sortie := false) -> Node:
	## game_mode_loop's mission start with the title's savedata.tmp (ui/boot.gd)
	var b = load("res://ui/battle.tscn").instantiate()
	b.campaign = "pd2" if w.campaign else "dash"
	b.mission_index = Debrief.chunk(w) - 1
	b.title_carry = {"image": Debrief.save_image(w), "script": w.script_no, "stash": w.stash, "new_campaign": false}
	b.auto_react = not sortie
	b.sortie_window = sortie
	b.plan_window = false               # the operation plan pressed done at once
	root.add_child(b)
	return b


func clear(b: Node) -> void:
	## the mission's scripts leave the end code 0x80 (cleared); mission_loop's check after
	## the player's command ends the mission, then the debrief
	b.w.set_ds8(0x50ADF2, 0x80)
	b._after_command()


func next_battle(b: Node, nxt: Array) -> Node:
	var script = b.get_script()
	b._next_mission(nxt)
	await process_frame
	await process_frame
	for n in root.get_children():
		if is_instance_valid(n) and n.get_script() == script and n != b and n.mission_index == int(nxt[1]) - 1:
			return n
	return null


func _init() -> void:
	await process_frame
	SF = load("res://ui/save_files.gd")
	var ok := true
	# 1. the scenario select: DASH mission 12 (step 8), default data
	var w: Pd2World = SF.title_world()
	var hk := Answers.new()
	hk.gd = root.get_node("/root/GameData")
	hk.sf = SF
	var lst := []
	for step in range(1, 0x17):
		var m: int = w.mem8(Debrief.PD2_STEPS + step)
		if w.mem8(Title.SCENARIO_OK + m):
			lst.append(m)
	hk.picks = [lst.find(12)]
	var res := Title.title_start(w, "2", hk)
	var single: bool = res == [12 | 0x40, 0] and w.campaign == 0 and Debrief.chunk(w) == 2 and w.script_no == 12 \
		and Debrief.campaign_mode(w) == 2 and w.ds16(0x50AD8E) == 1 and w.fault == ""
	print("scenario select: %s, flag %d, chunk %d, mission %d, mode %d, step %d" % [str(res), w.campaign,
		Debrief.chunk(w), w.script_no, Debrief.campaign_mode(w), w.ds16(0x50AD8E)])
	var b := battle(w)
	await process_frame
	var bw: Pd2World = b.w
	var started: bool = b.campaign == "dash" and b.script_no == 12 and Debrief.campaign_mode(bw) == 2
	b._cmd_withdraw()
	var back: bool = b.mission_over and b.debrief_result == 0x80 and Debrief.next_mission(bw).is_empty()
	print("its battle: %s chunk %d, mission %d; withdrawn: debrief 0x%X, next %s" % [b.campaign,
		b.mission_index + 1, b.script_no, b.debrief_result, str(Debrief.next_mission(bw))])
	ok = ok and single and started and back
	b.queue_free()
	# 2. PD2's step 7 (mission 6) ends: the debrief hands over to DASH (mission 12)
	w = SF.title_world()
	hk = Answers.new()
	hk.gd = root.get_node("/root/GameData")
	hk.sf = SF
	res = Title.title_start(w, "0", hk)
	w.set_ds16(0x50AD8E, 7)
	w.set_ds16(0x50AD92, 7)
	w.script_no = 6
	Debrief.set_head_byte(w, 5, 6)
	for i in 6:                        # steps 1-6 cleared (DS:0x50AD42..): the debrief's 50% rule
		w.set_ds8(0x50AD42 + i, 1)
	b = battle(w)
	await process_frame
	clear(b)
	bw = b.w
	var nxt: Array = Debrief.next_mission(bw)
	var handed: bool = res == [1, 0] and b.debrief_result == 0x80 and nxt == [0, 2] and bw.script_no == 12 \
		and Debrief.campaign_mode(bw) == 1 and bw.ds16(0x50AD8E) == 1
	print("PD2 step 7 cleared: debrief 0x%X, next %s, mission %d, mode %d, step %d" % [b.debrief_result,
		str(nxt), bw.script_no, Debrief.campaign_mode(bw), bw.ds16(0x50AD8E)])
	b.sortie_window = true             # the next mission's sortie opens and waits
	b.plan_window = false
	b.auto_react = false
	var b2: Node = await next_battle(b, nxt)
	var saved := false
	if b2 != null:
		var w2: Pd2World = b2.w
		var wr = SF.Writer.new()
		wr.pick = SLOT
		var s: int = Title.sortie_save(w2, wr)
		var data: Variant = SF.read("PD2REC%02d.BIN" % SLOT)
		saved = s == SLOT + 1 and data != null and wr.notes == [0x519EB0] and SF.read("MEMBER%02d.DAT" % SLOT) != null
		print("DASH mission %d's sortie: saved %s (slot %d): %s" % [b2.script_no, str(saved), s, SF.slot_line(SLOT, 0x519EE8)])
		b2.queue_free()
	ok = ok and handed and saved
	# 3. the continue of that save: DASH mission 12 in the campaign, then step 2 (mission 14)
	w = SF.title_world()
	hk = Answers.new()
	hk.gd = root.get_node("/root/GameData")
	hk.sf = SF
	hk.slots = [SLOT]
	res = Title.title_start(w, "1", hk)
	var cont: bool = res == [2, 0] and w.campaign == 0 and w.script_no == 12 and Debrief.campaign_mode(w) == 1 \
		and Debrief.chunk(w) == 2 and w.ds16(0x50AD8E) == 1 and w.ds8(0x50AD94) == SLOT + 1
	print("continue: %s, flag %d, mission %d, mode %d, chunk %d, step %d" % [str(res), w.campaign, w.script_no,
		Debrief.campaign_mode(w), Debrief.chunk(w), w.ds16(0x50AD8E)])
	b = battle(w)
	await process_frame
	clear(b)
	bw = b.w
	nxt = Debrief.next_mission(bw)
	var chained: bool = b.debrief_result == 0x80 and nxt == [0, 4] and bw.script_no == 14 and bw.ds16(0x50AD8E) == 2
	print("its battle cleared: debrief 0x%X, next %s, mission %d, step %d" % [b.debrief_result, str(nxt),
		bw.script_no, bw.ds16(0x50AD8E)])
	var b3: Node = await next_battle(b, nxt)
	var on: bool = b3 != null and b3.campaign == "dash" and b3.script_no == 14
	if b3 != null:
		print("next battle: %s chunk %d, mission %d, %d enemy units" % [b3.campaign, b3.mission_index + 1,
			b3.script_no, b3._count_side(3)])
		b3.queue_free()
	ok = ok and cont and chained and on
	# 4. the rescue mission on that save: nobody missing
	w = SF.title_world()
	hk = Answers.new()
	hk.gd = root.get_node("/root/GameData")
	hk.sf = SF
	hk.slots = [SLOT]
	res = Title.title_start(w, "3", hk)
	var rescue: bool = res == [0, 0] and hk.log.has(["box", 0x5175C8])
	print("rescue: %s, log %s" % [str(res), str(hk.log)])
	ok = ok and rescue
	for f in ["PD2REC%02d.BIN", "MEMBER%02d.DAT", "KEMURI%02d.DAT"]:
		DirAccess.remove_absolute(SF.DIR.path_join(f % SLOT))
	print("title flow: %s" % ("ok" if ok else "FAILED"))
	quit(0 if ok else 1)
