<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import Icon from './Icon.vue'
import { catalog, frameUrl } from './catalog'
import type { Frame, Point, Project, Viewport } from './catalog'
import { fitRects, FRAME_HEADER, moveFrame, zoomAt } from './geometry'
import { browserStorage, clearLayout, defaultPositions, loadLayout, readJson, readTheme, saveLayout, writeJson } from './storage'
import type { Theme } from './storage'

const storage = browserStorage()
const projects = catalog.projects
const recent = readJson(storage, 'recent')
const selectedId = ref(projects.find(project => project.enabled && project.id === recent)?.id || projects.find(project => project.enabled)?.id || '')
const current = computed(() => projects.find(project => project.id === selectedId.value && project.enabled))
const query = ref('')
const filtered = computed(() => projects.filter(project => [project.title, project.subtitle, project.framework, ...project.tags].join(' ').toLowerCase().includes(query.value.trim().toLowerCase())))
const enabledCount = projects.filter(project => project.enabled).length
const canvas = ref<HTMLElement>()
const searchInput = ref<HTMLInputElement>()
const viewport = ref<Viewport>({ x: 0, y: 0, scale: 1 })
const positions = ref<Record<string, Point>>({})
const selectedFrame = ref('')
const interactionFrame = ref<string | null>(null)
const theme = ref<Theme>(readTheme(storage))
const sidebarOpen = ref(false)
const spaceHeld = ref(false)
const dragging = ref(false)
const helpOpen = ref(false)
const loaded = ref<Record<string, boolean>>({})
const timedOut = ref<Record<string, boolean>>({})
const reloads = ref<Record<string, number>>({})
const iframeRefs = new Map<string, HTMLIFrameElement>()
const timers = new Map<string, ReturnType<typeof setTimeout>>()
let saveTimer: ReturnType<typeof setTimeout> | undefined
let media: MediaQueryList | undefined
let drag: { pointerId: number; mode: 'canvas' | 'frame'; start: Point; origin: Point; frame?: string } | null = null
let activeCapture: HTMLElement | null = null

const worldStyle = computed(() => ({ transform: `translate(${viewport.value.x}px, ${viewport.value.y}px) scale(${viewport.value.scale})` }))
const zoomLabel = computed(() => Math.round(viewport.value.scale * 100) + '%')
const activeFrame = computed(() => current.value?.frames.find(frame => frame.id === selectedFrame.value))
const sourceUrl = computed(() => {
  try {
    const value = current.value?.sourceUrl
    if (!value) return null
    const url = new URL(value)
    return url.protocol === 'https:' || url.protocol === 'http:' ? url.href : null
  } catch { return null }
})
const platformName: Record<string, string> = { mobile: '移动端', web: '网页端', desktop: '桌面端' }
const dotStyle = computed(() => ({ backgroundPosition: `${viewport.value.x}px ${viewport.value.y}px`, backgroundSize: `${24 * viewport.value.scale}px ${24 * viewport.value.scale}px` }))

