---
name: spotify
description: Near-black immersive music-player look with one vivid green accent, pill buttons, circular controls and compact bold-or-regular type.
---

# Spotify-inspired style

Adapted from `design-md/spotify/DESIGN.md` in VoltAgent/awesome-design-md (MIT). A third-party analysis of the brand's public website, not its official design system; the name and trademarks belong to their owner.

## Fonts

- Display: Helvetica Neue (replaces SpotifyMixUITitle)
- Body: Helvetica Neue (replaces SpotifyMixUI)

## Colors

| Name | Hex | Use |
| --- | --- | --- |
| Base | #121212 | Page background, sidebar |
| Surface | #181818 | Cards, containers |
| Surface raised | #1F1F1F | Pill buttons, inputs, circular controls |
| Surface high | #252525 | Alternate card surface, menus, dialogs |
| Border | #4D4D4D | Outlines on dark surfaces |
| Border light | #7C7C7C | Outlined pill stroke, muted dividers |
| Text | #FFFFFF | Primary text |
| Text muted | #B3B3B3 | Secondary text, inactive nav |
| Accent green | #1ED760 | Play buttons, selected items, primary call to action |
| Error | #F3727F | Error text |
| Warning | #FFA42B | Warning text |
| Info | #539DF5 | Announcements |

## Type scale

| Role | Font | Size | Weight | Line height |
| --- | --- | --- | --- | --- |
| Section title | Display | 24 | 700 | 1.2 |
| Feature heading | Display | 18 | 600 | 1.3 |
| Body bold | Body | 16 | 700 | 1.4 |
| Body | Body | 16 | 400 | 1.4 |
| Button label (type it in capitals) | Body | 14 | 700 | 1.0 |
| Caption | Body | 14 | 400 | 1.5 |
| Small | Body | 12 | 400 | 1.5 |
| Badge | Body | 10 | 600 | 1.3 |

## Spacing

Base unit 8, with 4 for tight gaps: 4, 8, 12, 16, 20, 24, 32. Content is dense: 16 padding inside cards, 16 gap between cards, 24 around the main area. A fixed sidebar sits beside a main content area, with a full-width now-playing bar at the bottom.

## Corner radius

- Buttons and search input: full pill (radius at least half the height, for example 500)
- Play and icon controls, avatars: circle (radius half the size)
- Cards and album art: 6 to 8
- Dialogs and panels: 8 to 12
- Badges and tags: 2 to 4

## Elevation

Shadows cannot be drawn. Express depth by stepping surfaces from #121212 to #181818 to #1F1F1F to #252525; the lighter the surface, the closer it is. Use a 1pt #4D4D4D or #7C7C7C stroke only for outlined buttons and inputs.

## Components

- Button (primary): fill #1ED760, text #000000 14pt 700 in capitals, height 48, horizontal padding 32, full pill
- Button (secondary): fill #1F1F1F, text #FFFFFF 14pt 700, height 40, horizontal padding 16, full pill; outlined variant has a transparent fill and a 1pt #7C7C7C stroke
- Play button: circle 48 to 56, fill #1ED760, black icon; small controls are #1F1F1F circles with white icons
- Card: fill #181818, radius 8, padding 16, square album art on top (radius 6), title 16pt 700 white, subtitle 14pt 400 #B3B3B3
- Input: fill #1F1F1F, white text 14pt, height 48, left padding 48 for a search icon, full pill
- Navigation bar: sidebar fill #121212; items 14pt, selected item 700 white, others 400 #B3B3B3; icons are circles
- Track row: 56 tall, index and title on the left, muted artist and duration at the right, no border

## Do

- Keep every surface near-black and let album art supply the colour
- Use green #1ED760 only for play controls, selected items and the main call to action
- Make all buttons pills and all play or icon controls circles
- Type button labels in capitals at 14pt bold
- Keep type compact (10 to 24pt) and mostly either 700 or 400
- Pack content densely, with tight gaps and little empty space

## Don't

- Don't use green as a background wash or decoration
- Don't use light surfaces for primary areas
- Don't use square buttons
- Don't add a second brand colour; green plus grey is the whole palette
- Don't use airy line heights or large display type
- Don't draw grey outlines on cards; separate them by surface shade
