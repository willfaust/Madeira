#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 David Brookes
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
set -euo pipefail
probe_dir="$(cd "$(dirname "$0")" && pwd)"
probe_derived="${DERIVED_DATA:-${TMPDIR:-/tmp}/madeira-ssd-probe}"
xcodegen generate --spec "$probe_dir/project.yml"
args=(-project "$probe_dir/MadeiraSSDProbe.xcodeproj" -scheme MadeiraSSDProbe
      -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath "$probe_derived")
if [[ -n "${TEAM_ID:-}" ]]; then
    : "${BUNDLE_ID:?Set a distinct bundle ID; never use the working Madeira bundle ID}"
    args+=("DEVELOPMENT_TEAM=$TEAM_ID" "PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID" -allowProvisioningUpdates)
else
    args+=(CODE_SIGNING_ALLOWED=NO)
fi
xcodebuild "${args[@]}" build
