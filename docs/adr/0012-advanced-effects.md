# Advanced Effects Extend the Effects List and Its Core Animation Rendering

2026-11-20 (#193). Status: **accepted** (reviewed 2026-11-20, as #193 requires before implementation). It builds on the effects list of #190 (drop shadow, inner shadow, layer blur, background blur), implemented in PR #214, which is not merged yet; where this ADR depends on a choice made there, it says so, and it is revisited if that PR changes.

The effects add menu prototype ("Effects add menu (open)", drawn in Fudehand) lists six more effects after shadows and blurs: **Noise**, **Texture**, **Glass**, **Shader**, and, marked Beta, **3D transform** and **Perspective**. This ADR fixes each one's parameters and rendering, the shader's security and performance limits, and how the canvas, `design_snapshot`, and the prototype window stay identical.

## Starting point: how #214 draws effects

- A layer's `effects` list holds entries `{ "type": "drop-shadow" | "inner-shadow" | "layer-blur" | "background-blur", "visible", … }`, drawn in list order; every layer type but group has effects. `DesignJSON` validates them for files and the Agent alike.
- `EffectLayers.build` turns them into Core Animation layers in the node's coordinates, sorted into buckets: `behind` (drop shadows), `backdrops` (background blurs, placed next to the node in its parent, because Core Animation background filters only see earlier layers in the same superlayer), `inner` (inner shadows, above the fill and below the children), and `filters` (layer blurs on the node itself).
- The canvas, the prototype window, and `AnimationPreview` all draw through `DesignRenderer`, and `design_snapshot` now composites the same layer tree offscreen with `CARenderer` instead of `render(in:)`, so Core Image filters, background filters, masks, and transforms come out the same in all of them.

This ADR keeps that model: **every new effect is more layers from `EffectLayers.build`, drawn by the one renderer.** No effect gets a separate snapshot path, which is what keeps canvas, snapshot, and prototype identical.

## Decisions

### Model

- **The six effects are new `type` values in the same list**, in #214's kebab-case: `noise`, `texture`, `glass`, `shader`, `transform-3d`, `perspective`. They share `visible` and the list's order and undo rules. Fields that do not belong to a type are refused, as for the existing effects.
- **Which layers accept which effect** (refused elsewhere with a reason):

  | Effect | `type` | Layer types | Per layer |
  | --- | --- | --- | --- |
  | Noise | `noise` | frame, rectangle, ellipse | any number |
  | Texture | `texture` | frame, rectangle, ellipse | any number |
  | Glass | `glass` | frame, rectangle, ellipse | at most one |
  | Shader | `shader` | frame, rectangle, ellipse | any number |
  | 3D transform | `transform-3d` | every type but group | at most one |
  | Perspective | `perspective` | frame | at most one |

  Noise, Texture, Shader, and Glass paint over a layer's area, so they need a shape to fill; text, image, and icon layers get them only if someone asks. Groups have no effects in #214, and this keeps that.
- **They join #214's `inner` bucket**: Noise, Texture, Shader, and Glass's tint and highlight are drawn with the inner shadows above the fill and below the children, all in list order, each clipped to the layer's shape (corner radius, ellipse) with #214's `clip`. (The first draft had a separate `surface` bucket below inner shadows; list order is simpler and lets people choose.)
- **The format version moves past #214's once that version has been released.** #214's version 9 is not in a release yet, so effect types added before the next release stay in version 9; the first one added after a release moves the version, so older builds refuse newer files with their usual message. Older files always open unchanged.

### Noise

`{ "type": "noise", "size": 1, "density": 0.5, "color": "#00000033", "seed": 0 }`

- `size`: grain size in pt, 0.5–8. `density`: share of grain cells drawn, 0–1. `color`: grain color; its alpha is the strength (as for shadows, there is no separate opacity). `seed`: integer ≥ 0.
- Rendering: whether a cell has a grain, and how strong it is, comes from a hash of `(seed, cell x, cell y)` in the layer's own coordinates — so grains stay put when the layer moves and are the same on every render, in every snapshot, and on another Mac. The hash and the tile pixels are computed in `FudehandCore` (testable, no AppKit); a 256×256-cell tile is made once per color, density, and seed and repeated from the layer's top-left corner by sublayers in the `inner` bucket that all show that one tile image, scaled without smoothing (`NoiseLayer`), so zooming never redraws it and a large layer costs no more than one small image. Grains are sized in points and grow when zooming in, like the rest of the design.

### Texture

`{ "type": "texture", "image": { "data": "<base64>" }, "size": 64, "opacity": 1, "blend": "normal" }` (implemented in #193's Texture PR)

- A tiled image over the layer's area. `image` is a PNG, JPEG, or SVG, validated like an image layer's `image`; the Agent passes `image.path` and Node reads it into base64, the same narrow exception image layers already have. `size`: tile width in pt, 4–1024, height following the image's aspect ratio. `opacity`: 0–1. `blend`: `normal`, `multiply`, `screen`, `overlay`, or `soft-light` (kebab-case like the effect types), mapped to the holder layer's `compositingFilter`, so it blends with the layer's fill.
- Rendering: the tile is drawn once into a block at least 256 pt on each side (a bitmap at its own pixel density, an SVG at 3 pixels per point, within 4096 pixels), cached per image and tile size, and the block repeats as sublayers in the `inner` bucket (`TextureLayer`). Small tiles on a large frame therefore stay a handful of layers. Unlike an SVG image layer, an SVG texture is not rasterized again when zooming in: a texture is surface detail, and one fixed raster keeps it cheap. An image so flat or narrow that a block would need more than 16 384 tiles draws nothing. The Agent reads a texture's image as `<N bytes>` like an image layer's; since `effects` is replaced whole, an update that sends that placeholder back at the same place in the list keeps the image.

### Glass

`{ "type": "glass", "radius": 20, "saturation": 1.4, "tint": "#FFFFFF33", "highlight": 0.5 }` (implemented in #193's Glass PR; the tint is stored in the effect's `color`)

- Frosted glass as one effect instead of a stack: `radius` is the backdrop blur, as for Background Blur (0–250); `saturation`, 0–2, boosts the backdrop's colors the way system materials do; `tint` is drawn over the blurred backdrop (its alpha is the tint strength); `highlight`, 0–1, is the opacity of a 1 pt light edge along the shape's inner top edge.
- Rendering: a `backdrops` layer exactly like Background Blur's, with background filters `CIColorControls` (saturation) then `CIGaussianBlur`; the tint and the highlight are `inner` layers. It therefore has **the same limit as Background Blur: it only sees the layers under it in the same parent.** Glass and a Background Blur on one layer would blur twice, so `DesignJSON` refuses the pair, as it refuses a second Glass (hidden ones count, so showing one later cannot make an invalid list); the properties panel leaves those choices out of its menus. The highlight is a 1 pt stroke just inside the shape, faded out by the middle of its height with a gradient mask.
- No refraction or edge distortion: that needs a displacement pass over the backdrop and is left for a later decision.

### Shader

`{ "type": "shader", "shader": "waves", "params": { "scale": 96, "angle": 30, "colorA": "#6C63FF", "colorB": "#FF8A65" }, "opacity": 1, "blend": "normal" }` (implemented in #193's Shader PR; the catalog and its parameter checks are `ShaderCatalog` in `FudehandCore`)

- **Only shaders that ship with Fudehand.** `shader` names an entry of a built-in catalog; each entry declares its parameters (name, kind `number` or `color`, range, default). `DesignJSON` validates `params` against the catalog, so a file or an Agent cannot pass anything the catalog does not declare, and a file naming an unknown shader is refused like any malformed file. The first catalog has three entries — **Waves** (scale, angle, two colors), **Mesh gradient** (four corner colors), and **Halftone** (dot size, angle, color) — looks that shapes and fills cannot fake.
- **No user-written shader code** — not in the App, not in project files, not from the Agent. Arbitrary GPU code from a file or a model can hang the GPU or the window server, cannot be checked before it runs, and turns opening a file into running code. Sharing shader code is already a non-goal of #193; custom code would need its own ADR (a separate process with a GPU time limit, at least).
- **Rendering:** each catalog entry is a Metal compute function. The sources ship as strings in `FudehandApp` and are compiled at first use with `MTLDevice.makeLibrary(source:)`: the Command Line Tools have no offline `metal` compiler (so no metallib, which Core Image's Metal kernels would need), and the sources are ours. The pipeline renders into a texture, read back as a bitmap at the layer's size × raster scale (capped by `DesignRenderer.maximumRasterSide`), which a layer in the `inner` bucket shows with the entry's opacity and blend. A bitmap rather than a live filter keeps the cost to one render per change instead of per composited frame. The layer (`ShaderLayer`) renders when it is displayed, on the main thread: a GPU pass over even a 4096-pixel bitmap takes milliseconds, so the planned background rendering was not needed, and results are cached by entry, parameters, and pixel size. The bitmap's longest side is capped at 4096 pixels. Plain Swift on the CPU was measured first and rejected: about 400 ms for a 1440 × 1024 bitmap in a debug build. Shaders are **static**: no time input, so canvas, snapshot, and prototype match. Animated shaders would be a prototype-only option later, following ADR 0008.
- The Agent finds the catalog with a new read-only tool, `design_list_shaders` (ids, names, parameters with kinds, ranges, and defaults), because the add menu shows it to people (ADR 0007).

### 3D transform (Beta)

`{ "type": "transform-3d", "rotateX": 0, "rotateY": 20, "translateZ": 0 }` (implemented with Perspective in #193's 3D PR)

- `rotateX` / `rotateY`: degrees, −80–80 (past that the layer turns edge-on and vanishes). `translateZ`: pt, −1000–1000. No `rotateZ`: the document has no 2D rotation (ADR 0006), and that belongs with rotation as a whole.
- Rendering: the node layer's `transform`, about its center (layers are anchored there since ADR 0008). The effect layers #214 puts next to the node in its parent (`backdrops`) get the same transform so a blur stays under its layer. Children are flattened into the layer's plane (a plain `CALayer` does this, like CSS `transform-style: flat`); nested 3D transforms do not share one 3D space.
- Without a Perspective on an ancestor frame, the projection is orthographic, as in CSS: a Y rotation narrows the layer without foreshortening.
- Prototype animations: `LayerAnimationPlayer` animates the `transform.scale` and `transform.rotation.z` key paths. Checked with `CARenderer` before implementing: they compose with the base 3D transform (a layer turned 60° about Y, 50 pt wide, renders 24 pt wide at a 0.5 scale and keeps its turn under a z rotation), so the transform stays on the layer's wrapper and no extra layer is needed.

### Perspective (Beta)

`{ "type": "perspective", "distance": 800, "originX": 0.5, "originY": 0.5 }`

- On a frame (at most one; likewise at most one 3D transform per layer, hidden ones included): its direct children's 3D transforms are seen from `distance` pt (100–10 000) in front of the point `originX`, `originY` (fractions of the frame's size). Rendering: the frame layer's `sublayerTransform` with `m34 = −1 / distance`, translated to the origin — what CSS `perspective` and `perspective-origin` mean. It applies to direct children; deeper descendants are flattened by their own parents, as in CSS. A group is a plain layer too, so a turned layer inside a group in a frame with perspective is drawn flat; put turned layers directly in the frame. A snapshot of a turned child taken on its own has no parent perspective and is drawn flat.
- **Both Beta effects are visual only.** Layout, `DesignIndex` rectangles, hit testing, snapping, selection boxes, and the layers panel use the untransformed rectangle, so clicking where a turned layer *looks* like it is may miss it. That is why they are Beta; fixing it means carrying a projected quad through `DesignIndex`, `DesignHitTest`, snapping, and the overlay, deferred until the effects are used.
- Snapshots get both for free through `CARenderer`; an `EffectRendererTests`-style pixel test proves it.

### Performance

- Pixel bitmaps are cached by what they depend on: the Noise tile by color, density, and seed; the Texture block by image and tile size; the Shader output by entry, parameters, and pixel size (the last two only, to bound memory). Moving, panning, and selecting never re-render them. Zooming keeps the old bitmap during the gesture and re-renders once when the zoom commits, the rule text and SVG images already follow.
- While a continuous gesture resizes a layer, Noise and Texture redraw (they are tiles, cheap); Shader output is stretched: each rebuilt shader layer takes over the previous bitmap (`ShaderLayer.carryOver`) and renders, on the main thread, once its size has not changed for 0.15 s. A render of a 1440 × 1024 frame at 2× takes about 24 ms in a debug build, too long for every frame of a drag but fine once.
- Glass, 3D transform, and Perspective are Core Animation filters and transforms: GPU work per composited frame, with no main-thread cost, like #214's blurs.
- **Gate:** `pnpm bench:native` gains a case where 10% of the layers carry a Noise, a Texture, a Glass, a Shader, and a 3D transform; drag and hover times stay within 10% of the same benchmark without them.

### Agent, export, and UI

- Agents read and write all six through `effects` in `design_create_node` / `design_update_node` (replaced whole, as #214 does), plus `design_list_shaders`. Tests in `tests/control-tools.test.ts` and the Swift effect and control tests; rows in `docs/agent-tools.md`.
- `DesignHTML` (HTML export, #213) maps Perspective to `perspective` / `perspective-origin`, 3D transform to `transform: rotateX() rotateY() translateZ()`, and Glass to `backdrop-filter: saturate() blur()` with the tint as a background and the highlight as an inset box shadow. Noise, Texture, and Shader cannot be drawn by `FudehandCore` (no Core Image there), so they are written as an HTML comment naming the effect and its parameters; exporting them as images is a follow-up.
- **Add menu**, grouped as in the prototype (`EffectType.menuGroup`): Inner shadow, Drop shadow, Layer blur, Background blur, Noise, Texture, Glass | Shader | 3D transform, Perspective — the last two with a **Beta** tag. An effect not implemented yet is not in the menu: no disabled placeholders (#189). Rows expand to their parameters like #214's; a Shader row has a catalog menu and shows that entry's parameters; a Texture row has *Choose Image…*.
- `GLOSSARY.md` gains Noise, Texture, Glass, Shader (with the shader catalog), 3D transform, and Perspective; `docs/macos.md` the rows' interaction; all UI copy goes into the four `Localizable.strings` tables.

### Delivery order

Each effect is its own PR after #214 is merged, in this order: **Noise → Texture → Glass → 3D transform + Perspective → Shader**. Self-contained bitmap effects first; Glass reuses #214's backdrop directly; the Beta pair needs the animation check; Shader is last because it brings Metal and a new tool. Each PR ships its effect end to end (model, rendering, snapshot test, Agent, menu entry, glossary, strings, light and dark evidence).

## Rejected Alternatives

- **User-written shader code** (Metal, Core Image Kernel Language, or a WebGL-like subset): see Shader. A built-in catalog covers the look with none of the risk.
- **Shaders as live Core Image filters on the layer**: re-run on every composited frame, including every pan and zoom frame, for an image that only changes with its parameters.
- **Noise from `CIRandomGenerator` or a random number generator**: the first cannot be seeded and is anchored to the filter's coordinate space, so grains slide when the layer moves; the second changes on every render.
- **Glass with its own backdrop capture** (rendering everything beneath the layer into a bitmap): would lift the same-parent limit, but costs a render of the whole frame beneath on every change and would make Glass and Background Blur behave differently. If the limit becomes a problem, it should be lifted for both together.
- **Texture as edge roughening (a displaced outline)**: needs a displacement pass over the layer's alpha on every change, for a look rarely used in UI design; a tiled image is cheap and what a texture usually means.
- **3D transform with its own perspective**: two turned layers side by side would vanish toward different points; a shared Perspective on the frame is how CSS works and makes HTML export a direct mapping.
- **Hit testing the projected quad now**: correct, but touches `DesignIndex`, `DesignHitTest`, snapping, and the overlay for a Beta effect; deferred.

## Consequences

- Nothing here starts before #214 is merged.
- Pixel effects cost memory: one bitmap per effect per layer at the current zoom, capped by `maximumRasterSide`.
- Glass sees only its siblings beneath it, the same as Background Blur.
- Turned and perspective layers are selected by their flat rectangle until hit testing learns quads.
- HTML export is lossy for Noise, Texture, and Shader until a follow-up exports them as images.
