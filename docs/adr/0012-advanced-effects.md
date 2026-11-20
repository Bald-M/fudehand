# Advanced Effects Are Rasterized Once and Shared by Canvas, Snapshot, and Prototype

2026-11-20 (#193). Status: **proposed** — to be reviewed before any of it is implemented, as #193 requires. It builds on the effects list from #190 (drop shadow, inner shadow, layer blur, background blur), which has not landed yet; where this ADR depends on a choice #190 makes, it says so.

The effects add menu prototype ("Effects add menu (open)", drawn in Fudehand) lists six more effects after shadows and blurs: **Noise**, **Texture**, **Glass**, **Shader**, and, marked Beta, **3D transform** and **Perspective**. This ADR fixes each one's parameters and rendering, the shader's security and performance limits, and how the canvas, `design_snapshot`, and the prototype window stay identical.

## The constraint that shapes everything

The canvas, the prototype window, and `AnimationPreview` all draw through `DesignRenderer` (a `CALayer` tree), so anything done there shows up in all three. `design_snapshot` and version snapshots use the same tree but draw it with `CALayer.render(in:)`, which **ignores Core Image `filters` / `backgroundFilters` and flattens 3D transforms**. An effect that relies on those would look right on the canvas and be missing from snapshots, which breaks the "Agents see what people see" promise of ADR 0006. So:

- **Pixel effects (Noise, Texture, Glass, Shader) are rendered by our own code into a bitmap, set as the `contents` of a sublayer.** The same function produces the bitmap for the canvas and for snapshots, so the two cannot drift. Core Image may be used *inside* that function (it is just a way to compute pixels), never as a live `CALayer` filter.
- **3D transform and Perspective use `CATransform3D` on the canvas and in the prototype**, which the GPU composites for free; the snapshot path applies the same matrix itself (see below). The matrix is computed once, in `FudehandCore`, so both paths use identical numbers.

## Decisions

### Model

- **The six effects are new entries in #190's `effects` list**, with the same shape as #190's: `{ "type": …, "visible": true, …parameters }`. Hidden entries keep their parameters and draw nothing. Validation is in `DesignJSON` only (ADR 0006), shared by file loading and the Agent; fields that do not belong to an effect's type are refused, like `animation` in ADR 0008.
- **Which layers accept which effect** (refused elsewhere with a reason):

  | Effect | `type` | Layer types | Per layer |
  | --- | --- | --- | --- |
  | Noise | `noise` | frame, rectangle, ellipse | any number |
  | Texture | `texture` | frame, rectangle, ellipse | any number |
  | Glass | `glass` | frame, rectangle, ellipse | at most one, not together with a background blur |
  | Shader | `shader` | frame, rectangle, ellipse | any number |
  | 3D transform | `transform3d` | every type | at most one |
  | Perspective | `perspective` | frame, group | at most one |

  Noise, Texture, and Shader paint *on* a layer's area, so they need one; text, image, and icon layers get them later only if asked for. Glass already contains a background blur, so the two together would blur twice.
- **Draw order.** Inside a layer, from bottom to top: fill → Noise / Texture / Shader in list order → stroke → children. They are clipped to the layer's shape (corner radius, ellipse). Glass replaces what the layer would show *under* its fill (see Glass). Shadows and blurs from #190 apply to the result, as they do to a fill.
- **The format version moves to the one after #190's.** Older files open unchanged; older builds refuse newer files with their usual message.

### Noise

`{ "type": "noise", "size": 1, "density": 0.5, "color": "#000000", "opacity": 0.2, "seed": 0 }`

- `size`: grain size in pt, 0.5–8. `density`: share of grains drawn, 0–1. `color`: grain color. `opacity`: 0–1. `seed`: integer, default 0.
- Rendering: each grain cell's on/off and strength come from a hash of `(seed, cell x, cell y)` — no random number generator, so the canvas, a snapshot, a reopened file, and another Mac produce the same pixels. A 256×256-cell tile is computed once per parameter set and drawn tiled across the layer, clipped to its shape. Grains are sized in points, so they grow when zooming in, like the rest of the design.

### Texture

`{ "type": "texture", "image": { "data": "<base64>" }, "size": 64, "opacity": 1, "blend": "normal" }`

- A tiled image over the layer's area. `image` is a PNG, JPEG, or SVG, stored and validated like an image layer's `image` (the Agent passes `image.path`; Node reads it into base64, the same narrow exception `image` already has). `size`: tile width in pt, 4–1024, height following the image's aspect ratio. `opacity`: 0–1. `blend`: `normal`, `multiply`, `screen`, `overlay`, or `softLight`.
- Rendering: the tile is decoded once and drawn tiled with the blend mode into the effect bitmap, clipped to the shape.

### Glass

`{ "type": "glass", "blur": 20, "tint": "#FFFFFF33", "saturation": 1.4, "highlight": 0.5 }`

- Frosted glass as one effect instead of four stacked ones: `blur` is the background blur radius in pt, 0–100; `tint` is drawn over the blurred backdrop (its alpha is the tint strength); `saturation`, 0–2, boosts the backdrop's colors the way system materials do; `highlight`, 0–1, is the opacity of a 1 pt light edge along the shape's top inner edge.
- Rendering: the backdrop is what lies beneath the layer inside its top-level frame. It is produced by **the same backdrop path #190 builds for background blur**, then saturated, blurred, tinted, and given the highlight, all in the effect function. Glass does not start until that path exists and is fast enough for background blur; if #190 ends up with a different backdrop strategy, Glass follows it.
- No refraction or edge distortion: that needs a displacement shader per frame of every backdrop change and is left for a later decision.

### Shader

`{ "type": "shader", "shader": "waves", "params": { "scale": 24, "colorA": "#FF6B6B", "colorB": "#4D96FF" }, "opacity": 1, "blend": "normal" }`

- **Only shaders that ship with Fudehand.** `shader` names one entry of a built-in catalog; each entry declares its parameters (name, kind `number` or `color`, range, default). `DesignJSON` validates `params` against the catalog, so a file or Agent cannot pass anything the catalog does not declare. The first catalog is three entries — **Waves**, **Mesh gradient** (four corner colors), and **Halftone** (dot size and angle) — chosen because shapes and fills cannot fake them.
- **No user-written shader code**, in the App, in files, or from the Agent. Arbitrary GPU code from a project file or a model can hang the GPU or the window server, is impossible to validate before running, and turns opening a file into running code. Sharing shader code is already a non-goal of #193; if custom code is ever wanted, it needs its own ADR (a sandboxed process with a GPU time limit, at least).
- **Rendering:** the shader sources are Metal Shading Language strings in `FudehandApp`, compiled at first use with `MTLDevice.makeLibrary(source:)` (the Command Line Tools have no offline `metal` compiler, and the sources are ours). A compute pass writes the effect bitmap at the layer's size × `contentsScale`, capped by `DesignRenderer.maximumRasterSide`, then it is clipped and blended like Texture. Shaders are **static**: no time input, so the canvas, snapshot, and prototype match and nothing redraws per frame. Animated shaders are a later, prototype-only option (ADR 0008's playback model).
- The Agent discovers the catalog with a new read-only tool, `design_list_shaders` (ids, names, parameters with kinds, ranges, and defaults), since the add menu shows it to people (ADR 0007).

