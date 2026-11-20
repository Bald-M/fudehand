# Frame layout guides (#192)

## Intent

Layout inside a frame often aligns to a grid, columns, or rows. Figma's layout grids overlay these on a frame; Fudehand has
none and can only snap to other layers' edges. People and Agents both need to add, edit, hide, and remove guides on a frame,
see them on the canvas, and snap layers to the columns and rows.

## Goals

- A frame holds an ordered list of layout guides: `grid` (size), `columns` and `rows` (count, alignment, width, gutter,
  margin); each has a color and can be shown or hidden.
- The canvas overlay draws visible guides of visible frames, clipped by clipping ancestors; lines stay 1 screen point wide at
  every zoom. Snapshots, thumbnails, and prototype playback never show them (they are not part of the layer tree's rendering).
- Moving and resizing a layer snaps to the column and row edges of the parent frame's visible guides.
- The properties panel gets a "Layout Guides" section; every add, edit, show/hide, and removal is one undo step.
- Guides are saved in `.fudehand` (format version 8; versions 6 and 7 added version snapshots and annotations); older files open unchanged. Agents read and write them through
  `design_get_node` / `design_create_node` / `design_update_node` as the `layoutGuides` field.

## Non-goals

Canvas-level rulers and guides; named, reusable guide styles; the #189 inspector redesign (the section uses today's
inspector controls and moves with the redesign).

## Approaches

1. **A `layoutGuides` field on the frame node, validated by `DesignJSON`, drawn by `CanvasOverlay` (chosen).** Edits go
   through the existing node update path, so undo, saving, and Agent parity come for free; the overlay is already
   screen-space and absent from snapshots and playback.
2. A document-level guide table keyed by frame id. Needs its own undo plumbing, file section, and tool; guides would not
   move with duplicated or deleted frames. Rejected.
3. Drawing guides as CALayers in `DesignRenderer`. Lines would scale with zoom and would leak into snapshots unless
   special-cased. Rejected.

## Design

- **Model (FudehandCore).** `LayoutGuide { type: grid|columns|rows, size, count, align: stretch|start|center|end, width,
  gutter, margin, color, visible }` with Figma's defaults (grid 10; 5 stretched columns/rows, gutter 20, margin 0; width 60
  for non-stretched; color `#FF00001A`). `LayoutGuide.bands(length:)` gives the column/row spans along the frame's width or
  height; `gridLines(length:)` the grid line offsets. Stretch fills `length − 2·margin`; start/end place from the margin on
  that side; center centers the block and ignores the margin.
- **JSON.** `layoutGuides` (frames only) is an array replaced whole on update. Grid allows `type, size, color, visible`;
  columns and rows allow `type, count, align, width, gutter, margin, color, visible`, and `width` only when `align` is not
  `stretch`. Ranges: size ≥ 1, count an integer 1–1000, width ≥ 1, gutter and margin ≥ 0. Every field that applies to the type is
  written, so an Agent reading a frame sees each guide in full.
- **Index.** `DesignIndex` collects, in its single traversal, each visible frame (all ancestors visible) with at least one
  visible guide, its world rect, and its clip rect; the overlay and snapping read that list instead of walking the tree.
- **Overlay.** One shape layer per drawn guide (pooled): columns and rows filled with the guide color, grids stroked at 1
  point. A grid whose screen spacing is under 4 points is skipped, so zooming out does not fill the frame solid.
- **Snapping.** The interaction context adds the parent frame's visible column and row bands as snap rectangles (edges only,
  not centers). Resizing now snaps the dragged edges to the same targets as moving (siblings, parent, guide bands); ⌃
  turns it off, as for moving.
- **Inspector.** Section "Layout Guides" with a "+" in the title row (adds a 10-point grid). Each guide row: type icon, a
  summary button ("Grid 10", "5 columns", "5 rows") opening a popover with the type and its fields and color, an eye
  toggle, and a remove button.

## Left to the builder

Exact popover layout; localized copy in the four tables using `GLOSSARY.md` terms.
