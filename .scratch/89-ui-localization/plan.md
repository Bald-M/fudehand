# UI localization (issue #89)

**Goal:** four UI languages (en-US default, en-GB, zh-Hans, zh-Hant), switchable in the App, persisted.

## Approaches

1. **String Catalog (`Localizable.xcstrings`)** — what the issue suggests. Rejected: it needs `xcstringstool`, which ships only with Xcode; the project builds with the Command Line Tools alone.
2. **Swift dictionaries in source** — no resources to ship, but translators cannot use standard tools and nothing tells AppKit which languages the App supports.
3. **`.strings` tables as SwiftPM resources (chosen)** — `native/Sources/AtlasCore/Resources/<lang>.lproj/Localizable.strings`, `defaultLocalization: "en"`. Builds with plain `swift build`; `native-build.mjs` also copies the `.lproj` folders into the app bundle so system-provided menu items follow the chosen language.

## Design

- Keys are the US English text; `L("Open…")` reads as the copy it shows. Every language, including `en`, has every key (tests enforce it).
- `AtlasCore/Localization.swift`: `AppLanguage` (raw values `en-US`, `en-GB`, `zh-Hans`, `zh-Hant`; `saved(in:)` / `save(in:)` on `UserDefaults` key `app.language`), `L10n.language`, `L10n.string(_:language:_:)`, global `L(_:_:)`.
- `AtlasStore.language` is `@Published`; views that observe the store re-render on change, the remaining views read `\.locale` from the environment, which each window root sets from the store.
- App menu → Language submenu. System-provided menu items (About, Quit, Edit, Window) follow `AppleLanguages`, written on every change and applied at the next launch; the menu says so.
- New layers get their default name in the UI language at creation time; existing names never change.
- Out of scope (issue #83): control-channel, field-validation, and command errors stay as they are. Undo step names are internal and become plain English.

## Tasks

1. Infrastructure: tests, `Localization.swift`, `Package.swift`, tables.
2. Replace UI copy in `AtlasApp` and user-facing `AtlasCore` messages; update tests that assert copy.
3. Language menu, persistence, app-bundle packaging.
4. Docs: `GLOSSARY.md`, `CLAUDE.md`, `CONTRIBUTING.md`, `docs/macos.md`, `CHANGELOG.md`.
5. Verify in the real app: four languages × light/dark, screenshots in `docs/evidence/`.
