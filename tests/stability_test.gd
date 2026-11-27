extends SceneTree

## Structural stability: support rules, material caps and the collapse policy.
##
##   godot --headless --path . --script res://tests/stability_test.gd
##
## The fixture library names items so BlockMaterials resolves real materials:
## Auto_bedrock is anchored and Auto_concrete_* / Auto_planks_* get reach 8 / 4.

const ANCHOR := 0
const CONCRETE := 1
const PLANKS := 2
const GRASS := 3

var _checks: int = 0
var _failures: int = 0
var _grid: NavGridMap


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("=== structural stability ===")

	_test_vertical_and_lateral()
	_test_terrain_support()
	_test_material_cap()
	_test_no_downward_support()
	_test_placement_collapse()
	_test_long_drag()
	_test_removal_cascade()
	await _test_falling_style()
	_test_debris_body()
	_test_debris_cap()
	_test_existing_unsupported_is_left_alone()
	_test_disabled()
	_test_authored_world_anchor()
	_test_overlay()
	_test_hud_readout()

	_finish()


# ---------------------------------------------------------------------------
# Support rules
# ---------------------------------------------------------------------------

func _test_vertical_and_lateral() -> void:
	_begin()

	_place(Vector3i(0, 0, 0), ANCHOR)
	for y in range(1, 11):
		_place(Vector3i(0, y, 0), CONCRETE)

	_expect("pillar: anchor is infinite", _grid.get_stability(Vector3i(0, 0, 0)) == 255)
	_expect("pillar: first block capped at reach", _grid.get_stability(Vector3i(0, 1, 0)) == 8)
	_expect(
		"pillar: vertical propagation loses nothing",
		_grid.get_stability(Vector3i(0, 10, 0)) == 8,
		str(_grid.get_stability(Vector3i(0, 10, 0)))
	)

	_place(Vector3i(1, 1, 0), CONCRETE)
	_place(Vector3i(2, 1, 0), CONCRETE)
	_place(Vector3i(3, 1, 0), CONCRETE)

	_expect("lateral: one step costs one", _grid.get_stability(Vector3i(1, 1, 0)) == 7)
	_expect("lateral: two steps cost two", _grid.get_stability(Vector3i(2, 1, 0)) == 6)
	_expect("lateral: three steps cost three", _grid.get_stability(Vector3i(3, 1, 0)) == 5)

	_grid.free()


func _test_terrain_support() -> void:
	_begin()

	# Natural ground is the weak link for sideways spans, not for the column.
	_place(Vector3i(110, 0, 0), ANCHOR)
	_place(Vector3i(110, 1, 0), GRASS)
	_place(Vector3i(110, 2, 0), CONCRETE)
	_place(Vector3i(111, 2, 0), CONCRETE)

	_expect(
		"terrain: grass itself only spans one block",
		_grid.get_stability(Vector3i(110, 1, 0)) == 1,
		str(_grid.get_stability(Vector3i(110, 1, 0)))
	)
	_expect(
		"terrain: concrete above grass keeps its own reach",
		_grid.get_stability(Vector3i(110, 2, 0)) == 8,
		str(_grid.get_stability(Vector3i(110, 2, 0)))
	)
	_expect(
		"terrain: lateral from that concrete is 7",
		_grid.get_stability(Vector3i(111, 2, 0)) == 7,
		str(_grid.get_stability(Vector3i(111, 2, 0)))
	)

	_grid.free()


func _test_material_cap() -> void:
	_begin()

	_place(Vector3i(20, 0, 0), ANCHOR)
	_place(Vector3i(20, 1, 0), CONCRETE)
	_place(Vector3i(21, 1, 0), PLANKS)
	_place(Vector3i(22, 1, 0), PLANKS)
	_place(Vector3i(23, 1, 0), PLANKS)
	_place(Vector3i(24, 1, 0), PLANKS)
	_place(Vector3i(25, 1, 0), PLANKS)

	_expect("cap: planks beside concrete 8 cap at 4", _grid.get_stability(Vector3i(21, 1, 0)) == 4)
	_expect("cap: planks decay to 3", _grid.get_stability(Vector3i(22, 1, 0)) == 3)
	_expect("cap: planks decay to 2", _grid.get_stability(Vector3i(23, 1, 0)) == 2)
	_expect("cap: planks decay to 1", _grid.get_stability(Vector3i(24, 1, 0)) == 1)
	_expect("cap: planks decay to unsupported", _grid.get_stability(Vector3i(25, 1, 0)) == 0)

	_grid.free()


