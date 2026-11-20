# Design foundations

The base design rules shared by the starter templates bundled with the App (`native/Resources/Templates/`). Each template shows
them in its "Design system" frame. People and Agents can follow them in any design; they are a convention, not part of the
`.fudehand` format, and changing a value in one design does not update others. `BundledTemplateTests` checks that every template
uses only the values on this page, so update both together.

## Colors

| Name | Hex | Job |
| --- | --- | --- |
| Canvas | `#F6F5F2` | Page and screen background |
| Surface | `#FFFFFF` | Cards, panels, inputs; text on Pine |
| Ink | `#1D1C21` | Primary text and icons |
| Muted | `#6B6874` | Secondary text, captions, inactive icons |
| Line | `#E4E1DB` | Borders and dividers (1 pt strokes) |
| Pine | `#1F6B57` | The single accent: primary buttons, active states, key figures |
| Pine Tint | `#E1EEE9` | Accent backgrounds: selected rows, badges, highlights |

Use Pine in one place per area; everything else stays neutral. Ink on Canvas, Muted on Surface, and Surface on Pine all meet
WCAG AA for body text.

## Type

One family, **Avenir Next** (bundled with macOS), in three weights: 400 Regular for body, 500 Medium for labels and buttons,
600 Demi Bold for headings and figures.

| Role | Size | Weight |
| --- | --- | --- |
| Display | 48 | 600 |
| Title | 32 | 600 |
| Heading | 24 | 600 |
| Subheading | 20 | 500 |
| Body | 16 | 400 |
| Small | 14 | 400 or 500 |
| Caption | 12 | 500 |

Line height is the font default (leave it unset): Avenir Next already sets generous leading. Body text is at least 16 on
phones and 14–16 on desktop.

## Spacing

Every gap and padding is one of **4, 8, 12, 16, 24, 32, 48, 64** (or 0). Use 16–24 inside cards, 24–32 between sections on a
phone, and 32–64 on desktop.

## Corner radius

| Radius | Use |
| --- | --- |
| 0 | Screens, full-bleed areas |
| 4 | Tags, small swatches |
| 8 | Buttons, inputs, list rows |
| 16 | Cards and panels |
| 999 | Pills and round avatars |

## Frame sizes

| Template | Size |
| --- | --- |
| Mobile App | 393 × 852 (iPhone 15/16) |
| Web Page | 1440 wide, height grows with content |
| Dashboard | 1440 × 900 |
