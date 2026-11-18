import net from 'node:net'
import { homedir } from 'node:os'
import { join } from 'node:path'

/** The location of the native App's control channel, matching ControlServer.defaultPath on the Swift side. */
export function defaultSocketPath(env = process.env) {
  return env.FUDEHAND_CONTROL_SOCKET || join(homedir(), 'Library/Application Support/fudehand/control.sock')
}

let nextId = 1

/** Sends one command and waits for the matching response; errors returned by the App are thrown as is. */
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
    // StringDecoder ensures a multi-byte character split across chunks is not cut off.
    socket.setEncoding('utf8')
    socket.setTimeout(timeoutMs, () => finish(new Error('Fudehand did not respond')))
    socket.once('error', error => finish(new Error(
      ['ENOENT', 'ECONNREFUSED', 'ENOTSOCK'].includes(error.code) ? 'Fudehand is not running'
        : ['ECONNRESET', 'EPIPE'].includes(error.code) ? 'Fudehand closed the connection early' : error.message,
    )))
    socket.once('connect', () => socket.write(JSON.stringify({ id, command, args }) + '\n'))
    socket.on('data', chunk => {
      const end = chunk.indexOf('\n')
      if (end < 0) { chunks.push(chunk); return }
      chunks.push(chunk.slice(0, end))
      let response
      try { response = JSON.parse(chunks.join('')) } catch { return finish(new Error('Fudehand returned an unparseable response')) }
      if (response.ok) finish(null, response.result)
      else finish(new Error(response.error || 'Fudehand returned an error'))
    })
    socket.once('end', () => finish(new Error('Fudehand closed the connection early')))
  })
}
