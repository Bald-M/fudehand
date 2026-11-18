---
name: airbnb
description: Warm, photo-led marketplace on pure white with one coral-red accent, soft rounded cards, pill search bar and friendly mid-weight rounded sans type.
---

# Airbnb-inspired style

Adapted from `design-md/airbnb/DESIGN.md` in VoltAgent/awesome-design-md (MIT). A third-party analysis of the brand's public website, not its official design system; the name and trademarks belong to their owner.

## Fonts

- Display: Avenir Next (replaces Airbnb Cereal VF)
- Body: Avenir Next (replaces Airbnb Cereal VF)

One family carries the whole scale. Avenir Next is a friendly geometric-humanist sans, close to the original's warmth. Weights stay modest: 400 body, 500 to 600 labels, 700 only for a few headings.

## Colors

| Name | Hex | Use |
| --- | --- | --- |
| Coral | #FF385C | The single brand colour: primary buttons, search orb, saved-heart |
| Coral Deep | #E00B41 | Darker coral, for a deeper alternate fill |
| Coral Pale | #FFD1DA | Disabled primary button |
| Ink | #222222 | Headlines, body, nav, rating numbers |
| Body | #3F3F3F | Long running text in reviews |
| Muted | #6A6A6A | Subtitles, inactive tabs, legal line |
| White | #FFFFFF | Page canvas, cards, footer |
| Soft Gray | #F7F7F7 | Light fill bands, date range fill |
| Strong Gray | #F2F2F2 | Round icon button fill |
| Hairline | #DDDDDD | 1pt strokes, dividers, card borders |
| Error | #C13515 | Form error text |
| Scrim | #00000080 | Modal backdrop |

Stars and ratings are ink, never yellow.

## Type scale

| Role | Font | Size | Weight | Line height |
| --- | --- | --- | --- | --- |
| Rating number | Display | 64 | 700 | 1.1 |
| Page headline | Display | 28 | 700 | 1.3 |
| Listing title | Display | 22 | 500 | 1.2 |
| Section head | Display | 20 | 600 | 1.2 |
| Card title / button | Body | 16 | 600 | 1.25 |
| Body | Body | 16 | 400 | 1.5 |
| Card meta, price | Body | 14 | 400 | 1.43 |
| Badge / legal | Body | 12 | 600 | 1.3 |

Headlines are deliberately small; photography carries the visual weight. The 64pt rating is the one loud type moment.

## Spacing

Base unit 4. Scale: 4, 8, 12, 16, 24, 32, 48, 64. Major sections have 64 vertical padding; card grids are dense with 16 gaps; card meta block 16 padding; larger cards and panels 24 padding. Content width about 1280.

## Corner radius

- Buttons and text inputs: 8
- Property and experience cards, photos, panels: 14
- Search bar, badges, tags: fully round (half the height)
- Search orb, icon buttons, date cells: ellipse or full round
- Large category chips: up to 32

## Elevation

Shadows cannot be drawn. Nearly every surface is flat white on white. Separate with 1pt #DDDDDD strokes or dividers and with photo corner clipping. Floating items (search bar, reservation card) get a 1pt #DDDDDD stroke instead of a shadow.

## Components

- Button (primary): fill #FF385C, white 16pt weight 500 text, 48 tall, padding 14 by 24, radius 8
- Button (secondary): white fill, 1pt #222222 stroke, ink 16pt weight 500 text, 48 tall, radius 8
- Card: white, no stroke for property cards; square photo with radius 14, then title 16pt weight 600, muted 14pt lines, price in ink weight 600. Panels use a 1pt #DDDDDD stroke, radius 14, padding 24
- Input: white fill, 1pt #DDDDDD stroke, radius 8, 56 tall, padding 14 by 12; muted 14pt label above, 16pt text
- Navigation bar: white, 80 tall, 1pt bottom hairline, three centred tabs (Homes, Experiences, Services) in 16pt weight 600 with a 2pt ink underline on the current one; muted for others
- Search bar: white, pill, 64 tall, 1pt hairline, three segments (Where, When, Who) split by thin vertical lines, ending in a 48 round coral orb with a white magnifier
- Guest favorite badge: white pill over the photo, 11pt weight 600, padding 4 by 10
- Reservation card: white, radius 14, 1pt stroke, padding 24, price at 21pt weight 700, full-width coral button

## Do

- Use coral for one or two moments per screen; everything else is white and ink
- Lead with large rounded photographs
- Keep every interactive element rounded
- Keep headings small and mid-weight
- Use 16pt gaps in card grids and 64pt between bands

## Don't

- Don't add a second brand colour or a dark canvas
- Don't use yellow stars or pure black text
- Don't use sharp corners on any control
- Don't use heavy display type; reserve 700 for the rating
- Don't stack card strokes with fills; keep cards white on white
