import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { materialName, minifySVG, weuiIcons } from '../scripts/build-icons.mjs'

const modules = join(import.meta.dirname, '..', 'node_modules')

describe('icon data build', () => {
  it('minifies an SVG to its drawing, keeping viewBox and paint attributes', () => {
    const svg = minifySVG(readFileSync(join(modules, 'lucide-static/icons/house.svg'), 'utf8'))
    expect(svg.startsWith('<svg')).toBe(true)
    expect(svg).toContain('viewBox="0 0 24 24"')
    expect(svg).toContain('stroke="currentColor"')
    expect(svg).toContain('stroke-width="2"')
    expect(svg).toContain('<path d="M15 21v-8')
    for (const removed of ['<!--', 'class=', 'width="24"', 'height="24"', '\n']) expect(svg).not.toContain(removed)
  })

  it('names Material fill variants with a .fill suffix', () => {
    expect(materialName('home-fill.svg')).toBe('home.fill')
    expect(materialName('home.svg')).toBe('home')
    expect(materialName('10k.svg')).toBe('10k')
  })

  it('extracts the WeUI icons from their stylesheet', () => {
    const icons = weuiIcons(readFileSync(join(modules, 'weui/src/style/icon/weui-icon.less'), 'utf8'))
    expect(Object.keys(icons)).toHaveLength(27)
    for (const name of ['success', 'search', 'close', 'warn', 'info']) {
      expect(icons[name]?.startsWith('<svg')).toBe(true)
      expect(icons[name]).toContain('</svg>')
    }
  })
})
