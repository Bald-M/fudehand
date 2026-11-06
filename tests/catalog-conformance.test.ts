import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { mkdtemp, mkdir, readFile, rm, symlink } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { servicesFromCatalog } from '../scripts/launcher.mjs'

type Key = string | number
type Op = { op: 'set'; path: Key[]; value: unknown } | { op: 'remove'; path: Key[] } | { op: 'appendCopy'; path: Key[]; index: number }
interface Conformance { catalog: unknown; cases: { name: string; ops: Op[]; error: string | null }[] }

const fixture: Conformance = JSON.parse(await readFile(new URL('./fixtures/catalog-conformance.json', import.meta.url), 'utf8'))

function apply(source: unknown, ops: Op[]) {
  const catalog = structuredClone(source)
  for (const op of ops) {
    const parentPath = op.op === 'appendCopy' ? op.path : op.path.slice(0, -1)
    const parent = parentPath.reduce<any>((value, key) => value[key], catalog)
    if (op.op === 'appendCopy') parent.push(structuredClone(parent[op.index]))
    else if (op.op === 'remove') Reflect.deleteProperty(parent, op.path.at(-1)!)
    else parent[op.path.at(-1)!] = op.value
  }
  return catalog
}

let root = ''
let outside = ''
beforeAll(async () => {
  root = await mkdtemp(join(tmpdir(), 'ui-atlas-conformance-'))
  outside = await mkdtemp(join(tmpdir(), 'ui-atlas-outside-'))
  await mkdir(join(root, 'examples/demo'), { recursive: true })
  await symlink(outside, join(root, 'examples/outside-link'))
})
afterAll(async () => {
  await rm(root, { recursive: true, force: true })
  await rm(outside, { recursive: true, force: true })
})

describe('与原生 App 共用的作品目录校验用例', () => {
  for (const testCase of fixture.cases) {
    it(testCase.name, async () => {
      const result = servicesFromCatalog(apply(fixture.catalog, testCase.ops), root)
      if (testCase.error === null) await expect(result).resolves.toBeInstanceOf(Array)
      else await expect(result).rejects.toThrow(testCase.error)
    })
  }
})