### 3D transform (Beta)

`{ "type": "transform3d", "rotateX": 0, "rotateY": 20, "translateZ": 0 }`

- `rotateX` / `rotateY`: degrees, −80–80 (past that the layer turns edge-on and vanishes). `translateZ`: pt, −1000–1000. No `rotateZ`: the document has no 2D rotation (ADR 0006), and adding one belongs with rotation as a whole.
- About the layer's center (the renderer already anchors layers there, ADR 0008). Children are flattened into the layer's plane (CSS `transform-style: flat`); nesting 3D transforms does not compose a shared 3D space.
- Without a Perspective ancestor the projection is orthographic, as in CSS: a Y rotation narrows the layer without foreshortening.

### Perspective (Beta)

`{ "type": "perspective", "distance": 800, "originX": 0.5, "originY": 0.5 }`

- On a frame or group: its descendants' 3D transforms are seen from `distance` pt (100–10000) in front of the point `originX`, `originY` (fractions of the container's size). On the canvas it is the container layer's `sublayerTransform` with `m34 = −1 / distance`, shifted to the origin, which is what CSS `perspective` and `perspective-origin` mean.
- **Both Beta effects are visual only.** Layout, the `DesignIndex` rectangles, hit testing, snapping, selection boxes, and the layers panel use the untransformed rectangle: clicking where a rotated layer *looks* like it is may miss it. That is why they are Beta; fixing it means carrying a quad per layer through `DesignIndex` and `DesignHitTest`, which is deferred until people use them.
- **Snapshots** cannot use `render(in:)` for these layers. The snapshot renders the transformed layer's subtree flat into a bitmap, computes the four projected corners with the shared `FudehandCore` matrix, and draws the bitmap through a perspective warp (`CIPerspectiveTransform`) at that place. Because the corners come from the same matrix the canvas uses, the two agree to within resampling.
- **Prototype animations:** `LayerAnimationPlayer` animates `transform.scale` and `transform.rotation.z` key paths, which compose with a layer's base transform. Implementation must test a 3D-transformed layer with Scale In and Spin; if they fight, the 3D transform moves to a wrapper layer.