func _test_no_downward_support() -> void:
	_begin()

	_place(Vector3i(30, 5, 0), ANCHOR)
	_place(Vector3i(30, 4, 0), CONCRETE)

	_expect(
		"downward: a block hanging under an anchor is unsupported",
		_grid.get_stability(Vector3i(30, 4, 0)) == 0,
		str(_grid.get_stability(Vector3i(30, 4, 0)))
	)
	_expect("empty cell reports -1", _grid.get_stability(Vector3i(30, 8, 0)) == -1)

	_grid.free()


# ---------------------------------------------------------------------------
# Collapse policy
# ---------------------------------------------------------------------------

func _test_placement_collapse() -> void:
	_begin()
	_grid.collapse_enabled = true
	_grid.collapse_style = NavGridMap.COLLAPSE_REMOVE

	_place(Vector3i(40, 5, 0), CONCRETE)
	_expect(
		"collapse: an unsupported placement falls immediately",
		not _grid.has_block(Vector3i(40, 5, 0))
	)

	_place(Vector3i(41, 0, 0), ANCHOR)
	_place(Vector3i(41, 1, 0), CONCRETE)
	_expect(
		"collapse: a supported placement stays",
		_grid.has_block(Vector3i(41, 1, 0))
	)

	_grid.free()


func _test_removal_cascade() -> void:
	_begin()
	_grid.collapse_enabled = true
	_grid.collapse_style = NavGridMap.COLLAPSE_REMOVE

	_place(Vector3i(50, 0, 0), ANCHOR)
	_place(Vector3i(50, 1, 0), CONCRETE)
	_place(Vector3i(51, 1, 0), CONCRETE)
	_place(Vector3i(52, 1, 0), CONCRETE)
	_place(Vector3i(53, 1, 0), CONCRETE)

	_expect("cascade: cantilever starts stable", _grid.has_block(Vector3i(53, 1, 0)))

	# Removing the base of the cantilever unsupports the whole arm.
	var collapse_events: Array = []
	_grid.structure_collapsed.connect(
		func(removed: Array[Vector3i], style: int) -> void:
			collapse_events.append({"cells": removed, "style": style})
	)
	_grid.remove_block(Vector3i(50, 1, 0))

	_expect("cascade: first block falls", not _grid.has_block(Vector3i(51, 1, 0)))
	_expect("cascade: second block falls", not _grid.has_block(Vector3i(52, 1, 0)))
	_expect("cascade: third block falls", not _grid.has_block(Vector3i(53, 1, 0)))
	_expect(
		"cascade: the anchor is untouched",
		_grid.has_block(Vector3i(50, 0, 0))
	)
	_expect(
		"signal: one collapse event per edit",
		collapse_events.size() == 1,
		str(collapse_events.size())
	)
	if not collapse_events.is_empty():
		_expect(
			"signal: reports every removed cell",
			(collapse_events[0]["cells"] as Array).size() == 3,
			str((collapse_events[0]["cells"] as Array).size())
		)
		_expect(
			"signal: carries the collapse style",
			int(collapse_events[0]["style"]) == NavGridMap.COLLAPSE_REMOVE
		)

	_grid.free()


func _test_existing_unsupported_is_left_alone() -> void:
	_begin()

	# Build a hanging block while collapse is off. It is connected to the
	# structure but has always been unsupported (support never flows down).
	_grid.collapse_enabled = false
	_place(Vector3i(61, 0, 0), ANCHOR)
	_place(Vector3i(61, 1, 0), CONCRETE)
	_place(Vector3i(62, 1, 0), CONCRETE)
	_place(Vector3i(63, 1, 0), CONCRETE)
	_place(Vector3i(63, 0, 0), CONCRETE)   # hangs below the arm
	_expect(
		"safety: the hanging block starts unsupported",
		_grid.get_stability(Vector3i(63, 0, 0)) == 0,
		str(_grid.get_stability(Vector3i(63, 0, 0)))
	)

	_grid.collapse_enabled = true
	_grid.collapse_style = NavGridMap.COLLAPSE_REMOVE
	_grid.remove_block(Vector3i(61, 1, 0))

	_expect(
		"safety: an already-unsupported cell is not demolished by an edit",
		_grid.has_block(Vector3i(63, 0, 0))
	)

	_grid.free()


