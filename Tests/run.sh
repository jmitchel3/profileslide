#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
swiftc -module-cache-path build/tests/module-cache Sources/ScrollGesture.swift Sources/Profiles.swift Tests/main.swift -o build/tests/regressions
build/tests/regressions
swiftc -module-cache-path build/tests/module-cache Sources/PromptInput.swift Tests/PromptInput/main.swift -o build/tests/prompt-input
build/tests/prompt-input
