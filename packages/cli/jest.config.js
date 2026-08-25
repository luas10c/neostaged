import { defineConfig } from 'jest'

export default defineConfig({
  cache: true,
  setupFilesAfterEnv: ['<rootDir>/tests/setup.ts'],
  transform: {
    '^.+\\.(t|j)sx?$': '@swc/jest'
  },
  moduleNameMapper: {
    "^#/(.+)$": '<rootDir>/src/$1'
  }
})
