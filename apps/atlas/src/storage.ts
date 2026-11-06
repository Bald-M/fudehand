import type { Point, Project, Viewport } from './catalog'
import { MAX_SCALE, MIN_SCALE } from './geometry'

export type Theme = 'system' | 'light' | 'dark'
export interface Layout { viewport: Viewport; positions: Record<string, Point> }
interface StorageLike { getItem(key: string): string | null; setItem(key: string, value: string): void; removeItem(key: string): void }
const PREFIX = 'ui-atlas:v1:'
const finite = (value: unknown): value is number => typeof value === 'number' && Number.isFinite(value)
const object = (value: unknown): value is Record<string, unknown> => typeof value === 'object' && value !== null && !Array.isArray(value)
const validPoint = (value: unknown): value is Point => object(value) && finite(value.x) && finite(value.y)

export function readJson(storage: StorageLike | undefined, key: string): unknown {
  try { const raw = storage?.getItem(PREFIX + key); return raw ? JSON.parse(raw) : null } catch { return null }
}
export function writeJson(storage: StorageLike | undefined, key: string, value: unknown) {
  try { storage?.setItem(PREFIX + key, JSON.stringify(value)) } catch { /* 存储不可用时仍可正常浏览。 */ }
}
export function clearLayout(storage: StorageLike | undefined, id: string) {
  try { storage?.removeItem(PREFIX + 'layout:' + id) } catch { /* 当前会话仍可恢复默认布局。 */ }
}
export function defaultPositions(project: Project): Record<string, Point> {
  return Object.fromEntries(project.frames.map(frame => [frame.id, { x: frame.x, y: frame.y }]))
}
export function restoreLayout(raw: unknown, project: Project): Layout | null {
  if (!object(raw) || raw.layoutVersion !== project.layoutVersion || !object(raw.viewport) || !object(raw.positions)) return null
  const view = raw.viewport
  if (!validPoint(view) || !finite(view.scale) || view.scale < MIN_SCALE || view.scale > MAX_SCALE) return null
  const positions = defaultPositions(project)
  for (const frame of project.frames) {
    const point = raw.positions[frame.id]
    if (point === undefined) continue
    if (!validPoint(point)) return null
    positions[frame.id] = { x: point.x, y: point.y }
  }
  return { viewport: { x: view.x, y: view.y, scale: view.scale }, positions }
}
export function loadLayout(storage: StorageLike | undefined, project: Project): Layout | null {
  return restoreLayout(readJson(storage, 'layout:' + project.id), project)
}
export function saveLayout(storage: StorageLike | undefined, project: Project, layout: Layout) {
  writeJson(storage, 'layout:' + project.id, { layoutVersion: project.layoutVersion, ...layout })
}
export function readTheme(storage: StorageLike | undefined): Theme {
  const value = readJson(storage, 'theme')
  return value === 'light' || value === 'dark' ? value : 'system'
}
export function browserStorage(): StorageLike | undefined {
  try { return window.localStorage } catch { return undefined }
}
