class_name ColorPaletteDB
extends RefCounted

## Loads the 16x1 color strips under textures/color_palettes and tints
## `_colorbase` block textures. Every palette is concatenated in sorted file
## order, so color indices in item suffixes are stable.

const PALETTE_FOLDER := "res://textures/color_palettes/"
const COLORBASE_MARKER := "_colorbase"
const COLOR_SUFFIX_MARKER := "_c"

static var _colors: Array[Color] = []
static var _loaded := false


static func colors() -> Array[Color]:
	if _loaded:
		return _colors
	_loaded = true

	var files := DirAccess.get_files_at(PALETTE_FOLDER)
	files.sort()
	for file_name: String in files:
		if not file_name.ends_with(".png"):
			continue
		var texture := load(PALETTE_FOLDER + file_name) as Texture2D
		if texture == null:
			continue
		var image: Image = texture.get_image()
		if image == null:
			continue
		image = image.duplicate()
		if image.is_compressed() and image.decompress() != OK:
			continue
		image.convert(Image.FORMAT_RGBA8)
		for x in image.get_width():
			_colors.append(image.get_pixel(x, 0))
	return _colors


static func count() -> int:
	return colors().size()


static func color_at(index: int) -> Color:
	var list := colors()
	if list.is_empty():
		return Color.WHITE
	return list[clampi(index, 0, list.size() - 1)]


static func is_colorbase_name(item_name: String) -> bool:
	return item_name.to_lower().contains(COLORBASE_MARKER)


## Parses the trailing `_cNN` on a generated color variant; -1 when absent.
static func color_index(item_name: String) -> int:
	var lower := item_name.to_lower()
	var position := lower.rfind(COLOR_SUFFIX_MARKER)
	if position == -1:
		return -1
	var tail := lower.substr(position + COLOR_SUFFIX_MARKER.length())
	if tail.length() != 2 or not tail.is_valid_int():
		return -1
	return int(tail)


## Multiplicative tint: preserves the base texture's shading and alpha, and
## normalises against the texture's average opaque luminance so dark pixels
## stay dark and highlights stay bright.
static func tint_image(source: Image, color: Color) -> Image:
	if source == null:
		return null
	var image: Image = source.duplicate()
	if image.is_compressed():
		if image.decompress() != OK:
			return null
	image.convert(Image.FORMAT_RGBA8)

	var total := 0.0
	var samples := 0
	for y in image.get_height():
		for x in image.get_width():
			var pixel: Color = image.get_pixel(x, y)
			if pixel.a <= 0.0:
				continue
			total += _luminance(pixel)
			samples += 1
	var average: float = total / float(maxi(samples, 1))
	var denominator: float = maxf(average, 0.001)

	for y in image.get_height():
		for x in image.get_width():
			var pixel: Color = image.get_pixel(x, y)
			if pixel.a <= 0.0:
				continue
			var factor: float = clampf(
				_luminance(pixel) / denominator,
				0.22,
				1.3
			)
			image.set_pixel(
				x,
				y,
				Color(
					clampf(color.r * factor, 0.0, 1.0),
					clampf(color.g * factor, 0.0, 1.0),
					clampf(color.b * factor, 0.0, 1.0),
					pixel.a
				)
			)
	return image


## Multiplicative tint matching StandardMaterial3D.albedo_color. Used for
## inventory/preview textures so an icon uses the same colour math as the
## placed mesh instead of the luminance-normalised preview tint.
static func tint_image_multiplicative(
	source: Image,
	color: Color
) -> Image:
	if source == null:
		return null
	var image: Image = source.duplicate()
	if image.is_compressed():
		if image.decompress() != OK:
			return null
	image.convert(Image.FORMAT_RGBA8)

	for y in image.get_height():
		for x in image.get_width():
			var pixel: Color = image.get_pixel(x, y)
			if pixel.a <= 0.0:
				continue
			image.set_pixel(
				x,
				y,
				Color(
					clampf(pixel.r * color.r, 0.0, 1.0),
					clampf(pixel.g * color.g, 0.0, 1.0),
					clampf(pixel.b * color.b, 0.0, 1.0),
					pixel.a
				)
			)
	return image


static func _luminance(color: Color) -> float:
	return color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722
