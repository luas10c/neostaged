#!/usr/bin/env node
'use strict'

import { spawn } from 'node:child_process'
import { copyFile, mkdir, readFile } from 'node:fs/promises'
import { setTimeout } from 'node:timers/promises'
import { dirname, join } from 'node:path'
import { createRequire } from 'node:module'

const require = createRequire(import.meta.dirname)

function isMusl() {
  if (process.platform !== 'linux') return false

  try {
    const report = process.report?.getReport?.()
    return !report?.header?.glibcVersionRuntime
  } catch {
    return false
  }
}

function getTarget() {
  if (process.platform === 'darwin') {
    if (process.arch === 'arm64') return 'darwin-arm64'
    if (process.arch === 'x64') return 'darwin-x64'
  }

  if (process.platform === 'win32') {
    if (process.arch === 'arm64') return 'win32-arm64-msvc'
    if (process.arch === 'ia32') return 'win32-ia32-msvc'
    if (process.arch === 'x64') return 'win32-x64-msvc'
  }

  if (process.platform === 'linux') {
    if (process.arch === 'x64') return `linux-x64-${isMusl() ? 'musl' : 'gnu'}`
    if (process.arch === 'arm64')
      return `linux-arm64-${isMusl() ? 'musl' : 'gnu'}`
    if (process.arch === 'arm') return 'linux-arm-gnueabihf'
    if (process.arch === 'ppc64') return 'linux-ppc64-gnu'
    if (process.arch === 's390x') return 'linux-s390x-gnu'
  }

  throw new Error(`Unsupported platform: ${process.platform} ${process.arch}`)
}

function runNpmInstallOnce(pkg, cwd) {
  return new Promise((resolve, reject) => {
    const command = process.platform === 'win32' ? 'npm.cmd' : 'npm'

    const child = spawn(
      command,
      ['install', '--no-save', '--ignore-scripts', '--prefer-online', pkg],
      {
        cwd,
        stdio: 'inherit'
      }
    )

    child.on('error', reject)

    child.on('close', (code) => {
      if (code === 0) {
        resolve()
        return
      }

      reject(new Error(`npm install failed with exit code ${code}`))
    })
  })
}

async function runNpmInstall(pkg, cwd) {
  const attempts = 3

  for (let attempt = 1; attempt <= attempts; attempt++) {
    try {
      await runNpmInstallOnce(pkg, cwd)
      return
    } catch (error) {
      if (attempt === attempts) {
        throw error
      }

      const delay = attempt * 1000

      console.warn(
        `npm install failed for ${pkg}. Retrying in ${delay}ms... (${attempt}/${attempts})`
      )

      await setTimeout(delay)
    }
  }
}

async function main() {
  const target = getTarget()

  const packageName = `@neostaged/neostaged-${target}`
  const binaryName = `neostaged-${target}.node`

  const packageJsonPath = join(import.meta.dirname, 'package.json')
  const packageJson = JSON.parse(await readFile(packageJsonPath, 'utf8'))

  const version = packageJson.optionalDependencies?.[packageName]

  if (!version) {
    throw new Error(`Missing optionalDependency for ${packageName}`)
  }

  try {
    require.resolve(`${packageName}/package.json`)
  } catch {
    console.log(`${packageName}@${version} not found, installing...`)

    await runNpmInstall(`${packageName}@${version}`, import.meta.dirname)
  }

  const nativePackageJson = require.resolve(`${packageName}/package.json`)
  const nativePackageDir = dirname(nativePackageJson)

  const source = join(nativePackageDir, binaryName)
  const outputDir = join(import.meta.dirname, 'bin')
  const output = join(outputDir, 'neostaged.node')

  await mkdir(outputDir, { recursive: true })
  await copyFile(source, output)

  console.log(`Installed ${packageName}@${version}`)
}

main().catch((error) => {
  console.error(error)
  process.exit(1)
})
