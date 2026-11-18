import { runSwift } from './native-swift.mjs'

// The canvas drag and hover benchmark (native/Tests/FudehandAppTests/CanvasBenchmarkTests.swift), built in release.
try {
  await runSwift('test', {
    configuration: 'release',
    args: ['-Xswiftc', '-enable-testing', '--filter', 'canvasDragAndHoverBenchmark'],
    env: { FUDEHAND_BENCHMARK: '1' },
  })
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error))
  process.exitCode = 1
}
