class_name RoutePaintComponent
extends UseComponent

## Held authored-route tool. BuildController routes primary/secondary use here
## while this scene is selected; RoutePainter owns the preview, painting and
## persistence so the component works even though the held scene is only
## instantiated for inspection.

func can_use(_actor: Node) -> bool:
	return true


func use(_actor: Node, _origin: Vector3, _direction: Vector3) -> void:
	RoutePainter.primary_click()


func alt_use(_actor: Node, _origin: Vector3, _direction: Vector3) -> void:
	RoutePainter.secondary_click()
