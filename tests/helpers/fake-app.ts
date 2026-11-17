import net from 'node:net'
import { rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { randomUUID } from 'node:crypto'

export interface ControlRequest { id: unknown, command: string, args: Record<string, unknown> }

/**
 * 假的 App 控制通道：记录收到的请求，用 respond 生成响应。返回 socket 路径、请求记录与关闭函数。
 * `splitInside` 让响应在该字符处分两次写出，模拟数据块切在多字节字符中间。
 */
export async function fakeApp(respond: (request: ControlRequest) => object, { splitInside = '' } = {}) {
  const socketPath = join(tmpdir(), `uia-${randomUUID().slice(0, 8)}.sock`)
  const received: ControlRequest[] = []
  const server = net.createServer(socket => {
    let buffer = ''
    socket.on('data', chunk => {
      buffer += chunk
      let index
      while ((index = buffer.indexOf('\n')) >= 0) {
        const request = JSON.parse(buffer.slice(0, index))
        buffer = buffer.slice(index + 1)
        received.push(request)
        const line = Buffer.from(JSON.stringify({ id: request.id, ...respond(request) }) + '\n')
        if (!splitInside) { socket.write(line); continue }
        const splitAt = line.indexOf(Buffer.from(splitInside)) + 1
        socket.write(line.subarray(0, splitAt))
        setTimeout(() => socket.write(line.subarray(splitAt)), 20)
      }
    })
  })
  await new Promise<void>(resolve => server.listen(socketPath, resolve))
  const close = async () => { await new Promise(resolve => server.close(resolve)); await rm(socketPath, { force: true }) }
  return { socketPath, received, close }
}
