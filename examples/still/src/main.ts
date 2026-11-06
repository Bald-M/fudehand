import { createApp } from 'vue'
import { installPreviewBridge } from '@ui-atlas/preview-bridge'
import catalog from '../../../catalog.json'
import App from './App.vue'
import './style.css'

installPreviewBridge(new URL(catalog.shell.url).origin)
createApp(App).mount('#app')
