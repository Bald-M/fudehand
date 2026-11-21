import { runSwift } from './native-swift.mjs'

// The canvas drag and hover benchmark (CanvasBenchmarkTests.swift), the layer selection benchmark
// (SelectionBenchmarkTests.swift), and the discrete edit benchmark (EditBenchmarkTests.swift) in
// native/Tests/FudehandAppTests, built in release.
try {
  await runSwift('test', {
    configuration: 'release',
    args: ['-Xswiftc', '-enable-testing', '--filter', 'canvasDragAndHoverBenchmark|layerSelectionBenchmark|editBenchmark'],
    env: { FUDEHAND_BENCHMARK: '1' },
  })
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error))
  process.exitCode = 1
}
