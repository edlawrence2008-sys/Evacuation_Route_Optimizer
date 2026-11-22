================================================================================
  EmacEArt Stylized Grass - grass shader demo project for Godot 4
================================================================================

HOW TO RUN
  Godot 4.7+  ->  Import  ->  point at project.godot  ->  Import & Edit
  Then F5 (or open Scenes/GrassDemo.tscn and press F6).

CONTROLS IN THE SCENE
  LMB + mouse move   orbit
  RMB + mouse move   pan
  wheel              zoom
  1 / 2 / 3 / 4      top down / ground level / side view / the winter field
  space              freeze time (inspect a single wind frame)
  H                  hide / show the parameter panel

THE PARAMETER PANEL
  The demo opens with a panel of sliders down the left edge. The drop-down at
  the top picks which field the sliders drive - Green Meadow, Dry Grass,
  Dead Grass or Winter Field - and the grass changes while a slider is being
  dragged.

  Thirty-two parameters sit on the panel, in eight groups:
      Wind  /  Gust  /  Base and Silhouette
      Small Tint  /  Large Tint  /  Foliage Shading
      Winter  /  Snow on the Blades

  Moving the sliders does not change the four grass materials that came with
  the pack. Close the demo, open it again, and the grass is back where it
  started.

THE REST OF THE PARAMETERS
  Colour fields, mode switches and textures are in the Inspector:
  select a grass field in the scene tree
  (Field_Green / Field_Dry / Field_Dead / Field_Winter)
  ->  Inspector  ->  Material Override  ->  Shader Parameters

  The groups match the headers from the Unity version:
      Base / Normal / PBR / Wind / Gust
      Tint Small  (Blob, Stripes)
      Tint Large  (Blob, Stripes)
      Foliage Shading
      Winter  (Snow)

  Each tint layer keeps TWO sets of parameters - one for blob mode and one for
  stripes mode. Switching "stripes mode" back and forth never loses your
  settings; the panel shows the set the material is actually using.

SECOND SCENE - THE WIND SPECTRUM
  Scenes/GrassSpectrum.tscn puts five wind settings side by side in one row,
  each group of clumps labelled with its name. Behind the row lies a wide field
  where the wind builds from dead calm to a gale. Open the scene and press F6:
  the camera runs a fixed move, first along the labelled row, then rising above
  the field. There are no controls - the scene is there to compare settings.

      setting        strength  speed  frequency  gust str.  gust scale  gust spd
      Calm             0.03     0.5      0.5       0.05        0.05       0.2
      Light Breeze     0.14     0.7      0.7       0.25        0.06       0.3
      Fresh Breeze     0.31     0.98     0.8       0.5         0.05       0.4
      Choppy Gusts     0.34     2.9      1.9       1.5         0.16       1.5
      Gale             0.85     3.1      1.0       1.5         0.05       1.1

  Fresh Breeze is what the green material uses. Pick a row and copy its numbers
  into the Wind and Gust groups of your own material. Watching this scene leaves
  the four grass materials exactly as they were.

WINTER
  A fourth field stands behind the meadow, snow on the blades, using
  Materials/EA_Grass_Winter.tres. Press 4 to move the camera to it.

  Winter is a dial on every material, not a second shader. Winter Amount at 0
  is the summer field, at 1 the winter one. The blade turns dry straw and snow
  settles from the tip downwards; Snow Coverage says how far down it reaches -
  1.0 buries the blade to the ground, 0.15 only frosts the tips.

  The grass carries winter, the ground does not. The demo puts a pale plane
  under the winter field; your own scene needs its own snowy ground.

WHAT IS INSIDE
  Shaders/EA_GrassWind.gdshader    the shader, commented line by line
  Materials/EA_Grass_Green.tres    green variant
  Materials/EA_Grass_Dry.tres      dry variant
  Materials/EA_Grass_Dead.tres     dead variant
  Materials/EA_Grass_Winter.tres   winter variant, snow on the blades
  Meshes/EA_Grass_Clump.mesh       grass clump
  Textures/GRASS_DIFF.tga          colour and the blade shape
  Textures/GRASS_NMAP.tga          surface detail
  icon.svg                         the pack icon in the project manager
  Scripts/GrassField.gd            fills a rectangle with clumps
  Scripts/DemoCamera.gd            orbit camera
  Scripts/WindSpectrum.gd          builds the labelled row and the large field
  Scripts/SpectrumCamera.gd        the camera move of the spectrum scene
  Scenes/UI_ParameterPanel.tscn    the slider panel of the demo scene
  Scripts/UI_ParameterPanel.gd     wires the panel to the selected material

  Three fields stand side by side so the variants can be compared:
      left = Dry, middle = Green, right = Dead
  The winter field stands behind them.

DOCUMENTATION
  Documentation/EmacEArt_Stylized_Grass_QuickStart_EN.pdf
  The short way in: put the grass in your own scene and pick a variant.

  Documentation/EmacEArt_Stylized_Grass_Documentation_EN.pdf   13 pages
  Every parameter, what the four variants differ in, how the winter dial works,
  where the blade shape comes from, and what is better left alone.

  Documentation/CONTENTS.txt   the file list of this pack
  Documentation/README.txt     this file
  Documentation/LICENSE.txt    the licence

IF YOU EDIT THE SHADER
  Every material stores its settings under the parameter names the shader uses.
  Change a name in the shader and the four grass materials lose the setting
  that went with it, with nothing on screen to say so. Change the name in the
  materials as well.

LICENCE
  EmacEArt Asset License - free for personal and commercial use, but resale or
  redistribution of the assets as standalone files or asset packs is prohibited.
  No credit is required, though it is always welcome.
  Full terms: LICENSE.txt in the root of the pack.

JOIN US ON DISCORD
  https://discord.com/invite/ctXaf5Ftqw
  Questions, screenshots of what you built with it, requests for the next
  version - this pack grows from what people report there.
================================================================================
