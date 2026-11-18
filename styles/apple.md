---
name: apple
description: Photography-first minimalism: full-bleed white, parchment and near-black tiles, tight semibold headlines and one quiet blue accent on pill buttons.
---

# Apple-inspired style

Adapted from `design-md/apple/DESIGN.md` in VoltAgent/awesome-design-md (MIT). A third-party analysis of the brand's public website, not its official design system; the name and trademarks belong to their owner.

## Fonts

- Display: System font (replaces SF Pro Display)
- Body: System font (replaces SF Pro Text)

Omit fontFamily on every text layer to get the system font. Never use weight 500: the ladder is 300 / 400 / 600.

## Colors

| Name | Hex | Use |
| --- | --- | --- |
| Action Blue | #0066CC | Every interactive element: pill buttons, text links |
| Sky Blue | #2997FF | Links and accents on dark tiles only |
| Ink | #1D1D1F | Headlines and body text on light surfaces |
| Ink Soft | #333333 | Text on pearl buttons, footer text |
| Ink Muted | #7A7A7A | Legal fine print, disabled text |
| White | #FFFFFF | Main canvas, cards, light tiles |
| Parchment | #F5F5F7 | Alternating light tile, footer, page background |
| Pearl | #FAFAFC | Secondary button fill |
| Tile Dark | #272729 | Dark tile; use #2A2A2C or #252527 for a neighbouring tile |
| Black | #000000 | Top navigation bar, video backdrops |
| Hairline | #E0E0E0 | 1pt card and chip stroke |
| Chip Gray | #D2D2D7 | Round control buttons over photos (about 64% opacity: #D2D2D7A3) |

On dark tiles use white text, with #CCCCCC for secondary copy.

## Type scale

| Role | Font | Size | Weight | Line height |
| --- | --- | --- | --- | --- |
| Hero headline | Display | 56 | 600 | 1.07 |
| Tile headline | Display | 40 | 600 | 1.1 |
| Section head | Display | 34 | 600 | 1.2 |
| Subcopy | Display | 28 | 400 | 1.14 |
| Tagline | Display | 21 | 600 | 1.19 |
| Body | Body | 17 | 400 | 1.47 |
| Caption / utility button | Body | 14 | 400 | 1.35 |
| Nav link / fine print | Body | 12 | 400 | 1.3 |

Body copy is 17pt, not 16. Weight 300 is rare: only for an airy 24pt lead paragraph.

## Spacing

Base unit 8. Scale: 4, 8, 12, 17, 24, 32, 48, 80. Each tile has 80 vertical padding; tiles stack edge to edge with no gap, and the colour change is the divider. Cards use 24 padding and 20 gaps. Keep at least 40 clear around a product image.

## Corner radius

- Pill buttons, search input, option chips: fully round (use half the height)
- Compact dark utility buttons: 8
- Pearl capsule buttons: 11
- Cards and square product thumbnails: 18 (inner images 8)
- Full-bleed tiles and hero photos: 0

## Elevation

Shadows cannot be drawn, and this style barely uses them anyway. Depth comes from surface change: white, parchment and near-black tiles alternating. Cards get a 1pt #E0E0E0 stroke. Product images sit directly on the tile with no shadow layer.

## Components

- Button (primary): fill #0066CC, white text 17pt weight 400, auto layout padding 11 vertical, 22 horizontal, full pill radius, about 44 tall
- Button (secondary): transparent or white fill, 1pt #0066CC stroke, #0066CC text 17pt, same padding and pill radius
- Button (dark utility): fill #1D1D1F, white 14pt text, padding 8 by 15, radius 8
- Card: white fill, 1pt #E0E0E0 stroke, radius 18, padding 24; image on top, name 17pt weight 600, price 17pt weight 400, then a blue text link
- Input: white fill, 1pt stroke, pill radius, 44 tall, padding 12 by 20, 17pt text
- Navigation bar: black fill, 44 tall, 12pt white links about 20 apart; a sub-navigation strip below in Parchment, 52 tall, category name 21pt weight 600 on the left and a blue pill button on the right
- Product tile: centred stack of headline 40pt, subcopy 28pt, two small blue pill buttons (Learn more, Buy), then the product image; fill white, parchment or #272729

## Do

- Use #0066CC for every interactive element and nothing else; it is the only accent
- Alternate light and dark full-bleed tiles to create rhythm instead of borders
- Keep headlines at weight 600 and body at 400
- Reserve pill radius for actions: buttons, chips, search
- Leave generous empty space around the product; let the image carry the screen
- Use #1D1D1F for text instead of pure black

## Don't

- Don't add a second accent colour
- Don't put strokes or fills behind headlines, or decorate with gradients; use photography for atmosphere
- Don't round full-bleed tiles
- Don't use weight 500 or tighten body line height below 1.47
- Don't mix many radii in one screen; choose 8, 18 or pill
- Don't use Sky Blue on light surfaces
