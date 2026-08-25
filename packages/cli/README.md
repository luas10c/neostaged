<div align="center">

<img src="https://github.com/luas10c/neostaged/blob/main/brand.png?raw=true" alt="Neostaged">

**Ultra-fast, zero-dependency pre-commit tool built with Zig & Node.js N-API.**

Run linters, formatters, and custom scripts against staged git files with modern visual feedback and total safety.

[![npm version](https://img.shields.io/npm/v/neostaged.svg?style=flat-square&color=26a1c0)](https://www.npmjs.com/package/neostaged)
[![license](https://img.shields.io/npm/l/neostaged.svg?style=flat-square&color=26a1c0)](https://github.com/luas10c/neostaged/blob/main/LICENSE)
[![node version](https://img.shields.io/node/v/neostaged.svg?style=flat-square&color=26a1c0)](https://nodejs.org)
[![zero dependencies](https://img.shields.io/badge/dependencies-0-26a1c0.svg?style=flat-square)](https://www.npmjs.com/package/neostaged)

</div>

---

## ⚡ Preview

```text
◆ neostaged v0.0.5 · ⎇ main · 2 staged
│
│ ◈ neostaged.json — 2 files · 1 pattern
│
│ ▸ **/*.txt · 1 file
│   ⠋ sleep 0.3 · 1 file · 320ms
│   ✓ echo hello · 1 file · 80ms
│   ✓ true · 1 file · 80ms
│
├─ ✓ done in 495ms · 3 ok · 0 failed · 0 skipped
│
│ ⏱ timings
│   TASK                            FILES  STATUS     DURATION
│   sleep 0.3                           1  ✓ ok    320ms
│   echo hello                          1  ✓ ok     80ms
│   true                                1  ✓ ok     80ms
╰─ staged ✓
```

---

## ✨ Features

- ⚡ **Blazing Fast Native Core**: Written in **Zig**, compiled directly into a native Node.js N-API binary (`.node`).
- 📦 **Zero Runtime Dependencies**: No heavy npm dependency trees to install or update.
- 🎨 **Modern Rail Layout UI**: Sleek left-rail layout with inline task statuses, live task spinners, and 24-bit TrueColor ANSI styling.
- 🛡️ **Git Safe & Automated Backups**: Automatically stashes unstaged modifications before running tasks, and safely restores or recovers state if a task fails.
- ⏱️ **Task Timings Summary**: Clear summary table listing exact duration per task in milliseconds.
- 📁 **Flexible Configuration**: Read rules from `.neostaged.json`, `neostaged.config.js`, `.neostagedrc`, or `package.json`.
- 🌐 **Cross-Platform**: Works identically across macOS, Linux, and Windows.

---

## 📦 Installation

Install `neostaged` using your favorite package manager:

```bash
# npm
npm install --save-dev neostaged

# pnpm
pnpm add -D neostaged

# yarn
yarn add -D neostaged

# bun
bun add -d neostaged
```

---

## 🚀 Quick Start

### 1. Configure rules

Create a `neostaged.json` (or `.neostaged.json`) in your project root:

```json
{
  "*.{js,ts,tsx}": [
    "eslint --fix",
    "prettier --write"
  ],
  "*.json": [
    "prettier --write"
  ]
}
```

### 2. Add to Git Pre-Commit Hook

#### With [Husky](https://github.com/typicode/husky):

```bash
npx husky add .husky/pre-commit "npx neostaged"
```

Or in `.husky/pre-commit`:

```sh
#!/bin/sh
. "$(dirname "$0")/_/husky.sh"

npx neostaged
```

---

## ⚙️ Configuration Formats

`neostaged` searches for configuration files in the following order:

1. `.neostaged.json` / `neostaged.json` / `neostaged.config.json`
2. `.neostagedrc`
3. `package.json` (under `"neostaged": { ... }`)
4. `.neostaged.js` / `neostaged.js` / `neostaged.config.js`
5. `.neostaged.cjs` / `neostaged.cjs` / `neostaged.config.cjs`
6. `.neostaged.mjs` / `neostaged.mjs` / `neostaged.config.mjs`

### Examples

#### `neostaged.json`
```json
{
  "*.{ts,tsx}": "eslint --fix",
  "*.md": "prettier --write"
}
```

#### `package.json`
```json
{
  "name": "my-project",
  "neostaged": {
    "*.js": ["eslint --fix", "prettier --write"]
  }
}
```

#### `neostaged.config.js`
```js
export default {
  "*.{js,ts}": ["eslint --fix", "prettier --write"],
  "*.css": "stylelint --fix"
};
```

---

## 🎨 Customizing the Spinner

Customize the animation and 24-bit TrueColor scheme using environment variables:

### Color (`NEOSTAGED_SPINNER_COLOR`)
- **Default**: `#26a1c0` (Solid Hex RGB)
- **Rainbow Mode**: `rainbow` (or `arcoiris`)
- **Custom Hex**: `#ff5733`, `#00ff88`, `#9966ff`

```bash
# Rainbow animation
NEOSTAGED_SPINNER_COLOR=rainbow npx neostaged

# Custom hex color
NEOSTAGED_SPINNER_COLOR=#ff5733 npx neostaged
```

### Spinner Theme (`NEOSTAGED_SPINNER`)
Select from 10 built-in themes:
- `dots` (Default: `⠋` `⠙` `⠹` `⠸` `⠼` `⠴` `⠦` `⠧` `⠇` `⠏`)
- `sparkle` (`✦` `✧` `✶` `✴` `✹`)
- `pulse` (`⎺` `⎻` `⎼` `⎽`)
- `bars` (` ` `▃` `▄` `▅` `▆` `▇` `█`)
- `diamond` (`◇` `◈` `◆`)
- `dense`, `moon`, `arc`, `bounce`, `arrow`

```bash
NEOSTAGED_SPINNER=sparkle npx neostaged
```

---

## 📊 Comparison

| Feature | `neostaged` | `lint-staged` | `nano-staged` |
|---|:---:|:---:|:---:|
| **Engine** | **Zig + N-API** | Node.js (JS) | Node.js (JS) |
| **Dependencies** | **0** | ~35+ | ~5+ |
| **V8 Rail Layout** | ✅ | ❌ | ❌ |
| **TrueColor 24-bit Spinner** | ✅ | ❌ | ❌ |
| **Partial Staging Backup** | ✅ | ✅ | ✅ |
| **Execution Timings Table** | ✅ | ❌ | ❌ |

---

## 📄 License

[MIT](./LICENSE) © [Luciano Alves](mailto:luas10c@gmail.com)
