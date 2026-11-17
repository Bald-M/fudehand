import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

export function sampleCatalog() {
  return {
    version: 1,
    projects: [{
      id: 'demo', title: '演示作品', subtitle: '', description: '', author: '原创作者', sourceUrl: null, framework: 'HTML', tags: [], enabled: true, layoutVersion: 1,
      preview: { cwd: 'examples/demo', command: ['pnpm', 'dev'], port: 31002, baseUrl: 'http://127.0.0.1:31002/demo/' },
      frames: [
        { id: 'home', title: '首页', platform: 'web', path: 'home', width: 1440, height: 900, x: 0, y: 0 },
        { id: 'phone', title: '手机', platform: 'mobile', path: '/demo/m?x=1', width: 390, height: 844, x: 1600, y: 0 },
      ],
    }],
  }
}

/** 临时仓库目录：写入 catalog.json 与示例目录，返回根目录和清理函数。 */
export async function atlasWorkspace(catalog: unknown = sampleCatalog()) {
  const root = await mkdtemp(join(tmpdir(), 'ui-atlas-tools-'))
  await mkdir(join(root, 'examples/demo'), { recursive: true })
  await writeFile(join(root, 'catalog.json'), JSON.stringify(catalog, null, 2) + '\n')
  return { root, dispose: () => rm(root, { recursive: true, force: true }) }
}
