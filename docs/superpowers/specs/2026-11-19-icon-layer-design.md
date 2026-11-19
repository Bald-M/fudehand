# Icon Layer Design

2026-11-19. Issue #155.

## Intent

When people and Agents draw prototypes for iOS/macOS, Android, WeChat mini programs, and the web, icons are among the most used elements, and today there are none: the Agent draws colored boxes or words where icons belong, and a person has to find an image and import it, which cannot be recolored or swapped and blurs when zoomed. This adds an **icon layer**: the document stores only the icon's name, color, and the layer's size; the canvas draws it as a vector, sharp at any zoom, and the icon can be recolored or swapped at any time. Four platform icon libraries are built in, so a prototype for a platform can use that platform's own icons by name.

## Goals

- A new layer type `icon` that saves, opens, renders, selects, moves, resizes, takes part in auto layout, and undoes like the other layers.
- Built-in icon libraries, addressed as `library/name`:

  | Library id | Source | How it ships |
  |---|---|---|
  | `sf` | SF Symbols (Apple) | Asked of the system by name; not bundled |
  | `material-outlined`, `material-rounded`, `material-sharp` | Material Symbols, weight 400, each with `-fill` variants named `<name>.fill` (e.g. `material-rounded/home.fill`) | Bundled |
  | `weui` | WeUI icons (WeChat), 27 icons | Bundled |
  | `lucide` | Lucide | Bundled |

- Agent: a tool that searches icons by keyword (and optionally library); `design_create_node` / `design_update_node` accept icon layers; an icon name that does not exist is an error that lists similar names, and nothing is created or changed.
- Person: the layers panel shows icon layers; the inspector edits the icon's color (size is the layer's width and height, already editable).
- `design_snapshot` shows icons.
- A file with an unknown icon name opens; that layer draws as a placeholder.

## Non-goals

- A panel for people to search and insert icons (a later issue).
- User-imported icon libraries.
- Multicolor, hierarchical, or variable-weight icons: icons are single-color.
- A general vector path layer or pen tool.
- Enforcing SF Symbols' license terms in the App.

## Anti-goals

- Storing icon artwork in the document (that is what the image layer already does badly for icons).
- Blurry icons when zoomed in, or icons missing from snapshots.
- Making a project file fail to open because an icon name is unknown on this machine (for example an SF Symbol from a newer macOS).

## Constraints

- `FudehandCore` has no AppKit dependency; SF Symbols lookups and drawing live in the App and are injected into Core where Core needs them (the same pattern as text measurement).
- One validation path for files and Agent edits (`DesignJSON`), per ADR 0006.
- Agent parity (ADR 0007): the search tool and icon layer fields ship with tests and a row in `docs/agent-tools.md`.
- No third-party Swift packages. Node packages may be dev dependencies.
- UI copy goes through `L()` in all four string tables; new terms go in `GLOSSARY.md`; the decision goes in an ADR (`docs/adr/0008-icon-layer.md`).
- Licenses (read in full on 2026-11-19): Lucide is ISC (plus MIT for the icons derived from Feather), Material Symbols is Apache-2.0, WeUI is MIT. All allow redistribution provided the notices ship with the copies. SF Symbols is governed by Apple's license: symbols may be used only in mockups of apps for Apple platforms and may not be bundled or modified; this is documented, not enforced.

## Approaches

1. **Bundle each library's icons as SVG data; render by rasterizing the shape and tinting it** (chosen). A script extracts SVGs from npm packages into one compressed JSON file per library in Core's resources. The canvas rasterizes the icon at layer size × zoom, reusing the tiered re-rasterization from #172, and tints it with the icon color. SF Symbols go through the same layer, with the shape supplied by `NSImage(systemSymbolName:)`. One rendering path for all libraries; snapshots and zoom work like image layers. Cost: about 3–4 MB of compressed data committed to the repository.
2. **Bundle icon fonts and draw glyphs with CoreText.** Smaller and natively vector, but WeUI has no font and SF Symbols needs its own path, so three rendering paths, plus name → glyph lookup through ligature tables. Rejected.
3. **Store the SVG in the document like an image layer.** Contradicts "the document stores only the name", and keeps the image layer's problems. Rejected.

The person picked approach 1 and chose to bundle all three Material styles.

## Design

### Document model