function point(event: PointerEvent | WheelEvent): Point {
  const rect = canvas.value!.getBoundingClientRect()
  return { x: event.clientX - rect.left, y: event.clientY - rect.top }
}
function size() { return { width: canvas.value?.clientWidth || 0, height: canvas.value?.clientHeight || 0 } }
function center() { const dimensions = size(); return { x: dimensions.width / 2, y: dimensions.height / 2 } }
function position(frame: Frame) { return positions.value[frame.id] || { x: frame.x, y: frame.y } }
function rects(frames: Frame[]) { return frames.map(frame => ({ ...position(frame), width: frame.width, height: frame.height + FRAME_HEADER })) }
function snapshot() { return { viewport: { ...viewport.value }, positions: Object.fromEntries(Object.entries(positions.value).map(([id, value]) => [id, { ...value }])) } }
function persist() {
  if (saveTimer) clearTimeout(saveTimer)
  if (current.value) saveLayout(storage, current.value, snapshot())
}
function scheduleSave() {
  if (saveTimer) clearTimeout(saveTimer)
  saveTimer = setTimeout(persist, 160)
}
function setView(value: Viewport) { viewport.value = value; scheduleSave() }
function fitAll() { if (current.value) setView(fitRects(rects(current.value.frames), size())) }
function focusFrame(frame: Frame) {
  selectedFrame.value = frame.id
  exitInteraction()
  setView(fitRects(rects([frame]), size(), 64))
}
function changeZoom(scale: number) { setView(zoomAt(viewport.value, center(), scale)) }
function exitInteraction() { interactionFrame.value = null }
function interact(frame: Frame) { selectedFrame.value = frame.id; interactionFrame.value = frame.id }
function clearPreviewTimers() { for (const timer of timers.values()) clearTimeout(timer); timers.clear() }
function armLoadTimer(frame: Frame) {
  if (timers.has(frame.id)) clearTimeout(timers.get(frame.id))
  timers.set(frame.id, setTimeout(() => { if (!loaded.value[frame.id]) timedOut.value[frame.id] = true }, 12000))
}
function onFrameLoad(frame: Frame) {
  loaded.value[frame.id] = true
  timedOut.value[frame.id] = false
  clearTimeout(timers.get(frame.id))
  timers.delete(frame.id)
}
function reload(frame: Frame) {
  exitInteraction()
  loaded.value[frame.id] = false
  timedOut.value[frame.id] = false
  reloads.value[frame.id] = (reloads.value[frame.id] || 0) + 1
  armLoadTimer(frame)
}
function setFrameRef(id: string, element: unknown) {
  if (element instanceof HTMLIFrameElement) iframeRefs.set(id, element)
  else iframeRefs.delete(id)
}
async function openProject() {
  exitInteraction()
  clearPreviewTimers()
  loaded.value = {}
  timedOut.value = {}
  reloads.value = {}
  sidebarOpen.value = false
  selectedFrame.value = current.value?.frames[0]?.id || ''
  if (!current.value) return
  const project = current.value
  const saved = loadLayout(storage, project)
  positions.value = saved?.positions || defaultPositions(project)
  if (saved) viewport.value = saved.viewport
  writeJson(storage, 'recent', project.id)
  await nextTick()
  if (current.value?.id !== project.id) return
  if (!saved) fitAll()
  project.frames.forEach(armLoadTimer)
}
function resetLayout() {
  if (!current.value) return
  exitInteraction()
  clearLayout(storage, current.value.id)
  positions.value = defaultPositions(current.value)
  fitAll()
}
function chooseProject(project: Project) { if (project.enabled) selectedId.value = project.id }
function startCanvasDrag(event: PointerEvent) {
  if (event.button !== 0 || !canvas.value) return
  if ((event.target as HTMLElement).closest('button, a, select, input') && !(event.target as HTMLElement).closest('.frame-cover')) return
  exitInteraction()
  canvas.value.focus({ preventScroll: true })
  dragging.value = false
  drag = { pointerId: event.pointerId, mode: 'canvas', start: point(event), origin: { x: viewport.value.x, y: viewport.value.y } }
  activeCapture = canvas.value
}
function startFrameDrag(event: PointerEvent, frame: Frame) {
  if (event.button !== 0 || !canvas.value) return
  event.stopPropagation()
  if (spaceHeld.value) { startCanvasDrag(event); return }
  selectedFrame.value = frame.id
  exitInteraction()
  dragging.value = false
  drag = { pointerId: event.pointerId, mode: 'frame', start: point(event), origin: { ...position(frame) }, frame: frame.id }
  activeCapture = canvas.value
}
function onPointerMove(event: PointerEvent) {
  if (!drag || event.pointerId !== drag.pointerId) return
  const next = point(event)
  const delta = { x: next.x - drag.start.x, y: next.y - drag.start.y }
  if (!dragging.value) {
    if (Math.hypot(delta.x, delta.y) < 3) return
    dragging.value = true
    activeCapture?.setPointerCapture(event.pointerId)
  }
  if (drag.mode === 'canvas') viewport.value = { ...viewport.value, x: drag.origin.x + delta.x, y: drag.origin.y + delta.y }
  else if (drag.frame) positions.value[drag.frame] = moveFrame(drag.origin, delta, viewport.value.scale)
}
function finishDrag(event?: PointerEvent) {
  // pointerup, lostpointercapture and the window listener all land here; only the first one ending a real drag saves.
  if (!drag || (event && event.pointerId !== drag.pointerId)) return
  const moved = dragging.value
  if (activeCapture?.hasPointerCapture(drag.pointerId)) activeCapture.releasePointerCapture(drag.pointerId)
  activeCapture = null
  drag = null
  dragging.value = false
  if (moved) persist()
}
function onWheel(event: WheelEvent) {
  if (event.ctrlKey || event.metaKey) setView(zoomAt(viewport.value, point(event), viewport.value.scale * Math.exp(-event.deltaY * 0.005)))
  else {
    const factor = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? size().height : 1
    setView({ ...viewport.value, x: viewport.value.x - event.deltaX * factor, y: viewport.value.y - event.deltaY * factor })
  }
}
function frameKey(event: KeyboardEvent, frame: Frame) {
  if (event.target !== event.currentTarget) return
  const directions: Record<string, Point> = { ArrowLeft: { x: -10, y: 0 }, ArrowRight: { x: 10, y: 0 }, ArrowUp: { x: 0, y: -10 }, ArrowDown: { x: 0, y: 10 } }
  const delta = directions[event.key]
  if (delta) {
    event.preventDefault()
    const origin = position(frame)
    positions.value[frame.id] = { x: origin.x + delta.x * (event.shiftKey ? 10 : 1), y: origin.y + delta.y * (event.shiftKey ? 10 : 1) }
    scheduleSave()
  }
}
function typingTarget(target: EventTarget | null) { return target instanceof HTMLElement && !!target.closest('input, textarea, select, button, a, [contenteditable="true"]') }
function onKeyDown(event: KeyboardEvent) {
  if (event.key === 'Escape') { exitInteraction(); sidebarOpen.value = false; helpOpen.value = false }
  if (typingTarget(event.target) || event.ctrlKey || event.metaKey || event.altKey) return
  if (event.key === '/') {
    event.preventDefault()
    sidebarOpen.value = true
    void nextTick(() => searchInput.value?.focus())
  }
  if (event.code === 'Space') { event.preventDefault(); spaceHeld.value = true }
}
function onKeyUp(event: KeyboardEvent) { if (event.code === 'Space') spaceHeld.value = false }
function onBlur() { spaceHeld.value = false; finishDrag() }
function onMessage(event: MessageEvent) {
  const frame = current.value?.frames.find(frame => frame.id === interactionFrame.value)
  if (!frame || event.data?.type !== 'ui-atlas:exit-preview') return
  const iframe = iframeRefs.get(frame.id)
  if (event.source === iframe?.contentWindow && event.origin === new URL(frameUrl(current.value!, frame)).origin) {
    exitInteraction()
    canvas.value?.focus({ preventScroll: true })
  }
}
function applyTheme() { document.documentElement.dataset.theme = theme.value === 'system' ? (media?.matches ? 'dark' : 'light') : theme.value }
watch(theme, () => { writeJson(storage, 'theme', theme.value); applyTheme() })
watch(selectedId, async (_id, oldId) => {
  if (saveTimer) clearTimeout(saveTimer)
  const previous = projects.find(project => project.id === oldId)
  if (previous) saveLayout(storage, previous, snapshot())
  await openProject()
})
onMounted(() => {
  media = window.matchMedia('(prefers-color-scheme: dark)')
  media.addEventListener('change', applyTheme)
  applyTheme()
  window.addEventListener('keydown', onKeyDown)
  window.addEventListener('keyup', onKeyUp)
  window.addEventListener('blur', onBlur)
  window.addEventListener('message', onMessage)
  window.addEventListener('pointerup', finishDrag)
  window.addEventListener('pointercancel', finishDrag)
  window.addEventListener('pagehide', persist)
  void openProject()
})
onBeforeUnmount(() => {
  persist()
  clearPreviewTimers()
  media?.removeEventListener('change', applyTheme)
  window.removeEventListener('keydown', onKeyDown)
  window.removeEventListener('keyup', onKeyUp)
  window.removeEventListener('blur', onBlur)
  window.removeEventListener('message', onMessage)
  window.removeEventListener('pointerup', finishDrag)
  window.removeEventListener('pointercancel', finishDrag)
  window.removeEventListener('pagehide', persist)
})
</script>