func _test_disabled() -> void:
	_begin()
	_grid.stability_enabled = false

	_place(Vector3i(70, 0, 0), ANCHOR)
	_place(Vector3i(70, 1, 0), CONCRETE)

	_expect("disabled: no field is computed", _grid.get_stability(Vector3i(70, 1, 0)) == -1)

	_grid.collapse_enabled = true
	_grid.collapse_style = NavGridMap.COLLAPSE_REMOVE
	_grid.remove_block(Vector3i(70, 0, 0))
	_expect(
		"disabled: no collapse runs",
		_grid.has_block(Vector3i(70, 1, 0))
	)

	_grid.free()


# ---------------------------------------------------------------------------
# Long batches
# ---------------------------------------------------------------------------

func _test_long_drag() -> void:
	_begin()
	_grid.collapse_enabled = true
	_grid.collapse_style = NavGridMap.COLLAPSE_REMOVE

	_place(Vector3i(0, 0, 0), ANCHOR)

	# One long drag, much wider than a single evaluation window.
	var cells: Array[Vector3i] = []
	for x in range(0, 24):
		cells.append(Vector3i(x, 1, 0))
	_grid.place_blocks(cells, CONCRETE, 0)

	# The anchor supports x=0 at reach 8; 7..1 decays to x=7. From x=8 on,
	# every placed cell is unsupported and must not be left floating.
	for x in range(0, 8):
		_expect(
			"long drag: supported cell %d stays" % x,
			_grid.has_block(Vector3i(x, 1, 0))
		)
	for x in range(8, 24):
		_expect(
			"long drag: floating cell %d is removed" % x,
			not _grid.has_block(Vector3i(x, 1, 0))
		)

	_grid.free()


# ---------------------------------------------------------------------------
# Falling collapse style
# ---------------------------------------------------------------------------

func _test_falling_style() -> void:
	_begin()
	_grid.collapse_enabled = true
	_grid.collapse_style = NavGridMap.COLLAPSE_FALL

	# Two-high pillar with an arm over a bedrock floor and a one-block gap.
	# Removing the bottom pillar cell leaves the upper cell and the arm
	# unsupported: they must drop into the gap and settle as blocks.
	_place(Vector3i(150, 0, 0), ANCHOR)
	_place(Vector3i(151, 0, 0), ANCHOR)
	_place(Vector3i(150, 1, 0), CONCRETE)
	_place(Vector3i(150, 2, 0), CONCRETE)
	_place(Vector3i(151, 2, 0), CONCRETE)

	_grid.remove_block(Vector3i(150, 1, 0))

	_expect(
		"fall: the pillar leaves immediately",
		not _grid.has_block(Vector3i(150, 2, 0))
	)
	_expect(
		"fall: the arm leaves immediately",
		not _grid.has_block(Vector3i(151, 2, 0))
	)

	await create_timer(0.7).timeout

	_expect(
		"fall: the pillar settles one block lower",
		_grid.has_block(Vector3i(150, 1, 0))
	)
	_expect(
		"fall: the arm settles one block lower",
		_grid.has_block(Vector3i(151, 1, 0))
	)
	_expect(
		"fall: nothing remains at the old height",
		not _grid.has_block(Vector3i(150, 2, 0))
	)

	_grid.free()


# ---------------------------------------------------------------------------
# Debris tier
# ---------------------------------------------------------------------------

