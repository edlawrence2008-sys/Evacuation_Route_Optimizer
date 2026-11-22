class_name ConnectedTextureBuilder
extends RefCounted

## Builds an OptiFine-style connected texture atlas from a single 16x16 source
## image authored in the four-quadrant format:
##   top-left = corner (q1), bottom-left = edge (q2),
##   top-right = overflow (q3), bottom-right = fully surrounded (q4).
##
## A 32x16 source keeps q1-q4 in its left 16x16 block and adds q5, a full
## background layer, in its right block. q5 is composited *behind* the four
## state pieces, exactly as the reference Python generator does; it is not a
## fifth connection state.
##
## The atlas is indexed by an 8-neighbour mask:
##   N=1 E=2 S=4 W=8 NE=16 SE=32 SW=64 NW=128
## so tile 0 is untouched and tile 255 is fully connected. All 256 masks are
## generated, which is equivalent to the 47 unique OptiFine CTM tiles.
##
## Sources painted as one complete framed pane (all four outer edges opaque)
## are normalised into the four states before the atlas is built.

const ATLAS_GRID := 16
const BIT_N := 1
const BIT_E := 2
const BIT_S := 4
const BIT_W := 8
const BIT_NE := 16
const BIT_SE := 32
const BIT_SW := 64
const BIT_NW := 128

## Atlas alpha categories used by build_material().
const ALPHA_OPAQUE := 0
const ALPHA_CUTOUT := 1
const ALPHA_BLEND := 2


static func build_material(source_path: String) -> StandardMaterial3D:
	var texture := _load_texture(source_path)
	if texture == null:
		return null

	var source_image := texture.get_image()
	if source_image == null:
		return null
	source_image = source_image.duplicate()
	if source_image.is_compressed():
		if source_image.decompress() != OK:
			return null
	source_image.convert(Image.FORMAT_RGBA8)

	var atlas := build_atlas_image(source_image)
	if atlas == null:
		return null

	var material := StandardMaterial3D.new()
	material.albedo_texture = ImageTexture.create_from_image(atlas)
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	material.vertex_color_use_as_albedo = true
	# CTM quads are outward-facing box faces with the same winding as the cube
	# path. Culling backfaces keeps the inside of the far side from drawing over
	# the outside of the near side (the material used to be CULL_DISABLED).
	material.cull_mode = BaseMaterial3D.CULL_BACK
	match _atlas_alpha_mode(atlas):
		ALPHA_CUTOUT:
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
			material.alpha_scissor_threshold = 0.5
		ALPHA_BLEND:
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_:
			material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	material.roughness = 0.15
	material.metallic = 0.0
	return material


## Classifies the generated atlas so an opaque CTM block does not pay for the
## transparent pass (and does not lose depth writes). 0 = opaque, 1 = cutout
## (only 0/255), 2 = partial alpha that needs blending.
static func _atlas_alpha_mode(atlas: Image) -> int:
	match atlas.detect_alpha():
		Image.ALPHA_BLEND:
			return ALPHA_BLEND
		Image.ALPHA_BIT:
			return ALPHA_CUTOUT
		_:
			return ALPHA_OPAQUE


static func build_atlas_image(source: Image) -> Image:
	var height := source.get_height()
	if height <= 0 or height % 2 != 0:
		return null
	var half: int = height >> 1
	var states := _build_states(source, half)
	var atlas_size := ATLAS_GRID * height
	var atlas := Image.create(
		atlas_size,
		atlas_size,
		false,
		Image.FORMAT_RGBA8
	)

	for mask in range(256):
		var tile_x := mask % ATLAS_GRID
		var tile_y := int(mask / float(ATLAS_GRID))
		var origin := Vector2i(tile_x * height, tile_y * height)
		var tile := Image.create(height, height, false, Image.FORMAT_RGBA8)

		_copy_quadrant(tile, Vector2i.ZERO, 0, 0, states, half, _state(mask, 0), 0)
		_copy_quadrant(tile, Vector2i.ZERO, 1, 0, states, half, _state(mask, 1), 1)
		_copy_quadrant(tile, Vector2i.ZERO, 0, 1, states, half, _state(mask, 2), 2)
		_copy_quadrant(tile, Vector2i.ZERO, 1, 1, states, half, _state(mask, 3), 3)

		# A 32x16 source is q1-q4 in the left 16x16 block plus a full q5
		# background in the right block. q5 sits *behind* the four state
		# pieces, so blend the composed tile over it rather than replacing
		# only fully transparent pixels. That also gives the correct result
		# for anti-aliased or partly transparent state pixels.
		if source.get_width() == height * 2:
			var background := _crop(source, Vector2i(height, 0), height)
			background.blend_rect(tile, Rect2i(0, 0, height, height), Vector2i.ZERO)
			tile = background

		atlas.blit_rect(tile, Rect2i(0, 0, height, height), origin)

	return atlas


