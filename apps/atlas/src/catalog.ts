import data from '../../../catalog.json'

export interface Point { x: number; y: number }
export interface Viewport extends Point { scale: number }
export interface Frame extends Point {
  id: string
  title: string
  platform: string
  path: string
  width: number
  height: number
}
export interface Project {
  id: string
  title: string
  subtitle: string
  description: string
  author: string
  sourceUrl: string | null
  framework: string
  tags: string[]
  enabled: boolean
  layoutVersion: number
  preview: { cwd: string; command: string[]; port: number; baseUrl: string }
  frames: Frame[]
}
export interface Catalog {
  version: number
  shell: { port: number; url: string }
  projects: Project[]
}
export const catalog: Catalog = data
export const frameUrl = (project: Project, frame: Frame) => new URL(frame.path, project.preview.baseUrl).href
