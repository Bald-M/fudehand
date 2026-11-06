/**
 * Connect a trusted local preview to UI Atlas. Pass the shell origin explicitly
 * if its host or port changes. The returned function removes the listener.
 */
export function installPreviewBridge(shellOrigin = 'http://127.0.0.1:4400'): () => void {
  const origin = new URL(shellOrigin).origin
  if (window.parent === window) return () => {}

  const onKeydown = (event: KeyboardEvent) => {
    if (event.key === 'Escape' && !event.defaultPrevented) {
      window.parent.postMessage({ type: 'ui-atlas:exit-preview' }, origin)
    }
  }
  window.addEventListener('keydown', onKeydown)
  return () => window.removeEventListener('keydown', onKeydown)
}
