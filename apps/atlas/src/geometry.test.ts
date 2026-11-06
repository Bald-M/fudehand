import { describe, expect, it } from 'vitest'
import { fitRects, moveFrame, screenToWorld, zoomAt } from './geometry'

describe('画布几何', () => {
  it('缩放时保持鼠标下方的画布坐标不变', () => {
    const view = { x: -180, y: 42, scale: 0.4 }
    const cursor = { x: 280, y: 190 }
    const world = screenToWorld(cursor, view)
    const next = zoomAt(view, cursor, 1.3)
    expect(screenToWorld(cursor, next)).toEqual(world)
    expect(zoomAt(view, cursor, 100).scale).toBe(2)
    expect(zoomAt(view, cursor, 0.001).scale).toBe(0.1)
  })
  it('在各缩放比例下按画布坐标移动画框', () => {
    expect(moveFrame({ x: 40, y: -20 }, { x: 80, y: 60 }, 0.5)).toEqual({ x: 200, y: 100 })
  })
  it('将正负坐标位置的画框全部容纳在视口内', () => {
    const rects = [{ x: -200, y: -100, width: 390, height: 888 }, { x: 400, y: 100, width: 1440, height: 944 }]
    const view = fitRects(rects, { width: 1200, height: 800 })
    for (const rect of rects) {
      expect(rect.x * view.scale + view.x).toBeGreaterThanOrEqual(63.99)
      expect(rect.y * view.scale + view.y).toBeGreaterThanOrEqual(63.99)
      expect((rect.x + rect.width) * view.scale + view.x).toBeLessThanOrEqual(1136.01)
      expect((rect.y + rect.height) * view.scale + view.y).toBeLessThanOrEqual(736.01)
    }
  })
  it('将单个画框居中，且缩放不超过 100%', () => {
    expect(fitRects([{ x: 100, y: 50, width: 200, height: 100 }], { width: 1000, height: 800 })).toEqual({ x: 300, y: 300, scale: 1 })
    expect(fitRects([], { width: 1000, height: 800 })).toEqual({ x: 0, y: 0, scale: 1 })
  })
})
