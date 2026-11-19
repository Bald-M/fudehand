# Style library

Reference files the Agent reads when the user names a style ("make it look like Linear") or asks for a design like a known product. Each file describes one style for Fudehand's layer model: colors, fonts, type scale, spacing, corner radius, how depth is shown, components, and do/don't. The Agent lists them with `style_list` and reads one with `style_read` (`scripts/style-library.mjs`); both tools are available to the chat panel's Agent harness and the MCP server. A style is never applied unless the user names one, and it never becomes part of the design document.

## Source and license

The files are adapted from [VoltAgent/awesome-design-md](https://github.com/VoltAgent/awesome-design-md) (`design-md/<name>/DESIGN.md`), Copyright (c) 2026 VoltAgent, licensed under the MIT License (see [LICENSE](LICENSE) in this directory). Changes from the originals: rewritten for a static layer model; responsive layout, interaction states, motion, gradients, shadows, and letter spacing removed; proprietary fonts replaced with fonts that ship with macOS, each naming the font it replaces; shortened to at most 6,000 characters.

The upstream files are third-party analyses of each brand's public website. They are not the brands' official design systems, and the brand names and trademarks belong to their owners. No brand fonts or logos are included.

## Adding a style

Follow the format of the existing files: a header with `name` (the file name without `.md`, lowercase letters, digits, and hyphens) and a one-sentence `description`, then the same sections. `tests/style-library.test.ts` checks the length limit, the header, the fonts, and that no web-only content is left.
