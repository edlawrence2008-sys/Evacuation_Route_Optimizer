extends Area3D

func _ready() -> void:
	body_entered.connect(_on_body_entered)

func _on_body_entered(body: Node3D) -> void:
	if not body.is_in_group("npc"):
		return

	var evacuation_manager := get_node_or_null("/root/EvacuationManager")
	if evacuation_manager and evacuation_manager.has_method("register_evacuation"):
		evacuation_manager.register_evacuation(body, self)

	GlobalData.register_evacuation()
	body.queue_free()
