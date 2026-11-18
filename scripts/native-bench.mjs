import { runSwift } from './native-swift.mjs'

// The canvas drag and hover benchmark (CanvasBenchmarkTests.swift) and the layer selection benchmark
// (SelectionBenchmarkTests.swift) in native/Tests/FudehandAppTests, built in release.
try {
  await runSwift('test', {
    configuration: 'release',
    args: ['-Xswiftc', '-enable-testing', '--filter', 'canvasDragAndHoverBenchmark|layerSelectionBenchmark'],
    env: { FUDEHAND_BENCHMARK: '1' },
  })
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error))
  process.exitCode = 1
}
