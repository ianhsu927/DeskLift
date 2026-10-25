#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
case "${1:-}" in
  "")
    xcodebuild -quiet -project DeskLift.xcodeproj -scheme DeskLift \
      -configuration Debug -destination 'platform=macOS,arch=arm64' \
      -derivedDataPath build/DerivedData -parallel-testing-enabled NO test
    ;;
  --cli)
    mkdir -p build/module-cache
    swiftc -swift-version 5 -module-cache-path build/module-cache \
      Sources/Protocol.swift Tests/ProtocolSafetyChecks.swift Tests/main.swift -o build/protocol-tests
    build/protocol-tests
    ;;
  *)
    print -u2 'Usage: ./scripts/test.sh [--cli]'
    exit 2
    ;;
esac
