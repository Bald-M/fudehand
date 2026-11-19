# Layer Animations and Text Sequences (#151)

## Intent

Clickable prototypes (#149) still look like a stack of screenshots: nothing moves unless it is clicked. Real apps have motion that
no click starts — content easing in, a spinning loader, a pulsing badge, a skeleton shimmer, a countdown ticking. This adds that
motion to prototype playback, as appearance only: it never changes the design document and never triggers anything.

The request was made in goal mode, so the calls below are the builder's own, recorded here for review.

## Goals

- A layer can have one **animation**: an entrance (fade in, slide in, scale in) or a loop (spin, pulse, shimmer), with duration,
  delay, easing, and repeat count (including infinite).
- A text layer can have a **text sequence**: a list of contents shown one after another at a fixed interval, looping or stopping
  on the last item — enough to look like a countdown.
- Both are saved in the project file, edited in the properties panel (undoable), and set by the Agent through the existing
  `design_create_node` / `design_update_node` tools.
- The prototype window plays them when a frame appears; the properties panel can preview the selected layer's animation without
  playing the prototype.

## Non-goals

As in the issue: real timers and logic, timelines and keyframe editing, click- or scroll-triggered animation, Smart Animate,
Lottie/GIF/video import or export, and static rotation, gradients, shadows, or vector paths in the document.

## Anti-goals

- The editing canvas never animates, and `design_snapshot` always shows the static state.
- Animation never writes to the document or the undo history while playing.
- Editing performance (`pnpm bench:native`) does not regress.

## Approaches

1. **A single `animation` field on the layer plus `text.sequence`, played by Core Animation** (chosen). Mirrors how `interaction`
   was added in #149: it moves, copies, and deletes with the layer, rides the existing patch path, and needs no new tool. Core
   Animation runs the motion off the main thread, so playback costs nothing per frame on the main thread.
2. **A list of animations per layer.** More expressive (fade in, then spin), but every editor and tool gets list handling for a
   case the issue does not ask for. It can be added later by accepting an array without breaking single-object files.
3. **A document-level timeline** (`[{layer, animation}]`). Rejected for the same reason ADR 0007 rejected document-level links:
   every layer edit would have to keep it consistent.

## Design

### Model (FudehandCore)

`DesignNode.animation: LayerAnimation?`

| Field | Values | Default |
|---|---|---|
| `type` | `fade-in`, `slide-in`, `scale-in` (entrance); `spin`, `pulse`, `shimmer` (loop) | required |
| `from` | `left`, `right`, `top`, `bottom` — `slide-in` only: the side the layer comes in from | `bottom` |
| `distance` | pt, 0–10000 — `slide-in` only | 40 |
| `property` | `scale`, `opacity` — `pulse` only | `scale` |
| `duration` | seconds, > 0 and ≤ 60; one cycle for a loop | 0.3 entrance, 1 spin/pulse, 1.5 shimmer |
| `delay` | seconds, 0–60 | 0 |
| `easing` | `linear`, `ease-in`, `ease-out`, `ease-in-out` | `ease-out` entrance, `linear` spin/shimmer, `ease-in-out` pulse |
| `repeat` | integer 1–1000, or `"infinite"` | 1 entrance, `"infinite"` loop |

What each type does (builder's call): fade in = opacity 0 → the layer's opacity; slide in = offset by `distance` from `from`, plus a
fade; scale in = scale 0.8 → 1 about the center, plus a fade; spin = one full clockwise turn per cycle about the center; pulse =
scale 1 → 1.1 → 1, or opacity 1 → 0.4 → 1; shimmer = a lighter band sweeping left to right across the layer (a moving gradient
mask, so it respects the layer's shape and its children). Fields that do not belong to the type are rejected, like `transition`
fields on `back`. An update replaces `animation` whole.

`DesignText.sequence: TextSequence?` — `{items: [string] (1–1000), interval: seconds 0.05–3600 (default 1), loop: bool (default false)}`.
Item *i* shows from *i × interval*; after the last item a looping sequence starts over, otherwise the last item stays. The
layer's `content` is what the canvas, layout outside playback, and snapshots show. `text` is still merged field by field on
update; `sequence` inside it is replaced whole.

Validation lives only in `DesignJSON`. Format version 3; versions 1 and 2 open unchanged.

`LayerAnimation` timing helpers and `TextSequence.index(at:)` are pure functions tested in Core. A Core function substitutes
each sequence's current item into a frame, so the App can run `DesignLayout` on it: each item keeps the layer's text style and
auto-size rules, and an auto layout parent re-flows around it.

### Rendering (FudehandApp)

- `DesignRenderer` layers move from a top-left anchor to a centered anchor (position = center). Nothing else in the renderer
  changes; this is what lets rotation and scale happen about the center without a static rotation field in the document.
- A new `LayerAnimationPlayer` attaches Core Animation animations to a renderer's layers for every visible animated layer in a
  subtree, starting at a given media time with `fillMode = .backwards`, so an entrance layer waits in its starting state during
  its delay and during the frame's transition. It ticks text sequences with a timer only when the subtree has any, re-laying out
  the frame and syncing the renderer only when an index changes. `stop()` removes everything it added.
- **Prototype window**: when a frame appears (playback start, or a navigate/back step), its renderer's animations restart, with
  entrances beginning when the transition ends. The renderer that is left stops when its transition finishes. Edits during
  playback re-render the frame without restarting animations.
- **Preview**: the properties panel's Animation section has *Preview*, which opens a popover rendering the selected layer (and its
  children) scaled to fit, playing its animation and text sequence, with *Replay*. The canvas stays still.

### Properties panel

An *Animation* section (all layers): *Add Animation* adds a fade in; then *Type*, the type's own fields, *Duration*, *Delay*,
*Easing*, *Repeat* (a count field plus a *Forever* toggle), *Preview*, *Remove Animation*. Text layers get a *Text Sequence* part
in the Text section: items one per line, *Interval (s)*, *Loop*, *Remove*. Every change is one undo step.

### Agent

`NODE_GUIDE` documents `animation` and `text.sequence`; `design_update_node` says animation is replaced whole. Previewing an
animation is a visual UI affordance and is listed as Missing in `docs/agent-tools.md`, like playing the prototype.

### Docs

ADR 0008 (animation model, centered anchor instead of a rotation field, single animation), `docs/macos.md` start/stop/preview
rules, `GLOSSARY.md` terms (Animation, Entrance, Loop, Text sequence), `CHANGELOG.md`, four `Localizable.strings`, light and dark
evidence in `docs/evidence/`.

## Left to the builder

Exact control layout, the preview popover size, and the shimmer band's width and strength.

## Dependency note

Overlays (#150) are being built in parallel. The player is a reusable "start animations for this subtree" call, so when overlays
land, opening one calls it for the overlay's frame.
