extends Node
## The game's sounds and music, as Pd2.exe plays them (RULES.md 5.26), from what the importer
## wrote to user://import/audio (audio.json: Pd2.exe's tables; the WAVs; the CD-DA tracks;
## the MIDI tunes rendered at import).
## - Waves (PlaySound through 0x40D440: one sound at a time, a new one stops the last):
##   se(n) is 0x40AFF0(n), slot n + 1, PD2_SE<n + 1>.WAV, played asynchronously;
##   wave("title1" / "title2", sync) the title's slot 0 (0x40D440(0, 1) / (0, 2): 2 waits
##   for its end, the caller awaits the seconds returned).
## - Music (the MIDI window 0x40A1B0, sent 0xC03C by music_start 0x40AFA0 and 0xC03D by
##   music_stop 0x40AF80): music_start(n), n 1-13 (else Pd2.exe's "Select Error" and no
##   change), the file of DS:0x5127EC + 4n; the same name while it plays changes nothing;
##   mode 0 plays the CD-DA track of DS:0x512690 (by the name's two digits) and mode 1 the
##   MIDI file; at its end (MM_MCINOTIFY, successful) it starts again from the beginning.
##   mode is DS:0x50CE71: 1 (MIDI) when the CD is not there; with the CD the title asks
##   (list DS:0x518918: CD-DA 0, MIDI 1). Pd2.exe sets no volume and has no option that
##   turns the sound or the music off (DS:0x554902 is always 7).
## log: every cue in order, for the tests (they run headless, with no audio heard).

const DIR := "user://import/audio"

var meta := {}
var mode := 1                   # DS:0x50CE71: 0 the CD's tracks, 1 the MIDI files
var mode_asked := false         # the title has asked (once a run, as game_mode_loop does)
var title_shown := false        # DS:0x524094: title2.wav has played (the first title only)
var log: Array = []             # [["music", n] / ["stop"] / ["se", n] / ["wave", name, sync], ...]
var playing := ""               # the MIDI window's name (+9) while it plays (+4 = 1)
var _music: AudioStreamPlayer
var _wave: AudioStreamPlayer
var _cache := {}


func _ready() -> void:
	_music = AudioStreamPlayer.new()
	_music.name = "Music"
	add_child(_music)
	_wave = AudioStreamPlayer.new()
	_wave.name = "Wave"
	add_child(_wave)
	reload()


func reload() -> void:
	meta = {}
	var p := DIR + "/audio.json"
	if FileAccess.file_exists(p):
		var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
		if d is Dictionary:
			meta = d
	mode = 1
	_cache.clear()


func set_volumes(music: float, sfx: float) -> void:
	## the Options' volumes (0-1; the port's own: the game has none)
	_music.volume_db = linear_to_db(music) if music > 0.0 else -80.0
	_wave.volume_db = linear_to_db(sfx) if sfx > 0.0 else -80.0


func cd_present() -> bool:
	## the MIDI window's WM_CREATE finds the CD ("PD2" volume): the CD-DA tracks were imported
	return not meta.get("cd", {}).is_empty()


func choices() -> Array:
	## the title's list DS:0x518918 (asked when the CD is there): CD-DA 0, MIDI 1
	return [GameData.exe_text("dash", 0x518920).strip_edges(), GameData.exe_text("dash", 0x51892C).strip_edges()]


func _stream(rel: String) -> AudioStream:
	if _cache.has(rel):
		return _cache[rel]
	var p := DIR + "/" + rel
	var s: AudioStream = null
	if FileAccess.file_exists(p):
		if rel.ends_with(".ogg"):
			s = AudioStreamOggVorbis.load_from_file(p)
		else:
			s = AudioStreamWAV.load_from_file(p, {})
	_cache[rel] = s
	return s


# --- the waves (0x40D440) ------------------------------------------------------------

func se(n: int) -> void:
	## 0x40AFF0(n): slot n + 1 (PD2_SE1-5.WAV, loaded by 0x40AE40), asynchronously
	log.append(["se", n])
	_play_wave("pd2_se%d" % (n + 1))


func wave(name: String, sync := false) -> float:
	## the title's slot 0 (title1.wav / title2.wav); sync (0x40D440(0, 2): SND_SYNC) returns
	## the seconds the game waits for its end, else 0
	log.append(["wave", name, sync])
	_play_wave(name)
	return float(meta.get("se", {}).get(name, {}).get("seconds", 0.0)) if sync else 0.0


func _play_wave(name: String) -> void:
	var e: Dictionary = meta.get("se", {}).get(name, {})
	var s := _stream(str(e.get("file", ""))) if not e.is_empty() else null
	if s == null:
		return
	_wave.stream = s                # (PlaySound: the sound playing stops)
	_wave.play()


# --- the music (the MIDI window 0x40A1B0) ---------------------------------------------

func music_start(n: int) -> int:
	## 0x40AFA0: 0x10000 (after its "Select Error  music_start()" box) out of 1-13, else 0x20000
	log.append(["music", n])
	if n < 1 or n > 13:
		push_warning("Select Error  music_start() %d" % n)
		return 0x10000
	var name := str(meta.get("tunes", {}).get(str(n), ""))
	if name == "":
		return 0x20000
	if playing == name:                 # 0xC03C: the same name while it plays
		return 0x20000
	_music.stop()
	playing = ""
	var rel := ""
	if mode == 0:
		var tr := int(meta.get("cd_track", {}).get(name, 0))
		rel = str(meta.get("cd", {}).get(str(tr), {}).get("file", ""))
	else:
		rel = str(meta.get("midi", {}).get(name, {}).get("file", ""))
	var s := _stream(rel) if rel != "" else null
	if s == null:                       # (no CD, no MIDI render: nothing plays, +4 stays 0)
		return 0x20000
	playing = name
	if s is AudioStreamOggVorbis:
		(s as AudioStreamOggVorbis).loop = true          # MM_MCINOTIFY: played again from 0
	elif s is AudioStreamWAV:
		var wv := s as AudioStreamWAV
		wv.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wv.loop_begin = 0
		wv.loop_end = int(wv.get_length() * wv.mix_rate)
	_music.stream = s
	_music.play()
	return 0x20000


func music_stop() -> int:
	## 0x40AF80 (0xC03D)
	log.append(["stop"])
	_music.stop()
	playing = ""
	return 0x20000


func mission_tune(chunk1: int) -> int:
	## 0x436530 / 0x4847C0: music_start's n, the dword at DS:0x50DDC5 + 4 x DS:0x50663D
	## (the chunk + 1); -1 past the table (music_start's error)
	var t: Array = meta.get("mission_tune", [])
	return int(t[chunk1 - 1]) if chunk1 >= 1 and chunk1 <= t.size() else -1


func mission_music(chunk1: int) -> int:
	return music_start(mission_tune(chunk1))


func cues(kind := "") -> Array:
	## the log's cues of a kind ("music", "se", "wave", "stop"), or all
	return log.filter(func(c): return kind == "" or c[0] == kind)
