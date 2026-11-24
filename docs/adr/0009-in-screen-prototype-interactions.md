# In-Screen Prototype Interactions Extend the Layer Fields and Stay in Playback State

2026-11-19 (#150). Building on [ADR 0007](0007-prototype-interactions.md), a prototype can now show what happens within a screen: frames scroll, layers have hover and pressed looks, interactions open and close overlays, and interactions show and hide layers.

## Decisions

- **Everything is a field of the layer**, as in ADR 0007: `scroll` (frames) and `fixedOnScroll`, `states {hover, pressed}`, and three more interaction actions — `open-overlay` (destination, `position`, `background`, `closeOnOutsideClick`, transition), `close-overlay`, and `toggle-visibility` (`targets`). The Agent sets them with `design_create_node` / `design_update_node`; there is no new tool. `states`, like `interaction`, is replaced whole on update.
- **Validation stays in `DesignJSON`**; whether a destination or a toggle target exists is checked for Agent edits only (`Prototype.checkDestinations`), and playback skips what a file still points at after it was deleted.
- **The project file format moves to version 4** (version 3 added layer animations, [ADR 0008](0008-layer-animations.md)). Older files open unchanged; a build that only knows version 3 refuses version 4 with its "newer version" message instead of failing on an unknown field.
- **Playback state is separate from the document.** Scroll offsets, open overlays, and toggled visibility live in `PrototypePlayer` for one playback; hover and press live in the prototype window. `Prototype.playback` turns a frame into the tree to render and hit-test — toggles applied, scrolled content offset, fixed layers moved above it, state looks applied — so rendering and click rules see the same layers. The design document and the editing canvas never change.
- **Overlays are top-level frames rendered into the same scene** as the frame on show, after a synthetic background rectangle, in one renderer; navigation transitions keep using the two renderers of ADR 0007. Only the topmost overlay takes input; navigating from it closes all overlays first, and Back closes the topmost one before it goes back.
- **The scope of states is fill and opacity**, with a fixed 0.15 s ease-out. That covers buttons, rows, and cards; more properties can be added to `LayerStyle` later without a format change in meaning.
- **Scrolling relies on the system's scroll events**: the trackpad's momentum phase gives inertia, and offsets are clamped to the content's extent (no rubber-band). The innermost scrolling frame that can still move along the gesture takes the scroll, so a horizontal carousel inside a vertical page works without any scroll linkage; only a mouse wheel, which turns vertically, is mapped onto a horizontal frame.

## Rejected Alternatives

- **Components and variants for states and tabs**: out of scope for #150; a visibility toggle on plain layers expresses tabs, switches, and expand/collapse. Main components and instances have since been added ([ADR 0014](0014-components-are-materialized-instances.md)), and a toggle inside an instance targets that instance's own layers; variants ([ADR 0015](0015-component-sets-store-variant-properties.md)) let an instance switch between versions of a component in the design, but do not switch by themselves in the prototype window.
- **A separate overlay window or layer stack outside the renderer**: two places to keep in sync with document edits and transitions; rendering overlays as part of the scene reuses the incremental renderer.
- **Saving toggled visibility into the document**: playback must never edit the design; a restart returns to the designed state.
- **Configurable state transition timing**: no request for it; a fixed short ease keeps the panel small.

## Consequences

- Toggle targets are layer ids, so duplicating a screen does not retarget its toggles to the copies.
- Layers fixed on scroll are reordered above the scrolled content only in playback; on the canvas they keep their stacking order.
- Drag and swipe gestures and nested scroll linkage remain out of scope. Layer animations ([ADR 0008](0008-layer-animations.md)) play on the frame on show; an overlay shows its layers as designed, without their animations or text sequences.
