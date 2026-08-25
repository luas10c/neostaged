import { defineConfig } from 'neostaged/config'

export default defineConfig({
  tasks: {
    '**/*.zig': ['sleep 4s {nofiles}']
  }
})
