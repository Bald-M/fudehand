import type { Plugin } from 'vite'

export declare const PREVIEW_TOKEN_ENV: 'UI_ATLAS_PREVIEW_TOKEN'
export declare const PREVIEW_COOKIE: 'ui_atlas_preview'
export declare function hasPreviewAccess(cookieHeader: string | undefined, token: string | undefined): boolean
export declare function previewGate(token?: string): Plugin
