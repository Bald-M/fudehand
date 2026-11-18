# Full-Project Chinese Localization

> Historical task record: it describes the localization of the browser-compatible version, and the "workbench", "exit bridge", and message protocol it mentions were removed with that version; see [ADR 0002](adr/0002-remove-browser-shell.md). The current convention is different: project documentation is written in English, while the App UI is currently Chinese only.

## Goal and Acceptance Scope

Make the Fudehand workbench, the Liubai (留白) three-platform example, the Inspiration Field (灵感原野) example, and the project's own documentation consistently natural Simplified Chinese. This covers main pages, text in decorative illustrations, empty states, dynamic buttons, dialogs, form validation, accessibility labels, page titles, and language attributes, as well as documentation, code comments, test descriptions, and the project's own startup messages.

Display names are uniformly "fudehand", "留白", and "灵感原野". Technical proper nouns (such as Vue, React, CSS), real shortcut key names, versions, and units keep their usual spelling.

Code identifiers, types, style class names, directories, package names, import paths, commands, configuration keys, internal category values, storage keys, and the message protocol stay compatible. Internal category values are separated from the Chinese display labels so that translation does not break filtering or adding items. Dependencies, third-party command output, and Git history are not modified, and no internationalization runtime dependency is introduced.

## Required Scenarios

- The workbench and the web-project index show Chinese names, and existing web-project IDs, layouts, and viewpoints can still be restored.
- Liubai's mobile, web, and desktop frames, before and after focus mode, and the new-task dialog all show Chinese.
- All of Inspiration Field's categories, the empty search state, before and after favoriting, the web-project details, new-item validation, and the About dialog all show Chinese.
- Chinese categories filter correctly, and new web projects are still saved to the chosen category; shortcuts and the exit bridge keep working.
- Check desktop and narrow widths, light and dark themes, and title wrapping and overflow.
- Scan the project source and documentation for leftover natural-language English, distinguishing case by case between content to translate and technical identifiers to keep.
- Run the existing type checks, tests, and builds, and complete the two local reviews, Standards and Spec, on the final changes.

This task is still delivered locally only; no remote repository is created and no deployment is performed.
