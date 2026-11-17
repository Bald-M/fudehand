import net from 'node:net'
import { homedir } from 'node:os'
import { join } from 'node:path'

/** 原生 App 控制通道的位置，与 Swift 端 ControlServer.defaultPath 一致。 */
export function defaultSocketPath(env = process.env) {
  return env.UI_ATLAS_CONTROL_SOCKET || join(homedir(), 'Library/Application Support/ui-atlas/control.sock')
}

let nextId = 1

/** 发送一条命令并等待对应响应；App 返回的错误原样抛出。 */
export function sendControl(command, args = {}, { socketPath = defaultSocketPath(), timeoutMs = 15000 } = {}) {
  return new Promise((resolveResult, reject) => {
    const id = nextId++
    const socket = net.createConnection(socketPath)
    const chunks = []
    let settled = false
    const finish = (error, result) => {
      if (settled) return
      settled = true
      socket.destroy()
      if (error) reject(error)
      else resolveResult(result)
    }
    // StringDecoder 保证多字节字符跨数据块时不被截断。
    socket.setEncoding('utf8')
    socket.setTimeout(timeoutMs, () => finish(new Error('ui-atlas did not respond')))
    socket.once('error', error => finish(new Error(
      ['ENOENT', 'ECONNREFUSED', 'ENOTSOCK'].includes(error.code) ? 'ui-atlas is not running'
        : ['ECONNRESET', 'EPIPE'].includes(error.code) ? 'ui-atlas closed the connection early' : error.message,
    )))
    socket.once('connect', () => socket.write(JSON.stringify({ id, command, args }) + '\n'))
    socket.on('data', chunk => {
      const end = chunk.indexOf('\n')
      if (end < 0) { chunks.push(chunk); return }
      chunks.push(chunk.slice(0, end))
      let response
      try { response = JSON.parse(chunks.join('')) } catch { return finish(new Error('ui-atlas returned an unparseable response')) }
      if (response.ok) finish(null, response.result)
      else finish(new Error(response.error || 'ui-atlas returned an error'))
    })
    socket.once('end', () => finish(new Error('ui-atlas closed the connection early')))
  })
}
