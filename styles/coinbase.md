---
name: coinbase
description: Calm institutional crypto look: white canvas, near-black editorial bands, a single bright blue pill CTA, regular-weight display type.
---

# Coinbase-inspired style

Adapted from `design-md/coinbase/DESIGN.md` in VoltAgent/awesome-design-md (MIT). A third-party analysis of the brand's public website, not its official design system; the name and trademarks belong to their owner.

## Fonts

- Display: Helvetica Neue (replaces CoinbaseDisplay), weight 400 only
- Body: System font (replaces CoinbaseSans), omit fontFamily
- Mono: Menlo (replaces CoinbaseMono), for prices and percentages

## Colors

| Name | Hex | Use |
| --- | --- | --- |
| Blue | #0052FF | Primary CTA pill, inline links, wordmark; scarce |
| Blue deep | #003ECC | Darker blue for secondary emphasis |
| Blue faded | #A8B8CC | Disabled-looking CTA |
| Ink | #0A0B0D | Headlines, nav text, dark band background |
| Body gray | #5B616E | Running text |
| Muted | #7C828A | Sub-titles, footer secondary, legal text |
| Canvas | #FFFFFF | Page background, light cards |
| Surface soft | #F7F7F7 | Alternating light band |
| Surface strong | #EEF0F3 | Secondary buttons, search pill, badges, icon plates |
| Hairline | #DEE1E6 | 1pt dividers and card outlines |
| Dark elevated | #16181C | Product mockup cards on dark bands |
| On-dark soft | #A8ACB3 | Secondary text on dark |
| Up green | #05B169 | Price-up text only |
| Down red | #CF202F | Price-down text only |

## Type scale

| Role | Font | Size | Weight | Line height |
| --- | --- | --- | --- | --- |
| Hero headline | Display | 80 | 400 | 1.0 |
| Section head | Display | 52 | 400 | 1.05 |
| CTA band headline | Display | 44 | 400 | 1.1 |
| Sub-section head | Body | 32 | 400 | 1.13 |
| Component title | Body | 18 | 600 | 1.33 |
| Body | Body | 16 | 400 | 1.5 |
| Button label | Body | 16 | 600 | 1.15 |
| Small / nav | Body | 14 | 500 | 1.4 |
| Badge | Body | 12 | 600 | 1.5 |
| Price figure | Mono | 18 | 500 | 1.4 |

## Spacing

Base unit 4: 4, 8, 12, 16, 20, 24, 32, 48, 96. Card padding 32, gap between cards 24, vertical padding of each full-width band 96. Content centered in a column about 1200 wide.

## Corner radius

- Buttons, search pill, badges: pill (100)
- Icon plates and avatars: fully round (9999)
- Inputs: 12
- Compact rows: 8
- Feature cards, mockup cards, pricing tiers: 24
- Sharp corners are not used

## Elevation

No shadows. Most surfaces are flat. Use a 1pt Hairline stroke on white cards, alternating bands (white, Surface soft, Ink), and on dark bands a Dark elevated card sitting on the Ink background. Overlap two or three mockup cards, offset a little, for a layered look.

## Components

- Button (primary): Blue fill, white 16pt weight 600, height 44, horizontal padding 20, pill
- Button (large CTA): same colours, height 56, horizontal padding 32, pill
- Button (secondary): Surface strong fill with Ink text on light; Dark elevated fill with white text on dark; same geometry
- Button (outline on dark): no fill, 1pt white stroke, white text, pill
- Card: white fill, 1pt Hairline stroke, radius 24, padding 32, title in Body 18 weight 600
- Input: white fill, 1pt Hairline stroke, radius 12, height 48, padding 14 by 16
- Navigation bar: height 64, white (or Ink on dark pages), wordmark left, links in 14 weight 500 centre, Sign in and a Blue pill right
- Dark hero band: Ink fill, white 80pt headline left, two pills below, stacked Dark elevated mockup cards right
- Asset row: 32 circle in Surface strong, name and ticker left, price in Mono 18, change in Up green or Down red text, 1pt Hairline divider, padding 16 vertical
- Badge: Surface strong fill, Ink text 12 weight 600, padding 4 by 12, pill

## Do

- Keep Blue for primary CTAs and a few accent moments per band.
- Set display headlines at weight 400.
- Rotate bands: white, Surface soft, Ink, with 96 padding.
- Set every number in Menlo.
- Use green and red as text colours only.
- Pair each dark hero with a stack of mockup cards.

## Don't

- Don't bold display headlines.
- Don't introduce a second brand colour.
- Don't use green or red as button fills.
- Don't use square corners on buttons.
- Don't mix Display and Body fonts inside one headline.
- Don't crowd marketing bands; density belongs in product screens.
