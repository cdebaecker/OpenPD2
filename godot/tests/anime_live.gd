extends SceneTree
## The animations' waits in a windowed run (not headless): a shot on a worker thread with
## the animations on waits for the main thread's frames (battle.anim_frame) and ends; a
## click during a frame's wait skips. godot --path engine/godot -s tests/anime_live.gd

var done := false
var frames := 0


func _init() -> void:
	await process_frame
	var b = load("res://ui/battle.tscn").instantiate()
	b.campaign = "dash"
	b.mission_index = 1
	b.sortie_window = false
	root.add_child(b)
	for i in 5:
		await process_frame
	if b._headless():
		print("anime live: headless, the waits are off (run it windowed)")
		quit(0)
		return
	var w: Pd2World = b.w
	var ok := true
	b.options = b.options & ~0x10
	b.hooks.anims = true
	# a kill's animation, played whole through the hooks on a worker thread
	var t0 := Time.get_ticks_msec()
	var th := Thread.new()
	var u: int = b.squad[0]
	var p: Vector2i = w.pos(u)
	th.start(func():
		for i in 8:
			if b.hooks.anim_frame(0x420CD0, p.x, p.y, i, 0, 0):
				break
		done = true)
	while not done and Time.get_ticks_msec() - t0 < 5000:
		await process_frame
	th.wait_to_finish()
	var ms := Time.get_ticks_msec() - t0
	ok = ok and done and ms >= 8 * 50
	print("kill animation: %d ms (8 frames of 50)" % ms)
	# a click during the third wait skips
	done = false
	var skipped_at := [-1]
	th = Thread.new()
	th.start(func():
		for i in 14:
			if b.hooks.anim_frame(0x417410, p.x, p.y, i, 0, 0):
				skipped_at[0] = i
				break
		done = true)
	var t1 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t1 < 80:
		await process_frame
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	b._input(ev)
	while not done and Time.get_ticks_msec() - t1 < 5000:
		await process_frame
	th.wait_to_finish()
	ok = ok and done and skipped_at[0] >= 1 and skipped_at[0] < 13 and b.anime_view._tex == null
	print("anime_bomb skipped at frame %d" % skipped_at[0])
	print("anime live: %s" % ok)
	quit(0 if ok else 1)
