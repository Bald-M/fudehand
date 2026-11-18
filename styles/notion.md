---
name: notion
description: Friendly editorial workspace look with a deep navy hero, one purple rectangular button, pastel tinted cards and warm grey hairlines.
---

# Notion-inspired style

Adapted from `design-md/notion/DESIGN.md` in VoltAgent/awesome-design-md (MIT). A third-party analysis of the brand's public website, not its official design system; the name and trademarks belong to their owner.

## Fonts

- Display: System font (replaces Notion Sans)
- Body: System font (replaces Notion Sans)

For System font, omit fontFamily on the text layer.

## Colors

| Name | Hex | Use |
| --- | --- | --- |
| Purple | #5645D4 | Main button, featured tier border, badges |
| Navy | #0A1530 | Hero band background |
| Ink | #1A1A1A | Headlines, body text |
| Charcoal | #37352F | Text on pastel cards |
| Steel | #787671 | Tertiary text, footer links, placeholder |
| Canvas | #FFFFFF | Page and card surface |
| Surface | #F6F5F4 | Soft sections, search field, featured tier |
| Hairline | #E5E3DF | 1pt borders and dividers |
| Hairline strong | #C8C4BE | Input and secondary button borders |
| Link blue | #0075DE | Inline links only |
| Tint yellow bold | #F9E79F | High-emphasis banner card |
| Tint peach | #FFE8D4 | Pastel feature card |
| Tint rose | #FDE0EC | Pastel feature card |
| Tint mint | #D9F3E1 | Pastel feature card |
| Tint lavender | #E6E0F5 | Pastel feature card |
| Tint sky | #DCECFA | Pastel feature card |

## Type scale

| Role | Font | Size | Weight | Line height |
| --- | --- | --- | --- | --- |
| Hero | Display | 80 | 600 | 1.05 |
| Section opener | Display | 56 | 600 | 1.1 |
| Page headline | Display | 48 | 600 | 1.15 |
| Subsection | Display | 36 | 600 | 1.2 |
| Card title | Display | 28 | 600 | 1.25 |
| Subtitle | Body | 18 | 400 | 1.5 |
| Body | Body | 16 | 400 | 1.55 |
| Button / small | Body | 14 | 500 | 1.3 |
| Badge | Body | 13 | 600 | 1.4 |

## Spacing

Base unit 4, mostly steps of 8: 4, 8, 12, 16, 20, 24, 32, 40, 48, 64, 96, 120. Card padding 24 to 32; hero band padding 120; gap between sections 64 to 96. Content about 1280 wide, centred, with 32 side margins.

## Corner radius

- Buttons, inputs, search field: 8 (rectangles, never pills)
- Cards, pricing tiers, mockup panels: 12
- Large feature panels: 16 to 24
- Tag chips: 4 to 6
- Status badges and pill tabs only: fully rounded (9999)

## Elevation

Shadows cannot be drawn. Default cards are flat white with a 1pt Hairline stroke. Pastel cards get depth from their tint fill and no stroke. Show the product mockup card above the navy hero band with a white fill and a 1pt Hairline stroke; the strong colour contrast carries the lift.

## Components

- Button (primary): Purple fill, white text 14 / 500, padding 10 by 18, radius 8.
- Button (secondary): transparent fill, 1pt Hairline strong stroke, Ink text 14 / 500, padding 10 by 18, radius 8. On navy: white fill with Ink text, or a stroke in #A4A097 with white text.
- Card: Canvas fill, 1pt Hairline stroke, radius 12, padding 24; pastel variant uses a tint fill, no stroke, Charcoal text, padding 32.
- Input: Canvas fill, 1pt Hairline strong stroke, radius 8, height 44, padding 12 by 16, text 16.
- Navigation bar: Canvas fill, height 64, 1pt Hairline bottom stroke; links 14 / 500 in Ink, Purple "Get Notion free" button on the right.
- Hero band: Navy fill, centred 80pt white headline, subtitle, button row, then a white mockup card below the buttons.
- Pricing card: Canvas fill, hairline stroke, radius 12, padding 32; the featured tier uses Surface fill and a 2pt Purple stroke.
- Badge: Purple fill, white text 13 / 600, padding 4 by 10, fully rounded.

## Do

- Keep Purple as the single dominant call to action.
- Use pastel tint cards generously, and the bold yellow tint for one high-emphasis banner.
- Centre the hero on the navy band and show real product UI inside it.
- Use 8pt radius for buttons and 12pt for every card family.
- Use warm greys (Charcoal, Steel, Hairline) rather than cool greys.

## Don't

- Don't make buttons pill-shaped.
- Don't use Purple for body text or large background areas.
- Don't mix Link blue with Purple; blue is for inline links only.
- Don't add heavy outlines or thick strokes to flat cards.
- Don't mix more than two or three pastel tints in one row.
