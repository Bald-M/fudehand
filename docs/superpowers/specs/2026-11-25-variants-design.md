# Variants and component sets (step 2 of #256)

Issue: [#256](https://github.com/Bald-M/fudehand/issues/256). Step 1 ([components spec](2026-11-24-components-design.md), [ADR 0014](../../adr/0014-components-are-materialized-instances.md)) delivered main components, instances, and overrides. This step adds variants, and fixes two small problems step 1 left with the *Reset Overrides* button.

## Intent

One component often comes in several versions: a button that is default, hovered, or disabled; a header that is light or dark, signed in or out. Today each version is an unrelated main component, so an instance cannot move from one to another without being replaced and losing its overrides. With variants, the versions live together in a **component set**, each described by property values (`State = Disabled, Size = Small`), and an instance switches between them in the properties panel, keeping the overrides that still apply.

## Goals

- Group main components into a component set; each one is a **variant**, described by a value for each of the set's **variant properties**.
- Add, rename, and remove variant properties; set a variant's values; add a variant to a set.
- Insert an instance of a component set (its first variant).
- Switch an instance to another variant of its set by choosing property values; overrides on layers that match carry over.
- Every feature has an Agent tool (ADR 0007).
- Saved in the project file; older files open unchanged.

## Non-goals

- Boolean, text, or instance-swap component properties (Figma's "component properties"); only variant properties.
- Variants shared between project files.
- Interactive components (variants switching by themselves in the prototype window).
- Special canvas drawing for component sets beyond what frames already draw.

## Anti-goals

- Losing overrides silently when a layer still matches after a switch.
- A file that fails to open because of a variant reference.
- Slowing down documents without components (the step 1 budget, about 2–3%, stays).

## Approaches

1. **Component set frame with stored property values (chosen).** A frame marked as a component set holds main components as its direct children; the set stores its property names in order, and each variant stores its values. Switching an instance re-points its root at another variant and rebuilds it with step 1's sync.
2. **Variants as override sets of one main component.** Cannot express variants that differ in structure (a disabled button with a lock icon).
3. **Property values encoded in layer names (`State=Hover, Size=Small`), as Figma does.** Renaming a layer breaks the variant, and every reader must parse names.

## Model

### Terms (to add to `GLOSSARY.md`)

- **Component set (组件集 / 元件集)**: a frame whose direct children are the variants of one component.
- **Variant (变体 / 變體)**: a main component inside a component set, described by a value for each variant property.
- **Variant property (变体属性 / 變體屬性)**: a named dimension of a component set, such as *State* or *Size*, with the values its variants use.

The *Avoid* notes added in step 1 ("variant, component set (a later step of #256)") and ADR 0014's "until variants exist" are rewritten.

### Fields

Stored in step 1's `ComponentFields` box, so layers outside components still pay nothing:

- `componentSet: [String]?` — on a component set: its variant property names, in display order (may be empty only while the set has no variants).
- `variant: [String: String]?` — on a variant: a value for each of its set's properties.

On disk: `"componentSet": ["State", "Size"]`, `"variant": {"State": "Disabled", "Size": "Small"}`, written only when set. `formatVersion` 11; files of version 10 and older open unchanged.

### Rules (validated on load and enforced on every edit)

- A component set is a frame, is not a main component or an instance, and is not inside a main component, an instance, or another component set.
- Every direct child of a component set is a main component with `variant`; `variant` appears only on direct children of a component set.
- A variant's keys are exactly its set's property names; values are non-empty strings; no two variants of a set have the same values.
- Property names in a set are unique and non-empty.
- A broken rule in a file is a load error, like other invalid fields, except that it never makes instances fail: instances of variants are ordinary instances of main components (step 1's repair still applies).

### Instances

An instance of a variant is an ordinary step 1 instance whose `instance` is the variant's id; nothing new is stored on it. Its set is the variant's parent. *Insert Component* and `design_create_instance` accept a component set id and use its first variant.

## Behavior

### Creating a component set

*Combine as Variants* (Edit menu and layers panel context menu): with two or more main components selected that share a parent and are not in a component set, wraps them in a new frame marked as a component set, placed at their union rectangle plus 16 points of padding on each side, keeping their canvas positions, named after the first one. It has one property, *Property 1* (localized, like default layer names), whose values are the components' names (made unique by appending " 2", " 3"). One undo step; the set is selected.

A single main component can also be combined, giving a set of one variant.

### Editing properties and variants

- In the properties panel, a selected component set shows *Variant Properties*: each property's name (editable), a remove button, and *Add Property*; plus *Add Variant*.
  - Adding a property gives every variant the value *Default* (localized).
  - Removing a property removes its value from every variant; when two variants would then have equal values, the removal is refused with an error naming them.
  - Renaming changes the key in every variant.
- *Add Variant* duplicates the selected variant (or the set's last one) inside the set, just after it, with the first property's value made unique (" 2", " 3"); it is a new main component with its own id.
- A selected variant shows its values as editable text fields, one per property; a value that would duplicate another variant's values is refused.
- Moving a layer into or out of a component set, or inserting a non-variant layer into one, is refused (structure error naming the set). Reordering variants inside the set is allowed. A main component pasted or duplicated into a set (or a variant duplicated) follows the *Add Variant* rule; any other layer is refused.
- Deleting a variant detaches its instances (step 1's rule). Deleting a component set deletes its variants and detaches all their instances. Detaching or deleting leaves the set valid; a set whose last variant is deleted stays as an empty component set, which the user can delete.

### Switching variants

- A selected instance of a variant shows, in its *Instance* section, one pop-up per variant property listing the values its set's variants use, with the current value chosen.
- Choosing a value switches to the variant whose values equal the instance's current values with that one changed. If no variant has exactly those values, it switches to the variant with that value that shares the most other values with the current one (ties: the first in set order).
- Switching keeps the instance's id, position, and root overrides, and for each layer below the root finds the layer in the new variant with the same **name path** (the names from the root down, matched in order among same-named siblings). A matched layer keeps its id, annotations, and overrides; an unmatched layer is removed with its annotations; a layer new in the target variant is added with a fresh id. Overrides whose property does not exist on the new layer (for example `text.content` on a layer that is no longer text) are dropped.
- Switching is one undo step and applies to every selected instance at once (each switches by its own current values).

### Panels and picker

- Layers panel: a component set gets its own icon (accessibility label *Component Set*).
- *Insert Component* lists component sets as one entry each (named after the set, previewing its first variant) and standalone main components; variants are not listed separately.

### The two step 1 fixes

- *Reset Overrides* on a layer below an instance root appears only when that layer has overrides of its own (or is a nested instance root with overrides in its subtree).
- It, and *Reset All Overrides*, are disabled when the instance's main component is missing.

## Agent tools

| Tool | Does | Returns |
|---|---|---|
| `design_combine_as_variants` (`ids`) | Combines main components into a new component set | the set |
| `design_set_variant_properties` (`id` of a set, `properties` list of names in order, `rename?` map old → new) | Adds, removes, renames, and reorders properties | the set |
| `design_set_variant` (`id` of a variant, `values` map) | Sets some of a variant's values | the variant |
| `design_add_variant` (`id` of a variant or set) | Adds a variant as *Add Variant* does | the new variant |
| `design_switch_variant` (`ids` of instances, `values` map) | Switches instances as choosing values does | the instances |

`design_list_components` adds, for a variant, its `set` id and `variant` values, and lists component sets (id, name, properties, variant ids). `design_create_instance` accepts a set id. `design_create_node`/`design_update_node` reject `componentSet` and `variant` like the step 1 fields. The coverage table in `docs/agent-tools.md` gets the new rows.

## Verification

- `FudehandCoreTests`: JSON round trip, validation rules, version 10 file opens; combine; property add/remove/rename with the duplicate-values refusal; add variant naming; structure refusals around sets; switching with name-path matching, overrides kept and dropped, ids and annotations kept, undo; deleting a variant or a set.
- `ControlProtocolTests`, `tests/control-tools.test.ts`, `StoreTests` for each tool.
- `LocalizationTests`, `AccessibilityTests` for new UI.
- `pnpm bench:native`: no change for documents without components.
- Real-app light and dark screenshots of a component set's properties, a variant's values, and an instance's variant pop-ups in `docs/evidence/`.
- ADR 0015 records the component set decision; ADR 0014, GLOSSARY, `docs/macos.md`, and `docs/agent-tools.md` are updated.

## Decisions from the builder check

- **Root overrides on a switch:** every overridden property of the instance root (fill, size, visibility, …) is kept, even when variants differ in size; `x`/`y` always belong to the instance.
- **Sources:** a switched instance's root gets `instance` and `source` = the new variant; every kept layer's `source` is re-pointed at its matched layer in the new variant; toggle targets are rewritten as in step 1. Implementation: build the new subtree from the new variant (step 1's `makeInstance`), then for each matched layer reuse the old id and copy the overridden values and `overrides` onto it.
- **Name-path pairing:** same-named siblings pair first with first, second with second; extras on either side are unmatched.
- **Nested instances on a switch:** a nested instance root is matched only when its name path matches and both point at the same main component, or at variants of the same component set; its own overrides and its subtree are then matched recursively the same way (a nested instance in the same set may thus also switch). Otherwise the nested subtree is unmatched and rebuilt.
- **Combine as Variants** is the one operation that moves main components into a set: they keep their ids, and their instances stay linked.
- **A component set is an ordinary frame** otherwise: fill, auto layout, clip, and guides stay editable and render; it does not resize itself, except that *Combine as Variants* sizes it and *Add Variant* grows it to include the new variant, which is placed 16 points below the variant it copies.
- **First variant** means first in the set's child order; reordering changes the default for new instances only.
- A version 11 file opened by an older Fudehand is refused by the existing format-version check.

## Left to the builder

- SF Symbol for component sets; exact layout of the property editor.
- How name-path matching is implemented, given the rule above.