<template>
  <div class="workspace">
    <button v-if="sidebarOpen" class="sidebar-scrim" aria-label="关闭作品列表" @click="sidebarOpen = false" />
    <aside class="sidebar" :class="{ 'is-open': sidebarOpen }" aria-label="作品资料库">
      <a class="brand" href="/" aria-label="界面图鉴 首页"><span class="brand-mark"><i /><i /><i /><i /></span><span>界面图鉴<span class="brand-dot">.</span></span><span class="local-badge">本地</span></a>
      <div class="library-label"><span>你的设计观察室</span><span class="tiny-dot" /></div>
      <label class="search-box"><Icon name="search" :size="16" /><input ref="searchInput" v-model="query" type="search" placeholder="搜索作品、技术栈…" aria-label="搜索作品" /><kbd>/</kbd></label>
      <div class="section-heading"><span>作品收藏</span><span>{{ String(projects.length).padStart(2, '0') }}</span></div>
      <nav class="project-list" aria-label="选择作品">
        <button v-for="project in filtered" :key="project.id" class="project-card" :class="{ active: project.id === selectedId }" :disabled="!project.enabled" @click="chooseProject(project)">
          <span class="project-number">{{ String(projects.indexOf(project) + 1).padStart(2, '0') }}</span>
          <span class="project-copy"><strong>{{ project.title }}</strong><small>{{ project.subtitle }}</small><span class="project-tags"><span>{{ project.framework }}</span><span>{{ project.frames.length }} 个画框</span></span></span>
          <Icon v-if="project.enabled" name="chevron" :size="14" /><span v-else class="disabled-tag">未启用</span>
        </button>
        <p v-if="projects.length && !filtered.length" class="search-empty">没有找到匹配的作品。<br />试试作品名或技术栈。</p>
        <p v-if="!projects.length" class="search-empty">收藏夹还是空的。<br />在 catalog.json 中添加第一个作品。</p>
      </nav>
      <div v-if="current" class="project-details">
        <div class="section-heading"><span>关于这个作品</span><Icon name="book" :size="14" /></div>
        <p>{{ current.description }}</p>
        <div class="detail-tags"><span v-for="tag in current.tags" :key="tag">{{ tag }}</span></div>
        <div class="author-row"><span class="avatar">图</span><div><strong>{{ current.author }}</strong><small>{{ sourceUrl ? '设计参考' : '原创演示 · 本地模拟数据' }}</small></div></div>
        <a v-if="sourceUrl" class="source-link" :href="sourceUrl" target="_blank" rel="noopener noreferrer">查看原作 <Icon name="arrow" :size="14" /></a>
        <div class="source-path"><Icon name="folder" :size="14" /><code>{{ current.preview.cwd }}</code></div>
      </div>
      <div class="sidebar-footer"><span class="status-dot" /><span>本地工作空间</span><span class="version">v0.1</span></div>
    </aside>

    <main class="main-area">
      <header class="topbar">
        <div class="breadcrumb"><button class="icon-button mobile-menu" aria-label="打开作品列表" @click="sidebarOpen = !sidebarOpen"><Icon name="menu" /></button><span class="breadcrumb-root">我的收藏</span><span class="breadcrumb-separator">/</span><strong>{{ current?.title || '空白画布' }}</strong><span v-if="current" class="framework-badge">{{ current.framework }}</span></div>
        <div class="topbar-actions"><span class="autosave"><Icon name="check" :size="13" /> 布局自动记忆</span><label class="theme-select"><Icon :name="theme === 'system' ? 'system' : theme === 'dark' ? 'moon' : 'sun'" :size="16" /><select v-model="theme" aria-label="外观主题"><option value="system">跟随系统</option><option value="light">浅色模式</option><option value="dark">深色模式</option></select></label><button class="icon-button" aria-label="查看操作说明" :aria-expanded="helpOpen" @click="helpOpen = !helpOpen"><span class="help-icon">?</span></button></div>
      </header>

      <div class="canvas-toolbar">
        <div class="mode-switch" aria-label="画布操作模式"><button :class="{ selected: !interactionFrame }" @click="exitInteraction"><Icon name="pointer" :size="15" /><span>浏览画布</span></button><button :class="{ selected: interactionFrame }" :disabled="!activeFrame" @click="activeFrame && interact(activeFrame)"><Icon name="play" :size="14" /><span>交互预览</span></button></div>
        <div v-if="interactionFrame" class="interaction-notice"><span class="status-dot" />正在操作案例<button class="exit-button" @click="exitInteraction">退出交互 <kbd>Esc</kbd></button></div>
        <div v-else class="toolbar-caption"><span>{{ current?.frames.length || 0 }} 个画框</span><span class="divider-dot">·</span><span>点击画框标题栏可拖动</span></div>
        <button class="text-button reset-button" :disabled="!current" title="恢复配置中的初始位置和视角" @click="resetLayout"><Icon name="reset" :size="15" /><span>恢复默认布局</span></button>
      </div>

      <div ref="canvas" class="canvas" :class="{ 'is-grabbing': dragging, 'space-held': spaceHeld, 'is-interacting': interactionFrame }" :style="dotStyle" tabindex="0" aria-label="界面作品画布。拖动平移，Ctrl 或 Command 加滚轮缩放。" @pointerdown="startCanvasDrag" @pointermove="onPointerMove" @pointerup="finishDrag" @pointercancel="finishDrag" @lostpointercapture="finishDrag" @wheel.prevent="onWheel">
        <div v-if="current" class="canvas-watermark"><span class="watermark-line" /><span>{{ current.title.toUpperCase() }} / 设计探索</span></div>
        <div v-if="current" :key="current.id" class="world" :style="worldStyle">
          <section v-for="frame in current.frames" :key="current.id + ':' + frame.id" class="preview-frame" :class="{ 'is-selected': frame.id === selectedFrame, 'is-live': interactionFrame === frame.id }" :style="{ left: position(frame).x + 'px', top: position(frame).y + 'px', width: frame.width + 'px' }" :aria-label="frame.title">
            <div class="frame-header" tabindex="0" :aria-label="frame.title + '，方向键移动，双击聚焦'" @pointerdown="startFrameDrag($event, frame)" @dblclick="focusFrame(frame)" @keydown="frameKey($event, frame)">
              <span class="frame-heading"><Icon :name="frame.platform" :size="16" /><strong>{{ frame.title }}</strong><span class="frame-dimensions">{{ frame.width }} × {{ frame.height }}</span></span>
              <div class="frame-actions" @pointerdown.stop @dblclick.stop><button :aria-label="'聚焦 ' + frame.title" title="聚焦画框" @click="focusFrame(frame)"><Icon name="focus" :size="16" /></button><button :aria-label="'交互 ' + frame.title" title="进入交互" @click="interact(frame)"><Icon name="play" :size="15" /></button><button :aria-label="'重载 ' + frame.title" title="重载预览" @click="reload(frame)"><Icon name="reset" :size="15" /></button><a :href="frameUrl(current, frame)" target="_blank" rel="noopener noreferrer" :aria-label="'新窗口打开 ' + frame.title" title="新窗口打开"><Icon name="arrow" :size="16" /></a></div>
            </div>
            <div class="frame-content" :style="{ height: frame.height + 'px' }">
              <iframe :key="current.id + ':' + frame.id + ':' + (reloads[frame.id] || 0)" :ref="element => setFrameRef(frame.id, element)" :src="frameUrl(current, frame)" :title="current.title + ' · ' + frame.title" :width="frame.width" :height="frame.height" :tabindex="interactionFrame === frame.id ? 0 : -1" :inert="interactionFrame !== frame.id" @load="onFrameLoad(frame)" />
              <div v-if="!loaded[frame.id]" class="frame-loading"><span v-if="!timedOut[frame.id]" class="spinner" /><strong>{{ timedOut[frame.id] ? '预览仍未响应' : '正在打开预览…' }}</strong><span>{{ timedOut[frame.id] ? '请检查本地案例服务，或在新窗口中查看。' : '每一个案例都在独立的视口中运行。' }}</span><div v-if="timedOut[frame.id]"><button @pointerdown.stop @click="reload(frame)">重新加载</button><a :href="frameUrl(current, frame)" target="_blank" rel="noopener noreferrer" @pointerdown.stop>新窗口打开</a></div></div>
              <div v-if="interactionFrame !== frame.id" class="frame-cover" role="button" tabindex="-1" :aria-label="'浏览 ' + frame.title + '；双击进入交互'" @pointerdown="selectedFrame = frame.id" @click="selectedFrame = frame.id" @dblclick.stop="interact(frame)" />
            </div>
          </section>
        </div>
        <div v-if="!current" class="canvas-empty"><span class="empty-mark"><Icon name="book" :size="28" /></span><h1>给好设计，留一方空间。</h1><p>{{ projects.length ? '当前没有启用的作品。将 catalog.json 中的 enabled 设为 true，重启后即可查看。' : '在 catalog.json 中添加作品与画框，然后重新启动工作空间。' }}</p></div>
      </div>

      <div class="bottom-panel">
        <div v-if="current" class="frame-tabs" aria-label="定位画框"><button class="all-frames" title="适应全部画框" @click="fitAll"><Icon name="fit" :size="15" /><span>全部画框</span></button><span class="tab-divider" /><button v-for="frame in current.frames" :key="frame.id" :class="{ active: selectedFrame === frame.id }" @click="focusFrame(frame)"><Icon :name="frame.platform" :size="15" /><span>{{ platformName[frame.platform] || frame.platform }}</span></button></div>
        <div class="zoom-control"><button class="icon-button" aria-label="缩小画布" :disabled="!current || viewport.scale <= 0.1" @click="changeZoom(viewport.scale / 1.2)"><Icon name="minus" :size="16" /></button><button class="zoom-number" :disabled="!current" title="恢复 100% 缩放" aria-label="恢复百分之百缩放" @click="changeZoom(1)">{{ zoomLabel }}</button><button class="icon-button" aria-label="放大画布" :disabled="!current || viewport.scale >= 2" @click="changeZoom(viewport.scale * 1.2)"><Icon name="plus" :size="16" /></button><span class="tab-divider" /><button class="icon-button" aria-label="适应全部画框" :disabled="!current" @click="fitAll"><Icon name="fit" :size="17" /></button></div>
      </div>
      <footer class="workspace-footer"><span><span class="footer-dot" />{{ enabledCount }} 个本地作品 · 独立视口</span><span class="shortcut-hint"><kbd>空格</kbd> 拖动画布 <span>·</span> <kbd>⌘ / Ctrl</kbd> + 滚轮缩放 <span>·</span> 双击画框进入交互</span><span class="footer-wordmark">给好设计，留一方空间</span></footer>
    </main>
    <div v-if="helpOpen" class="help-popover" role="dialog" aria-label="画布操作说明"><div><strong>自在浏览，深入观察。</strong><button class="icon-button" aria-label="关闭操作说明" @click="helpOpen = false"><Icon name="close" :size="16" /></button></div><dl><dt>移动画布</dt><dd>拖动空白处，或按住空格键拖动</dd><dt>缩放画布</dt><dd>⌘ / Ctrl + 滚轮，或底部缩放按钮</dd><dt>移动画框</dt><dd>拖动标题栏，或聚焦标题栏后按方向键</dd><dt>聚焦画框</dt><dd>双击标题栏，或点击底部设备标签</dd><dt>操作案例</dt><dd>点击交互按钮，或双击画框内容</dd><dt>返回浏览</dt><dd>点击“退出交互”；接入快捷键的案例支持 Esc</dd></dl><p>画框尺寸以 CSS 像素计；预览不等同于真实设备模拟。</p></div>
  </div>
</template>
