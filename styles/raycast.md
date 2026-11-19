---
name: raycast
description: Pure near-black command-palette look with hairline-bordered cards, tight radii, one white call-to-action and a few saturated category colours.
---

# Raycast-inspired style

Adapted from `design-md/raycast/DESIGN.md` in VoltAgent/awesome-design-md (MIT). A third-party analysis of the brand's public website, not its official design system; the name and trademarks belong to their owner.

## Fonts

- Display: System font (replaces Inter). Omit fontFamily.
- Body: System font (replaces Inter). Omit fontFamily.

## Colors

| Name | Hex | Use |
| --- | --- | --- |
| Canvas | #07080A | Page background, nav, footer |
| Surface | #0D0D0D | Cards and panels |
| Surface elevated | #101111 | Inputs, tertiary buttons, selected chips, featured card |
| Surface card | #121212 | Icon tiles, key caps, selected row |
| Hairline | #242728 | 1pt border on every card and input |
| Hairline strong | #FFFFFF29 | Outline buttons, table dividers |
| Ink | #F4F4F6 | Headlines |
| Body | #CDCDCD | Paragraphs, footer links |
| Mute | #9C9C9D | Metadata, captions |
| White | #FFFFFF | The one primary button fill and button labels on dark |
| Stripe red | #FF5757 | Hero banner stripes, once per page |
| Category accents | #57C1FF #FF6161 #59D499 #FFC533 | Only inside small illustrations and tags |

## Type scale

| Role | Font | Size | Weight | Line height |
| --- | --- | --- | --- | --- |
| Hero | Display | 64 | 600 | 1.1 |
| Section title | Display | 56 | 500 | 1.17 |
| Heading | Display | 24 | 500 | 1.4 |
| Card title | Display | 18 | 500 | 1.4 |
| Lead | Body | 18 | 400 | 1.6 |
| Body | Body | 16 | 400 | 1.6 |
| Small / button | Body | 14 | 500 | 1.6 |
| Caption | Body | 12 | 400 | 1.5 |

## Spacing

Base unit 8, with 2, 4 and 12 for tight gaps. Scale: 4, 8, 12, 16, 24, 32, 48, 96. Card padding 24 (16 for list cards); grid gap 16; gap between sections 96; content width about 1240.

## Corner radius

- Buttons, inputs, small cards, icon tiles: 8
- Feature and pricing cards: 10
- Palette rows: 6
- Key caps and badges: 4
- Large hero mock-up frame: 16
- Filter chips: fully round (pill)

## Elevation

No shadows. Depth is a four-step ladder: Canvas, Surface, Surface elevated, Surface card, each slightly lighter, plus a 1pt Hairline stroke on every card. A featured card only moves up one step.

## Components

- Button (primary): fill #FFFFFF, text #000000 14pt weight 500, height 36, horizontal padding 16, radius 8. At most one per screen section.
- Button (secondary): no fill, text white 14pt weight 500, height 36, padding 16, radius 8. Outline version adds a 1pt Hairline strong stroke.
- Card: fill Surface, 1pt Hairline stroke, radius 10, padding 24, auto layout vertical, spacing 12; heading 18pt/500 Ink, text 14pt Body.
- Input: fill Surface elevated, 1pt Hairline stroke, height 36, padding 12, radius 8, text 16pt white; the search field is 44 high with padding 16.
- Navigation bar: canvas fill, height 56, 48 side padding, 1pt Hairline rule below; wordmark left, 14pt/500 links centred, white primary button right.
- Command palette: Surface fill, 1pt Hairline stroke, radius 16; rows 6 and 10 padding, radius 6; the selected row uses Surface card; key caps are Surface card, 20 high, radius 4, 12pt text.
- Extension card: Surface fill, 1pt Hairline stroke, radius 8, padding 16; 48 square icon tile left, name and description centre, outline button right.
- Filter chip: no fill, Body text 14pt, padding 4 and 10, pill radius; the selected chip uses Surface elevated.

## Do

- Keep every screen on one continuous dark canvas from top to footer.
- Make the white button the only primary action; everything else is monochrome.
- Build elevation from the surface ladder and 1pt Hairline strokes.
- Show a palette-style mock-up as the hero visual, with key caps for shortcuts.
- Use a flat red stripe band across the top of the first hero only.
- Keep category colours inside small tiles and tags.

## Don't

- Don't add shadows to cards.
- Don't tint the primary button; white is the action colour.
- Don't use category colours on text, buttons or chrome.
- Don't repeat the red stripes lower on the page.
- Don't pad cards beyond 24 on every side.
- Don't make a light page with this style.