- `NodeType.icon`, default name `L("Icon")`, default size 24 × 24 when created without a size.
- New field `icon: { name: String, color: "#RRGGBB" }`. `name` is required; `color` defaults to `#000000`. Size is the layer's `width` and `height`; the icon is drawn centered and scaled to fit (keeping its aspect ratio) inside the layer's bounds.
- Generic fields (`opacity`, `visible`, `locked`, `fill`, `stroke`, `sizing`, `interaction`, `animation`) apply as for a rectangle; `animation` is allowed so icons can animate like other layers *(builder's call)*. `cornerRadius`, `children`, `layout`, `clipsContent`, `text`, `image` are not supported on an icon.
- `DesignJSON` validates the name's syntax in both files and Agent edits: `<library>/<name>` with a known library id and a non-empty name. It does **not** check that the icon exists, so a file with an unknown name still opens. `icon` is one of the nested objects merged field by field on update.
- The format version becomes 4 (icon layers; 3 is already taken by layer animations). Version 1–3 files open unchanged, and an older build shows its "created by a newer version" error for a file with icons. *(Builder's call.)*

### Icon catalog (Core)

- `IconCatalog` in `FudehandCore` loads a bundled library lazily on first use from `Resources/Icons/<library>.json.zlib` (raw DEFLATE, read with `NSData.decompressed(using: .zlib)`). Each file maps a name to its minimal SVG source and, for Lucide, its tags.
- SF Symbols: the App injects two functions into the catalog, one that says whether a symbol name exists and one that lists all names. The list is read from `/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist` (undocumented; if it is missing or unreadable, `sf` search returns nothing but existence checks still work through `NSImage(systemSymbolName:)`).
- `exists(name)` and `suggestions(for:)`: suggestions rank names in the same library first, by shared tokens, substring, and then edit distance; up to 5.
- `search(query, library?, limit)`: case-insensitive; ranks exact name, name prefix, name substring, then tag match; default limit 50; returns `[{ name: "library/name" }]`.

### Agent

- New tool `design_search_icons { query, library?, limit? }` → control command `search_icons`.
- `design_create_node` / `design_update_node` accept `type: "icon"` and `icon { name, color }`. In `ControlCommands`, after `DesignJSON` validation, every icon name created, or changed by an update, must exist; otherwise the command fails with `Unknown icon <name>; similar: a, b, c` and the document is untouched. An update that does not change the name of an icon layer with an unknown name (opened from a file) is allowed.
- Tool descriptions document the icon fields. The design guidance (`scripts/design-guidance.mjs`) adds: pick the library by the prototype's target platform (Apple → `sf`, Android → a `material-*` style, mini program → `weui`, web → `lucide`), search before using a name, and keep one library and style per screen.

### Rendering (App)

- `IconLayer` (a `CALayer` subclass, like `ImageLayer`): draws the shape at bounds × `contentsScale` into a bitmap and tints it with the icon color (draw the shape, then fill with the color using source-in compositing), stored in `contents`. It re-rasterizes when the name, color, or size changes, or when zoom settles, with the same tiered rule as SVG images. Tinting into `contents` rather than using a `mask` keeps `CALayer.render(in:)` snapshots working (it ignores masks). Snapshots flip the bitmap as image layers do.
- Bundled icons are drawn from their SVG source with `NSImage(data:)`; SF Symbols with `NSImage(systemSymbolName:)` configured to the pixel size. Lucide's stroked artwork renders through the same path because only the shape's alpha is used.
- Unknown icon name: the layer draws a placeholder — a light gray box with a diagonal line — at the layer's size.

### Person-facing UI

- Layers panel: icon layers show an icon-type glyph like the other types.
- Inspector: an Icon section shows the icon name (read only for now) and a color well; color changes go through the store as one undo step. Size uses the existing W/H fields.
- New UI copy (`Icon`, section labels) goes in all four string tables.

### Data build

- `scripts/build-icons.mjs` reads the dev dependencies `lucide-static@1.75.0`, `@material-symbols/svg-400@0.49.0`, `weui@2.6.26`, strips each SVG to a minimal form (drop comments, `class`, `width`/`height`, keep `viewBox` and the drawing attributes), and writes the compressed per-library files and `Resources/Icons/LICENSES.txt` with each library's license text and version. Material's `x-fill.svg` becomes `x.fill`; WeUI's CSS `mask-image` data URIs become `weui/<name>` with the `weui-icon-` prefix removed. The outputs are committed; the script is rerun only to update a library.
- `pnpm build:icons` runs the script.

### Docs

`GLOSSARY.md` (icon layer, icon library, icon name), `docs/adr/0008-icon-layer.md` (this decision, including the SF Symbols restriction), `docs/agent-tools.md` coverage row, `docs/macos.md` (icon layer behavior), README and CHANGELOG, evidence screenshots in light and dark in `docs/evidence/`.

## Left to the builder

- Exact placeholder drawing and the Layers panel glyph.
- Search ranking weights and tokenization details.
- How the catalog's injected SF Symbols functions are wired at App start.
