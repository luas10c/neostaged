#!/usr/bin/env node

import { createRequire } from 'node:module'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

const require = createRequire(import.meta.url)

const help = `
neostaged

Run commands against staged files

Options:
  --cwd PATH       Run neostaged from a specific directory
  --config PATH    Use a specific neostaged config file
  --list           Print the staged files and exit
  --allow-empty    Allow empty commits when tasks revert all staged changes
  --no-stash       Disable the automatic backup snapshot
  --no-revert      Keep task modifications in the working tree on failure
  -h, --help       Print help
  -V, --version    Print version
`

interface Options {
  cwd?: string
  config?: string
  list: boolean
  stash: boolean
  revert: boolean
  allowEmpty: boolean
}

function fail(message: string): never {
  console.error(message)
  process.exit(1)
}

function parseArgs(argv: string[]): Options {
  const options: Options = {
    list: false,
    stash: true,
    revert: true,
    allowEmpty: false,
  }

  for (let i = 2; i < argv.length; i++) {
    const arg = argv[i]

    if (arg === '--cwd') {
      const value = argv[++i]
      if (value === undefined) fail(`Missing value for ${arg}`)
      options.cwd = resolve(value)
    } else if (arg === '--config') {
      const value = argv[++i]
      if (value === undefined) fail(`Missing value for ${arg}`)
      options.config = value
    } else if (arg === '--list') {
      options.list = true
    } else if (arg === '--allow-empty') {
      options.allowEmpty = true
    } else if (arg === '--no-stash') {
      options.stash = false
    } else if (arg === '--no-revert') {
      options.revert = false
    } else if (arg === '-h' || arg === '--help') {
      console.log(help)
      process.exit(0)
    } else if (arg === '-V' || arg === '--version') {
      console.log(getVersion())
      process.exit(0)
    } else {
      fail(`Unknown argument: ${arg}`)
    }
  }

  return options
}

function getVersion(): string {
  try {
    const packageJsonPath = resolve(import.meta.dirname, '..', 'package.json')
    const packageJson = JSON.parse(readFileSync(packageJsonPath, 'utf8')) as { version?: string }
    return packageJson.version ?? '0.0.0'
  } catch {
    return '0.0.0'
  }
}

function isMusl(): boolean {
  if (process.platform !== 'linux') return false
  try {
    const report = (process.report?.getReport?.() as { header?: { glibcVersionRuntime?: string } } | undefined)
    return !report?.header?.glibcVersionRuntime
  } catch {
    return false
  }
}

function getTarget(): string {
  const { platform, arch } = process

  if (platform === 'darwin') {
    if (arch === 'arm64') return 'darwin-arm64'
    if (arch === 'x64') return 'darwin-x64'
  }

  if (platform === 'win32') {
    if (arch === 'arm64') return 'win32-arm64-msvc'
    if (arch === 'ia32') return 'win32-ia32-msvc'
    if (arch === 'x64') return 'win32-x64-msvc'
  }

  if (platform === 'linux') {
    const musl = isMusl() ? 'musl' : 'gnu'
    if (arch === 'x64') return `linux-x64-${musl}`
    if (arch === 'arm64') return `linux-arm64-${musl}`
    if (arch === 'arm') return 'linux-arm-gnueabihf'
    if (arch === 'ppc64') return 'linux-ppc64-gnu'
    if (arch === 's390x') return 'linux-s390x-gnu'
  }

  throw new Error(`Unsupported platform: ${platform} ${arch}`)
}

function loadNativeAddon(): { run: (options: Record<string, unknown>) => boolean } {
  // 1. Try local dev binary (built by zig build and placed in packages/cli/bin/neostaged.node)
  const localAddonPath = resolve(import.meta.dirname, '..', 'bin', 'neostaged.node')
  try {
    return require(localAddonPath) as { run: (options: Record<string, unknown>) => boolean }
  } catch {
    // Fall through to npm optionalDependency lookup
  }

  // 2. Resolve platform-specific npm package
  const target = getTarget()
  const packageName = `@neostaged/neostaged-${target}`

  try {
    return require(packageName) as { run: (options: Record<string, unknown>) => boolean }
  } catch (err) {
    const reason = err instanceof Error ? err.message : String(err)
    fail(`Failed to load native binary package (${packageName}): ${reason}`)
  }
}

try {
  const options = parseArgs(process.argv)

  const addon = loadNativeAddon()

  const ok = addon.run({
    cwd: options.cwd ?? resolve('.'),
    config: options.config,
    list: options.list,
    color: Boolean(process.stdout.isTTY) && !('NO_COLOR' in process.env),
    stash: options.stash,
    revert: options.revert,
    allow_empty: options.allowEmpty,
  })

  process.exitCode = ok ? 0 : 1
} catch (err) {
  console.error(err instanceof Error ? (err.message || err) : err)
  process.exit(1)
}
