extends SceneTree
## Both campaigns end to end: PD2's new game (chunk 0), then each mission in turn as
## game_mode_loop chains them (the debrief's save, Debrief.next_mission), through the
## hand-over into DASH and on to the ending. Each battle runs as the automatic runs do
## (auto_react: the briefing, plan and sortie answered, the pilot choice "fill at random"),
## plays TURNS turns (the player only ends its turn; the computer's phase, the strikes and
## the mission's turn scripts run), then the cleared end code 0x80 is set as the missions'
## scripts set it and mission_loop ends the mission at its check.
## The squad: auto_form fills each formable group from the pool's first rows, then starts.
## Each line shows the sortie check's result: where it is not "start" the game would keep
## the player on the sortie screen, but the automatic run goes on, and such a mission
## usually fails at once (end code 0x82).
## Fails on: a rules fault in the battle's log, a mission that doesn't end, a chain longer
## than MAX_MISSIONS, or no campaign end (debrief 0x81 at step 10, or no next mission).
##   godot --headless --path engine/godot -s tests/campaign_run.gd [-- turns]

const MAX_MISSIONS := 60
var TURNS := 2


func _battle() -> Node:
	return current_scene if current_scene and current_scene.has_method("_next_mission") else null


func _settle(b) -> void:
	for i in 600:
		await process_frame
		if not b.busy:
			return


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		TURNS = int(args[0])
	await process_frame
	var b = load("res://ui/battle.tscn").instantiate()
	b.campaign = "pd2"
	b.mission_index = 0
	b.auto_react = true
	b.auto_form = true
	root.add_child(b)
	current_scene = b
	var ok := true
	var path := []
	var ended := false
	var t0 := Time.get_ticks_msec()
	for n in MAX_MISSIONS:
		for i in 5:
			await process_frame
		await _settle(b)
		var w: Pd2World = b.w
		var label := "%s chunk %d (script %d, step %d)" % [b.campaign, b.mission_index + 1, b.script_no, w.ds16(0x50AD8E)]
		var squad: int = b.squad.size()
		var stand_in: bool = b.sandbox
		var check := "none"
		for e in b.auto_sortie_log:
			if e[0] == "check":
				check = str(e.slice(1))
		var enemies: int = b._count_side(3)
		var turns := 0
		for t in TURNS:
			if b.mission_over:
				break
			b._end_turn()
			await _settle(b)
			turns += 1
		var by_script: bool = b.mission_over
		if not b.mission_over:
			w.set_ds8(0x50ADF2, 0x80)
			b._after_command()
			await _settle(b)
		var log_text: String = b.log_box.get_parsed_text() if b.log_box else ""
		var faults := log_text.count("rules fault")
		var line := ("%2d. %s: %d DoLLS" + (" (STAND-IN)" if stand_in else "") + ", %d enemy units, %d turn(s)%s; over %s, debrief 0x%X, then step %d") % [
			n + 1, label, squad, enemies, turns, " (ended by its script)" if by_script else "", b.mission_over,
			b.debrief_result, w.ds16(0x50AD8E)]
		var codes := []
		for m in RegEx.create_from_string("0x[0-9A-F]+").search_all(log_text.substr(log_text.rfind(" (code "))) if log_text.rfind(" (code ") >= 0 else []:
			codes.append(m.get_string())
			break
		line += "; end code %s; sortie check %s" % [codes[0] if not codes.is_empty() else "?", check]
		if faults:
			line += "  [%d rules fault(s)]" % faults
			for l in log_text.split("\n"):
				if l.contains("rules fault"):
					print("      ", l)
		print(line)
		path.append(label)
		if not b.mission_over or faults:
			ok = false
			break
		if b.debrief_result == 0x81:
			# the debrief's end: the ending's or a game over's screens, then the title
			ended = w.ds16(0x50AD8E) == 10
			print("the campaign ends (debrief 0x81) at step %d" % w.ds16(0x50AD8E))
			break
		var nxt: Array = Debrief.next_mission(w)
		if nxt.is_empty():
			ended = w.ds16(0x50AD92) > 20 or Debrief.campaign_mode(w) != 1
			print("the chain ends: campaign mode %d, DS:0x50AD92 %d, step %d" % [Debrief.campaign_mode(w),
				w.ds16(0x50AD92), w.ds16(0x50AD8E)])
			break
		b._next_mission(nxt)
		await process_frame
		await process_frame
		var nb = _battle()
		if nb == null or nb == b:
			print("no next battle")
			ok = false
			break
		b = nb
	print("%d missions in %.1f s" % [path.size(), (Time.get_ticks_msec() - t0) / 1000.0])
	ok = ok and ended
	print("campaign run: %s" % ("ok" if ok else "FAILED"))
	quit(0 if ok else 1)
