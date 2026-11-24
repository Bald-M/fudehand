# Find (⌘F) — design

Issue: #257. Approved 2026-11-24.

## Intent

A person working on a document with many text layers and frames cannot find a piece of copy (a button label, a typo) except by eye or by expanding the layers panel. Design tools offer ⌘F for this and people expect it. An Agent should be able to find layers by text the same way, without reading the whole document.

## Goals

- ⌘F (Edit › Find) opens a find bar over the canvas; the query matches text-layer content and layer names, case-insensitively.
- The bar shows the match count and current position, and steps through matches; each step selects the layer and focuses the viewport on it.
- Agent parity: `design_find_nodes` returns the same matches.

## Non-goals

Find and replace, regex or whole-word options, searching across files, searching the chat or inspector, a persistent filter in the layers panel.

## Anti-goals

- Find must not change the document, mark it edited, or add undo steps.
- Typing a query must not stall on a 16,000-layer document.

## Approaches

1. **Matching in `FudehandCore` + floating bar over the canvas + one store method shared with the Agent tool (chosen).** Testable rules in Core, the UI and the tool call the same store method (ADR 0007 §2.3), navigation reuses `setSelection` and `focus`.
2. A search field in the window toolbar. Rejected: the toolbar is already full, and it reads as a document search with results UI rather than step-through find.
3. A filter field in the layers panel. Rejected: listed as a non-goal; it answers a different question (narrowing the tree) and does not step through the canvas.

## Design

- `DesignFind.matches(in: DesignDocument, query:) -> [DesignFind.Match]` in `FudehandCore`. Depth-first document order. A layer matches when its text content or its name contains the trimmed query (case- and diacritic-insensitive). Each layer appears once; `Match` carries `id`, `name`, `type`, `field` (`text` takes precedence over `name`), and an `excerpt` of the matched field around the hit. Hidden and locked layers are included. An empty query has no matches.
- `FudehandStore.findLayers(_ query:)` wraps it; both the find bar and the control command call it.
- Find bar: a small floating bar at the top-right of the canvas with a search field, an "n / m" count (*No Results* when none), previous / next / close icon buttons (localized accessibility labels, `iconHitTarget()`). Its query and current position are view state, not document state. Matches are recomputed when the query or the document changes.
- Menu: Edit › Find (⌘F) opens the bar and focuses the field; Find Next (⌘G) and Find Previous (⇧⌘G) step, enabled while the bar is open. In the field, Return steps forward, Shift-Return back, Esc closes. Stepping wraps around, selects the match with `setSelection`, and focuses it with `focus`.
- Control channel: `findNodes(query:, limit:)` → `{ matches: [...], total }`; tool `design_find_nodes { query, limit? }` in `scripts/fudehand-tools.mjs`, tests in Vitest, a row in `docs/agent-tools.md`.
- Docs: behavior in `docs/macos.md`, *Find bar* in `GLOSSARY.md`; UI copy in all four `Localizable.strings`.

## Left to the builder

Exact bar styling, excerpt length, the default `limit`, and whether the store focuses with the index rather than a tree search.
