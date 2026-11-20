# Annotations Live in the Design Document and Share Its Undo History

2026-11-20 (#19). Review notes and design rationale had nowhere to go on the canvas: they were written in a chat conversation or elsewhere, could not point at a frame, a layer, or a spot inside one, and were not saved with the project file. Fudehand now has **annotations**: plain-text notes pinned to a point inside a layer, each with a thread of replies, that people and Agents read and write.

## Decisions

- **Annotations are stored in the project file, beside the layer tree.** `DesignDocument` gains `annotations`, written as a top-level `annotations` array in the `.fudehand` JSON and left out when empty. The format moves to version 7; versions 1–6 open with no annotations. Each annotation has `id`, `node` (the layer it is pinned to), `x` and `y` relative to the layer's top-left corner in pt, `author` (`person` or `agent`), `text`, and `replies` (`id`, `author`, `text`). `DesignAnnotation.from` validates them when a file opens, and a file whose annotation names a missing layer or repeats an id is refused with the reason, like other malformed files.
- **Annotations are not layers.** They are drawn by `CanvasOverlay` above everything else, so they never appear in the layers panel, in `design_get_document`, or in `design_snapshot`, and they are hit-tested before resize handles and layers.
- **The anchor is relative to the layer.** An annotation follows its layer when the layer moves, is reparented, or the canvas pans and zooms. When the layer shrinks, the marker is kept inside the layer's rectangle; the stored point does not change, so growing the layer back restores it.
- **Deleting a layer deletes the annotations on it and on its descendants, in the same undo step.** `DesignEditor` drops annotations whose layer no longer exists after every edit, so every path that removes layers (delete, ungroup, and whatever comes later) is covered in one place, and undo brings them back with the layer. A hidden layer's annotations are hidden with it.
- **Annotation edits go into the shared undo history.** Adding, replying, editing, and deleting are each one step; an Agent's are named `Agent: Add Annotation` and so on. They also make the document dirty. This keeps "the App owns one document with one history" (ADR 0006) without exceptions, and an Agent can undo its own notes like any other edit.
- **One path for people and Agents.** The canvas popover and the control channel both call the same `FudehandStore` methods (`addAnnotation`, `replyToAnnotation`, `updateAnnotation`, `deleteAnnotation`). Text is trimmed and must not be empty; that check, like every field check, is in Swift only. The Agent tools are `design_list_annotations`, `design_add_annotation` (with `replyTo` for a reply, per `docs/agent-tools.md` §5.2), `design_update_annotation`, and `design_delete_annotation`.
- **A new annotation is not added until it has text.** The Annotate tool opens an empty thread (a draft) at the clicked point; collapsing it without submitting adds nothing, so there are no empty annotations and no undo step for an abandoned note.

## Rejected Alternatives

- **A separate file next to the project file**: annotations would be lost when the `.fudehand` file is copied, sent, or renamed on its own, the App would have to keep two files in step, and an unsaved document would have nowhere to keep them.
- **Keep annotation edits out of the undo history**: ⌘Z after writing a note would undo the layer edit before it, which surprises people, and "the document changed but undo does not see it" contradicts ADR 0006. Notes being undoable costs nothing that matters.
- **Store the anchor as a fraction of the layer's size**: the marker would slide across the content whenever the layer is resized, and Agents reason in points everywhere else.
- **Make annotations a layer type**: they would show in the layers panel and snapshots, take part in auto layout and hit testing, and could be nested or styled, all of which is wrong for a note.
- **Keep orphaned annotations when their layer is deleted**: they would have no position to draw at, and a later layer could never reclaim them meaningfully.

## Consequences

- Moving a marker to another point or layer, resolving threads, assignment, rich text, attachments, multi-user sync, and exporting annotations are out of scope (#19 non-goals); an Agent that needs to move a note deletes it and adds it again.
- The format version is 7; an older Fudehand refuses a file that contains annotations with the usual "created by a newer version" message.
