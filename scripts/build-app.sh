#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

architectures=("$(uname -m)")
if [[ "${1:-}" == "--universal" ]]; then architectures=(arm64 x86_64); fi
app="$PWD/dist/MacTouch.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
binaries=()
for architecture in "${architectures[@]}"; do
  xcrun swift build -c release --arch "$architecture" --scratch-path ".build/$architecture"
  bin_path=$(xcrun swift build -c release --arch "$architecture" --scratch-path ".build/$architecture" --show-bin-path)
  binaries+=("$bin_path/MacTouch")
done
if [[ ${#binaries[@]} -gt 1 ]]; then
  xcrun lipo -create "${binaries[@]}" -output "$app/Contents/MacOS/MacTouch"
else
  cp "${binaries[0]}" "$app/Contents/MacOS/MacTouch"
fi
# Remove debug records containing local source paths before public distribution.
xcrun strip -S "$app/Contents/MacOS/MacTouch"
cp Resources/Info.plist "$app/Contents/Info.plist"
if [[ -d ThirdParty ]]; then ditto ThirdParty "$app/Contents/Resources/ThirdParty"; fi
cp README.md "$app/Contents/Resources/README.md"
ditto docs "$app/Contents/Resources/docs"
xcrun swift scripts/make-icon.swift "$app/Contents/Resources"
if [[ -n "${CODE_SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$CODE_SIGN_IDENTITY" "$app"
else
  codesign --force --sign - "$app"
fi
codesign --verify --strict "$app"
ditto -c -k --norsrc --noextattr --noacl --keepParent "$app" "$PWD/dist/MacTouch.zip"
echo "Built $app"
echo "Transfer archive: $PWD/dist/MacTouch.zip"
