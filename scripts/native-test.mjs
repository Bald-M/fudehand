import { runSwift } from './native-swift.mjs'

try {
  await runSwift('test')
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error))
  process.exitCode = 1
}
