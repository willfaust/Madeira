#!/bin/bash
# Meson's host compiler is macOS, but DXMT's embedded Metal runs on the iPad.
set -euo pipefail
args=("$@")
if [[ ${args[0]:-} == -sdk && ${args[1]:-} == macosx &&
      ( ${args[2]:-} == metal || ${args[2]:-} == metallib ) ]]; then
    args[1]=iphoneos
    for ((index=3; index<${#args[@]}; index++)); do
        if [[ ${args[index]} == --target=air64-apple-macos* ]]; then
            args[index]="--target=air64-apple-ios${IOS_DEPLOYMENT_TARGET:-18.0}"
        fi
    done
fi
exec /usr/bin/xcrun "${args[@]}"
