export type NeostagedTaskCommands = string | string[]

export interface NeostagedConfig {
  /**
   * Glob patterns of files that should never trigger tasks.
   */
  ignores?: string | string[]

  /**
   * Map of glob patterns matched against staged files to the commands
   * that should run for them.
   */
  tasks?: Record<string, NeostagedTaskCommands>
}

/**
 * Type-safe helper for `neostaged.config.js` / `.mjs` / `.cjs` files.
 * Returns the config unchanged; it only exists so editors can check the
 * shape of your configuration:
 *
 * ```js
 * import { defineConfig } from 'neostaged/config'
 *
 * export default defineConfig({
 *   ignores: [],
 *   tasks: {
 *     '*.ts': []
 *   }
 * })
 * ```
 */
export function defineConfig<T extends NeostagedConfig>(config: T): T {
  return config
}
