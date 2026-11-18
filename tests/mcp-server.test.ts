import { afterEach, describe, expect, it } from 'vitest'
import { fileURLToPath } from 'node:url'
import { readFile } from 'node:fs/promises'
import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js'
import { fakeApp } from './helpers/fake-app'
import { designGuidance } from '../scripts/design-guidance.mjs'

const server = fileURLToPath(new URL('../scripts/mcp-server.mjs', import.meta.url))
const cleanup: (() => Promise<unknown>)[] = []
afterEach(async () => { for (const action of cleanup.splice(0).reverse()) await action() })

async function connect(socketPath: string) {
  const client = new Client({ name: 'ui-atlas-test', version: '0.0.0' })
  const env = Object.fromEntries(Object.entries(process.env).filter((entry): entry is [string, string] => entry[1] !== undefined))
  await client.connect(new StdioClientTransport({
    command: process.execPath, args: [server, '--root', '/repo'], stderr: 'ignore',
    env: { ...env, UI_ATLAS_CONTROL_SOCKET: socketPath },
  }))
  cleanup.push(() => client.close())
  return client
}

function text(result: { content: unknown }) {
  return (result.content as { type: string, text: string }[]).map(item => item.text).join('\n')
}

describe('MCP server', () => {
  it('lists the design tools with their input schemas', async () => {
    const client = await connect('/tmp/unused.sock')
    const { tools } = await client.listTools()
    expect(tools.map(tool => tool.name)).toEqual(expect.arrayContaining(['design_create_node', 'design_update_node', 'design_snapshot']))
    expect(tools.find(tool => tool.name === 'design_create_node')?.inputSchema.required).toEqual(['node'])
  })

  it('reports the version from package.json', async () => {
    const client = await connect('/tmp/unused.sock')
    const { version } = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'))
    expect(client.getServerVersion()?.version).toBe(version)
  })

  it('gives connecting Agents the design guidance as its instructions', async () => {
    const client = await connect('/tmp/unused.sock')
    expect(client.getInstructions()).toContain(designGuidance)
  })

  it('forwards calls to the App through UI_ATLAS_CONTROL_SOCKET', async () => {
    const app = await fakeApp(request => ({ ok: true, result: { id: 'abc', got: request.args } }))
    cleanup.push(app.close)
    const client = await connect(app.socketPath)
    // Chinese kept deliberately: it checks that non-ASCII text passes through unchanged.
    const result = await client.callTool({ name: 'design_create_node', arguments: { node: { type: 'text', text: { content: '你好' } } } })
    expect(result.isError).toBeFalsy()
    expect(JSON.parse(text(result))).toEqual({ id: 'abc', got: { node: { type: 'text', text: { content: '你好' } } } })
    expect(app.received[0].command).toBe('create_node')
  })

  it('returns an English error when the App is not running', async () => {
    const client = await connect('/tmp/ui-atlas-missing.sock')
    const result = await client.callTool({ name: 'design_get_state', arguments: {} })
    expect(result.isError).toBe(true)
    expect(text(result)).toBe('ui-atlas is not running')
  })
})
