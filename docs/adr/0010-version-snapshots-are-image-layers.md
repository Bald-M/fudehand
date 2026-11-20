# Version Snapshots Are Image Layers With a Snapshot Record

2026-11-20 (#20). A person or an Agent can save a *version snapshot* of a frame: the frame as it looks now, rendered into a read-only picture placed beside it on the canvas, so the old and new versions can be compared side by side or overlaid. This replaces the original plan for #20, which was built on the web frames and `frame_snapshot` that [ADR 0006](0006-native-design-document.md) removed.

## Decisions

- **A version snapshot is an ordinary image layer** with one more field, `versionSnapshot {frame, createdAt, note}`: the id of the frame it was taken of, the time in ISO 8601 (UTC, whole seconds), and an optional note. The picture is the layer's `image.data`, a PNG rendered by `DesignRenderer.snapshotPNG` at scale 2, with its longest side capped at 8192 pixels like other bitmaps on the canvas (a larger frame renders at a lower scale), with `fit: stretch`. *Replace Image…* is not offered for a snapshot. Being a layer, it is drawn, hit-tested, moved, saved, undone, listed in the layers panel, and deleted by the code that already exists; nothing on the canvas special-cases it.
- **Saving a snapshot is one undoable edit** that inserts a top-level layer named "<frame name> Snapshot", the frame's size, placed `VersionSnapshot.gap` (40 pt) to the right of the frame and of the snapshots already taken of it, top-aligned with the frame. Only frames can be snapshotted; a nested frame's snapshot goes to the right of its top-level frame, level with the nested frame, so it never covers the screen.
- **Comparison uses existing layer fields.** *Overlay on Frame* moves the snapshot to the frame's position at 50% opacity, and *Place Beside Frame* puts it back to the right at full opacity; the opacity slider then adjusts the overlay. Both are one undoable position-and-opacity edit, which the Agent makes with `design_update_node` using the bounds that `design_list_version_snapshots` returns.
- **The snapshot is not tied to the frame's lifetime.** Deleting the frame keeps its snapshots (the properties panel shows the frame as deleted); editing the frame never changes them.
- **Entry points**: *Canvas → Save Version Snapshot* (⌥⌘S) with one frame selected, and the *Version Snapshots* section of a frame's properties, which also lists that frame's snapshots and selects one when chosen. The Agent has `design_save_version_snapshot` and `design_list_version_snapshots`, served by the same store method as the menu ([ADR 0007](0007-agent-parity.md)); the note is changed with `design_update_node` (`versionSnapshot.note`), and a snapshot is deleted with `design_delete_nodes`.
- **The project file format moves to version 6.** Older files open unchanged. A build that only knows version 5 would fail on the unknown `versionSnapshot` field, so it now refuses the file with its "newer version" message instead.

## File Size and Cleanup

A snapshot is stored in the project file as base64 PNG, about a third larger than the PNG itself. A 390 × 844 phone frame at scale 2 is 780 × 1688 pixels: tens of kilobytes for flat designs, up to a few megabytes for photo-heavy ones. Nothing is cleaned up automatically; snapshots are deleted like any other layer, and `design_list_version_snapshots` shows what is there.

## Rejected Alternatives

- **A separate list of snapshot records in the document, outside the layer tree**: it would need its own rendering, hit-testing, selection, moving, layers-panel rows, and undo handling, all of which an image layer already has. The only thing a layer cannot express is the link to the frame and the time, which the `versionSnapshot` field adds.
- **Saving the frame's layer tree instead of a picture**: an editable old version is a non-goal of #20 (duplicating the frame does that), and a copy of the tree would be edited, searched, and laid out like real content.
- **Storing the PNG in a sidecar file next to the project file**: a `.fudehand` file is a single self-contained JSON document; a sidecar would break moving, sharing, and opening the file from an Agent.
- **A dedicated overlay mode on the canvas**: a canvas state to enter and leave, kept outside the document; laying the layer over the frame with the opacity slider gives the same comparison and is saved and undoable.

## Consequences

- Project files with snapshots grow with every snapshot; a person removes the ones they no longer need.
- A snapshot is a picture: it does not follow later edits, is not part of the prototype (only top-level frames are screens), and shows fonts and icons as they were drawn on the Mac that saved it.
- Automatic or timed snapshots, version history of the whole document, and persisting the undo history remain out of scope.
