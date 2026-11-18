---
name: stripe
description: Airy fintech marketing look: white and cool off-white surfaces, deep navy ink, one electric indigo pill CTA, light-weight display type.
---

# Stripe-inspired style

Adapted from `design-md/stripe/DESIGN.md` in VoltAgent/awesome-design-md (MIT). A third-party analysis of the brand's public website, not its official design system; the name and trademarks belong to their owner.

## Fonts

- Display: Helvetica Neue (replaces Sohne), always weight 300
- Body: Helvetica Neue (replaces Sohne), weight 300 for running text, 400 for buttons and captions

## Colors

| Name | Hex | Use |
| --- | --- | --- |
| Indigo | #533AFD | Filled CTA pill, links, one per section |
| Indigo deep | #4434D4 | Tag text, secondary accents |
| Indigo soft | #665EFD | Chart highlights, small UI accents |
| Indigo tint | #B9B9F9 | Tag pill fill |
| Navy dark | #1C1E54 | Featured pricing card, dark buttons, dashboard chrome |
| Ink | #0D253D | Headlines and body text (never pure black) |
| Ink secondary | #273951 | Secondary text on white |
| Ink muted | #64748D | Captions, helper text, table labels |
| Canvas | #FFFFFF | Page background, cards, inputs |
| Canvas soft | #F6F9FC | Feature bands under the hero |
| Cream | #F5E9D4 | Warm interlude band or card |
| Hairline | #E3E8EE | 1pt card and table borders |
| Input line | #A8C3DE | 1pt input border |
| Ruby | #EA2261 | Small accent dots in product UI, never a button |

## Type scale

| Role | Font | Size | Weight | Line height |
| --- | --- | --- | --- | --- |
| Hero headline | Display | 56 | 300 | 1.05 |
| Section opener | Display | 48 | 300 | 1.15 |
| Card title | Display | 32 | 300 | 1.1 |
| Compact title | Display | 26 | 300 | 1.12 |
| Subheading | Display | 20 | 300 | 1.4 |
| Body | Body | 16 | 300 | 1.4 |
| Button label | Body | 16 | 400 | 1.0 |
| Caption | Body | 13 | 400 | 1.4 |
| Eyebrow tag | Body | 10 | 400 | 1.15 |

Numbers that represent money stay in Body at weight 300 or 400; keep digits right-aligned in tables.

## Spacing

Base unit 8, with 2, 4 and 12 for fine work: 4, 8, 12, 16, 24, 32, 64. Card padding 32 (24 for dashboard mockups). Gap between sections 64 to 96. Content centered in a column about 1200 wide.

## Corner radius

- Buttons and tag pills: fully round (9999)
- Inputs: 6
- Small tags and table chrome: 4
- Compact cards and alerts: 8
- Feature cards, pricing cards, mockup panels: 12
- Large mockup frames: 16

## Elevation

No shadows. Express lift with a 1pt Hairline stroke on white cards, a Canvas soft or Cream band behind them, and the dark Navy card as the highest emphasis. Atmosphere comes from a flat pastel band across the top of the hero (cream, lavender, a touch of ruby) made of plain overlapping rectangles or ellipses at partial opacity.

## Components

- Button (primary): Indigo fill, white 16pt weight 400, padding 8 by 16 (height about 40), fully round
- Button (secondary): white fill, 1pt Indigo stroke, Indigo text, same geometry
- Button (on dark): Navy dark fill, white text, same geometry
- Card: white fill, 1pt Hairline stroke, radius 12, padding 32, title in Display 22 to 32, body in Body 16
- Featured pricing card: Navy dark fill, white text, otherwise identical to the card
- Input: white fill, 1pt Input line stroke, radius 6, padding 8 by 12, Ink text 16
- Navigation bar: white fill, padding 16 by 24, wordmark left, links in Ink 15 center, Sign in text plus Indigo pill right
- Tag: Indigo tint fill, Indigo deep text 10, padding 4 by 8, fully round
- Dashboard mockup: white card, radius 12, padding 24, rows of Ink 14 text and muted numbers separated by Hairline lines

## Do

- Use one filled Indigo pill per section and keep it the only filled button on light surfaces.
- Set every headline at weight 300 for the thin, editorial look.
- Keep Ink navy for text; use Ink muted for secondary lines.
- Alternate white, Canvas soft and Cream bands for rhythm.
- Show the product with a mockup card under each feature explanation.
- Use the dark Navy card for the single featured option.

## Don't

- Don't raise display weight above 300.
- Don't use Indigo as body text colour.
- Don't make buttons rectangles; they are pills.
- Don't add accent colours beyond Indigo, Ruby and the cream and lavender band tones.
- Don't use pure black text.
- Don't shrink button padding below 8 by 16.
