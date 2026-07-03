#!/bin/bash
# build.sh — baut die zwei Apps:
#   calltap.app   -> ~/Applications (Recorder/Daemon, headless) — bewusst im Benutzer-
#                 ordner: die Mikrofon-/Systemaudio-TCC-Freigaben haengen daran, ein
#                 Umzug wuerde sie riskieren. Sichtbar bist du hier eh nie.
#   CallNotes.app -> /Applications (Menueleisten-App) — im normalen Programme-Ordner,
#                 damit sie ueber Spotlight/Finder auffindbar ist.
set -euo pipefail
cd "$(dirname "$0")"

USER_APPS="$HOME/Applications"
APPS="/Applications"
mkdir -p "$USER_APPS"

# App-Icon bei Bedarf erzeugen
[ -f assets/AppIcon.icns ] || swift assets/make-assets.swift

# --- calltap.app ---------------------------------------------------------------
APP="$USER_APPS/calltap.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O calltap.swift -o "$APP/Contents/MacOS/calltap" \
  -framework CoreAudio -framework AudioToolbox -framework AVFoundation -framework Foundation
cp calltap-Info.plist "$APP/Contents/Info.plist"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null || true
codesign --force -s - --identifier at.dasgeht.calltap "$APP"
echo "OK: $APP"

# --- CallNotes.app (Menueleiste) -------------------------------------------------
APP2="$APPS/CallNotes.app"
mkdir -p "$APP2/Contents/MacOS" "$APP2/Contents/Resources"
swiftc -O -parse-as-library SettingsApp.swift -o "$APP2/Contents/MacOS/CallNotes" \
  -framework SwiftUI -framework AppKit -framework AVFoundation -framework Foundation
cp CallNotes-Info.plist "$APP2/Contents/Info.plist"
cp assets/AppIcon.icns "$APP2/Contents/Resources/AppIcon.icns" 2>/dev/null || true
codesign --force -s - --identifier at.dasgeht.callnotes "$APP2"
echo "OK: $APP2"
