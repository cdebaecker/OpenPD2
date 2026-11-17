extends SceneTree
## The new campaign's start (the title's "start the campaign"): while the pilot choice waits
## (0x422050; the map built on a worker thread meanwhile), mouse moves and keys reach the
## battle before its world and camera exist; they must be ignored. Windowed:
##   godot --path engine/godot -s tests/pick_input.gd

func _win(b):
	for _n in 400:
		await process_frame
		var h = b.react_panel
		if h != null and is_instance_valid(h) and not h.is_queued_for_deletion():
			var ws: Array = h.get_children().filter(func(n): return n.has_method("answer"))
			if not ws.is_empty():
				return ws[-1]
	return null


func _init() -> void:
	await process_frame
	var b = load("res://ui/battle.tscn").instantiate()
	b.campaign = "pd2"
	b.mission_index = 0
	root.add_child(b)
	var gw = await _win(b)
	if gw == null:
		print("no pilot choice")
		quit(1)
		return
	var early: bool = b.cam == null or b.w == null
	# the player moves the mouse over the map's side and presses a key while choosing
	for p in [Vector2(5, 5), Vector2(100, 200), Vector2(400, 390)]:
		var mm := InputEventMouseMotion.new()
		mm.position = p
		mm.global_position = p
		b._unhandled_input(mm)
	var k := InputEventKey.new()
	k.keycode = KEY_E
	k.pressed = true
	b._unhandled_input(k)
	print("pilot choice open, battle not built yet: %s; input taken without error" % early)
	quit(0)
