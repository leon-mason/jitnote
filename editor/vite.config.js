import { defineConfig } from 'vite'

// The bundle is served from the app's assets, fully offline, so everything is local and paths are relative.
export default defineConfig({
  base: './',
  build: {
    outDir: '../android/app/src/main/assets/editor',
    emptyOutDir: true,
    assetsDir: '.',
    chunkSizeWarningLimit: 4096,
    rollupOptions: {
      output: { manualChunks: undefined, inlineDynamicImports: true },
    },
  },
})
