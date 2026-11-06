import { describe, expect, it } from 'vitest'
import { catalog } from './catalog'
import { loadLayout, readTheme, restoreLayout, saveLayout } from './storage'

const project = catalog.projects[0]!
const layout = { viewport: { x: -50, y: 100, scale: 0.5 }, positions: { mobile: { x: 60, y: -10 } } }
const encoded = () => ({ layoutVersion: project.layoutVersion, ...layout })

describe('layout persistence', () => {
  it('round trips layout while defaulting newly added frames from catalog', () => {
    const values = new Map<string, string>()
    const storage = { getItem: (key: string) => values.get(key) ?? null, setItem: (key: string, value: string) => { values.set(key, value) }, removeItem: (key: string) => { values.delete(key) } }
    saveLayout(storage, project, layout)
    const restored = loadLayout(storage, project)!
    expect(restored.viewport).toEqual(layout.viewport)
    expect(restored.positions.mobile).toEqual(layout.positions.mobile)
    expect(restored.positions.web).toEqual({ x: project.frames[1]!.x, y: project.frames[1]!.y })
    expect(values.size).toBe(1)
  })
  it('rejects stale versions, damaged structure, invalid zoom and nonfinite coordinates', () => {
    expect(restoreLayout({ ...encoded(), layoutVersion: 99 }, project)).toBeNull()
    expect(restoreLayout({ ...encoded(), viewport: { ...layout.viewport, scale: 20 } }, project)).toBeNull()
    expect(restoreLayout({ ...encoded(), positions: { mobile: { x: Infinity, y: 0 } } }, project)).toBeNull()
    expect(restoreLayout({ ...encoded(), viewport: { x: 0, y: NaN, scale: 1 } }, project)).toBeNull()
    expect(restoreLayout(null, project)).toBeNull()
  })
  it('survives blocked storage and malformed JSON', () => {
    const blocked = { getItem: () => { throw new Error('blocked') }, setItem: () => { throw new Error('blocked') }, removeItem: () => { throw new Error('blocked') } }
    expect(loadLayout(blocked, project)).toBeNull()
    expect(() => saveLayout(blocked, project, layout)).not.toThrow()
    expect(readTheme(blocked)).toBe('system')
    expect(loadLayout({ ...blocked, getItem: () => '{bad' }, project)).toBeNull()
  })
})
