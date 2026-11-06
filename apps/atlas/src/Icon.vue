<script setup lang="ts">
defineProps<{ name: string; size?: number }>()
const paths: Record<string, string> = {
  search: 'M21 21l-4.5-4.5M19 10.5a8.5 8.5 0 1 1-17 0 8.5 8.5 0 0 1 17 0',
  arrow: 'M7 17 17 7M7 7h10v10',
  plus: 'M12 5v14M5 12h14', minus: 'M5 12h14',
  fit: 'M8 3H3v5M16 3h5v5M3 16v5h5M21 16v5h-5',
  focus: 'M8 3H3v5M16 3h5v5M3 16v5h5M21 16v5h-5M8 8h8v8H8z',
  hand: 'M7 12V6a2 2 0 0 1 4 0v5M11 10V4a2 2 0 0 1 4 0v7M15 10V6a2 2 0 0 1 4 0v8c0 5-3 8-7 8-3 0-5-2-7-5l-2-4a2 2 0 0 1 3-2l3 3',
  pointer: 'm5 3 14 9-7 1-3 7z',
  play: 'm8 5 11 7-11 7z',
  close: 'M6 6l12 12M18 6 6 18',
  reset: 'M3 11a9 9 0 1 1 2.6 6.4M3 4v7h7',
  sun: 'M12 3V1M12 23v-2M3 12H1M23 12h-2M5.6 5.6 4.2 4.2M19.8 19.8l-1.4-1.4M18.4 5.6l1.4-1.4M4.2 19.8l1.4-1.4M16 12a4 4 0 1 1-8 0 4 4 0 0 1 8 0',
  moon: 'M20.8 13a9 9 0 0 1-9.8-9.8A9 9 0 1 0 20.8 13',
  system: 'M3 4h18v13H3zM8 21h8M12 17v4',
  menu: 'M4 6h16M4 12h16M4 18h16',
  mobile: 'M7 2h10v20H7zM11 18h2',
  web: 'M3 4h18v16H3zM3 9h18M7 6h.01M10 6h.01',
  desktop: 'M2 3h20v15H2zM8 22h8M12 18v4',
  book: 'M12 5c-3-2-6-2-10-1v15c4-1 7-1 10 1 3-2 6-2 10-1V4c-4-1-7-1-10 1zM12 5v15',
  chevron: 'm9 5 7 7-7 7',
  folder: 'M3 6h7l2 3h9v11H3zM3 6V3h7l2 3h9v3',
  check: 'm5 12 4 4L19 6',
}
</script>
<template><svg :width="size || 18" :height="size || 18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path :d="paths[name] || paths.web" /></svg></template>
