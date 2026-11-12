extends SceneTree
## The sortie's back, load and abort (Campaign.sortie_back / sortie_system, 0x45ED60's
## regions 0x46 and 0x45) in play, on DASH's mission 12 from its SAVEDATA.ORG:
## 1. back: the sortie's result 2 makes the mission start's loop (0x416CF0) run the
##    briefing and the plan again, then the sortie opens again (a second round).
## 2. SAVE (slot 36: PD2REC35.BIN, KEMURI35.DAT, MEMBER35.DAT), a pilot joined, then LOAD of
##    that slot: the screen ends with 2, the loop goes round with the saved groups.
## 3. LOAD of a save made in a battle: 0x498070's note, the screen goes on.
## 4. ABORT ("abort the operation?" yes): the result 1, the loop's code 0x81, the title.
## The files are removed after.

const SLOT := 35
const BATTLE_SLOT := 34


var SF


func _init() -> void:
	await process_frame
	SF = load("res://ui/save_files.gd")
	var ok := true
	var b = load("res://ui/battle.tscn").instantiate()
	b.campaign = "dash"
	b.mission_index = 1
	b.auto_react = false
	b.sortie_window = true
	b.plan_window = false
	root.add_child(b)
	await process_frame
	var w: Pd2World = b.w
	var first: bool = b.sortie_panel != null and b.pre_battle_rounds == 1
	# 1. back
	b._sortie_back_press()
	await process_frame
	var back: bool = b.sortie_panel != null and b.pre_battle_rounds == 2 and w.ds8(0x50AD94) == 1 \
		and not b.mission_over and b.squad.is_empty()
	print("back: sortie open again %s, rounds %d" % [str(b.sortie_panel != null), b.pre_battle_rounds])
	ok = ok and first and back
	# 2. save, change, load
	b._sortie_system_run(1, 1, SLOT)
	var saved: bool = SF.read("PD2REC%02d.BIN" % SLOT) != null and SF.read("MEMBER%02d.DAT" % SLOT) != null \
		and SF.read("KEMURI%02d.DAT" % SLOT) != null and b.sortie_text != ""
	var groups := w.groups.duplicate()
	var g: int = b.sortie_sel
	var joined := -1
	if w.crew_pool_n > 0:
		joined = Campaign.group_join(w, g, w.ds[2])
	var changed: bool = w.groups != groups
	b._sortie_system_run(2, 1, SLOT)
	await process_frame
	var nb = b
	for n in root.get_children():
		if is_instance_valid(n) and n.get_script() == b.get_script() and not n.is_queued_for_deletion():
			nb = n
	var lw: Pd2World = nb.w
	var loaded: bool = lw.groups == groups and nb.sortie_panel != null and nb.pre_battle_rounds >= 3 \
		and lw.ds8(0x50AD94) == 1
	print("save %s, a pilot joined (code %d, changed %s), load: groups back %s, rounds %d" % [str(saved), joined,
		str(changed), str(lw.groups == groups), nb.pre_battle_rounds])
	ok = ok and saved and loaded
	# 3. a battle's save cannot be loaded in the sortie
	var bimg := Debrief.save_image(lw)
	bimg[2] = 1                          # DS:0x50663A = 1 in its head: made in a battle
	var bw := lw.duplicate_world()
	Debrief.load_image(bw, bimg)
	SF.write("PD2REC%02d.BIN" % BATTLE_SLOT, Title.write_save(bw))
	SF.write("MEMBER%02d.DAT" % BATTLE_SLOT, Title.member_write(bw))
	nb.sortie_loading = BATTLE_SLOT
	nb._sortie_draw()
	var refused: bool = nb.sortie_loading == 0x29 and nb.sortie_text == SF.exe(0x519F0C) and nb.sortie_panel != null
	nb.sortie_loading = -1
	print("a battle's save in the sortie: refused %s (%s)" % [str(refused), nb.sortie_text])
	ok = ok and refused
	# 4. abort the operation
	var gone := false
	nb._sortie_system_run(0, 1)
	gone = nb.mission_over and nb.sortie_panel == null
	print("abort: left for the title %s" % str(gone))
	ok = ok and gone
	await process_frame
	for s in [SLOT, BATTLE_SLOT]:
		for f in ["PD2REC%02d.BIN", "MEMBER%02d.DAT", "KEMURI%02d.DAT"]:
			DirAccess.remove_absolute(SF.DIR.path_join(f % s))
	print("sortie back flow: %s" % ("ok" if ok else "FAILED"))
	quit(0 if ok else 1)
