import { fileURLToPath } from 'node:url'
import { resolve } from 'node:path'
import { readFileSync } from 'node:fs'
import { parseArgs } from 'node:util'
import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import { CallToolRequestSchema, ListToolsRequestSchema } from '@modelcontextprotocol/sdk/types.js'
import { callTool, tools } from './atlas-tools.mjs'
import { designGuidance } from './design-guidance.mjs'

const { values } = parseArgs({ options: { root: { type: 'string' } } })
const ctx = { root: values.root ? resolve(values.root) : fileURLToPath(new URL('../', import.meta.url)) }

const { version } = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'))
const server = new Server({ name: 'ui-atlas', version }, { capabilities: { tools: {} }, instructions: designGuidance })
server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: tools.map(({ name, description, inputSchema }) => ({ name, description, inputSchema })),
}))
server.setRequestHandler(CallToolRequestSchema, request => callTool(request.params.name, request.params.arguments, ctx))
await server.connect(new StdioServerTransport())
