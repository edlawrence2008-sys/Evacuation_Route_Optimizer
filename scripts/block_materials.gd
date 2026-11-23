class_name BlockMaterials
extends RefCounted

## Block material registry backed by resources/block_materials.json.
##
## A material (Concrete, Dirt, Grass, ...) owns the base properties shown in the
## Property tab. A block group is one texture's normal block plus its slab,
## stair and panel variants; variants inherit the material values and apply the
## variant modifiers from the same JSON file.

const DATA_PATH := "res://resources/block_materials.json"

## Canonical property keys shared by the JSON, the Property tab and future
## gameplay systems (stability, support limits, fire, buoyancy, pathing).
const PROPERTY_KEYS: Array[String] = [
	"base_stability",
	"base_durability",
	"base_weight",
	"buoyancy",
	"base_path_cost",
	"flammability",
]

## Properties that a shape variant modifies. Buoyancy, path cost and
## flammability stay at the material level.
const VARIANT_PROPERTY_KEYS: Array[String] = [
	"base_stability",
	"base_durability",
	"base_weight",
]

const FALLBACK_PROPERTIES := {
	"base_stability": 0.0,
	"base_durability": 0.0,
	"base_weight": 0.0,
	"buoyancy": 0.0,
	"base_path_cost": 1.0,
	"flammability": 0.0,
}

## Longest prefixes first so "stairs_upsidedown_" wins over "stairs_".
const SHAPE_PREFIXES: Array[String] = [
	"stairs_upsidedown_",
	"slab_bottom_",
	"slab_top_",
	"slab_side_",
	"panel_bottom_",
	"panel_top_",
	"panel_side_",
	"stairs_",
	"slab_",
	"panel_",
	"stair_",
	"connect_",
]

static var _materials: Array = []
static var _variants: Dictionary = {}
static var _loaded := false


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true

	if not FileAccess.file_exists(DATA_PATH):
		push_warning("BlockMaterials: missing " + DATA_PATH)
		return

	var file := FileAccess.open(DATA_PATH, FileAccess.READ)
	if file == null:
		push_warning("BlockMaterials: could not read " + DATA_PATH)
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()

	if not parsed is Dictionary:
		push_warning("BlockMaterials: malformed JSON in " + DATA_PATH)
		return

	var data: Dictionary = parsed
	var materials: Variant = data.get("materials", [])
	if materials is Array:
		_materials = materials
	var variants: Variant = data.get("variant_modifiers", {})
	if variants is Dictionary:
		_variants = variants


## Reloads the JSON. Useful for editor tools and tests.
static func reload() -> void:
	_materials = []
	_variants = {}
	_loaded = false
	_ensure_loaded()


## The lower-case texture/material name after removing Auto_ and any shape
## prefix. Example: Auto_Slab_Top_concrete_brick_yellow -> concrete_brick_yellow.
static func material_name(item_name: String) -> String:
	var clean := item_name
	if clean.begins_with("Auto_"):
		clean = clean.substr(5)
	var lower := clean.to_lower()

	# CTM items carry Connect_ before the shape prefix:
	# Auto_Connect_Slab_Top_foo -> slab_top_foo -> foo.
	var is_ctm := lower.begins_with("connect_")
	if is_ctm:
		lower = lower.substr(8)

	for prefix in SHAPE_PREFIXES:
		if lower.begins_with(prefix) and prefix != "connect_":
			lower = lower.substr(prefix.length())
			break

	# Autoblock color variants keep `_colorbase_cNN` in the item name but
	# belong to the same inventory group as the uncolored base. For CTM
	# sources the `_colorbase` suffix is part of the source name: merging
	# hardwood_cornered and hardwood_cornered_colorbase would hide one of
	# them, so CTM groups keep `_colorbase` and strip only the trailing color
	# index (`_cNN`). Color variants of one CTM source therefore share a
	# group, while the plain source stays separate.
	if is_ctm:
		var color_pos := lower.rfind("_c")
		if color_pos != -1 and lower.length() - color_pos == 4:
			var color_tail := lower.substr(color_pos + 2)
			if color_tail.is_valid_int():
				lower = lower.substr(0, color_pos)
	else:
		var colorbase := lower.find("_colorbase")
		if colorbase != -1:
			lower = lower.substr(0, colorbase)

	return lower


## The material definition dictionary for an item, or {} when unknown.
static func material_for(item_name: String) -> Dictionary:
	_ensure_loaded()
	var name := material_name(item_name)
	var best: Dictionary = {}
	var best_length := -1

	for material: Variant in _materials:
		if not material is Dictionary:
			continue
		var definition: Dictionary = material
		var prefixes: Variant = definition.get("prefixes", [])
		if not prefixes is Array:
			continue
		for prefix_value: Variant in prefixes:
			var prefix := String(prefix_value)
			if (
				not prefix.is_empty()
				and name.begins_with(prefix)
				and prefix.length() > best_length
			):
				best = definition
				best_length = prefix.length()

	return best


static func material_id(item_name: String) -> String:
	return String(material_for(item_name).get("id", ""))


static func material_label(item_name: String) -> String:
	var definition := material_for(item_name)
	return String(definition.get("label", ""))


## Human-readable name for the texture-level block group (normal block plus
## its variants): Concrete Brick Yellow, Dirt Rough, ...
static func block_group_label(item_name: String) -> String:
	var name := material_name(item_name)
	if name.is_empty():
		return ""
	return name.replace("_", " ").capitalize()


## Removes the Auto_ prefix and every shape prefix, leaving the bare group name.
static func block_group_id(item_name: String) -> String:
	return material_name(item_name)


## "block", "slab", "stairs" or "panel".
static func variant_of(item_name: String) -> String:
	var lower := item_name.to_lower()
	if lower.begins_with("auto_"):
		lower = lower.substr(5)
	if lower.begins_with("connect_"):
		lower = lower.substr(8)

	if lower.begins_with("slab_"):
		return "slab"
	if lower.begins_with("panel_"):
		return "panel"
	if lower.begins_with("stairs_") or lower.begins_with("stair_"):
		return "stairs"
	return "block"


static func variant_label(item_name: String) -> String:
	var variant := variant_of(item_name)
	var definition: Variant = _variants.get(variant, {})
	if definition is Dictionary:
		return String((definition as Dictionary).get("label", variant.capitalize()))
	return variant.capitalize()


## Resolved values for the six Property-tab rows. Variants inherit the
## material values and scale stability, durability and weight by their modifier.
static func properties_for_item(item_name: String) -> Dictionary:
	_ensure_loaded()
	var definition := material_for(item_name)
	var base: Dictionary = definition.get("properties", {})
	var variant := variant_of(item_name)
	var modifiers: Dictionary = {}
	var modifier_value: Variant = _variants.get(variant, {})
	if modifier_value is Dictionary:
		modifiers = modifier_value

	var result: Dictionary = {}
	for key in PROPERTY_KEYS:
		var value := float(base.get(key, FALLBACK_PROPERTIES[key]))
		if key in VARIANT_PROPERTY_KEYS:
			value *= float(modifiers.get(key, 1.0))
		result[key] = value
	return result


## Convenience for the Property tab and tooltips.
static func default_properties() -> Dictionary:
	return FALLBACK_PROPERTIES.duplicate()
