extends Resource

class_name CycleData

## Represent the colors on the sky during the day cycle.
## Colors aligned on the left are the morning-light.
## Colors on the right are the end-of-day light.
@export var colors: GradientTexture2D

## Length of the day/night phase in seconds. Day and night are separate
## resources, so each can be authored independently; both default to 24 minutes.
@export var length: float = 1440.0

## Control the sun lights enegry during the day.
@export var light_energy: Curve

## Optional per-phase sun/moon light colour. White keeps the controller's base.
@export var light_color: Color = Color.WHITE

## Optional per-phase ambient and fog shaping. Empty curves fall back to the
## authored WorldEnvironment values, so existing presets keep working.
@export_group("Atmosphere")
@export var ambient_energy: Curve
@export var fog_density: Curve
@export var volumetric_fog_density: Curve

## Image layer abover the sky color
@export var sky_cover: Texture2D

@export_group("Sky Color Variations")
## Multiplier for horizon darkening
@export var horizon_darkening_multiplier: float = 0.1
## Multiplier for ground horizon darkening
@export var ground_horizon_darkening_multiplier: float = 0.2
## Multiplier for ground bottom darkening
@export var ground_bottom_darkening_multiplier: float = 0.4

## Optional independent sky gradients. When assigned they replace the
## darkening-derived horizon/zenith/lower-sky colours above.
@export var horizon_colors: GradientTexture2D
@export var zenith_colors: GradientTexture2D
@export var lower_sky_colors: GradientTexture2D
