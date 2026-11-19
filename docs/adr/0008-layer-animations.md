# Layer Animations Are Playback-Only Fields Played by Core Animation

2026-11-19 (#151). Prototype frames can now move on their own: a layer can have an entrance or loop animation, and a text layer a text sequence that looks like a countdown. Both play only in the prototype window and the properties panel's preview.

## Decisions

- **One `animation` field per layer, and `text.sequence` on text**, like `interaction` in [ADR 0007](0007-prototype-interactions.md): they move, copy, and delete with the layer, ride the partial-update path (both replaced whole), and the Agent sets them with the existing node tools. Validation is in `DesignJSON` only; fields that do not belong to the animation's type are refused.
- **A single animation, not a list.** The asked-for effects each need one; combining an entrance with a loop can come later by also accepting an array, without breaking files that hold one object.
- **Appearance only.** Playback never writes to the document or the undo history. The canvas, snapshots, and layout outside playback use the static fields; a text sequence's items replace the text only in what the prototype window and the preview render, after running the layout again so auto-sized text and auto layout parents fit.
- **Core Animation runs it.** `LayerAnimationPlayer` adds `CAAnimation`s to the renderer's layers (begin time plus `fillMode = .backwards`, so entrances wait in their starting state through the delay and the incoming transition). Only text sequences need the main thread, and only when an item changes. The editing canvas never creates a player, so editing performance is unchanged.
- **Layers are anchored at their center instead of a static rotation field.** The renderer used a top-left anchor; it now positions each layer by its center, which lets Spin and Scale In turn and scale about the center through Core Animation key paths. ADR 0006's limit stands: the document has no rotation.
- **Shimmer is a moving gradient mask.** The document has no gradients; the mask exists only while playing, keeps the layer's shape, and covers its children, which is what a skeleton placeholder needs.
- **The project file format moves to version 3.** Versions 1 and 2 open unchanged; older builds refuse version 3 with their "newer version" message instead of failing on unknown fields.

## Rejected Alternatives

- **A list of animations per layer** — more editing UI and tool surface than the issue needs.
- **A document-level timeline** — every layer edit would have to keep it consistent (the same reason ADR 0007 rejected document-level links).
- **Rotating with keyframed transforms around a top-left anchor** — Core Animation interpolates matrices, so the center wobbles between keyframes.
- **Driving animation from a per-frame timer** — would cost main-thread time every frame and fight with the renderer's syncs.

## Consequences

- Animations start when a frame appears; click- or scroll-triggered animation, real timers, and Smart Animate remain out of scope.
- When overlays (#150) land, opening one starts the player for the overlay's frame the same way.
- Animations are set up when their frame appears: an animation edited during playback, or one that depends on a layer's opacity or size (fades, Pulse, Shimmer), plays as edited the next time the frame appears; a layer that changes type gets a new Core Animation layer and stops animating until then.
