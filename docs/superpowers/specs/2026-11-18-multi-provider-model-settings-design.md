# Multi-Provider Model Settings Design

Tracking: issue to be created on approval. Date: 2026-11-18. Status: awaiting approval.

Prototype: the canvas "ui-atlas AI 对话面板原型", row "模型设置改进 · 多提供方" (artboards "模型设置 · 提供方列表" and "模型菜单 · 跨提供方切换"). The prototype copy is Chinese; the App's source language is US English. The prototype is a private canvas and is not in the repository: this document and its sketches are the authority, and they carry everything the prototype decided.

## Intent

A user who has DeepSeek set up and wants to add an OpenAI key believes they must delete the DeepSeek settings first. They do not: the key, model, and base URL are already stored per model provider (Keychain account = provider id; `agent.<provider>.model`, `.baseUrl`, `.hasKey`, `.keyHint`, `.models` in UserDefaults). The settings sheet hides this. One picker is both "the provider I am editing" and "the provider the chat uses", nothing shows which providers are configured, and *Delete Saved Key* sits where it reads as a required step.

Switching to a model of another provider also takes four steps through the sheet, because the model menu under the chat input lists only the current provider's models.

This change makes the per-provider storage visible, lets the user check a key before relying on it, and makes any configured provider's models one click away.

## Goals

- The settings sheet shows all model providers at once, each with its state (has a key or not, its model, whether the chat uses it).
- Editing a provider's settings and choosing the provider the chat uses are separate actions.
- A *Test* button confirms that the entered or saved API key works.
- The model menu under the chat input switches between models of every configured provider.
- Providers are shown as **DeepSeek**, **Claude**, and **ChatGPT**.

## Non-goals

- User-defined providers (other OpenAI-compatible services such as OpenRouter or a local server). The prototype's "添加 OpenAI 兼容服务… 二期" row is a placeholder for a later change and is not built.
- A model per conversation. The chosen provider and model stay global, as today.
- Changes to the Agent harness protocol, the provider adapters, or the provider ids (`deepseek`, `anthropic`, `openai`).
- Changing where anything is stored. No migration is needed.

## Anti-goals

- An API key reaching UserDefaults, logs, process arguments, or the repository. Keys stay in the Keychain and reach the harness only through `UI_ATLAS_API_KEY`.
- More Keychain reads than today. Opening the sheet, selecting a provider in it, or opening the model menu must not read the Keychain (each read can raise a macOS authorization prompt).
- A destructive action that takes effect before *Save*.

## Approaches

1. **Chosen: provider list + detail in the sheet, grouped model menu.** Matches the storage that already exists, so it is a UI and view-state change with a few additions to `ChatSession`. Solves both problems.
2. Keep the single picker and add explanatory text plus status marks in the picker. Smallest change, but leaves editing and activating conflated and does nothing for switching.
3. A list of named "model configurations" (provider + key + base URL + model, several per provider). Also covers user-defined providers, but needs a new storage model, Keychain account scheme, migration, and harness changes. Too large for the problem at hand; it is the natural shape for the later user-defined-providers change.

The user chose approach 1 from the prototype.

## Design

### Provider names

`ChatSettings.providers` titles become `DeepSeek`, `Claude`, `ChatGPT`; ids are unchanged. Provider names are brand names and are not localized. Update the *Model provider* entry in `GLOSSARY.md` and every string that names a provider.

The `openai` provider still needs an OpenAI API key; a ChatGPT subscription does not include one. The detail pane's help text for that provider says so (builder's wording).

### Settings sheet

Layout, about 640 pt wide:

```
Model settings
┌──────────────────────┐  ChatGPT                       [Use for Chat]
│ ● DeepSeek   In use  │
│   deepseek-v4-pro    │  API key   [••••••••••••••••]        [Test]
│ ○ Claude             │  Base URL  [Leave empty to use the official…]
│   No API key         │  Model     [gpt-5.3-codex              ⌃⌄]
│ ● ChatGPT            │
│   gpt-5.3-codex      │  ✓ The key works. 42 models available.
└──────────────────────┘
                           Each provider keeps its own key, base URL,
                           and model. Keys are stored only in this
                           Mac's keychain…
                                                    [Cancel]  [Save]
```

