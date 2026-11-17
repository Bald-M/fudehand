// Set and check the version number in one place: pnpm version:set <x.y.z>, pnpm version:check.
// Only the version text is rewritten; everything else (indentation, key order, line breaks) is left untouched.
import { readFile, writeFile } from 'node:fs/promises'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseArgs } from 'node:util'

const { values, positionals } = parseArgs({ options: { root: { type: 'string' } }, allowPositionals: true })
const root = values.root ? resolve(values.root) : fileURLToPath(new URL('../', import.meta.url))
const [command, version] = positionals

// Where the version lives: file, field name, and a regex matching prefix + value + suffix.
// The MCP server reads package.json at runtime, so it is not listed here.
const fields = {
  version: [
    { file: 'package.json', label: 'version', pattern: /("version"\s*:\s*")([^"]*)(")/ },
    { file: 'native/Resources/Info.plist', label: 'CFBundleShortVersionString', pattern: /(<key>CFBundleShortVersionString<\/key>\s*<string>)([^<]*)(<\/string>)/ },
  ],
  build: { file: 'native/Resources/Info.plist', label: 'CFBundleVersion', pattern: /(<key>CFBundleVersion<\/key>\s*<string>)([^<]*)(<\/string>)/ },
}
const semver = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$/

function fail(message) {
  console.error(message)
  process.exit(1)
}

const texts = new Map()
async function text(file) {
  if (!texts.has(file)) texts.set(file, await readFile(join(root, file), 'utf8'))
  return texts.get(file)
}

async function current(field) {
  const match = (await text(field.file)).match(field.pattern)
  if (!match) fail(`${field.label} not found in ${field.file}`)
  return match[2]
}

function replace(field, value) {
  texts.set(field.file, texts.get(field.file).replace(field.pattern, (_, before, _old, after) => `${before}${value}${after}`))
}

if (command === 'set') {
  if (!version || !semver.test(version)) fail(`The version must look like x.y.z (a pre-release suffix such as -beta.1 is allowed); got: ${version ?? '(empty)'}`)
  const changes = []
  for (const field of fields.version) changes.push([field, await current(field), version])
  const build = await current(fields.build)
  if (!/^\d+$/.test(build)) fail(`${fields.build.label} in ${fields.build.file} is not an integer: ${build}`)
  changes.push([fields.build, build, String(Number(build) + 1)])

  for (const [field, , value] of changes) replace(field, value)
  for (const file of new Set(changes.map(([field]) => field.file))) await writeFile(join(root, file), texts.get(file))
  for (const [field, before, after] of changes) console.log(`${field.file} ${field.label}: ${before} → ${after}`)
} else if (command === 'check') {
  const found = []
  for (const field of fields.version) found.push([field, await current(field)])
  if (new Set(found.map(([, value]) => value)).size === 1) {
    console.log(`Versions match: ${found[0][1]}`)
  } else {
    fail(['Versions differ:', ...found.map(([field, value]) => `  ${field.file} ${field.label}: ${value}`)].join('\n'))
  }
} else {
  fail('Usage: node scripts/version.mjs set <x.y.z> | check')
}
