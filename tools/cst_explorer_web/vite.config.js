import { defineConfig } from 'vite'
import { svelte } from '@sveltejs/vite-plugin-svelte'

export default defineConfig({
  plugins: [svelte()],
  base: './',
  build: { target: 'es2022', outDir: 'dist' },
  server: { port: 5173, strictPort: true },
})
