import { describe, expect, it } from '@jest/globals'

import { defineConfig } from '#/config'

describe('defineConfig', () => {
  it('returns the config unchanged', () => {
    const config = defineConfig({
      ignores: ['**/generated/**'],
      tasks: {
        '**/*.ts': ['eslint --fix', 'prettier --write'],
        '*.css': 'stylelint --fix'
      }
    })

    expect(config).toEqual({
      ignores: ['**/generated/**'],
      tasks: {
        '**/*.ts': ['eslint --fix', 'prettier --write'],
        '*.css': 'stylelint --fix'
      }
    })
    expect(config.tasks?.['**/*.ts']).toEqual(['eslint --fix', 'prettier --write'])
  })

  it('accepts the minimal empty shape', () => {
    expect(defineConfig({ ignores: [], tasks: { '**/*.ts': [] } })).toEqual({
      ignores: [],
      tasks: {
        '**/*.ts': []
      }
    })
  })

  it('accepts a single ignore pattern string', () => {
    expect(defineConfig({ ignores: '**/vendor/**' }).ignores).toBe('**/vendor/**')
  })
})
