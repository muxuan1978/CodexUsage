#!/bin/zsh
set -eu
cd "${0:A:h}"
bundle="build/Codex Usage.app"
mkdir -p "$bundle/Contents/MacOS" build/ModuleCache
xcrun swiftc -O -warnings-as-errors -module-cache-path build/ModuleCache Sources/*.swift -o "$bundle/Contents/MacOS/CodexUsage"
mkdir -p "$bundle/Contents/Resources"
cp Assets/CodexUsage.icns "$bundle/Contents/Resources/CodexUsage.icns"
cp Info.plist "$bundle/Contents/Info.plist"
plutil -lint "$bundle/Contents/Info.plist"
codesign --force --sign - "$bundle"
codesign --verify --strict "$bundle"
