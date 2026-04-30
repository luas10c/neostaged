mkdir -p .cache/node-libs/win-x86

curl -L \
  -o .cache/node-libs/win-x86/node.lib \
  https://nodejs.org/dist/v24.11.0/win-x86/node.lib


mkdir -p .cache/node-libs/win-arm64

curl -L \
  -o .cache/node-libs/win-arm64/node.lib \
  https://nodejs.org/dist/v24.11.0/win-arm64/node.lib

mkdir -p .cache/node-libs/win-x64
curl -fL \
  -o .cache/node-libs/win-x64/node.lib \
  https://nodejs.org/download/release/latest-v24.x/win-x64/node.lib
