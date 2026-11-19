# Icon Layers Store a Name; Four Icon Libraries Are Built In

2026-11-19 (#155). Icons are among the most used elements in a prototype, and until now neither a person nor an Agent had any: the Agent drew colored boxes or words where icons belong, and a person had to import an image, which cannot be recolored or swapped and blurs when zoomed. Fudehand now has an **icon layer** and four built-in **icon libraries**, one per target platform. The design is in [the spec](../superpowers/specs/2026-11-19-icon-layer-design.md).

## Decisions

- **The document stores only the icon name and color.** An icon layer has `icon: { name: "<library>/<name>", color }`; its size is the layer's width and height, and the icon is drawn aspect-fit and centered in it. The artwork comes from the library when the layer is drawn, so an icon can be recolored or swapped at any time and project files stay small. The project file format moves to version 5; versions 1–4 open unchanged.
- **Four libraries, addressed by id:** `sf` (SF Symbols, asked of the system by name and not bundled), `material-outlined`, `material-rounded`, `material-sharp` (Material Symbols at weight 400; fill variants are `<name>.fill`), `weui` (the 27 WeUI icons), and `lucide` (Lucide). A prototype for Apple platforms, Android, a WeChat mini program, or the web uses that platform's own icons.
- **Bundled libraries ship as compressed SVG data.** `scripts/build-icons.mjs` (`pnpm build:icons`) extracts each icon's SVG from the pinned npm packages (dev dependencies), reduces it to its drawing, and writes one raw-DEFLATE JSON file per library into `FudehandCore/Resources/Icons` (about 2.6 MB in all), together with `LICENSES.txt`. The outputs are committed, so building the App needs no network; the script runs again only to update a library.
- **One rendering path for every library.** `IconLayer` draws the icon's shape — an SVG from the bundle, or an SF Symbol from `NSImage(systemSymbolName:)` — into a bitmap at the layer's size × zoom and tints it with the icon color. It is drawn again when the zoom settles or the layer grows, as SVG images are, so it stays sharp at any zoom. The tint is drawn into the bitmap rather than applied as a mask because `CALayer.render(in:)`, which snapshots use, ignores masks.
- **Name validity depends on the Mac, so it is checked in two places.** `DesignJSON` checks only the name's form (a known library id and a non-empty name), for files and Agent edits alike. Whether the icon exists is checked when an Agent creates a layer or sets an icon name: an unknown name is an error that lists up to five similar names, and nothing changes. A project file naming an icon this Mac lacks — say an SF Symbol from a newer macOS — still opens, and the layer draws a gray placeholder.
- **Search lives in the App.** `IconCatalog` (`FudehandCore`) loads a library on first use and ranks matches by exact name, name prefix, name substring, every word of the query in the name, and then every word in the name or the icon's keywords (Lucide's tags and the system's SF Symbol keywords); case and the separators libraries use (space, `-`, `_`, `.`) are ignored, so `shopping cart` finds `shopping-cart` and `shopping_cart`. The Agent searches with `design_search_icons`. SF Symbol names and keywords come from the system's `CoreGlyphs.bundle/Contents/Resources/name_availability.plist` and `symbol_search.plist`, which are not a documented API: if they move, SF Symbols still draw and validate by name but no longer appear in search.
- **SF Symbols keep an optical margin.** A symbol's image is only its glyph bounds, while the bundled libraries draw on padded artboards, so a symbol is drawn at a point size of 3/4 of the layer's shorter side rather than fitted edge to edge; icons from different libraries in same-size layers then look the same size.

## Licenses

- Lucide (`lucide-static`): ISC, with the icons derived from Feather under MIT. Material Symbols (`@material-symbols/svg-400`): Apache License 2.0. WeUI (`weui`): MIT. Each allows redistribution with its notice; the full texts ship in the App as `LICENSES.txt` in `FudehandCore`'s resource bundle.
- SF Symbols are governed by Apple's license: they may be used only in mockups of apps for Apple platforms, and may not be bundled, modified, or used in other products' interfaces. Fudehand does not bundle them — the system draws them — and does not enforce these terms; the `design_search_icons` description tells Agents about them.

## Rejected Alternatives

- **Bundle icon fonts and draw glyphs with CoreText**: smaller and natively vector, but WeUI has no font and SF Symbols needs its own path, which makes three rendering paths, plus name-to-glyph lookup through ligature tables.
- **Store the SVG in the document, as an image layer does**: the icon could not be recolored or swapped, and every file would carry the artwork.
- **Use a `mask` layer to tint the icon**: simplest on screen, but snapshots would show nothing.
- **Validate icon existence in `DesignJSON`**: a file would fail to open on a Mac whose SF Symbols are older than the one that saved it.

## Consequences

- A person sees icon layers in the layers panel and changes their color in the properties panel; a panel to search and insert icons comes later.
- Icons are single-color. Multicolor or hierarchical SF Symbol rendering, variable weights, user-imported libraries, and a general vector path layer are out of scope.
- Updating a bundled library is a dependency bump plus `pnpm build:icons`; pnpm's minimum release age applies to the new version.
