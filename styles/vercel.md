---
name: vercel
description: Stark ink-on-near-white developer platform look with hairline borders, tight bold sans headlines, mono labels and black pill buttons.
---

# Vercel-inspired style

Adapted from `design-md/vercel/DESIGN.md` in VoltAgent/awesome-design-md (MIT). A third-party analysis of the brand's public website, not its official design system; the name and trademarks belong to their owner.

## Fonts

- Display: Helvetica Neue (replaces Geist)
- Body: Helvetica Neue (replaces Geist)
- Mono: Menlo (replaces Geist Mono)

## Colors

| Name | Hex | Use |
| --- | --- | --- |
| Ink | #171717 | Headings, body on light, primary button fill, dark bands |
| Body | #4D4D4D | Secondary text, nav links, footer |
| Mute | #888888 | Placeholder, fine print |
| Canvas | #FFFFFF | Cards, inputs, modals |
| Canvas soft | #FAFAFA | Page background, soft cards, badges |
| Canvas inset | #F5F5F5 | Inset regions, dropdown surfaces |
| Hairline | #EBEBEB | 1pt borders and dividers |
| Hairline strong | #A1A1A1 | Stronger dividers, de-emphasised text |
| Link blue | #0070F3 | Inline links, info |
| Link soft | #D3E5FF | Announcement pill fill |
| Error | #EE0000 | Errors, destructive |
| Warning | #F5A623 | Caution status |
| Violet | #7928CA | Rare accent in illustration |
| Pink | #FF0080 | Rare accent in illustration |

## Type scale

| Role | Font | Size | Weight | Line height |
| --- | --- | --- | --- | --- |
| Hero headline | Display | 48 | 600 | 1.0 |
| Section headline | Display | 32 | 600 | 1.25 |
| Card headline | Display | 24 | 600 | 1.33 |
| Lead paragraph | Body | 18 | 400 | 1.55 |
| Body | Body | 16 | 400 | 1.5 |
| Small body / button | Body | 14 | 500 | 1.43 |
| Caption | Body | 12 | 400 | 1.33 |
| Eyebrow / code | Mono | 12 | 400 | 1.33 |

## Spacing

Base unit 4. Scale: 4, 8, 12, 16, 24, 32, 40, 48, 64, 96. Screen padding 24; gap between sections 64 to 96; inside a card the headline and paragraph sit 8 apart, then a wider gap before the buttons. Page content is centred, about 1200 wide.

## Corner radius

- Marketing buttons, badges, tabs, banners: pill (fully rounded, 100)
- Small in-app buttons and inputs: 6
- Cards: 8; pricing and large cards: 12
- Images and code panels: 8 to 12
- Icon buttons: circle

## Elevation

Shadows cannot be drawn. Express depth with a 1pt Hairline stroke on white cards over the Canvas soft page, and with flat bands that alternate Canvas soft, Canvas, and Ink. The dark Ink band is the main depth cue between sections. Never stack more than one border.

## Components

- Button (primary): Ink fill, white text 16 / 500, height 48, horizontal padding 20, pill radius. Small version: height 32, text 14.
- Button (secondary): Canvas fill, 1pt Hairline stroke, Ink text 16 / 500, same size and pill radius as primary.
- Card: Canvas fill, 1pt Hairline stroke, radius 8, padding 24; headline 24 / 600, body 16 in Body colour.
- Input: Canvas fill, 1pt Hairline stroke, radius 6, height 40, padding 12 horizontal, text 14, placeholder Mute.
- Navigation bar: Canvas fill, height 64, padding 12 by 24, logo left, links 14 in Body colour centred, small Ink "Sign Up" button (height 28, radius 6) right.
- Pricing card: Canvas fill, hairline stroke, radius 12, padding 32; tier name 24, price 48 / 600. The featured tier flips to Ink fill with white text and a white button.
- Code panel: Ink fill, radius 8, padding 24, white Mono text 13 / line height 1.54.
- Eyebrow label: Mono 12 in Body colour above a headline.

## Do

- Reserve Ink for the main call to action and for one dark band per page.
- Write headlines in sentence case, weight 600, ending with a period.
- Set eyebrows, code and technical labels in Mono; keep paragraphs in Body font.
- Keep surfaces flat: Canvas soft page, white cards, hairline borders.
- Use lots of space between sections and tight spacing inside cards.
- For a hero accent, use large flat colour blocks from the blue, violet, pink and amber hues instead of a gradient.

## Don't

- Don't add more accent colours than the few listed; the page is mostly ink and grey.
- Don't use all-caps headlines or weight 700 and above.
- Don't mix pill buttons and 6pt buttons on the same screen.
- Don't set body paragraphs in Mono.
- Don't use heavy borders or thick strokes; stay at 1pt.
