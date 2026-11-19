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
 * with a few sentences tightened to make room; the rule for the style library (#115) was added and
 * the wording tightened again to stay under the limit.
 */
export const designGuidance = `## Design guidance

This is for a new or redone screen; keep small edits in the existing style. Follow any visual direction the user sets (colors, fonts, a reference) exactly: the user's own words take precedence. For a named style or product look, use style_list then style_read, or say none exists; never apply one unasked.

Process:
1. Ground it. If the request leaves the product, audience, or the screen's main job open, pick one, state the assumption in your reply, and carry on without waiting.
2. Plan. In your reply, before creating layers: 4–6 named hex colors; macOS font families and roles; a one-line layout concept with its alignment; what makes this screen unlike another product's.
3. Review. Whatever you'd produce for similar requests is a default, not a choice: revise it and say what changed.
4. Build. In that reply, build each screen in one design_create_node call with nested children.
5. Critique. Check the result (design_snapshot or layers), remove decoration that doesn't serve the request, and fix what's off.

Quality floor, met without announcing it:
- Real copy in the user's language that fits the subject: never Lorem ipsum or placeholders like "Title"; a button says what it does.
- Real icons (design_search_icons), not shapes or letters: sf for Apple, material-* for Android, weui for WeChat mini programs, lucide for web; one library per screen.
- At most two font families and a clear type scale.
- Readable text contrast; colors that belong together.
- Consistent spacing and alignment, with auto layout.
- Boldness in one place; everything else quiet.

Generic looks to avoid unless asked: white with an indigo/blue/purple accent in the system font; cream with a serif headline and a terracotta accent; near-black with one acid-green or vermilion accent; a newspaper layout with hairline rules; identical rounded cards, one corner radius everywhere; an all-caps label above every heading; arrows on buttons; numbered markers on content that isn't a sequence.`
