import type { Point, Viewport } from './catalog'

export const MIN_SCALE = 0.1
export const MAX_SCALE = 2
export const FRAME_HEADER = 44
export interface Rect extends Point { width: number; height: number }
export interface Size { width: number; height: number }
export const clampScale = (scale: number) => Math.min(MAX_SCALE, Math.max(MIN_SCALE, scale))

export function screenToWorld(point: Point, viewport: Viewport): Point {
  return { x: (point.x - viewport.x) / viewport.scale, y: (point.y - viewport.y) / viewport.scale }
}

export function zoomAt(viewport: Viewport, point: Point, scale: number): Viewport {
  const nextScale = clampScale(scale)
  const world = screenToWorld(point, viewport)
  return { x: point.x - world.x * nextScale, y: point.y - world.y * nextScale, scale: nextScale }
}

export function moveFrame(start: Point, screenDelta: Point, scale: number): Point {
  return { x: start.x + screenDelta.x / scale, y: start.y + screenDelta.y / scale }
}

export function fitRects(rects: Rect[], size: Size, padding = 64): Viewport {
  if (!rects.length || size.width <= 0 || size.height <= 0) return { x: 0, y: 0, scale: 1 }
  const left = Math.min(...rects.map(rect => rect.x))
  const top = Math.min(...rects.map(rect => rect.y))
  const right = Math.max(...rects.map(rect => rect.x + rect.width))
  const bottom = Math.max(...rects.map(rect => rect.y + rect.height))
  const scale = Math.min(1, clampScale(Math.min(
    Math.max(1, size.width - padding * 2) / Math.max(1, right - left),
    Math.max(1, size.height - padding * 2) / Math.max(1, bottom - top),
  )))
  return {
    x: (size.width - (right - left) * scale) / 2 - left * scale,
    y: (size.height - (bottom - top) * scale) / 2 - top * scale,
    scale,
  }
}
