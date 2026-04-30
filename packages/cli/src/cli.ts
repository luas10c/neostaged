#!/usr/bin/env node

import { createRequire } from 'node:module'
import { join } from 'node:path'

const require = createRequire(import.meta.dirname)

const addon = require(
  join(import.meta.dirname, 'neostaged-x86_64-linux-musl.node')
)

const help = `
neostaged

Run commands against staged files

Options:
  --cwd PATH       Run neostaged from a specific directory
  --config PATH    Use a specific neostaged config file
  --list           Print the staged files and exit
  -h, --help       Print help
  -V, --version    Print version
`

type Options = {
  cwd: string
  config: string | null
  list: boolean
}

function parseArgs(argv: unknown[]) {
  const options: Options = {
    cwd: '.',
    config: null,
    list: false
  }

  for (let i = 2; i < argv.length; i++) {
    const arg = argv[i] as '--cwd' | '--config' | '--list'

    if (arg === '--cwd') {
      options.cwd = argv[++i] as '--cwd' | '--config' | '--list'
    } else if (arg === '--config') {
      options.config = argv[++i] as null
    } else if (arg === '--list') {
      options.list = true
    } else if (arg === '-h' || arg === '--help') {
      console.log(help)
      process.exit(0)
    } else if (arg === '-V' || arg === '--version') {
      console.log('neostaged')
      process.exit(0)
    } else {
      console.error(`Unknown argument: ${arg}`)
      process.exit(1)
    }
  }

  return options
}

try {
  addon.run(parseArgs(process.argv))
} catch (err) {
  console.error(err instanceof Error ? err.message || err : err)
  process.exit(1)
}
