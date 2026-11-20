# Starter Templates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship three starter templates that follow one set of design foundations, with localized names and tests that keep them valid.

**Architecture:** Templates are `.fudehand` files in `native/Resources/Templates/`, already copied into the app and listed by
`FudehandStore.templates(in:)`. A Core test reads them from the repository and checks decoding and foundation values; the launch
window shows `L(template.name)`.

**Tech Stack:** Swift 6 (Swift Testing), the Fudehand MCP tools for authoring.

**Spec:** `docs/superpowers/specs/2026-11-20-starter-templates-design.md`, values in `docs/design-foundations.md`.

## Global Constraints

- Colors: `#F6F5F2 #FFFFFF #1D1C21 #6B6874 #E4E1DB #1F6B57 #E1EEE9`; font family `Avenir Next`, weights 400/500/600.
- Font sizes 12/14/16/20/24/32/48; gaps and paddings 0/4/8/12/16/24/32/48/64; corner radii 0/4/8/16/999; stroke width 1.
- Template file names: `Mobile App.fudehand`, `Web Page.fudehand`, `Dashboard.fudehand`.
- UI copy only through `L("…")` with entries in all four tables.

## Review Focus

- A template added by a person with no table entry: shows its file name (L falls back to the key) — covered by the existing fallback; test asserts `L("Some Template") == "Some Template"`.
- Editing a template's text grows its parent: every text layer is inside an auto-layout frame — test checks every text node's parent has `layout`.
- An image layer would embed data and bloat the file: test rejects `image` layers in templates.
- Format version bump: test decodes with `DesignDocument.decode`, which rejects unknown versions.
- Template folder empty by mistake: test expects exactly the three names.

---

### Task 1: Template tests and name localization

**Files:**
- Create: `native/Tests/FudehandCoreTests/BundledTemplateTests.swift`
- Modify: `native/Sources/FudehandApp/LaunchView.swift` (show `L(template.name)` in label and help)
- Modify: four `Localizable.strings` (keys `Mobile App`, `Web Page`, `Dashboard`)

- [ ] Write tests: `bundledTemplatesAreTheThreeStarters`, `bundledTemplatesDecodeAndFollowTheFoundations` (palette, family,
  weights, sizes, spacing, padding, radius, stroke width, no image layers, a top-level frame named `Design system`, text parents
  have auto layout), `bundledTemplateNamesAreLocalized` (each name has a non-empty entry in every table; zh-Hans differs from key).
- [ ] Run `swift test --package-path native --filter BundledTemplateTests`; expect FAIL (no templates).
- [ ] Add table entries and LaunchView change; commit.

### Task 2: Author the three templates

- [ ] Build and open the app from this worktree (`pnpm dev`), build each template with `design_create_node` using only foundation
  values, save to `native/Resources/Templates/<Name>.fudehand`.
- [ ] Run the template tests; expect PASS. Commit.

### Task 3: Docs, evidence, gate

- [ ] Link `docs/design-foundations.md` from `native/Resources/Templates/README.md`, `GLOSSARY.md` Template entry, and
  `docs/macos.md` (naming convention).
- [ ] Screenshots of launch window and each template on the canvas, light and dark, into `docs/evidence/22-*`.
- [ ] `pnpm test:native` and `pnpm check` pass. Commit.
