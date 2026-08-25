#!/usr/bin/env bash
set -euo pipefail

NODE_VERSION="v24.11.0"
BASE_URL="https://nodejs.org/dist/${NODE_VERSION}"

mkdir -p .cache/node-libs/win-x86 .cache/node-libs/win-arm64 .cache/node-libs/win-x64

curl -fSL -o .cache/node-libs/win-x86/node.lib "${BASE_URL}/win-x86/node.lib"
curl -fSL -o .cache/node-libs/win-arm64/node.lib "${BASE_URL}/win-arm64/node.lib"
curl -fSL -o .cache/node-libs/win-x64/node.lib "${BASE_URL}/win-x64/node.lib"