func _test_debris_body() -> void:
	_begin()
	_clear_debris()
	_grid.collapse_enabled = true
	_grid.collapse_style = NavGridMap.COLLAPSE_RIGID
	# Chunk streaming hides the grid; debris must not inherit that visibility.
	_grid.visible = false

	_place(Vector3i(90, 0, 0), ANCHOR)
	_place(Vector3i(90, 1, 0), CONCRETE)
	_place(Vector3i(91, 1, 0), CONCRETE)
	_place(Vector3i(92, 1, 0), CONCRETE)

	_grid.remove_block(Vector3i(90, 1, 0))

	var bodies := get_nodes_in_group("stability_debris")
	_expect("debris: body spawned", bodies.size() > 0, str(bodies.size()))

	if not bodies.is_empty():
		var body := bodies[0] as RigidBody3D
		_expect("debris: is a rigid body", body != null)
		if body != null:
			_expect("debris: isolated on collision layer 0", body.collision_layer == 0)
			_expect("debris: collides with the world layer", body.collision_mask == 1)
			_expect("debris: owns a collision shape", body.get_child_count() > 0)
			var collision := body.get_child(0) as CollisionShape3D
			_expect(
				"debris: collider is convex (concave bodies fall through chunks)",
				collision != null and collision.shape is ConvexPolygonShape3D
			)
			_expect(
				"debris: visible even when the grid is hidden",
				body.is_visible_in_tree()
			)

	# The build path is the same loop through a placement: a floating placement
	# collapses immediately and must spawn debris without the freed-entry error.
	_grid.place_block(Vector3i(95, 6, 0), CONCRETE)
	_expect(
		"debris: placement collapse also spawns a body",
		get_nodes_in_group("stability_debris").size() >= 2,
		str(get_nodes_in_group("stability_debris").size())
	)
	_expect(
		"debris: the floating placement was removed",
		not _grid.has_block(Vector3i(95, 6, 0))
	)

	_grid.free()
	_clear_debris()


# ---------------------------------------------------------------------------
# Debris cap
# ---------------------------------------------------------------------------

func _test_debris_cap() -> void:
	_begin()
	_clear_debris()
	_grid.collapse_enabled = true
	_grid.collapse_style = NavGridMap.COLLAPSE_RIGID

	for index in 6:
		_spawn_test_debris(Vector3i(120 + index, 4, 0))

	var bodies := get_nodes_in_group("stability_debris")
	_expect("debris: cap reaches six bodies", bodies.size() == 6, str(bodies.size()))

	if not bodies.is_empty():
		# Force-free one body the way the 6 s timer does, leaving a dangling
		# reference in the tracking array. A typed assignment of that reference
		# used to raise "assign invalid previously freed instance".
		bodies[0].free()

	_spawn_test_debris(Vector3i(131, 4, 0))
	_spawn_test_debris(Vector3i(132, 4, 0))

	_expect(
		"debris: cap never exceeds six entries",
		_grid._debris_bodies.size() <= 6,
		str(_grid._debris_bodies.size())
	)

	var valid: int = 0
	for entry: Variant in _grid._debris_bodies:
		if is_instance_valid(entry):
			valid += 1
	_expect("debris: cap discards freed entries", valid <= 6, str(valid))

	_grid.free()
	_clear_debris()


# ---------------------------------------------------------------------------
# Authored (non-generated) worlds
# ---------------------------------------------------------------------------

func _test_authored_world_anchor() -> void:
	_begin()

	# The starter map is authored directly on the GridMap, with no bedrock in
	# the scene. initialize_navigation() seeds it and adds the anchor layer.
	_grid.set_cell_item(Vector3i(0, 0, 0), CONCRETE)
	_grid.set_cell_item(Vector3i(1, 0, 0), CONCRETE)
	_grid.initialize_navigation()

	_expect(
		"authored: bedrock is added under the platform",
		_grid.get_block_item(Vector3i(0, -1, 0)) == ANCHOR,
		str(_grid.get_block_item(Vector3i(0, -1, 0)))
	)
	_expect(
		"authored: platform cells are supported",
		_grid.get_stability(Vector3i(0, 0, 0)) > 0,
		str(_grid.get_stability(Vector3i(0, 0, 0)))
	)

	_grid.free()


# ---------------------------------------------------------------------------
# Debug overlay
# ---------------------------------------------------------------------------

