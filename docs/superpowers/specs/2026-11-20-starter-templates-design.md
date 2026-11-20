# Starter Templates Design

Issue #22. Builds on the launch window's Templates section (#54).

## Intent

The launch window already lists the `.fudehand` files in `native/Resources/Templates/`, but none ship. Every new design starts
blank, and people and Agents re-decide frame sizes, colors, type sizes, and spacing each time. A few starter templates that share
one set of design foundations give both a starting point and a convention to follow.

## Goals

- Three templates: Mobile App (393 × 852), Web Page (1440 wide), and Dashboard (1440 × 900). Each has its screen and a
  "Design system" frame showing the colors, type scale, spacing scale, and corner radii.
- Every color, font, font size, weight, gap, padding, and corner radius in a template comes from
  [Design foundations](../../design-foundations.md).
- Templates use auto layout, so editing text or adding and removing children keeps the layout intact. They use only what the
  renderer supports (no rotation, gradients, shadows, or vector paths).
- Template names are localized: the file name (US English) is a key in the four `Localizable.strings` tables; a template without
  an entry (one a person added) shows its file name.
- Tests: every bundled template decodes through `DesignDocument` (format and version checks), uses only foundation values, has a
  "Design system" frame, and has a name entry in all four tables.
- Evidence: launch window and canvas, light and dark, in `docs/evidence/`.

## Non-goals

Document-level variables or shared styles; components; a template market or a template management UI; light/dark-switching
templates; Agent tools for templates (listed as Missing in `docs/agent-tools.md`, separate work); making the foundations a
style-library entry (#115).

## Approaches

1. **Author the templates in the running App through the Fudehand tools and save them** (picked): the files are exactly what
   the App writes, and the token test catches any drift from the foundations.
2. Generate the files with a Node script from a token file: guarantees consistency but adds a build step and code to maintain
   for three static files.
3. Hand-write the JSON: error-prone and easy to drift.

## Calls left to the builder

Screen content and copy (English, real-sounding, no lorem ipsum); exact layer structure within the auto-layout rule.
