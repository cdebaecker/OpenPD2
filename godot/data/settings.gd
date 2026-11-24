extends Node
## The port's own options (not the game's: the title's OPTIONS, notes/engine-choices.md "The
## Options menu"), kept in user://settings.cfg and applied at start:
## - language: "auto" (the system's), "en", "fr", "ja";
## - window: "x1" / "x2" / "x3" (the 640 x 480 client at that scale) or "full"; the window's
##   size and place are remembered when it is closed (geometry);
## - pace: 0 the game's, 1 fast, 2 fastest (the steps' and animations' waits, the missiles'
##   flight);
## - auto_text: a click wait goes on by itself after 3 s;
## - music / sfx: volumes 0-10;
## - music_source: "ask" (the title's list, as the game), "cd", "midi";
## - skip_logos: the logos not played at start;

var path := "user://settings.cfg"   # (tests point it elsewhere)
const LANGUAGES := ["auto", "en", "fr", "ja"]
const WINDOWS := ["x1", "x2", "x3", "full"]
const SOURCES := ["ask", "cd", "midi"]
const STEP_MS := [0x21, 12, 0]          # a unit's hex step (the game: 0x21 ms)
const ANIM_SCALE := [1.0, 0.5, 0.25]    # the anime's frame waits
const FLIGHT_STEPS := [2, 5, 12]        # the missiles' flight steps a frame
const AUTO_TEXT_SECS := 3.0

var language := "auto"
var window := "x2"
var pace := 0
var auto_text := false
var music := 10
var sfx := 10
var music_source := "ask"
var skip_logos := false
var geometry := Rect2i()               # the window's last place and size (x1-x3 only)

var _headless := false


func _ready() -> void:
	_headless = DisplayServer.get_name() == "headless"
	load_file()
	apply_all()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		remember_window()


func load_file() -> void:
	var c := ConfigFile.new()
	if c.load(path) != OK:
		return
	language = _pick(str(c.get_value("options", "language", language)), LANGUAGES, language)
	window = _pick(str(c.get_value("options", "window", window)), WINDOWS, window)
	pace = clampi(int(c.get_value("options", "pace", pace)), 0, 2)
	auto_text = bool(c.get_value("options", "auto_text", auto_text))
	music = clampi(int(c.get_value("options", "music", music)), 0, 10)
	sfx = clampi(int(c.get_value("options", "sfx", sfx)), 0, 10)
	music_source = _pick(str(c.get_value("options", "music_source", music_source)), SOURCES, music_source)
	skip_logos = bool(c.get_value("options", "skip_logos", skip_logos))
	var g: Variant = c.get_value("window", "geometry", null)
	if g is Rect2i:
		geometry = g


func save_file() -> void:
	var c := ConfigFile.new()
	c.set_value("options", "language", language)
	c.set_value("options", "window", window)
	c.set_value("options", "pace", pace)
	c.set_value("options", "auto_text", auto_text)
	c.set_value("options", "music", music)
	c.set_value("options", "sfx", sfx)
	c.set_value("options", "music_source", music_source)
	c.set_value("options", "skip_logos", skip_logos)
	if geometry.size != Vector2i.ZERO:
		c.set_value("window", "geometry", geometry)
	c.save(path)


static func _pick(v: String, allowed: Array, dflt: String) -> String:
	return v if v in allowed else dflt


func apply_all() -> void:
	apply_language(true)
	apply_audio()
	apply_window(true)
	# (the title's script loaded at run time: naming its class here would load GameWindow,
	# which reads this autoload, while it is being made)
	var tv: GDScript = load("res://ui/title_view.gd")
	if music_source != "ask":
		GameAudio.mode_asked = true
		GameAudio.mode = 0 if music_source == "cd" and GameAudio.cd_present() else 1
	if skip_logos:
		tv.logos_done = true


func apply_language(start := false) -> void:
	## (at start "auto" leaves GameData's own choice, the system's: tests set theirs)
	if start and language == "auto":
		return
	var l := OS.get_locale_language() if language == "auto" else language
	if GameData.language != l:
		GameData.language = l
		GameData.reload()


func apply_audio() -> void:
	GameAudio.set_volumes(music / 10.0, sfx / 10.0)


func apply_window(start := false) -> void:
	## x1-x3: the 640 x 480 client at that scale, centred (at start, the remembered place and
	## size when there is one); full: the screen
	if _headless:
		return
	var win := get_tree().root
	if window == "full":
		win.mode = Window.MODE_FULLSCREEN
		return
	if win.mode == Window.MODE_FULLSCREEN or win.mode == Window.MODE_EXCLUSIVE_FULLSCREEN:
		win.mode = Window.MODE_WINDOWED
	if start and geometry.size != Vector2i.ZERO and _fits(geometry):
		win.size = geometry.size
		win.position = geometry.position
		return
	var k := WINDOWS.find(window) + 1
	var sz := Vector2i(640, 480) * k
	var scr := DisplayServer.screen_get_usable_rect(win.current_screen)
	win.size = sz
	win.position = scr.position + (scr.size - sz) / 2


func _fits(r: Rect2i) -> bool:
	for s in DisplayServer.get_screen_count():
		if DisplayServer.screen_get_usable_rect(s).grow(32).encloses(r):
			return true
	return false


func remember_window() -> void:
	## (the window closed, or the title's QUIT)
	if _headless:
		return
	var win := get_tree().root
	if win.mode == Window.MODE_WINDOWED:
		geometry = Rect2i(win.position, win.size)
	save_file()


# --- the pace ------------------------------------------------------------------------

func step_secs() -> float:
	return STEP_MS[pace] / 1000.0


func anim_secs(ms: int) -> float:
	return ms * ANIM_SCALE[pace] / 1000.0


func flight_steps() -> int:
	return FLIGHT_STEPS[pace]
