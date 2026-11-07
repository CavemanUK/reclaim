#!/bin/bash
# Runs the test suite with only the Command Line Tools installed.
# Swift Testing lives in the CLT's extra Frameworks folder, and its Foundation cross-import overlay
# (_Testing_Foundation) ships without a module, so overlays are disabled.
set -euo pipefail
cd "$(dirname "$0")/.."
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
exec swift test \
    -Xswiftc -F -Xswiftc "$F" \
    -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
    -Xlinker -F -Xlinker "$F" -Xlinker -rpath -Xlinker "$F" "$@"
