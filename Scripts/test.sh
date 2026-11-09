#!/bin/zsh
# Runs the tests with only the Command Line Tools installed: SwiftPM does not
# search the folder that holds Swift Testing, so pass it explicitly.
set -euo pipefail
cd "${0:A:h}/.."
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
if [[ -d $F ]]; then
  swift test -Xswiftc -F -Xswiftc $F -Xlinker -F -Xlinker $F \
    -Xlinker -rpath -Xlinker $F -Xlinker -rpath -Xlinker $L "$@"
else
  swift test "$@"
fi
