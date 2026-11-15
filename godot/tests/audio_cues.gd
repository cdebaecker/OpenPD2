extends SceneTree
## The sounds' and the music's cues per scene (RULES.md 5.26), from GameAudio's log (so it
## runs headless): the title (title2.wav waited for, music_start(5)), the mission start
## (0x416CF0: 9), the battle (0x436530: the mission's tune, PD2 chunk 1: 3), the debrief
## (PD2 step 1 cleared: 5 after the results), the animations' 0x40AFF0 at their waits, and
## the MIDI window's rules (the same tune goes on; 1-13 only; CD-DA or MIDI files).
## godot --headless --path engine/godot -s tests/audio_cues.gd

var fails := []
var GameAudio: Node


func check(what: String, ok: bool, got: Variant = null) -> void:
	print("%s %s%s" % ["ok  " if ok else "FAIL", what, "" if got == null else "  (%s)" % str(got)])
	if not ok:
		fails.append(what)


func tunes() -> Array:
	return GameAudio.cues("music").map(func(c): return c[1])


func _init() -> void:
	await process_frame
	GameAudio = root.get_node("GameAudio")
	if not root.get_node("GameData").available() or GameAudio.meta.is_empty():
		print("audio cues: no import (run the importer)")
		quit(1)
		return
	check("audio.json: 13 tunes, the mission table", GameAudio.meta.tunes.size() == 13 and GameAudio.mission_tune(1) == 3)
	# --- the title
	GameAudio.log.clear()
	GameAudio.mode_asked = false
	GameAudio.title_shown = false
	var boot = load("res://ui/boot.tscn").instantiate()
	root.add_child(boot)
	for i in 3:
		await process_frame
	var log0: Array = GameAudio.log.duplicate()
	check("title: title2.wav (sync) then music 5", log0 == [["wave", "title2", true], ["music", 5]], log0)
	check("title: the CD there, CD-DA (mode 0)", GameAudio.mode == (0 if GameAudio.cd_present() else 1), GameAudio.mode)
	boot.queue_free()
	await process_frame
	var boot2 = load("res://ui/boot.tscn").instantiate()
	root.add_child(boot2)
	await process_frame
	check("title again: music 5 only", GameAudio.log.slice(log0.size()) == [["music", 5]], GameAudio.log.slice(log0.size()))
	boot2.queue_free()
	await process_frame
	# --- the mission start and the battle
	GameAudio.log.clear()
	var b = load("res://ui/battle.tscn").instantiate()
	b.campaign = "pd2"
	b.mission_index = 0
	b.auto_react = true
	root.add_child(b)
	for i in 3:
		await process_frame
	check("mission start then battle: 9, 3", tunes() == [9, 3], tunes())
	check("battle: pd2_06gm plays", GameAudio.playing == "pd2_06gm.mid", GameAudio.playing)
	# --- the debrief (withdraw: the scenario hook's 0x80, PD2 step 1 cleared)
	b._cmd_withdraw()
	await process_frame
	check("debrief, PD2 step 1 cleared: 5 after the results", tunes() == [9, 3, 5] and b.debrief_result == 0x80, tunes())
	# --- the animations' sounds (0x40AFF0), before their waits
	var want := {0x41EFF0: [0, 6], 0x41FD60: [0, 12], 0x420CD0: [1, 1], 0x417410: [1, 1], 0x41A5B0: [2, 1],
		0x419870: [3, 3], 0x41E850: [3, 3], 0x419BE0: [3, 1], 0x4200D0: [4, 6], 0x4209D0: [4, 12]}
	for p in want:
		GameAudio.log.clear()
		var spec: Dictionary = load("res://ui/anime_view.gd").PLAYERS[p]   # (loaded at run time: after the autoloads)
		for i in int(spec.frames):
			await b._anim_step(p, 10, 10, i, 0, 0, [])
		var se: Array = GameAudio.cues("se")
		check("anim 0x%X: %d x se %d" % [p, want[p][1], want[p][0]],
			se.size() == want[p][1] and se.all(func(c): return c[1] == want[p][0]), se.size())
	# --- the MIDI window
	GameAudio.log.clear()
	GameAudio.music_stop()
	GameAudio.music_start(5)
	var s0: AudioStream = GameAudio.get("_music").stream
	GameAudio.music_start(5)
	check("the same tune while it plays: not restarted", GameAudio.get("_music").stream == s0 and GameAudio.playing == "pd2_04gm.mid")
	check("music_start(0) and (14): Select Error", GameAudio.music_start(0) == 0x10000 and GameAudio.music_start(14) == 0x10000)
	GameAudio.music_stop()
	GameAudio.mode = 1
	GameAudio.music_start(9)
	var midi: bool = GameAudio.meta.get("midi", {}).has("pd2_07gm.mid")
	check("MIDI mode: pd2_07gm's render (or nothing without one)", GameAudio.playing == ("pd2_07gm.mid" if midi else ""), GameAudio.playing)
	GameAudio.music_stop()
	GameAudio.mode = 0
	GameAudio.music_start(13)
	check("CD-DA mode: Pd2_12gm and Pd2_14gm share track 6",
		int(GameAudio.meta.cd_track["pd2_12gm.mid"]) == 6 and int(GameAudio.meta.cd_track["pd2_14gm.mid"]) == 6)
	GameAudio.music_stop()
	print("audio cues: %s" % ("ok" if fails.is_empty() else "FAILED " + str(fails)))
	quit(0 if fails.is_empty() else 1)
