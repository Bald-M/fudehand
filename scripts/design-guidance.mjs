/**
 * The design guidance every Agent editing a Fudehand design document gets: the chat panel's harness puts it in its
 * system prompt and the MCP server sends it as its `instructions`. This is the only copy. Keep it under 2,000 characters:
 * MCP clients such as Claude Code cut a server's instructions off at about 2,048.
 *
 * Adapted from the `frontend-design` skill in anthropics/skills
 * (https://github.com/anthropics/skills/tree/main/skills/frontend-design), Copyright Anthropic, PBC, licensed under
 * the Apache License, Version 2.0 (the same license as this repository; see LICENSE).
 * Changes from the original: rewritten for the Fudehand layer model and tools; the parts about web pages that have no
 * counterpart in a static design document were removed; the process was turned into five numbered steps in which the
 * Agent states its assumption and carries on instead of confirming with the client; the quality floor was rewritten;
 * the whole text was shortened; the white-with-indigo look was added to the generic looks and copy in the user's
 * language to the quality floor, both from trying the guidance in the App; built-in icons were added to the quality floor,
 * with a few sentences tightened to make room.
 */
export const designGuidance = `## Design guidance

This is for a new or redone screen; make a small edit in the design's existing style. Follow any visual direction the user sets (colors, fonts, style, a reference) exactly: the user's own words take precedence over everything below.

Process:
1. Ground it. If the request leaves the product, audience, or the screen's main job open, pick one, state the assumption in your reply, and carry on without waiting.
2. Plan. In your reply, before creating layers: 4–6 named hex colors; installed macOS font families and their roles; a one-sentence layout concept with its alignment; what makes this screen unlike another product's.
3. Review. Whatever you would also produce for any similar request is a default, not a choice: revise it and say what changed.
4. Build. In the same reply, build each screen in one design_create_node call with nested children.
5. Critique. Check the result (design_snapshot, or read the layers back), remove decoration that does not serve the request, and fix what is off.

Quality floor, met without announcing it:
- Real copy in the user's language that fits the subject: never Lorem ipsum or placeholders like "Title"; a button says what it does.
- Real icons (design_search_icons), not shapes or letters: sf for Apple, material-* for Android, weui for WeChat mini programs, lucide for web; one library per screen.
- At most two font families and a clear type scale.
- Readable text contrast; colors that belong together.
- Consistent spacing and alignment, structured with auto layout.
- Boldness in one place; everything else quiet.

Generic looks to avoid unless asked for: white with an indigo/blue/purple accent in the system font; cream with a serif headline and a terracotta accent; near-black with one acid-green or vermilion accent; a newspaper layout with hairline rules; identical rounded cards, one corner radius everywhere; an all-caps label above every heading; arrows on buttons; numbered markers on content that is not a sequence.`
