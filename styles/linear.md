---
name: linear
description: Near-black software-craft canvas with charcoal panels, hairline borders and a single lavender-blue accent; dense, technical and quiet.
---

# Linear-inspired style

Adapted from `design-md/linear.app/DESIGN.md` in VoltAgent/awesome-design-md (MIT). A third-party analysis of the brand's public website, not its official design system; the name and trademarks belong to their owner.

## Fonts

- Display: System font (replaces Linear Display). Omit fontFamily.
- Body: System font (replaces Linear Text). Omit fontFamily.
- Mono: Menlo (replaces Linear Mono)

## Colors

| Name | Hex | Use |
| --- | --- | --- |
| Canvas | #010102 | Page background, nav, footer |
| Surface 1 | #0F1011 | Cards, panels, inputs, secondary buttons |
| Surface 2 | #141516 | Featured card, selected tab, badges |
| Surface 3 | #18191A | Menus, sub-navigation |
| Hairline | #23252A | 1pt borders on cards and dividers |
| Hairline strong | #34343A | Input borders, nested surfaces |
| Ink | #F7F8F8 | Headlines and emphasized text |
| Ink muted | #D0D6E0 | Secondary text |
| Ink subtle | #8A8F98 | Tertiary text, footer, inactive tabs |
| Ink faint | #62666D | Footnotes, disabled text |
| Accent | #5E6AD2 | Primary button, brand mark, link emphasis only |
| Success | #27A644 | Status pills, the only other chroma |

## Type scale

| Role | Font | Size | Weight | Line height |
| --- | --- | --- | --- | --- |
| Hero | Display | 80 | 600 | 1.05 |
| Section title | Display | 56 | 600 | 1.1 |
| Sub-section | Display | 40 | 600 | 1.15 |
| Card title | Display | 22 | 500 | 1.25 |
| Lead | Body | 18 | 400 | 1.5 |
| Body | Body | 16 | 400 | 1.5 |
| Small / button | Body | 14 | 400 or 500 | 1.5 |
| Caption | Body | 12 | 400 | 1.4 |
| Code / ID | Mono | 13 | 400 | 1.5 |

Display is semibold at most (600), never 700+. Body stays 400; labels and buttons 500.

## Spacing

Base unit 4. Scale: 4, 8, 12, 16, 24, 32, 48, 96. Card padding 24 (32 for quotes, 48 for closing banners); gap between blocks inside a panel 24; gap between sections 96. Content width about 1280.

## Corner radius

- Buttons and inputs: 8
- Cards and panels: 12
- Product screenshot frames: 16
- Badges and tabs: fully round (pill)
- Small chips: 4
- Avatars: circle

## Elevation

No shadows. Depth is a ladder of surfaces: canvas, then Surface 1, 2, 3, each one step lighter, plus a 1pt Hairline stroke on every raised panel. A featured item moves up one surface step and uses Hairline strong.

## Components

- Button (primary): fill #5E6AD2, text #FFFFFF 14pt weight 500, height 36, horizontal padding 14, radius 8.
- Button (secondary): fill Surface 1, 1pt Hairline stroke, text Ink 14pt weight 500, height 36, padding 14, radius 8. A plain text button uses the canvas fill with no stroke.
- Card: fill Surface 1, 1pt Hairline stroke, radius 12, padding 24, auto layout vertical, spacing 12; title 22pt/500 Ink, text 14pt Ink muted.
- Input: fill Surface 1, 1pt Hairline strong stroke, height 40, padding 12 horizontal, radius 8, text 16pt Ink, placeholder Ink subtle.
- Navigation bar: canvas fill, height 56, 32 side padding, 14pt Ink links, a secondary button and a primary button at the right.
- Product screenshot panel: Surface 1, radius 16, padding 24, 1pt Hairline stroke; the screenshot is the hero of each section.
- Status badge: Surface 2 fill, text Ink muted 12pt, padding 2 vertical and 8 horizontal, pill radius.
- Changelog row: canvas fill, padding 24 vertical, 1pt Hairline rule underneath, version in Mono 13pt.

## Do

- Anchor every screen on the near-black canvas and lift sections with the surface ladder.
- Use the lavender accent only for the brand mark, the single primary button and link emphasis.
- Pair semibold display with regular body; keep headings large and body text small and dense.
- Lead each section with a product-UI panel inside a Surface 1 frame.
- Give every raised surface a 1pt Hairline stroke.

## Don't

- Don't use pure black #000000 as the canvas; keep the faint blue tint.
- Don't fill cards or sections with the accent colour.
- Don't add a second chromatic accent beyond the status green.
- Don't use shadows, glows or decorative gradients.
- Don't round buttons into pills; pills are for tabs and badges.
- Don't make a light page with this style.
