extends RichTextLabel


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	visible = false
	
	if GlobalData.has_signal("npc_evacuated"):
		GlobalData.npc_evacuated.connect(_on_npc_evacuated)
	if GlobalData.has_signal("npc_spawned"):
		GlobalData.npc_spawned.connect(_on_npc_spawned)


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(_delta: float) -> void:
	if Input.is_action_just_pressed("ui_statistics_toggle"):
		visible = not visible

	if visible:
		_update_statistics_display()


## Refreshes the RichTextLabel text with current game statistics.
func _update_statistics_display() -> void:
	var total_alive: int = get_tree().get_nodes_in_group("npc").size()
	var global_cap: int = GlobalData.global_unit_cap

	var total_spawned: int = GlobalData.npcs_spawned
	var total_evacuated: int = GlobalData.npcs_evacuated
	var total_quota: int = GlobalData.get_total_max_spawns()
	var total_quota_str: String = str(total_quota) if total_quota >= 0 else "∞"

	var text_builder := "[b][color=yellow]--- GAME STATISTICS ---[/color][/b]\n"
	text_builder += "• [b]Global Active Units:[/b] %d/%d\n" % [total_alive, global_cap]
	text_builder += "• [b]Spawned:[/b] %d\n" % total_spawned
	text_builder += "• [b]Evacuated:[/b] %d\n" % total_evacuated
	text_builder += "• [b]Total Spawn Quota:[/b] %s\n\n" % total_quota_str

	text_builder += "[b][color=lightblue]Spawn Sections:[/color][/b]\n"

	var sections: Array = GlobalData.get_all_sections()
	if sections.is_empty():
		text_builder += "  [italic]No active spawn sections.[/italic]\n"
	else:
		for section in sections:
			var spawned_count: int = GlobalData.get_section_spawn_count(section)
			var quota: int = GlobalData.get_section_quota(section)
			var quota_str: String = str(quota) if quota >= 0 else "∞"

			text_builder += "  - [b]%s:[/b] %d/%s spawned\n" % [section, spawned_count, quota_str]

	text = text_builder


func _on_npc_evacuated(_total_count: int) -> void:
	if visible:
		_update_statistics_display()


func _on_npc_spawned(_total_count: int) -> void:
	if visible:
		_update_statistics_display()
