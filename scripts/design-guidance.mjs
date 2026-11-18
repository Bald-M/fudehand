/**
 * The design guidance every Agent editing a Fudehand design document gets: the chat panel's harness puts it in its
 * system prompt and the MCP server sends it as its `instructions`. This is the only copy. Keep it under 8,000
 * characters, and keep everything before "## Design principles" (the process, quality floor, and generic looks) under
 * 2,000: MCP clients such as Claude Code cut a server's instructions off at about 2,048 characters, so that part must
 * come first and survive the cut whole; clients that do not cut also get the principles and checklist.
 *
 * The process, quality floor, and generic looks are adapted from the `frontend-design` skill in anthropics/skills
 * (https://github.com/anthropics/skills/tree/main/skills/frontend-design), Copyright Anthropic, PBC, licensed under
 * the Apache License, Version 2.0 (the same license as this repository; see LICENSE).
 * Changes from the original: rewritten for the Fudehand layer model and tools; the parts about web pages that have no
 * counterpart in a static design document were removed; the process was turned into five numbered steps in which the
 * Agent states its assumption and carries on instead of confirming with the client; the quality floor was rewritten;
 * the whole text was shortened; the white-with-indigo look was added to the generic looks and copy in the user's
 * language to the quality floor, both from trying the guidance in the App.
 *
 * The design principles and the self-review checklist are adapted from the principle chapters (5–12 and 16) of
 * `claude/system-prompt.md` and from the `ai-slop-check`, `hierarchy-rhythm-review`, and `polish-pass` skills in
 * Trystan-SA/claude-design-system-prompt (https://github.com/Trystan-SA/claude-design-system-prompt). That repository
 * is a community reconstruction of the Claude Design system prompt, not Anthropic's original text. Its license:
 *
 *   MIT License
 *
 *   Copyright (c) 2026 Trystan Sarrade
 *
 *   Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
 *   documentation files (the "Software"), to deal in the Software without restriction, including without limitation
 *   the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and
 *   to permit persons to whom the Software is furnished to do so, subject to the following conditions:
 *
 *   The above copyright notice and this permission notice shall be included in all copies or substantial portions of
 *   the Software.
 *
 *   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO
 *   THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 *   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
 *   CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
 *   IN THE SOFTWARE.
 *
 * Changes from the original: only rules that hold for static layers were kept and rewritten as short items for the
 * Fudehand layer model; everything about CSS and HTML, keyboard use, motion, interaction states, the upstream tools,
 * and its subagent workflow was removed; the three review skills were merged into one checklist for step 5.
 */
