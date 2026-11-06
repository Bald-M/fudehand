<script setup lang="ts">
defineProps<{ name: string; size?: number }>()
const paths: Record<string, string> = {
  plus: 'M12 5v14M5 12h14', check: 'm5 12 4 4L19 6', arrow: 'M5 12h14m-5-5 5 5-5 5',
  more: 'M5 12h.01M12 12h.01M19 12h.01', home: 'm3 10 9-7 9 7v10H3V10Zm6 10v-7h6v7',
  calendar: 'M5 5h14v16H5V5Zm3-3v6m8-6v6M5 10h14', folder: 'M3 5h7l2 3h9v12H3V5Z',
  chart: 'M5 20V10m7 10V4m7 16v-7', settings: 'M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8Zm0-5v2m0 14v2M3 12h2m14 0h2M5.6 5.6 7 7m10 10 1.4 1.4M5.6 18.4 7 17M17 7l1.4-1.4',
  leaf: 'M5 19C1 9 9 3 20 4c1 11-5 18-15 15Zm0 0L16 8', sun: 'M12 7a5 5 0 1 0 0 10 5 5 0 0 0 0-10ZM12 1v2m0 18v2M1 12h2m18 0h2M4 4l2 2m12 12 2 2M4 20l2-2M18 6l2-2',
  clock: 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18Zm0 4v5l3 2', search: 'M10 3a7 7 0 1 0 0 14 7 7 0 0 0 0-14Zm5 12 6 6', close: 'm6 6 12 12M6 18 18 6',
  note: 'M5 3h14v18H5V3Zm4 6h6m-6 4h6m-6 4h3', headphones: 'M4 14v-3a8 8 0 0 1 16 0v3M4 12h3v8H4v-8Zm13 0h3v8h-3v-8Z',
}
</script>
<template><svg :width="size || 20" :height="size || 20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path :d="paths[name] || paths.leaf" /></svg></template>
