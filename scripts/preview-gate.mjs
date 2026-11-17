/**
 * 预览令牌：App 每次启动案例服务时生成随机令牌，经环境变量交给启动器和各案例的开发服务，
 * 并写入画框 WKWebView 的 Cookie。案例服务只响应带该 Cookie 的请求，浏览器直接访问端口会得到 403。
 * 目的是让作品只在 App 的画框中打开，不防御本机其他程序（见 docs/adr/0005）。
 */
export const PREVIEW_TOKEN_ENV = 'UI_ATLAS_PREVIEW_TOKEN'
export const PREVIEW_COOKIE = 'ui_atlas_preview'

export function hasPreviewAccess(cookieHeader, token) {
  if (!token) return true
  return (cookieHeader ?? '').split(';').some(part => part.trim() === `${PREVIEW_COOKIE}=${token}`)
}

/** Vite 插件：在 Vite 自身中间件之前拒绝没有预览令牌的请求。没有令牌（不经 App 启动）时不拦截。 */
export function previewGate(token = process.env[PREVIEW_TOKEN_ENV]) {
  return {
    name: 'ui-atlas-preview-gate',
    apply: 'serve',
    configureServer(server) {
      if (!token) return
      server.middlewares.use((request, response, next) => {
        if (hasPreviewAccess(request.headers.cookie, token)) return next()
        response.statusCode = 403
        response.setHeader('Content-Type', 'text/plain; charset=utf-8')
        response.end('请在 ui-atlas App 中查看此作品。')
      })
    },
  }
}