## Splits the source into the four connection-state pieces the Python
## generator expects: corner (top-left + left borders), edge (one border),
## overflow (inner-corner dot), and null (no borders).
##
## A correctly authored source already contains those pieces, so they are used
## verbatim. Sources painted as one complete framed pane (all four outer edges
## opaque, like the classroom window) are normalised first, otherwise every
## tile would contain a frame and the texture would never visually connect.
static func _build_states(source: Image, half: int) -> Dictionary:
	var cr := _crop(source, Vector2i(0, 0), half)
	if not _is_framed_source(source, half):
		return {
			"cr": cr,
			"ed": _crop(source, Vector2i(0, half), half),
			"of": _crop(source, Vector2i(half, 0), half),
			"nu": _crop(source, Vector2i(half, half), half),
		}

	# The source is one framed pane. Keep its top-left corner for "corner";
	# drop the bottom frame from the edge piece; fill the inner-corner piece
	# with the same glass as "surrounded" and add a single frame pixel; and use
	# an unframed central crop for "surrounded".
	var ed := _crop(source, Vector2i(0, half), half)
	for x in range(half):
		ed.set_pixel(x, half - 1, ed.get_pixel(x, half - 2))

	var interior_origin := Vector2i(
		(source.get_width() - half) >> 1,
		(source.get_height() - half) >> 1
	)
	var nu := _crop(source, interior_origin, half)
	# The inner-corner quadrant must still contain glass; only its corner pixel
	# is frame. Leaving it transparent carves a see-through notch out of any
	# block diagonally adjacent to a removed block.
	var of := nu.duplicate()
	of.set_pixel(half - 1, 0, source.get_pixel(source.get_width() - 1, 0))

	return {
		"cr": cr,
		"ed": ed,
		"of": of,
		"nu": nu,
	}


## True when the bottom-right quadrant is framed along its outer edges, which
## means the source was painted as a complete pane instead of the four states.
static func _is_framed_source(source: Image, half: int) -> bool:
	if source.get_width() != source.get_height():
		return false
	var edge := source.get_height() - 1
	var opaque := 0
	for i in range(half):
		if source.get_pixel(half + i, edge).a > 0.9:
			opaque += 1
		if source.get_pixel(edge, half + i).a > 0.9:
			opaque += 1
	return opaque > half


static func _crop(source: Image, origin: Vector2i, size: int) -> Image:
	var piece := Image.create(size, size, false, Image.FORMAT_RGBA8)
	piece.blit_rect(
		source,
		Rect2i(origin.x, origin.y, size, size),
		Vector2i.ZERO
	)
	return piece


static func _state(mask: int, quadrant: int) -> String:
	var n: bool
	var e: bool
	var s: bool
	var w: bool
	var ne: bool
	var se: bool
	var sw: bool
	var nw: bool

	match quadrant:
		0:
			n = (mask & BIT_N) != 0
			w = (mask & BIT_W) != 0
			nw = (mask & BIT_NW) != 0
			if not n and not w:
				return "cr"
			if n and not w:
				return "edv"
			if w and not n:
				return "edh"
			return "nu" if nw else "of"
		1:
			n = (mask & BIT_N) != 0
			e = (mask & BIT_E) != 0
			ne = (mask & BIT_NE) != 0
			if not n and not e:
				return "cr"
			if n and not e:
				return "edv"
			if e and not n:
				return "edh"
			return "nu" if ne else "of"
		2:
			s = (mask & BIT_S) != 0
			w = (mask & BIT_W) != 0
			sw = (mask & BIT_SW) != 0
			if not s and not w:
				return "cr"
			if s and not w:
				return "edv"
			if w and not s:
				return "edh"
			return "nu" if sw else "of"
		_:
			s = (mask & BIT_S) != 0
			e = (mask & BIT_E) != 0
			se = (mask & BIT_SE) != 0
			if not s and not e:
				return "cr"
			if s and not e:
				return "edv"
			if e and not s:
				return "edh"
			return "nu" if se else "of"


## Copies one state piece into an output quadrant. The transforms mirror the
## Python generator: cr/edh/edv/of/nu are rotated and flipped per output corner.
static func _copy_quadrant(
	atlas: Image,
	origin: Vector2i,
	qx: int,
	qy: int,
	states: Dictionary,
	half: int,
	state: String,
	quadrant: int
) -> void:
	var piece: Image = states["nu"]
	match state:
		"cr":
			piece = states["cr"]
		"edh", "edv":
			piece = states["ed"]
		"of":
			piece = states["of"]

	for y in range(half):
		for x in range(half):
			var sx := x
			var sy := y
			match quadrant:
				0:
					match state:
						"cr":
							pass
						"edh":
							sx = y
							sy = half - 1 - x
						"edv":
							sy = half - 1 - y
						"of":
							sx = half - 1 - x
						"nu":
							sx = half - 1 - x
							sy = half - 1 - y
				1:
					match state:
						"cr":
							sx = half - 1 - x
						"edh":
							sx = y
							sy = x
						"edv":
							sx = half - 1 - x
							sy = half - 1 - y
						"of":
							pass
						"nu":
							sy = half - 1 - y
				2:
					match state:
						"cr":
							sy = half - 1 - y
						"edh":
							sx = half - 1 - y
							sy = half - 1 - x
						"edv":
							pass
						"of":
							sx = half - 1 - x
							sy = half - 1 - y
						"nu":
							sx = half - 1 - x
				3:
					match state:
						"cr":
							sx = half - 1 - x
							sy = half - 1 - y
						"edh":
							sx = half - 1 - y
							sy = x
						"edv":
							sx = half - 1 - x
						"of":
							sy = half - 1 - y
						"nu":
							pass

			var color := piece.get_pixel(
				clampi(sx, 0, half - 1),
				clampi(sy, 0, half - 1)
			)
			atlas.set_pixel(
				origin.x + qx * half + x,
				origin.y + qy * half + y,
				color
			)


static func _load_texture(path: String) -> Texture2D:
	if not FileAccess.file_exists(path):
		return null
	if ResourceLoader.exists(path, "Texture2D"):
		return load(path) as Texture2D
	var image := Image.new()
	if image.load(path) == OK:
		return ImageTexture.create_from_image(image)
	return null
