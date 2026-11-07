#!/bin/sh
# Runs the test suite. With only the Command Line Tools installed (no Xcode), Swift Testing
# isn't on the default search path, so point the compiler at it explicitly.
set -eu

cd "$(dirname "$0")/.."

if xcode-select -p | grep -q CommandLineTools; then
    FRAMEWORKS="$(xcode-select -p)/Library/Developer/Frameworks"
    # -disable-cross-import-overlays works around CLT installs missing _Testing_Foundation's module files.
    exec swift test \
        -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
        -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
        -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
        "$@"
else
    exec swift test "$@"
fi