func _test_overlay() -> void:
	_begin()
	# Chunk streaming hides the grid; the overlay must be parented outside it.
	_grid.visible = false

	_place(Vector3i(80, 0, 0), ANCHOR)
	for y in range(1, 4):
		_place(Vector3i(80, y, 0), CONCRETE)
	_place(Vector3i(81, 1, 0), CONCRETE)

	_grid.stability_debug = true
	_grid._update_stability_overlay(1.0)

	var host := _grid.get_parent()
	var overlay := host.get_node_or_null("StabilityOverlay") as MultiMeshInstance3D
	_expect("overlay: node exists", overlay != null)

	if overlay != null:
		_expect(
			"overlay: draws exposed cells",
			overlay.multimesh.instance_count > 0,
			str(overlay.multimesh.instance_count)
		)
		_expect("overlay: visible", overlay.visible)
		_expect(
			"overlay: visible even when the grid is hidden",
			overlay.is_visible_in_tree()
		)

		_grid.stability_debug = false
		_grid._update_stability_overlay(1.0)
		_expect("overlay: hides when the toggle is off", not overlay.visible)

	_grid.free()

	if overlay != null and is_instance_valid(overlay):
		overlay.free()


# ---------------------------------------------------------------------------
# Build HUD readout
# ---------------------------------------------------------------------------

func _test_hud_readout() -> void:
	var readout = load("res://scripts/world/stability_readout.gd").new()
	root.add_child(readout)

	readout.show_value(8, 8)
	_expect("hud: text shows current and maximum", readout.text == "8 / 8", readout.text)
	_expect("hud: label is visible", readout.visible)

	readout.show_value(255, 255)
	_expect("hud: anchored cell reads infinite", readout.text == "∞", readout.text)

	readout.show_value(0, 4)
	_expect(
		"hud: unsupported cells say so",
		readout.text == "0 / 4  UNSUPPORTED",
		readout.text
	)

	readout.hide_value()
	_expect("hud: hides on request", not readout.visible)

	readout.free()


# ---------------------------------------------------------------------------
# Fixture
# ---------------------------------------------------------------------------

func _begin() -> void:
	_grid = NavGridMap.new()
	_grid.sync_settings_on_ready = false
	_grid.name = "StabilityTestGrid"
	_grid.mesh_library = _make_library()
	_grid.cell_size = Vector3.ONE
	_grid.enable_greedy_meshing = false
	_grid.enable_flow_fields = false
	_grid.auto_generate_stairs = false
	_grid.wall_force_enabled = false
	_grid.stability_enabled = true
	_grid.collapse_enabled = false
	root.add_child(_grid)


func _place(cell: Vector3i, item: int) -> void:
	if not _grid.place_block(cell, item, 0):
		print("FAIL: could not place %s" % cell)


func _make_library() -> MeshLibrary:
	var library := MeshLibrary.new()
	var box := BoxMesh.new()
	var shape := BoxShape3D.new()
	box.size = Vector3.ONE
	shape.size = Vector3.ONE

	var names := {
		ANCHOR: "Auto_bedrock",
		CONCRETE: "Auto_concrete_test",
		PLANKS: "Auto_planks_test",
		GRASS: "Auto_grass_test",
	}

	for item: int in names:
		library.create_item(item)
		library.set_item_name(item, String(names[item]))
		library.set_item_mesh(item, box)
		library.set_item_shapes(item, [shape, Transform3D.IDENTITY])

	return library


func _spawn_test_debris(cell: Vector3i) -> void:
	var cells: Array[Vector3i] = [cell]
	_grid._spawn_collapse_debris(
		cells,
		{cell: CONCRETE},
		{cell: 0}
	)


func _clear_debris() -> void:
	for body in get_nodes_in_group("stability_debris"):
		if is_instance_valid(body):
			body.free()


func _expect(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if condition:
		return
	_failures += 1
	if detail.is_empty():
		print("FAIL: %s" % label)
	else:
		print("FAIL: %s (%s)" % [label, detail])


func _finish() -> void:
	print("checks=%d failures=%d" % [_checks, _failures])
	if _failures == 0:
		print("=== PASS ===")
	quit(1 if _failures > 0 else 0)
