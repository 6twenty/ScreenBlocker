#!/bin/bash
set -e

cd "$(dirname "$0")"

# With only the Command Line Tools installed (no Xcode), Swift Testing ships
# outside the default search paths, so point the compiler and linker at it.
CLT_DEV="/Library/Developer/CommandLineTools/Library/Developer"
EXTRA_FLAGS=()
if [ -d "$CLT_DEV/Frameworks/Testing.framework" ]; then
    EXTRA_FLAGS=(
        -Xswiftc -F -Xswiftc "$CLT_DEV/Frameworks"
        -Xlinker -F -Xlinker "$CLT_DEV/Frameworks"
        -Xlinker -rpath -Xlinker "$CLT_DEV/Frameworks"
        -Xlinker -rpath -Xlinker "$CLT_DEV/usr/lib"
        # The CLT ship _Testing_Foundation without a module file, so the
        # Testing+Foundation cross-import fails unless overlays are disabled.
        -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays
    )
fi

# Tests share a global clock, so run them serially.
swift test --no-parallel "${EXTRA_FLAGS[@]}" "$@"
