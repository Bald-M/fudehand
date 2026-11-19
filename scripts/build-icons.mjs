#!/usr/bin/env node
// Builds the bundled icon libraries: extracts each icon's SVG from the npm packages, reduces it to its drawing, and writes one
// raw-DEFLATE-compressed JSON file per library, plus the libraries' license texts, into FudehandCore's resources.
// Run with `pnpm build:icons` after changing an icon package version; the outputs are committed.
import { mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { dirname, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { deflateRawSync } from 'node:zlib'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const output = join(root, 'native/Sources/FudehandCore/Resources/Icons')
const require = createRequire(join(root, 'package.json'))
const packageDir = name => dirname(require.resolve(`${name}/package.json`))

const ATTRIBUTE = /([\w:-]+)\s*=\s*("[^"]*"|'[^']*')/g

/** Reduces an SVG to its drawing: drops comments, classes, and the declared size (turned into a viewBox when it has none), and whitespace. */
export function minifySVG(source) {
  let svg = source.replace(/<!--[\s\S]*?-->/g, '').replace(/<\?xml[\s\S]*?\?>/g, '').trim()
  svg = svg.replace(/<svg\b([^>]*)>/, (_, attributes) => {
    const values = new Map([...attributes.matchAll(ATTRIBUTE)].map(([, key, value]) => [key, value.slice(1, -1)]))
    if (!values.has('viewBox') && values.has('width') && values.has('height')) {
      values.set('viewBox', `0 0 ${parseFloat(values.get('width'))} ${parseFloat(values.get('height'))}`)
    }
    for (const key of ['width', 'height', 'class']) values.delete(key)
    values.set('xmlns', 'http://www.w3.org/2000/svg')
    return `<svg ${[...values].map(([key, value]) => `${key}="${value.replaceAll('"', "'")}"`).join(' ')}>`
  })
  return svg
    .replace(/\sclass\s*=\s*("[^"]*"|'[^']*')/g, '')
    .replace(/\s+/g, ' ')
    .replace(/>\s+</g, '><')
    .replace(/\s*(\/?)>/g, '$1>')
    .trim()
}

/** Material Symbols file name → icon name: `home-fill.svg` is the filled variant `home.fill`. */
export function materialName(file) {
  const base = file.replace(/\.svg$/, '')
  return base.endsWith('-fill') ? `${base.slice(0, -'-fill'.length)}.fill` : base
}

/** The WeUI icons: each `.weui-icon-<name>` rule's `mask-image` data URI, keyed by `<name>`. */
export function weuiIcons(less) {
  const icons = {}
  for (const [, name, url] of less.matchAll(/^\.weui-icon-([\w-]+)\s*\{\s*mask-image:\s*url\((.*)\);\s*$/gm)) {
    const data = url.replace(/^(["'])(.*)\1$/, '$2').replace(/^data:image\/svg\+xml,/, '')
    icons[name] = minifySVG(decodeURIComponent(data))
  }
  return icons
}

function svgDirectory(directory, name = file => file.replace(/\.svg$/, '')) {
  const icons = {}
  for (const file of readdirSync(directory).filter(file => file.endsWith('.svg')).sort()) {
    icons[name(file)] = minifySVG(readFileSync(join(directory, file), 'utf8'))
  }
  return icons
}

function write(library, version, icons, tags = {}) {
  const entries = Object.keys(icons).sort().map(name => [name, tags[name]?.length ? { svg: icons[name], tags: tags[name] } : { svg: icons[name] }])
  const json = JSON.stringify({ library, version, icons: Object.fromEntries(entries) })
  writeFileSync(join(output, `${library}.json.zlib`), deflateRawSync(json, { level: 9 }))
  return entries.length
}

function main() {
  mkdirSync(output, { recursive: true })
  const version = name => JSON.parse(readFileSync(join(packageDir(name), 'package.json'), 'utf8')).version
  const counts = {}
  const material = packageDir('@material-symbols/svg-400')
  for (const style of ['outlined', 'rounded', 'sharp']) {
    counts[`material-${style}`] = write(`material-${style}`, version('@material-symbols/svg-400'), svgDirectory(join(material, style), materialName))
  }
  const weui = packageDir('weui')
  counts.weui = write('weui', version('weui'), weuiIcons(readFileSync(join(weui, 'src/style/icon/weui-icon.less'), 'utf8')))
  const lucide = packageDir('lucide-static')
  counts.lucide = write('lucide', version('lucide-static'), svgDirectory(join(lucide, 'icons')),
    JSON.parse(readFileSync(join(lucide, 'tags.json'), 'utf8')))

  const notices = [
    ['Lucide', 'lucide-static', join(lucide, 'LICENSE')],
    ['Material Symbols', '@material-symbols/svg-400', join(material, 'LICENSE')],
    ['WeUI', 'weui', join(weui, 'LICENSE.txt')],
  ].map(([title, name, file]) => `${title} (${name} ${version(name)})\n${'='.repeat(60)}\n\n${readFileSync(file, 'utf8').trim()}\n`)
  writeFileSync(join(output, 'LICENSES.txt'),
    `Fudehand bundles icons from the following libraries. Their licenses follow.\n\n${notices.join('\n\n')}`)
  console.log(Object.entries(counts).map(([library, count]) => `${library}: ${count}`).join('\n'))
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main()