- **List** (left): one row per provider with a filled mark when it has a key and a hollow mark when it does not (the difference must not rely on colour alone), the provider name, a second line with its model (the provider's default model name when the model is empty and the default is known; otherwise *Default model*) or *No API key*, and an *In use* tag on the provider the chat will use. The sheet opens with the chat's current provider selected.
- **Detail** (right), for the selected provider:
  - Header: the provider name, then one of: *In use* (this provider is the one the chat will use), a *Use for Chat* button (it has a key and the last test did not fail), or the hint *Add an API key to use this provider*.
  - *API key*: with a saved key, the masked hint plus *Test*, *Replace*, *Remove*. Without one, or after *Replace*, a secure field plus *Test*; *Test* is unavailable while the field is empty and there is no saved key.
  - *Base URL* and *Model*: as today (text field with the model menu beside it, listing the cached or just-fetched models).
  - Status line: the test state (below).
- **Drafts**: every edit, including *Use for Chat* and *Remove*, is held in the sheet per provider and survives selecting another provider. *Save* applies all of them; *Cancel* discards all of them. Nothing is written before *Save*, with one exception: a successful test caches the fetched model list, as today.
- **Save** applies, for each provider with changes: the new key to the Keychain (or deletes it when removed), the key flag and masked hint, the model, and the base URL. It then sets the chat's provider when *Use for Chat* changed it. The harness restarts only if the provider in use, its model, base URL, or key actually changed. Saving an untested key is allowed. If a Keychain write fails, the sheet stays open and shows the error, as today.
- **Automatic switch** (author's call, not decided with the user): if, after applying the drafts, the provider in use has no key and at least one other provider has one, the chat switches to the first provider with a key in `ChatSettings.providers` order. The list shows this before *Save*: the *In use* tag moves as soon as the drafts make it true. This keeps first-run setup one step (add a key to any provider, save, chat) instead of ending on *No API key set for DeepSeek*.
- A key typed but not yet saved counts as "has a key" for the list marks, the header, and the rule above. After *Remove*, *Test* is unavailable until a new key is typed.
- Removing the key of the provider in use is allowed; the chat panel then shows the existing *No API key set for …* notice.

### Test

*Test* runs the existing model-list request (`ChatSession.listModels`, the harness's `--list-models` mode) for the selected provider with the draft base URL and the draft key, or the saved key when no new key was typed. Reading the saved key here is the one Keychain read the sheet makes, and only on this click. No new harness mode or endpoint is added: a successful model list is the proof that the key and base URL work.

States shown on the status line, per provider:

| State | Shown |
| --- | --- |
| Not tested, no key | *Add an API key, then test it.* |
| Not tested, has key | With cached models: *N models available.* Otherwise: *Test the key to load the available models.* |
| Testing | Spinner, *Testing…*; the button reads *Testing…* and ignores clicks |
| Passed | Green check, *The key works. N models available.* The list is cached for the model menus. |
| Failed | Warning mark, *The test failed: <message from the harness>. You can still save.* in the error colour |

- Leaving the key field after typing a new key runs the test automatically (today's behaviour of fetching the model list on blur). Editing the key or base URL afterwards returns the state to *not tested*. Only the result of the latest request is used.
- The sheet no longer fetches the model list when it opens or when a provider is selected; it shows the cached list. This removes two Keychain reads that happen today.
- A failed test hides *Use for Chat* for that provider but does not block *Save*, since the failure may be a network problem.

### Model menu under the chat input

```
DeepSeek
  deepseek-chat        Default
✓ deepseek-v4-pro
  deepseek-reasoner
ChatGPT
  gpt-5.3-codex        Default
  All 42 Models  ▸
Claude
  Add API Key…
──────────────
Reload Model List
Model Settings…
```

- The button shows `<Provider> · <model>`; with an empty model it shows the provider's default model name when known, otherwise *Default model*.
- One section per provider, in the order of `ChatSettings.providers`.
- A provider with a key lists its models from the cache. With at most 8 cached models, all are listed. With more, the section lists the default model, the selected model (when it belongs to this provider and is not the default), and an *All N Models* submenu with the full list. With an empty cache the section lists only its default entry.
- The default entry (author's calls for the cases the prototype does not show):
  - When the provider's default model name is known, the default entry is the row with that id and the *Default* hint; the id is not listed a second time. It is checked when the stored model is empty or equals that id.
  - When the name is not known yet (a model list cached by an earlier version, before the next test or reload), the entry reads *Default model* and the cached list follows unchanged, even if it repeats the default id.
  - The 8-model threshold counts the cached list as stored.
  - A stored model that is not in the provider's cache (typed by hand in the sheet) gets its own checked row in the section of the provider in use, in both the short and the long form. "Belongs to this provider" means that the provider is the one in use.
- Choosing a model sets the chat's provider and model in one step, keeping that provider's stored base URL. Choosing the default entry stores an empty model, as today.
- *Reload Model List* also caches the default model name.
- A provider without a key shows *Add API Key…*, which opens the settings sheet with that provider selected.
- *Reload Model List* reloads the provider in use only, as today.
- The menu stays unavailable while a reply is running: changing the provider or model restarts the harness, which is then given the conversation's user and assistant texts only.

### Code shape

- `ChatSession` gains what the sheet and menu need for providers other than the one in use: reading a provider's cached models, caching each provider's default model name beside its model list (`agent.<provider>.defaultModel`), and storing a provider's model and base URL without switching to it. The sheet reads stored settings through the session instead of `UserDefaults.standard` (it does today at `ChatPanel.swift`, in the provider `onChange`).
- The rule that turns (providers, key flags, cached models, default models, current selection) into menu sections, including the 8-model threshold, is a pure function with unit tests. The sheet's per-provider draft state and the rule for what *Save* writes are likewise testable without the view.
- `ChatSettingsSheet` is rewritten around the list and drafts; `ChatPanel`'s `modelMenu` uses the sections.

## Left to the builder

- Exact English copy and the three translations (the strings above are the intent), using `L("…")` and all four `Localizable.strings` tables.
- Whether the pure rules live in `AtlasCore` or `AtlasApp`, and their names.
- Widths, spacing, and SwiftUI controls (for example `List` versus a custom column), provided the result matches the prototype's structure and looks native in light and dark appearance.

## Verification

- Unit tests: menu sections (no key, empty cache, ≤ 8 models, > 8 models with and without a non-default selection); draft application on *Save* and discard on *Cancel*, including removing a key and changing the provider in use; storing settings for a provider that is not in use leaves the provider in use and the running harness alone; the existing `ChatSessionTests` and `LocalizationTests` keep passing.
- `pnpm test:native` and `pnpm check` pass.
- In the real app, light and dark: the sheet with a configured and an unconfigured provider selected, a passed and a failed test, and the model menu with a short and a long model list. Screenshots go to `docs/evidence/`.
- Test against real provider keys is left to the user; the PR notes what was not checked.

## Docs to update

`docs/macos.md` (Chat panel: *Input* and the model settings behaviour), `GLOSSARY.md` (*Model provider*), any provider names in `README.md`, and the help text in the sheet.
