import { defineConfig } from 'jest'

export default defineConfig({
  transform: {
    '^.+\\.(t|j)sx?$': '@swc/jest'
  }
})
