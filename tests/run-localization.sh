#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_BUILD=$(mktemp -d)
trap 'rm -rf "$TEST_BUILD"' EXIT
swiftc -module-cache-path "$TEST_BUILD/modules" -parse-as-library AppText.swift tests/AppTextTests.swift -o "$TEST_BUILD/app-text-tests"
"$TEST_BUILD/app-text-tests"
swiftc -module-cache-path "$TEST_BUILD/modules" -D CALLNOTES_TESTING -parse-as-library AppText.swift RecordingApps.swift SettingsApp.swift tests/AppTextStoreTests.swift -o "$TEST_BUILD/store-tests" -framework SwiftUI -framework AppKit -framework AVFoundation -framework Foundation
CALLNOTES_LANG=en "$TEST_BUILD/store-tests"
python3 -m unittest discover -s tests -p test_ui_notifications.py
