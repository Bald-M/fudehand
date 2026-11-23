import { runSwift } from './native-swift.mjs'

// The canvas drag, hover, pan and rest compositing, bitmap main-thread, and large-design opening benchmarks
// (CanvasBenchmarkTests.swift), the layer selection benchmark (SelectionBenchmarkTests.swift), and the discrete edit
// benchmark (EditBenchmarkTests.swift) in native/Tests/FudehandAppTests, built in release. They run one at a time: each
// measures the main thread, which a benchmark running beside it would hold up. The bitmap main-thread and opening
// benchmarks run first, each in a process of its own: the compositing benchmarks leave the GPU and memory busy for a while
// after them, which shows up as main-thread gaps.
const groups = [
  'canvasBitmapMainThreadBenchmark',
  'canvasOpenLargeDesignBenchmark',
  'canvasDragAndHoverBenchmark|canvasPanCompositeBenchmark|canvasRestCompositeBenchmark|layerSelectionBenchmark|editBenchmark',
]
try {
  for (const filter of groups) {
    await runSwift('test', {
      configuration: 'release',
      args: ['-Xswiftc', '-enable-testing', '--no-parallel', '--filter', filter],
      env: { FUDEHAND_BENCHMARK: '1' },
    })
  }
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error))
  process.exitCode = 1
}
