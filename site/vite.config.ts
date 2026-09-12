import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// Project-path Pages deploy: https://rao-studios.github.io/MaryOS/
export default defineConfig({
  base: '/MaryOS/',
  plugins: [react()],
  build: { outDir: 'dist', emptyOutDir: true },
  test: { environment: 'node', include: ['test/**/*.test.ts'] },
})
