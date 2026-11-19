import { describe, expect, it } from 'vitest'
import { readdir, readFile } from 'node:fs/promises'
import { join } from 'node:path'
import { callTool, tools } from '../scripts/fudehand-tools.mjs'
import { designGuidance } from '../scripts/design-guidance.mjs'

const STYLES = join(import.meta.dirname, '..', 'styles')
// No App is running: the style tools must work without the control channel.
const ctx = { root: '/nonexistent', socketPath: '/nonexistent/control.sock' }
const text = (result: { content: { text?: string }[] }) => result.content.map(item => item.text ?? '').join('\n')

async function styleFiles() {
  const names = (await readdir(STYLES)).filter(name => name.endsWith('.md') && name !== 'README.md')
  return Promise.all(names.map(async name => ({ name, content: await readFile(join(STYLES, name), 'utf8') })))
}

// macOS ships these families; "System font" means San Francisco, used by omitting fontFamily.
const MAC_FONTS = new Set([
  'System font', 'Helvetica Neue', 'Helvetica', 'Avenir Next', 'Avenir', 'Futura', 'Gill Sans', 'Optima', 'Seravek',
  'Georgia', 'Charter', 'Iowan Old Style', 'Didot', 'Baskerville', 'Big Caslon', 'Hoefler Text', 'Palatino',
  'Times New Roman', 'Menlo', 'Monaco', 'Courier New', 'American Typewriter', 'Rockwell',
])

describe('style library files', () => {
  it('has a first batch of at most 12 styles', async () => {
    const files = await styleFiles()
    expect(files.length).toBeGreaterThanOrEqual(8)
    expect(files.length).toBeLessThanOrEqual(12)
  })

  it('keeps every style file within 6000 characters', async () => {
    for (const { name, content } of await styleFiles()) expect([...content].length, name).toBeLessThanOrEqual(6000)
  })

  it('names each file after its slug and gives it a one-sentence description', async () => {
    for (const { name, content } of await styleFiles()) {
      const header = content.match(/^---\nname: ([a-z0-9-]+)\ndescription: (.+)\n---\n/)
      expect(header, name).not.toBeNull()
      expect(`${header![1]}.md`).toBe(name)
    }
  })

  it('leaves out what the layer model cannot do: breakpoints, interaction states, motion', async () => {
    for (const { name, content } of await styleFiles()) {
      expect(content, name).not.toMatch(/breakpoint|responsive|hover|pressed|focus|active state|transition|animat|motion|collapse|media query/i)
    }
  })

  it('uses only fonts that ship with macOS and names the font each replaces', async () => {
    for (const { name, content } of await styleFiles()) {
      const lines = content.split('## Fonts')[1]?.split('\n## ')[0].split('\n').filter(line => line.startsWith('- ')) ?? []
      expect(lines.length, name).toBeGreaterThan(0)
      for (const line of lines) {
        const match = line.match(/^- [^:]+: (.+?) \(replaces [^)]+\)/)
        expect(match, `${name}: ${line}`).not.toBeNull()
        expect(MAC_FONTS.has(match![1]), `${name}: ${match![1]}`).toBe(true)
      }
    }
  })

  it('credits the upstream source and states the files are not official brand systems', async () => {
    for (const { name, content } of await styleFiles()) {
      expect(content, name).toContain('VoltAgent/awesome-design-md (MIT)')
      expect(content, name).toMatch(/not its official design system/)
    }
    const license = await readFile(join(STYLES, 'LICENSE'), 'utf8')
    expect(license).toMatch(/MIT License/)
    expect(license).toMatch(/Copyright \(c\) 2026 VoltAgent/)
  })
})

describe('style tools', () => {
  it('offers style_list and style_read with English descriptions', () => {
    const names = tools.map((tool: { name: string }) => tool.name)
    expect(names).toEqual(expect.arrayContaining(['style_list', 'style_read']))
    const read = tools.find((tool: { name: string }) => tool.name === 'style_read')
    expect(read.inputSchema.required).toEqual(['name'])
  })

  it('lists every style with its description, without the App running', async () => {
    const result = await callTool('style_list', {}, ctx)
    expect(result.isError).toBeFalsy()
    const listed = JSON.parse(text(result)) as { name: string, description: string }[]
    const files = await styleFiles()
    expect(listed.map(style => style.name).sort()).toEqual(files.map(file => file.name.replace(/\.md$/, '')).sort())
    for (const style of listed) expect(style.description.length).toBeGreaterThan(10)
  })

  it('reads one style file by name', async () => {
    const [first] = await styleFiles()
    const result = await callTool('style_read', { name: first.name.replace(/\.md$/, '') }, ctx)
    expect(result.isError).toBeFalsy()
    expect(text(result)).toBe(first.content)
  })

  it('reports an unknown style with the available names', async () => {
    const result = await callTool('style_read', { name: 'no-such-style' }, ctx)
    expect(result.isError).toBe(true)
    expect(text(result)).toMatch(/^Unknown style: no-such-style\. Available styles: [a-z0-9-]+(, [a-z0-9-]+)+$/)
  })

  it('refuses names that could reach outside the style library', async () => {
    for (const name of ['../package', '..', 'a/b', 'a\\b', '/etc/passwd', 'README', 'LICENSE', '', 'linear.md']) {
      const result = await callTool('style_read', { name }, ctx)
      expect(result.isError, name).toBe(true)
      expect(text(result), name).not.toMatch(/"name"|MIT License|# Fudehand/)
    }
  })
})

describe('style rule in the design guidance', () => {
  it('reads a style only when the user names one', () => {
    expect(designGuidance).toMatch(/style_list/)
    expect(designGuidance).toMatch(/style_read/)
    expect(designGuidance).toMatch(/never apply one unasked/)
  })
})
