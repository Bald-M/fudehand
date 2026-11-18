# Prototype Interactions Live on Layers and Play in Their Own Window

2026-11-19 (#149). A design document can now be played as a clickable prototype: a layer can have a click interaction that goes to a top-level frame or back, with a transition, and Play Prototype shows the frames in a separate prototype window. This is the base that screen-level interactions (#150) and layer animation (#151) build on.

## Decisions

- **The interaction is a field of the layer** (`interaction` on `DesignNode`), not a separate list of links in the document. It moves, copies, and deletes with its layer, rides the existing undo history and partial-update path, and the Agent sets it with the existing `design_create_node` / `design_update_node` tools; no new tool is needed. An update replaces the interaction whole rather than merging it, because its fields depend on its action (`back` has none).
- **Validation stays in `DesignJSON`**: the shape of an interaction is checked once, for file reading and Agent edits alike. Whether the destination is a top-level frame depends on the rest of the document, so it is checked separately: Agent edits are refused when it is not, while a project file may hold an interaction whose frame was deleted later — deleting a frame does not touch other layers — and playback simply ignores it. The properties panel offers top-level frames only and marks a missing one.
- **The project file format moves to version 2.** Version 1 files open unchanged and are written as version 2 on the next save; a Fudehand that only knows version 1 refuses version 2 files with its existing "newer version" message instead of dropping the interactions it does not understand.
- **Playback runs in a separate window**, not as a mode of the editing canvas. The canvas's input state machine stays about editing, and the prototype window reuses `DesignRenderer` with two renderers taking turns during a transition. The playback rules — start frame, which layer answers a click, history for Back — are in `FudehandCore` (`Prototype`, `PrototypePlayer`) and tested there.
- **The prototype window follows the document** instead of keeping a snapshot taken when playback started, so a designer (or the Agent) can fix a screen and see it at once. It renders the panels' copy of the document, which updates when an edit is committed, not on every frame of a drag.
- **Clicks during a transition are ignored**: a transition always plays to its end, and nothing is queued.

## Rejected Alternatives

- **Links stored at the document level** (`{from, to}` pairs): every layer edit — delete, move, duplicate, Agent subtree creation — would also need to keep the list consistent.
- **A dedicated `design_set_interaction` tool**: one more tool for the model to learn, and a second validation path beside `DesignJSON`.
- **Playing inside the editing canvas**: it would share the viewport, selection, and input handling with editing, and leaving playback would have to restore all of them.
- **Keeping interactions in a version-1 file**: older builds reject unknown fields, so such a file would fail to open with a confusing field error rather than the upgrade message.

## Consequences

- Only clicks trigger interactions, and only whole-frame navigation is supported; hover and press states, scrolling, overlays (#150), and layer animation (#151) are added on top of this model.
- The canvas does not draw connections between frames.