### Performance

- **Bitmaps are cached by `(effect parameters, layer size, contentsScale)`** on the layer's record in `DesignRenderer`. Moving a layer, panning, and selecting never re-render an effect. Zooming keeps the old bitmap during the gesture and re-renders once when the zoom commits, the same rule as text and SVG images (`CanvasViewport`).
- **While a layer is being resized** in a continuous gesture, its effect bitmaps are stretched and re-rendered once when the gesture ends; Glass re-renders its backdrop at most once per frame and only for layers whose backdrop changed.
- **Rendering runs off the main thread** for Shader and Glass (Metal / Core Image), and the old bitmap stays until the new one is ready. Noise and Texture are cheap enough to draw inline.
- **Gate:** `pnpm bench:native` gains a case with 10% of layers carrying a Noise, a Texture, a Shader, and a 3D transform; drag and hover frame times must stay within 10% of the same benchmark without effects.

### Agent, export, and UI

- Agents read and write all six through the existing `effects` field of `design_create_node` / `design_update_node` (as #190 adds it), plus `design_list_shaders`. Tests in `tests/control-tools.test.ts` and the Swift control tests; `docs/agent-tools.md` coverage rows.
- `DesignHTML` (HTML export, #213) maps Perspective to CSS `perspective` / `perspective-origin`, 3D transform to `transform: rotateX() rotateY() translateZ()`, and Glass to `backdrop-filter: blur() saturate()` with the tint as a background. Noise, Texture, and Shader cannot be drawn by `FudehandCore` (no AppKit there), so they are exported as an HTML comment listing the effect and its parameters; exporting them as images is a follow-up.
- **Add menu:** grouped as in the prototype — Inner shadow, Drop shadow, Layer blur, Background blur, Noise, Texture, Glass | Shader | 3D transform, Perspective — with a **Beta** tag on the last two. An effect that is not implemented yet is not in the menu; there are no disabled placeholders (#189's rule). Each effect row expands to its parameters as #190's rows do; a Shader row shows its catalog entry's parameters.
- `GLOSSARY.md` gains Noise, Texture, Glass, Shader (and shader catalog), 3D transform, and Perspective; all UI copy goes into the four `Localizable.strings` tables.

### Delivery order

Each effect is its own PR, after #190 lands and in this order: **Noise → Texture → 3D transform + Perspective → Glass → Shader**. Cheap, self-contained effects first; Glass waits for #190's backdrop; Shader is last because it brings Metal and a new tool. Each PR ships its effect end to end (model, canvas, snapshot, prototype, Agent, menu entry, glossary, strings, evidence).

## Rejected Alternatives

- **Live Core Image filters on `CALayer` (`filters`, `compositingFilter`, `backgroundFilters`)**: the cheapest canvas path, but `render(in:)` drops them, so snapshots and version snapshots would be wrong, and on macOS they need `layerUsesCoreImageFilters` on every hosting view.
- **Rendering snapshots by capturing the window** (`CGWindowListCreateImage` or `cacheDisplay`): only works for what is on screen, at screen scale, with the selection overlay on top; snapshots render frames that are off screen or at other scales.
- **User-written shader code** (Metal, Core Image Kernel Language, or a WebGL-like subset): see Shader. A built-in catalog covers the asked-for look with none of the risk.
- **Noise from a random generator per render**: grains would change on every redraw and differ between canvas and snapshot.
- **Texture as edge roughening (a displaced outline)**: needs a displacement pass over the layer's alpha on every change, for a look rarely used in UI design; a tiled image is what a designer usually means and is cheap.
- **3D transform carrying its own perspective**: two layers side by side would vanish toward different points; a shared Perspective on the container is how CSS works, which also makes HTML export a direct mapping.
- **Hit testing the projected quad now**: correct, but touches `DesignIndex`, `DesignHitTest`, snapping, and the overlay for a Beta effect; deferred.

## Consequences

- None of this starts until #190 is merged and this ADR is accepted; the parts that depend on #190's backdrop (Glass) may change with it.
- Effects cost memory: one bitmap per pixel effect per layer at the current zoom, capped by `maximumRasterSide`. A document with hundreds of large effect layers uses noticeably more memory than one without.
- Rotated and perspective layers are selected by their flat rectangle until hit testing learns quads.
- HTML export is lossy for Noise, Texture, and Shader until a follow-up exports them as images.
