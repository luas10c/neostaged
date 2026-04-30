import { defineConfig, globalIgnores } from 'eslint/config'

import globals from 'globals'

import js from '@eslint/js'
import typescript from 'typescript-eslint'

export default defineConfig([
  globalIgnores(['node_modules', 'coverage', 'dist']),
  js.configs.recommended,
  typescript.configs.recommended,
  {
    languageOptions: {
      globals: {
        ...globals.es2022,
        ...globals.node
      }
    }
  }
])