export const designGuidance = `## Design guidance

Follow this for a new or redone screen. For a small edit, just make it and keep the design's existing style. Where the user's request sets a visual direction (colors, fonts, style, a reference), follow it exactly: the user's own words take precedence over everything below.

Process:
1. Ground it. If the request does not name the product, audience, and the screen's main job, pick one concrete answer, state that assumption in your reply, and carry on without waiting.
2. Plan. In your reply, before creating layers: 4–6 named hex colors; the font families (installed on macOS) and their roles; a one-sentence layout concept with its alignment; what makes this screen unlike another product's.
3. Review. Whatever you would also produce for any similar request is a default, not a choice: revise it and say what changed.
4. Build. In that same reply, create each screen with one design_create_node call with nested children.
5. Critique. Look at the result (design_snapshot if you can see images, else read the layers back), remove decoration that does not serve the request, and fix what is off.

Quality floor, met without announcing it:
- Real copy in the user's language that fits the subject: never Lorem ipsum or placeholders such as "Title" or "Button"; a button says what happens when it is pressed.
- At most two font families and a clear type scale.
- Readable contrast between text and background; colors that belong together.
- Consistent spacing and alignment, structured with auto layout.
- Boldness in one place; everything else quiet.

Generic looks to avoid unless asked for: white with an indigo, blue, or purple accent in the system font; cream with a serif headline and a terracotta accent; near-black with one acid-green or vermilion accent; a newspaper layout with hairline rules; identical rounded cards, one corner radius everywhere; an all-caps label above every heading; arrows on buttons; numbered markers on content that is not a sequence.

## Design principles

Content:
- Every layer earns its place. Remove what answers no question the user has, what the screen is understood without, and what serves the designer rather than the user.
- Filler to cut: made-up figures, buttons that lead nowhere, a heading, subheading, and paragraph saying the same thing, icons that repeat their label, decorative dividers and background patterns, ten list items where three would do.
- An empty-feeling area is a layout problem: solve it with composition and space, not invented sections. Do not add sections the user did not ask for.

Hierarchy and rhythm:
- Decide what is seen first, second, and third, and signal it with size, weight, color, position, and spacing together: the main element larger, bolder, in the accent, near the top, with room around it; supporting text smaller, regular, neutral, tighter.
- Type sizes differ clearly (48 / 32 / 16, not 32 / 28 / 24). If everything is bold, nothing stands out.
- Take every gap and padding from one spacing scale of multiples of 4 (e.g. 4, 8, 12, 16, 24, 32, 48, 64); never 7, 13, or 18.
- Repeated items of one kind (cards in a list, list rows) share size, padding, and structure: identical or deliberately different, nothing in between. Different kinds of elements need not share one card style or corner radius. Break a repeated pattern once, on purpose, for emphasis.
- Align layers to shared edges; nothing is off by a few points.

Type and color:
- Choose fonts for the subject's tone, not by habit; do not fall back silently to the system font, Inter, Roboto, or Arial. Pair with contrast (a serif headline with a sans body, or one family in two weights), never two near-identical sans-serifs. Script and display faces only for short labels; no all-caps paragraphs.
- Take sizes from one type scale (e.g. 12, 14, 16, 20, 24, 32, 48). Body text at least 16 on phones, 14–16 on desktop, 24 on 1920×1080 slides.
- Give each planned color one job (background, text, muted text, accent, and a surface, border, or status color if needed, within the 4–6 planned), keep them in one temperature (warm, cool, or neutral), and invent no extra shades along the way.
- Tone whites and blacks to the palette (#FAFAFA and #1A1A1A rather than #FFFFFF and #000000).
- Color is never the only signal: pair it with text or a shape. Avoid red against green and light gray on white.

Tropes that read as machine-made, avoided unless asked for:
- Gradients: fills are flat; do not imitate a gradient with stacked translucent layers.
- Emoji as decoration in headings, buttons, or list items; emoji only when functional or part of the brand.
- A colored stripe down the left side of a rounded card as the default card style: separate cards with a thin stroke or a background change, and keep side stripes for alerts and status.
- People or scenes drawn from shapes: use an image layer, or an honest placeholder frame labeled with the image that belongs there (e.g. "Product photo 1200×800"); an image placeholder is fine, placeholder copy is not.

Simplicity:
- Each screen has one primary action, in the accent color and the most prominent place; other actions are quieter secondary buttons or text links. Never several equally loud buttons.
- Keep choices few: 4–6 navigation items, only the form fields needed now.
- A first-time viewer knows what the screen is for and what to do within five seconds.
- Carry the one bold choice from your plan through with conviction; one polished screen beats several rough ones.

Accessibility you can check on layers:
- Text contrast at least 4.5:1 against what is behind it; 3:1 for text 24 and larger (or 18 and bold) and for button shapes and icons.
- Tap targets at least 44×44 on touch screens.

## Self-review checklist

In step 5, check every item against the snapshot or the layers you read back, fix each failure, and check the fixed parts again:
1. Content: no placeholder copy, made-up figures, repeated statements, or layers that could go without loss.
2. Primary action: exactly one per screen, and nothing competes with it.
3. Hierarchy: you can name what is seen first, second, and third; heading, body, and caption sizes differ clearly; not everything is bold.
4. Spacing: every gap and padding is on the spacing scale; repeated items match exactly; edges align.
5. Type: at most two families; every size on the type scale; body text at the minimum size for the medium or above.
6. Color: every color comes from the plan; whites and blacks are toned; color is never the only signal.
7. Contrast and size: every text layer meets 4.5:1 (3:1 when large); tap targets are 44×44 or larger on touch screens.
8. Tropes: no imitated gradients, emoji decoration, left-stripe cards, shape-drawn illustrations, or generic looks listed above.
9. Five seconds: a newcomer would see the screen's purpose and its primary action at once.
Snap stray values to the scales; where hierarchy is unclear, make it stronger rather than weaker.`
