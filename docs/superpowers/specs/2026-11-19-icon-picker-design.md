# Icon Picker Design

Issue #156. Builds on the icon layer from #155 ([ADR 0008](../../adr/0008-icon-layer.md)).

## Intent

An Agent can already search the icon libraries and insert icons by name. A person has no way to: they can only recolor an icon
layer an Agent made. The icon picker lets a person find an icon by keyword, insert it on the canvas, and swap the icon of an
existing icon layer, without knowing icon names.

## Goals

- An Icon button on the bottom canvas toolbar opens the icon picker as a popover; its search field has focus, and Esc closes it.
- The picker switches between SF Symbols, Material Symbols (with a style menu: Outlined, Rounded, Sharp), WeUI, and Lucide.
- An empty search shows the whole library, sorted by name; a search shows `IconCatalog.search` results for that library; no
  results shows an empty state.
- Icons show in a lazily rendered grid, with thumbnails cached; the name shows on hover. Libraries of thousands of icons scroll
  and search without stalling.
- The SF Symbols library shows a one-line notice that the symbols may be used only in designs for Apple platforms.
- Clicking an icon inserts a 24 × 24 black icon layer named after the icon (the part after `<library>/`), placed like Insert
  Image: into the selected frame at its origin, otherwise centered in the viewport. The new layer is selected, the popover closes,
  and the insert is one undo step ("Insert Icon").
- The inspector's Icon section has a Replace button next to the icon name that opens the same picker, starting on the current
  icon's library. Choosing an icon changes only `icon.name`; position, size, and color stay. One undo step ("Replace Icon").

## Non-goals

The icon layer itself, the libraries, and the Agent tools (#155); favorites, recents, or custom categories; user-imported
libraries; dragging icons from the picker onto the canvas.

## Approaches

The picker's shape was set by the issue; the open question was how a person's insert relates to the Agent's. The chosen way
adds store methods `insertIcon(_:)` and `replaceIcon(_:)` for the UI and adds no Agent tool: an Agent already does the same with
`design_search_icons` plus `design_create_node` / `design_update_node`, as Insert Image maps to `design_create_node`. The
coverage table in `docs/agent-tools.md` records this. A new `design_insert_icon` tool was rejected as a variant of
`design_create_node` (agent-tools §5.2).

Closing the picker after an insert was chosen over keeping it open: every insert lands at the same place, so several in a row
would stack.

## Left to the builder

- `IconCatalog` gains a public way to list a library's names, sorted.
- Thumbnails are template images (SVG data via `NSImage(data:)`, SF Symbols via `NSImage(systemSymbolName:)`) tinted with the
  label color, so they read in light and dark appearance.
