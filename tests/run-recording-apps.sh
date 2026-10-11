#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_BUILD=$(mktemp -d)
trap 'rm -rf "$TEST_BUILD"' EXIT
swiftc -module-cache-path "$TEST_BUILD/modules" -parse-as-library RecordingApps.swift tests/RecordingAppsTests.swift -o "$TEST_BUILD/recording-apps-tests"
"$TEST_BUILD/recording-apps-tests"
swiftc -module-cache-path "$TEST_BUILD/modules" -D CALLNOTES_TESTING -parse-as-library RecordingApps.swift SettingsApp.swift tests/RecordingAppsStoreTests.swift -o "$TEST_BUILD/store-tests" -framework SwiftUI -framework AppKit -framework AVFoundation -framework Foundation
"$TEST_BUILD/store-tests"
swiftc -module-cache-path "$TEST_BUILD/modules" -D CALLNOTES_TESTING -parse-as-library RecordingApps.swift calltap.swift tests/RecordingAppsWatchTests.swift -o "$TEST_BUILD/watch-tests" -framework CoreAudio -framework AudioToolbox -framework AVFoundation -framework Foundation
"$TEST_BUILD/watch-tests"
