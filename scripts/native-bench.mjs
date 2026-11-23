import { runSwift } from './native-swift.mjs'

// The canvas drag, hover, pan compositing, and bitmap main-thread benchmarks (CanvasBenchmarkTests.swift), the layer
// selection benchmark (SelectionBenchmarkTests.swift), and the discrete edit benchmark (EditBenchmarkTests.swift) in
// native/Tests/FudehandAppTests, built in release. They run one at a time: each measures the main thread, which a
// benchmark running beside it would hold up.
try {
  await runSwift('test', {
    configuration: 'release',
    args: ['-Xswiftc', '-enable-testing', '--no-parallel', '--filter', 'canvasDragAndHoverBenchmark|canvasPanCompositeBenchmark|canvasBitmapMainThreadBenchmark|layerSelectionBenchmark|editBenchmark'],
    env: { FUDEHAND_BENCHMARK: '1' },
  })
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error))
  process.exitCode = 1
}
