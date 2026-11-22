import net from 'node:net'
import { rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { randomUUID } from 'node:crypto'

export interface ControlRequest { id: unknown, command: string, args: Record<string, unknown> }

/**
 * A fake App control channel: records the requests it receives and produces responses with respond. Returns the socket path, the request log, and a close function.
 * `splitInside` makes the response be written in two parts at that character, simulating a chunk boundary in the middle of a multi-byte character.
 */
export async function fakeApp(respond: (request: ControlRequest) => object, { splitInside = '' } = {}) {
  const socketPath = join(tmpdir(), `uia-${randomUUID().slice(0, 8)}.sock`)
  const received: ControlRequest[] = []
  const server = net.createServer(socket => {
    // Collect chunks and scan only each new chunk for the newline: rescanning a growing string on every chunk is quadratic for a multi-MB request.
    let chunks: Buffer[] = []
    socket.on('data', (chunk: Buffer) => {
      let index
      while ((index = chunk.indexOf('\n')) >= 0) {
        chunks.push(chunk.subarray(0, index))
        const request = JSON.parse(Buffer.concat(chunks).toString('utf8'))
        chunks = []
        chunk = chunk.subarray(index + 1)
        received.push(request)
        const line = Buffer.from(JSON.stringify({ id: request.id, ...respond(request) }) + '\n')
        if (!splitInside) { socket.write(line); continue }
        const splitAt = line.indexOf(Buffer.from(splitInside)) + 1
        socket.write(line.subarray(0, splitAt))
        setTimeout(() => socket.write(line.subarray(splitAt)), 20)
      }
      if (chunk.length) chunks.push(chunk)
    })
  })
  await new Promise<void>(resolve => server.listen(socketPath, resolve))
  const close = async () => { await new Promise(resolve => server.close(resolve)); await rm(socketPath, { force: true }) }
  return { socketPath, received, close }
}
