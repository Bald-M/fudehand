import { readdir, readFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { join } from 'node:path'

/**
 * The style library: reference files the Agent reads when the user names a style (see styles/README.md).
 * Unlike the design tools these never touch the design document, so they run in Node and do not go through the
 * App's control channel (ADR 0007).
 */
const STYLES = fileURLToPath(new URL('../styles/', import.meta.url))
const SLUG = /^[a-z0-9-]+$/

const text = value => ({ content: [{ type: 'text', text: value }] })

async function styleNames() {
  return (await readdir(STYLES)).filter(file => file.endsWith('.md') && file !== 'README.md').map(file => file.slice(0, -3)).sort()
}

export const styleTools = [
  {
    name: 'style_list',
    description: 'List the styles in the style library (name and a one-sentence description). Use it only when the user names a style or asks for a design that looks like a product, then read the matching style with style_read. Works without Fudehand running.',
    inputSchema: { type: 'object', properties: {}, required: [] },
    async run() {
      const styles = await Promise.all((await styleNames()).map(async name => {
        const content = await readFile(join(STYLES, `${name}.md`), 'utf8')
        return { name, description: content.match(/^description: (.+)$/m)?.[1] ?? '' }
      }))
      return text(JSON.stringify(styles, null, 2))
    },
  },
  {
    name: 'style_read',
    description: 'Read one style file from the style library: colors, fonts (macOS substitutes), type scale, spacing, corner radius, components, and do/don\'t. Build with its values. The styles are third-party analyses of public websites, not official brand systems. Works without Fudehand running.',
    inputSchema: { type: 'object', properties: { name: { type: 'string', description: 'Style name as returned by style_list' } }, required: ['name'] },
    async run({ name }) {
      const names = await styleNames()
      // Only a bare slug from the list is accepted, so a name can never form a path outside the style library.
      if (typeof name !== 'string' || !SLUG.test(name) || !names.includes(name)) {
        throw new Error(`Unknown style: ${name}. Available styles: ${names.join(', ')}`)
      }
      return text(await readFile(join(STYLES, `${name}.md`), 'utf8'))
    },
  },
]
