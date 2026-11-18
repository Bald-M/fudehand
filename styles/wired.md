---
name: wired
description: Editorial technology-magazine look: pure black on white, tall high-contrast serif headlines, serif reading text, square corners, hairline rules.
---

# Wired-inspired style

Adapted from `design-md/wired/DESIGN.md` in VoltAgent/awesome-design-md (MIT). A third-party analysis of the brand's public website, not its official design system; the name and trademarks belong to their owner.

## Fonts

- Display: Didot (replaces WiredDisplay)
- Body: Georgia (replaces BreveText, the serif reading face)
- Labels: Helvetica Neue (replaces Apercu, the sans used for navigation, metadata and buttons)

## Colors

| Name | Hex | Use |
| --- | --- | --- |
| Ink | #000000 | Headlines, wordmark, primary buttons, footer fill |
| Ink soft | #1A1A1A | Emphasised captions, footer links |
| Canvas | #FFFFFF | Page background |
| Canvas soft | #F5F5F5 | Rare tinted panels, table headers |
| Hairline | #E0E0E0 | 1pt dividers between story rows |
| Muted | #757575 | Bylines, timestamps, supporting lines |
| Link | #057DBC | Inline links inside article text only |

## Type scale

| Role | Font | Size | Weight | Line height |
| --- | --- | --- | --- | --- |
| Cover headline | Display | 64 | 400 | 0.93 |
| Section headline | Display | 48 | 400 | 1.05 |
| Story headline | Display | 32 | 400 | 1.1 |
| Sub-headline | Display | 26 | 400 | 1.08 |
| Card heading | Labels | 20 | 700 | 1.2 |
| Lead paragraph | Body | 19 | 400 | 1.47 |
| Article text | Body | 16 | 400 | 1.5 |
| Nav and eyebrow | Labels | 14 | 700 | 1.3 |
| Byline | Body | 13 | 700 | 2.2 |
| Caption | Labels | 12 | 400 | 1.33 |

## Spacing

Base unit 4: 4, 8, 12, 16, 20, 24, 32, 48. Hero and story grid use 48 above and below; story rows use 16 vertical padding; page side padding is 20 to 48 inside a wide container of about 1200.

## Corner radius

- Everything (buttons, inputs, cards, images): 0
- Only exception: circular icon buttons and small author avatars (radius half the size)

## Elevation

Shadows cannot be drawn. Almost everything is flat on white. Depth is a 1pt #E0E0E0 hairline for dividers and input borders, a 1pt or 2pt #000000 stroke for outlined buttons, and a #F5F5F5 panel for rare tinted areas.

## Components

- Button (primary): fill #000000, text #FFFFFF Labels 16pt 700, vertical padding 12, horizontal padding 20, radius 0
- Button (secondary): fill #FFFFFF, 1pt #000000 stroke, text #000000 Labels 16pt 700, same padding, radius 0
- Card: no fill and no stroke on the white canvas; photo on top (16:9 for the cover, 4:3 for the rest), then headline and a muted byline, padding 12 to 16
- Input: fill #FFFFFF, 1pt #000000 stroke, text Labels 17pt, padding 12 by 16, radius 0
- Navigation bar: white, 12 by 20 padding, menu icon left, wordmark text centred, Subscribe button right; link text Labels 14pt 700
- Masthead band: thin white strip with the centred wordmark in Display
- Story row: full width, 16 vertical padding, 1pt #E0E0E0 line below, bold Labels headline with muted byline beneath
- Footer: fill #000000, text #FFFFFF Labels 14pt, 48 padding, text columns only

## Do

- Keep it strictly black and white; reserve black for the wordmark, buttons and footer
- Set cover headlines in Didot at 64pt weight 400 for the high-contrast serif look
- Use serif for narrative text and sans for navigation, labels and buttons
- Keep all corners square
- Separate story rows with 1pt #E0E0E0 hairlines
- Lay content out as a magazine grid: one large cover story, a two-up row, then stacked rows

## Don't

- Don't add a chromatic accent; blue is for inline article links only
- Don't round buttons or cards
- Don't use bold weights for display headlines
- Don't use a sans face for big headlines
- Don't add decorative graphics, badges or tinted backgrounds
