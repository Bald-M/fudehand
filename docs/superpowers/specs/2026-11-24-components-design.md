# Components and instances (step 1 of #256)

Issue: [#256](https://github.com/Bald-M/fudehand/issues/256). Step 1 delivers main components, instances, and overrides within one design document. Step 2 (variants) gets its own design once step 1 has landed.

## Intent

A part that repeats across screens — a header, a tab bar, a button — is made once and reused, and every use stays the same as the original. Today the only reuse is copy and paste, and copies have no link to their original: changing the header means finding and editing every copy, and copies drift. With components, a person or an Agent edits the main component once and every instance follows, while each instance can still change its own text, colors, and visibility.

## Goals

- Turn a layer into a **main component**.
- Place **instances** of it anywhere in the same design document.
- An edit to the main component (its properties, its children's properties, children added, removed, or reordered) reaches every instance at once, live during a drag, as part of the same undo step.
- An instance's own edits to its layers' properties are **overrides**: they survive later edits to the main component. Properties not overridden keep following it.
- Reset overrides; detach an instance into plain layers.
- Saved in the project file; older files open unchanged.
- Every feature has an Agent tool (ADR 0007).

## Non-goals

- Variants and component sets (step 2). The format below leaves room for them: a component set will group main components; nothing in step 1 assumes a component stands alone forever.
- Components shared between project files, libraries, publishing.
- Adding, removing, or reordering layers inside an instance.
- Keeping component structure in HTML export (instances export as the layers they are).
- Design tokens or named styles.

## Anti-goals

- Slowing down documents without components: opening, dragging, and editing large documents must stay as fast as today (`pnpm bench:native`).
- A project file that fails to open because of a component reference.

## Approaches

1. **Materialized instances (chosen).** An instance is an ordinary subtree of layers in the document, with ids of its own, that also records which main component it comes from; each layer in it records the layer of the main component it mirrors and which of its properties are overridden. After every edit, the editor brings affected instances up to date with their main components. Rendering, the layer index, hit testing, layout, snapshots, the prototype window, and HTML export see ordinary layers and do not change. The cost is that propagation must be correct and cheap on every edit, and the file stores each instance's layers in full.
2. **Virtual instances.** An instance stores only its main component's id and its overrides, and everything that reads the tree (renderer, `DesignIndex`, hit testing, layout, snapshots, prototype, HTML export, Agent reads) expands it on the fly. Smaller files, but every one of those subsystems changes, and ids of layers inside an instance must be invented and kept stable for selection and annotations.
3. **Linked copies.** Copy and paste records the original; a "push changes" command rewrites copies on request. Cheap, but changes do not reach instances on their own, which is the point of the feature.

Approach 1 is chosen because the App already treats the document as a tree of concrete layers everywhere (ADR 0006), so only the editor and the panels learn about components.

## Model

### Terms (to add to `GLOSSARY.md`, with Simplified and Traditional Chinese names)

- **Main component (主组件 / 主元件)**: a layer marked as the source of instances. It is edited like any layer.
- **Instance (实例 / 實例)**: a layer whose content mirrors a main component, placed anywhere in the same design document.
- **Override (覆盖 / 覆寫)**: a property of a layer inside an instance (the instance itself included) that the instance changed, so it no longer follows the main component.
- **Detach instance (分离实例 / 中斷實例連結)**: turning an instance into ordinary layers.

The "component (组件)" entry in _Avoid_ under *Icon name*, the "variant" note under *State*, and the same note in ADR 0009 are rewritten: components are in scope; variants come with step 2.

### Fields on `DesignNode`

- `component: Bool` — set on a main component.
- `instance: String?` — on an instance's root layer: the id of its main component.
- `source: String?` — on every layer inside an instance, the root included: the id of the layer in the main component it mirrors. The root's source is the main component itself.
- `overrides: Set<String>` — on layers inside an instance: the overridden properties, as property paths (below).

Rules, checked in `DesignJSON`/`DesignDocument` validation, so they hold for files and Agent edits alike:

- A main component is not inside another main component, is not an instance, and is not inside an instance.
- An instance is not inside its own main component, directly or through nested instances (no cycles). Instances of other components may sit inside a main component (a header containing button instances); they propagate in turn.
- `source` and `overrides` appear only inside an instance; `instance` only on an instance root.

### Property paths

An override is a path in the layer's JSON form: a top-level key (`fill`, `visible`, `opacity`, `name`, `width`, `effects`, …), or `key.field` for the nested objects `DesignJSON.nestedKeys` merges field by field (`text.content`, `text.color`, `stroke.width`, `layout.spacing`, `sizing.horizontal`, `icon.name`, …). Overriding `text.content` keeps the font following the main component. `id`, `type`, `children`, and the component fields themselves are never overridable. The root's `x` and `y` always belong to the instance and are never synced or recorded as overrides.

### Format

`formatVersion` 10. On disk: `"component": true`, `"instance": "<id>"`, `"source": "<id>"`, `"overrides": ["fill", "text.content"]`, each written only when set. Files of version 9 and older open unchanged.

No component reference makes a file fail to open. On open, an instance loads as detached layers (its `instance`, `source`, and `overrides` dropped, nested instances of other components kept) when its main component is missing or not a main component, when it would form a cycle, or when its layers do not match its main component one to one (a `source` naming no layer of the main component, or two layers with the same `source`). Every other instance is then fully synced from its main component, so values that differ but are not overrides follow the main component, as they would after the next edit. Paste repairs the same way. Other broken rules (`component` inside an instance, `source` outside one) are load errors like other invalid fields.

## Behavior

### Propagation (`ComponentSync`, `FudehandCore`)

`ComponentSync.reconcile(old:new:)` runs inside `DesignEditor.perform` and `applyLive`, after the change and before annotation pruning and layout, so the main component's edit and its effect on instances are one undo step and appear on the canvas in the same frame. Undo and redo restore whole documents and need no reconcile.

1. **Record overrides.** For each layer inside an instance that the change edited, the properties that changed become overrides, unless the new value equals the main component's (new) value, in which case the override is removed. This is how edits from the canvas, the properties panel, and `design_update_node` all become overrides without each path knowing about components. `design_replace_color` over a whole document therefore changes the main component and leaves instances following it rather than overriding them.
2. **Sync instances.** For each main component whose subtree changed (or whose nested instances changed), every instance of it is rebuilt from it: each instance layer takes every property of its source layer except its id, its overrides, and (for the root) `x`/`y`; children are matched by `source`; a layer new in the main component gets a new layer with a fresh id; a layer gone from the main component is removed from the instance (its annotations go with it, as for any deleted layer); order follows the main component. Components are processed so that one containing instances of another is synced after it.
3. **No components, no work.** Unchanged subtrees are skipped by comparing old and new nodes, which is cheap because unchanged arrays share storage. A document without components must not do measurable extra work per edit.

Layout runs after reconcile, so an instance's auto layout and text sizes are computed for its own content.

### Nested instances

Main component A may contain an instance of B. Every instance of A then holds a copy of that nested instance; its root carries `instance: B` and `source: <the nested instance in A>`.

- **Sync goes through the nearest main component.** Every layer syncs from its `source`, which is always a layer in the main component of the instance it sits in directly: the copy inside an A instance follows A's nested instance, which follows B. When B changes, B's instances are synced first (including the one inside A), then A's instances. Overrides are kept at each level: A's nested instance can override B, and an A instance can override that again.
- **Reset Overrides** on a layer in the copy goes back to the value in A (its source), not to B.
- **Detaching an A instance** keeps its nested copies as instances of B: their `source` is rewritten to the matching layer in B, and their `overrides` are recomputed as the properties whose values differ from B's.
- **Counts** (`design_list_components`, the properties panel's instance count) count every layer whose `instance` is the component, nested copies included.

### References inside a component

Interactions that name layers by id (toggle-visibility targets) and point inside the main component are rewritten in each instance to the matching layers of that instance, so an instance's button toggles its own layers. Targets outside the main component (frames to navigate to, overlays) are copied as they are. The override check compares after this rewriting, so rewritten targets are not overrides.

### Structure inside an instance

Inserting, deleting, moving, reordering, grouping, or pasting layers inside an instance (below its root) is refused: Agent tools return an error naming the instance; in the UI those commands are disabled and canvas drags do not reparent into or out of an instance. Changing properties (including position and size of layers inside it, and visibility) is allowed and becomes an override. The instance root itself is moved, resized, reparented, and deleted like any layer.

### Creating

- **Create Component** (Object menu / layers panel context menu, ⌥⌘K): marks the one selected layer as a main component. Allowed for any layer type that is not inside an instance or a main component and is not one.
- **Instances**: Copy then Paste, or Duplicate, of a main component in the same document creates an instance of it (with the clipboard's usual placement); copying an instance makes another instance of the same main component. Copying a layer that contains a main component pastes that main component as an instance as well (main components stay unique within a document).
- **Cut and Paste** of a main component in the same document moves it: it stays the main component, keeps its id, and its instances stay linked; the cut does not detach them. Until the paste, those instances keep pointing at the missing main component and are left as they are by sync; the paste brings the main component back under its id and they follow it again. A file saved in between opens with them detached, by the rule above. Delete (not Cut) still detaches at once.
- **Into another project file**: pasting a main component makes it a main component in that document (with a new id); pasting an instance whose main component is pasted with it links it to the pasted copy; pasting an instance alone pastes detached layers.
- **Insert Component** (bottom toolbar, beside Insert Icon): a popover listing the document's main components by name with a small preview, searchable; clicking one inserts an instance placed as an icon is placed (into the selected frame at its top-left, otherwise centered in the viewport), selects it, and is one undoable edit.

### Editing panels

- Layers panel: main components and instances get their own icons (SF Symbols, localized accessibility labels); layers inside an instance show overridden ones with a subtle marker.
- Properties panel, Design tab: a *Component* section. For a main component: its instance count and *Select Instances*. For an instance: the main component's name, *Go to Main Component* (selects and focuses it), *Reset All Overrides*, and *Detach Instance*. A property row that is overridden on the selected layer inside an instance shows a reset control for that property.
- Detach Instance clears `instance`, `source`, and `overrides` on the instance and its layers; nested instances of other components stay instances.

### Deleting

Deleting a main component detaches its instances in the same undo step (they keep their current look as ordinary layers). Undo restores both.

### Prototype, snapshots, export

Instances are ordinary layers to all of these. Interactions inside a main component are copied into instances like any property and can be overridden.

## Agent tools

Following `docs/agent-tools.md`: each forwards to a control command and calls the same store method as the UI; each document change is one step named `Agent: …`.

| Tool | Does | Returns |
|---|---|---|
| `design_create_component` (`id`) | Marks a layer as a main component | the layer |
| `design_create_instance` (`component`, `parent?`, `index?`, `x?`, `y?`) | Inserts an instance (placed as the UI places it when `x`/`y` are left out) | the instance |
| `design_list_components` | Main components with id, name, size, and instance ids | list |
| `design_reset_overrides` (`id`, `properties?`) | Clears overrides on a layer inside an instance (all of its layers when `id` is the root and `properties` is left out) | the layer |
| `design_detach_instance` (`ids`) | Detaches instances | the layers |

`design_get_node`/`design_get_document` show `component`, `instance`, `source`, and `overrides`; `design_create_node`/`design_update_node` reject setting them directly (the tools above are the only way). Structural tools (`design_create_node` with a parent inside an instance, `design_move_node`, `design_delete_nodes`, `design_paste`, `design_duplicate_nodes`) return the structure error described above. The coverage table gets a *Components* row.

## Verification

- `FudehandCoreTests`: JSON round trip and validation rules; dangling references load detached; reconcile (property propagation, overrides kept and removed, child added/removed/reordered, nested instances, cycle refused, replace-color case); one undo step; deleting a main component detaches; clipboard rules.
- `ControlProtocolTests`, `tests/control-tools.test.ts`, and `StoreTests` for each new tool.
- `LocalizationTests` and `AccessibilityTests` for the new UI.
- `pnpm bench:native` before and after: no regression on the existing documents (which have no components); add one benchmark of dragging a layer inside a main component with 50 instances.
- Real-app check in light and dark appearance; screenshots in `docs/evidence/`.
- A new ADR records the materialized-instance decision.

## Left to the builder

- Exact SF Symbols, the overridden-property marker's look, and the Insert Component popover's preview size.
- How reconcile finds changed subtrees and orders components, provided the performance anti-goal holds.
- Whether `overrides` is a `Set` or a sorted array in memory (sorted on disk).
