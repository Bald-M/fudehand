# Components and Instances Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Main components, instances, and overrides inside one design document (step 1 of #256; variants are step 2).

**Architecture:** Instances are materialized: ordinary layers that also carry `instance`, `source`, and `overrides`. A pure `ComponentSync` in `FudehandCore` runs inside `DesignEditor.perform`/`applyLive` after every change: it records overrides for edited instance layers, then rebuilds affected instances from their main components, before annotation pruning and layout. Renderer, `DesignIndex`, hit testing, snapshots, prototype, and HTML export are unchanged.

**Tech Stack:** Swift 6 toolchain (Swift 5 language mode), SwiftUI + AppKit, `FudehandCore`/`FudehandApp` targets, Node 22 MCP tools (`scripts/fudehand-tools.mjs`), Vitest.

**Spec:** `docs/superpowers/specs/2026-11-24-components-design.md`

## Global Constraints

- Work in `.claude/worktrees/256-components` on branch `claude/256-components`; commits `type(components): 中文简述`, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; the PR links `Refs #256` (not `Closes`: variants remain). Create Component goes in the Edit menu after Duplicate, because the App has no Object menu (the spec's "Object menu").
- `DesignDocument.formatVersion` = 10; version ≤ 9 files open unchanged. On-disk keys: `component` (true only), `instance` (string), `source` (string), `overrides` (sorted array of strings), each written only when set.
- No component reference makes a file fail to open (spec "Format").
- Root `x`/`y` of an instance are never synced and never overrides. `id`, `type`, `children`, `component`, `instance`, `source`, `overrides` are never overridable.
- Every document-changing tool is one undo step named `Agent: <Action>`; UI and tool call the same store method (`docs/agent-tools.md` §2–3).
- UI copy only via `L("…")` with keys in all four `Localizable.strings`; icon-only controls get `.accessibilityLabel` and `iconHitTarget()`.
- Code comments, docs, errors, test names in English. Control/validation errors are not localized.
- Documents without components must not get slower: `pnpm bench:native` numbers within noise of `main`.
- Run Swift tests with `pnpm test:native` or `swift test --package-path native --filter …` (never two Swift builds on one scratch dir at once).

## Review Focus

- **Text measured differently in an instance:** an instance whose text is overridden longer than the main component's must lay out its own auto layout (hug) after sync — pinned by `testOverriddenTextReflowsInstanceLayout` in Task 4.
- **Undo across a sync:** undoing an edit to a main component restores every instance exactly (including ids of layers sync added) — `testUndoRestoresInstancesAndIDs` in Task 4.
- **Drag inside a main component with many instances:** live drag stays smooth and ends as one undo step — `testDragInMainComponentIsOneStep` in Task 4 and the benchmark in Task 8.
- **Agent sets component fields directly** (`design_update_node` with `instance`, `overrides`, …): rejected with an error, document unchanged — `testComponentFieldsCannotBePatched` in Task 1.
- **Selection after sync removes a layer:** a selected layer inside an instance that sync deletes drops out of the selection without a crash — `testSelectionDropsLayersRemovedBySync` in Task 6.

---

### Task 1: Model, JSON, and format version 10

**Files:**
- Modify: `native/Sources/FudehandCore/DesignDocument.swift` (`DesignNode` fields, `formatVersion`, `decode`, validation)
- Modify: `native/Sources/FudehandCore/DesignJSON.swift` (`nodeKeys`, `node(from:)`, `object(_:)`, `apply(_:to:)`)
- Test: `native/Tests/FudehandCoreTests/ComponentModelTests.swift` (new)

**Interfaces:**
- Produces: on `DesignNode`: `var component = false`, `var instance: String?`, `var source: String?`, `var overrides: Set<String> = []`. `DesignDocument.validateComponents() throws` (structural rules). `DesignJSON.componentKeys: Set<String> = ["component", "instance", "source", "overrides"]`. `DesignJSON.node(from:)` keeps reading these keys (files, clipboard); `DesignJSON.apply` throws `"Layer <id>: cannot change <key>"` for any of them.

- [ ] **Step 1: Write failing tests** in `ComponentModelTests`:
  - `testRoundTripsComponentFields`: a document with a frame `component: true` and an instance root (`instance: "m"`, `source: "m"`, `overrides: ["text.content","fill"]`) with a child (`source: "m-title"`) encodes with `"version": 10`, `"overrides": ["fill","text.content"]` (sorted), and decodes equal.
  - `testOmitsUnsetComponentFields`: a plain layer's object has none of the four keys.
  - `testVersion9FileOpens`: a version-9 file without the keys decodes; re-encoded version is 10.
  - `testComponentInsideInstanceIsLoadError`, `testComponentInsideComponentIsLoadError`, `testSourceOutsideInstanceIsLoadError`, `testInstanceKeyBelowRootOfOtherInstanceAllowed` (a nested instance root inside an instance has both `instance` and `source`: allowed).
  - `testComponentFieldsCannotBePatched`: `DesignJSON.apply(["overrides": []], …)` and each other key throws `cannot change`; node unchanged.
- [ ] **Step 2: Run** `swift test --package-path native --filter FudehandCoreTests.ComponentModelTests` — expected FAIL (no such members).
- [ ] **Step 3: Implement.** Add fields and keys; `object(_:)` writes them only when set; bump `formatVersion` to 10 and extend its doc comment ("10 components"); `decode` calls `validateComponents()` after `validateUniqueIDs()`. Validation rules exactly as spec "Fields on DesignNode" except the dangling/cycle/mismatch cases, which Task 5's repair handles (not errors).
- [ ] **Step 4: Run** the filter again and `swift test --package-path native --filter FudehandCoreTests.DesignDocumentTests` — PASS.
- [ ] **Step 5: Commit** `feat(components): 图层模型与工程文件支持主组件和实例字段`.

### Task 2: Property paths

**Files:**
- Create: `native/Sources/FudehandCore/ComponentProperty.swift`
- Test: `native/Tests/FudehandCoreTests/ComponentPropertyTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct ComponentProperty: Sendable {
      public let path: String                       // JSON path: "fill", "text.content", …
      public func equal(_ a: DesignNode, _ b: DesignNode) -> Bool
      public func copy(from source: DesignNode, to target: inout DesignNode)
      public static let all: [ComponentProperty]
      public static func named(_ path: String) -> ComponentProperty?
      /// Paths whose values differ between a and b.
      public static func changed(_ a: DesignNode, _ b: DesignNode) -> Set<String>
  }
  ```
  Paths: every key of `DesignJSON.nodeKeys` minus `id`, `type`, `children`, the four component keys; for each key in `DesignJSON.nestedKeys` that is an object on the node (`stroke`, `sizing`, `text`, `icon`, `layout`, `image`, `versionSnapshot`) one path per field (`text.content`, `text.fontSize`, …, `layout.padding` as a whole), plus the whole-key path used when either side is nil (`text` nil ↔ non-nil copies the whole object). Work on Swift values with key paths, not JSON (no image base64 per frame).

- [ ] **Step 1: Failing tests:** `testCoversEveryNodeKey` (every `nodeKeys` entry not excluded is a path or a prefix of one); `testTextContentAloneKeepsFont` (copy `text.content` only → target keeps its font size); `testChangedReportsFieldPaths` (changing `fill` and `text.color` → `["fill","text.color"]`); `testWholeObjectWhenOneSideNil` (stroke nil vs set → `["stroke"]`).
- [ ] **Step 2: Run** `--filter FudehandCoreTests.ComponentPropertyTests` — FAIL.
- [ ] **Step 3: Implement** `ComponentProperty` with a static table.
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(components): 定义可覆盖属性路径`.

### Task 3: Sync one level (`ComponentSync`)

**Files:**
- Create: `native/Sources/FudehandCore/ComponentSync.swift`
- Test: `native/Tests/FudehandCoreTests/ComponentSyncTests.swift`

**Interfaces:**
- Consumes: Task 1 fields, Task 2 `ComponentProperty`.
- Produces:
  ```swift
  public enum ComponentSync {
      /// Records overrides for edited instance layers, then rebuilds instances whose main component (or own subtree) changed.
      public static func reconcile(old: DesignDocument, new: inout DesignDocument)
      /// Builds instance layers for `component` with fresh ids (used by create-instance and paste).
      public static func makeInstance(of component: DesignNode, existing: inout Set<String>) -> DesignNode
      /// Rebuilds one instance subtree from its main component, keeping overrides and the root's x/y.
      static func sync(_ instance: inout DesignNode, from component: DesignNode, existing: inout Set<String>)
      public static func detach(_ node: inout DesignNode)   // clears instance/source/overrides on node and below, nested instances kept (Task 4 refines)
      public static func resetOverrides(_ node: inout DesignNode, component: DesignNode, properties: Set<String>?)
  }
  ```
  Ids: `DesignDocument.newID(existing:)`.

- [ ] **Step 1: Failing tests** (build documents with a helper `componentFixture()` returning main `m` = frame with text child `t`, and instance `i` of it at x 300):
  - `testMakeInstanceMirrorsComponent` (same properties, new ids, `source` set, root `source == "m"`).
  - `testFillChangePropagates`, `testTextContentOverrideSurvives` (override `text.content` on instance, change main's content and color → instance keeps content, takes color).
  - `testEditEqualToMainRemovesOverride`.
  - `testRootPositionNeverSyncedOrOverridden`.
  - `testChildAddedRemovedReordered` (new main child appears with fresh id; removed one disappears; order follows main).
  - `testReplaceColorEverywhereLeavesInstancesFollowing` (change fill on both main and instance to the same new color in one edit → no override).
  - `testUnchangedDocumentIsReturnedAsIs` (no components: `new` storage identical — compare `new.nodes` with `==` and assert no instance work by counting a test hook `ComponentSync.syncCount`).
- [ ] **Step 2: Run** `--filter FudehandCoreTests.ComponentSyncTests` — FAIL.
- [ ] **Step 3: Implement.** Walk old/new in parallel, descending only into subtrees where `!=` (array storage identity makes unchanged subtrees cheap). Override recording: for an edited layer with `source`, `changed(old, new)` minus root `x`/`y`; for each path, insert when the new value differs from its source layer's new value, remove when equal. Then collect main components whose subtree changed and instances whose subtree changed, and `sync` each affected instance; skip instances whose main component is missing (Cut case).
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(components): 主组件修改同步到实例并记录覆盖`.

### Task 4: Nested instances, interaction targets, editor integration

**Files:**
- Modify: `native/Sources/FudehandCore/ComponentSync.swift`
- Modify: `native/Sources/FudehandCore/DesignEditor.swift` (`perform`, `applyLive`: call `ComponentSync.reconcile(old: document, new: &next)` right after `change`, before `pruneAnnotations`)
- Test: `ComponentSyncTests.swift`, `native/Tests/FudehandCoreTests/DesignEditorTests.swift`

**Interfaces:**
- Consumes: Task 3.
- Produces: same API; reconcile now orders components so one containing instances of another syncs after it; `detach` rewrites nested instance copies' `source` to B's layers and recomputes their `overrides` with `ComponentProperty.changed` against B.

- [ ] **Step 1: Failing tests:**
  - `testNestedChangeReachesOuterInstances` (B changes → B's instance in A → A's instances).
  - `testResetOnNestedCopyGoesBackToA`.
  - `testDetachOuterKeepsNestedInstanceOfB` (source rewritten into B, overrides recomputed).
  - `testCycleIsNotCreated` — `reconcile` leaves a would-be cycle untouched and `DesignDocument.insert` of an instance of A into A throws `"Layer <id>: an instance cannot be inside its own main component"`.
  - `testToggleTargetsRewrittenToInstanceLayers` and `testNavigateTargetsKept`; rewritten targets are not overrides.
  - Editor (`DesignEditorTests`): `testMainComponentEditIsOneUndoStep`, `testUndoRestoresInstancesAndIDs`, `testDragInMainComponentIsOneStep` (beginGesture/applyLive×3/endGesture: instance follows each frame; one step), `testOverriddenTextReflowsInstanceLayout` (hug frame instance with longer overridden text is wider than main after layout).
- [ ] **Step 2: Run** `--filter "FudehandCoreTests.(ComponentSyncTests|DesignEditorTests)"` — FAIL.
- [ ] **Step 3: Implement** ordering (topological over "contains instance of"), nested `source` resolution through the nearest main component, toggle-target rewrite (map main layer id → instance layer id via `source`), and the editor calls.
- [ ] **Step 4: Run** — PASS; also run all `FudehandCoreTests` (existing editor/layout tests unchanged).
- [ ] **Step 5: Commit** `feat(components): 支持嵌套实例与原型目标改写，接入撤销历史`.

### Task 5: Structure rules, delete, load repair, clipboard

**Files:**
- Modify: `native/Sources/FudehandCore/DesignEditor.swift` (`DesignDocument.insert`, `delete`, `move`)
- Modify: `native/Sources/FudehandCore/DesignDocument.swift` (`decode` → repair)
- Modify: `native/Sources/FudehandCore/LayerClipboard.swift` (`paste`, `duplicate`)
- Modify: `native/Sources/FudehandApp/StoreClipboard.swift` (`copyLayers` cut path)
- Test: `ComponentSyncTests.swift`, `native/Tests/FudehandCoreTests/LayerClipboardTests.swift`, `native/Tests/FudehandAppTests/StoreClipboardTests.swift`

**Interfaces:**
- Produces: `DesignDocument.delete(_ ids: Set<String>, detachingInstances: Bool = true) throws`; `ComponentSync.repair(_ document: inout DesignDocument)` (detach mismatched/dangling/cyclic instances, then full sync); structure error text `"Layer <id> is inside instance <rootId>; change its main component instead"`.

- [ ] **Step 1: Failing tests:**
  - `testInsertDeleteMoveInsideInstanceThrow` (insert under an instance child, delete an instance child, move into/out of an instance → the error; root moves and deletes fine).
  - `testDeletingMainComponentDetachesInstances` (one step; undo restores links).
  - `testRepairDetachesDanglingMismatchedAndCyclic` and `testRepairSyncsNonOverriddenValues`; `testFileWithDanglingInstanceOpens` (decode succeeds).
  - Clipboard (`LayerClipboardTests`): `testPasteMainComponentMakesInstance`, `testDuplicateInstanceMakesInstance`, `testPasteContainerWithMainComponentMakesInstanceInside`, `testPasteIntoOtherDocumentKeepsMainComponent` (new id, instances pasted with it linked to it), `testPasteInstanceAloneIntoOtherDocumentDetaches`.
  - Store (`StoreClipboardTests`): `testCutPasteMainComponentKeepsLinks` (cut leaves instances pointing at the missing id; paste restores the id and they follow the next edit).
- [ ] **Step 2: Run** the three filters — FAIL.
- [ ] **Step 3: Implement.** `decode` calls `repair` after validation; paste runs `repair` on the pasted subtree (same document: a main component whose id exists becomes an instance via `makeInstance`; whose id is free and is referenced by instances keeps the id; other document: keeps `component`, maps instance references to the pasted copy's new id). Cut calls `delete(…, detachingInstances: false)`.
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(components): 实例内禁止结构修改，删除主组件分离实例，剪贴板与读文件修复`.

### Task 6: Store methods, control commands, Agent tools

**Files:**
- Create: `native/Sources/FudehandApp/StoreComponents.swift`
- Modify: `native/Sources/FudehandCore/ControlProtocol.swift`, `native/Sources/FudehandApp/ControlCommands.swift`, `scripts/fudehand-tools.mjs`, `docs/agent-tools.md` (coverage row *Components*)
- Test: `native/Tests/FudehandAppTests/StoreTests.swift`, `native/Tests/FudehandCoreTests/ControlProtocolTests.swift`, `tests/control-tools.test.ts`

**Interfaces:**
- Consumes: Tasks 3–5.
- Produces (store, all `throws`, each one undo step named by `step:`):
  ```swift
  func createComponent(_ id: String, step: String = "Create Component") throws -> DesignNode
  func createInstance(of component: String, parent: String?, index: Int?, at point: Point?, step: String = "Insert Component") throws -> DesignNode
  func listComponents() -> [(component: DesignNode, instances: [String])]
  func resetOverrides(_ id: String, properties: Set<String>?, step: String = "Reset Overrides") throws -> DesignNode
  func detachInstances(_ ids: Set<String>, step: String = "Detach Instance") throws -> [DesignNode]
  ```
  Commands: `createComponent(String)`, `createInstance(component: String, parent: String?, index: Int?, x: Double?, y: Double?)`, `listComponents`, `resetOverrides(String, properties: [String]?)`, `detachInstance([String])`; wire names `create_component`, `create_instance`, `list_components`, `reset_overrides`, `detach_instance`; tools `design_create_component`, `design_create_instance`, `design_list_components`, `design_reset_overrides`, `design_detach_instance`; Agent step names `Agent: Create Component`, `Agent: Insert Component`, `Agent: Reset Overrides`, `Agent: Detach Instance`. `x`/`y` omitted → placement as `insertIcon` (`insertionPlacement`). `list_components` returns `[{id, name, width, height, instances: [ids]}]` counting nested copies.

- [ ] **Step 1: Failing tests:** protocol parsing and bad-argument rejection for each command (`ControlProtocolTests`); each tool listed and forwards args unchanged (`control-tools.test.ts`); `StoreTests`: `testCreateComponentViaControlMatchesUI`, `testCreateInstanceViaControlIsOneAgentStep`, `testResetOverridesViaControl`, `testDetachViaControl`, `testListComponentsCountsNestedCopies`, `testCreateComponentInsideInstanceFails` (error text), `testSelectionDropsLayersRemovedBySync`.
- [ ] **Step 2: Run** `pnpm vitest run tests/control-tools.test.ts` and `swift test --package-path native --filter "FudehandCoreTests.ControlProtocolTests|FudehandAppTests.StoreTests"` — FAIL.
- [ ] **Step 3: Implement** store methods, dispatch (calling the store methods), and tool descriptions (English, GLOSSARY terms: main component, instance, override, detach). `design_update_node`/`design_create_node` descriptions say component fields are set only by these tools.
- [ ] **Step 4: Run** — PASS; `pnpm check` PASS.
- [ ] **Step 5: Commit** `feat(components): 新增组件相关 Agent 工具`.

### Task 7: UI

**Files:**
- Modify: `native/Sources/FudehandApp/FudehandApp.swift` (Edit menu after Duplicate: *Create Component* ⌥⌘K, *Detach Instance* ⌥⌘B; enabled per selection)
- Modify: `native/Sources/FudehandApp/LayersPanel.swift` (row icon: main component `square.on.square.dashed`-style, instance `diamond`-style; overridden marker; context menu items)
- Modify: `native/Sources/FudehandApp/InspectorPanel.swift` (*Component* section; per-property reset control on overridden rows)
- Create: `native/Sources/FudehandApp/ComponentPicker.swift`; Modify: `CanvasToolbar.swift` (*Insert Component* button with popover beside Insert Icon)
- Modify: four `native/Sources/FudehandCore/Resources/*.lproj/Localizable.strings`; `native/Tests/FudehandCoreTests/LocalizationTests.swift` (add `ComponentPicker.swift` to the UI file list)
- Test: `LocalizationTests`, `AccessibilityTests`, `native/Tests/FudehandAppTests/StoreTests.swift`

**Interfaces:**
- Consumes: Task 6 store methods only (no new logic in views).

- [ ] **Step 1: Failing tests:** `LocalizationTests` and `AccessibilityTests` fail once the new `L(…)` keys and icon buttons are added without table entries/labels (write the views first, then run to see the failures — this is the existing guard); `StoreTests.testInsertComponentPlacesLikeIcon` (into the selected frame's top-left, else viewport center; selected; one step).
- [ ] **Step 2: Run** `swift test --package-path native --filter "FudehandCoreTests.LocalizationTests|FudehandCoreTests.AccessibilityTests|FudehandAppTests.StoreTests"` — FAIL.
- [ ] **Step 3: Implement** views and the four string tables. UI copy (US English source → zh-Hans / zh-Hant): Create Component → 创建组件 / 建立元件; Main Component → 主组件 / 主元件; Instance → 实例 / 實例; Insert Component → 插入组件 / 插入元件; Go to Main Component → 前往主组件 / 前往主元件; Select Instances → 选择实例 / 選取實例; Reset All Overrides → 重置所有覆盖 / 重設所有覆寫; Reset Override → 重置覆盖 / 重設覆寫; Detach Instance → 分离实例 / 中斷實例連結; No Components → 没有组件 / 沒有元件; "%d Instances" → 「%d 个实例」/「%d 個實例」. en-GB matches en-US.
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(components): 菜单、图层面板、属性面板与插入组件面板`.

### Task 8: Docs, benchmark, real-app evidence

**Files:**
- Modify: `GLOSSARY.md` (add Main component, Instance, Override, Detach instance; rewrite the _Avoid_ under *Icon name* and the note under *State*), `docs/adr/0009-in-screen-prototype-interactions.md` (components now in scope; variants pending), `docs/macos.md` (Components section: create, insert, overrides, structure rule, delete, clipboard, menus), `docs/agent-tools.md` (if not done in Task 6)
- Create: `docs/adr/0014-components-are-materialized-instances.md` (decision, rejected virtual instances and linked copies, consequences)
- Modify: `native/Tests/FudehandAppTests/EditBenchmarkTests.swift` (new `[bench]` case: drag a layer inside a main component with 50 instances)
- Create: `docs/evidence/components-*.png`

- [ ] **Step 1:** Write the docs and ADR.
- [ ] **Step 2:** Run `pnpm bench:native` on `main` (a temporary worktree at `origin/main`, with its own `FUDEHAND_SWIFT_SCRATCH`; never `git stash`) and on the branch; record both sets of `[bench]` lines in the PR. Expected: existing cases within noise; new case reported.
- [ ] **Step 3:** Full gate: `pnpm test:native` and `pnpm check` — all PASS.
- [ ] **Step 4:** Real app (`pnpm dev`, private control socket per memory note): create a header component, three instances on three frames, override one title, change main fill; screenshot layers panel, properties panel, and Insert Component popover in light and dark into `docs/evidence/`.
- [ ] **Step 5: Commit** `docs(components): 术语、ADR、使用说明与界面证据`; push, open draft PR `feat(components): 支持主组件、实例与覆盖` with `Refs #256`, `gh pr ready` once evidence is in.
