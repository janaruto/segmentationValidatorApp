#!/bin/bash
# Takes screenshots of the main screens in the iOS Simulator, in English and German.
# Used by the "Screenshots" GitHub workflow; works the same on any Mac with Xcode.
#
# Usage: scripts/take_screenshots.sh <path to Debug-iphonesimulator/SegmentationValidator.app> <output folder>
set -euo pipefail

APP="$1"
OUT="$2"
BUNDLE_ID="com.janaruto.SegmentationValidator"
mkdir -p "$OUT"

# Newest available iPhone simulator (prefers a "Pro" model for a typical screen size).
DEVICE=$(xcrun simctl list devices available --json | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
candidates = []
for runtime, entries in devices.items():
    if "iOS" not in runtime:
        continue
    version = [int(part) for part in runtime.rsplit("iOS-", 1)[-1].split("-") if part.isdigit()]
    for device in entries:
        name = device["name"]
        if name.startswith("iPhone"):
            preferred = "Pro" in name and "Max" not in name
            candidates.append((preferred, version, name, device["udid"]))
if not candidates:
    sys.exit("No iPhone simulator available")
candidates.sort()
print(candidates[-1][3])
')
echo "Using simulator $DEVICE"

xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b
xcrun simctl status_bar "$DEVICE" override --time "9:41" --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 || true

shot() {
    local name="$1"
    shift
    xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl launch "$DEVICE" "$BUNDLE_ID" "$@" >/dev/null
    sleep 7
    xcrun simctl io "$DEVICE" screenshot "$OUT/$name.png" >/dev/null
    echo "Saved $name.png"
}

for lang in en de; do
    if [ "$lang" = "de" ]; then locale="de_CH"; else locale="en_US"; fi
    common=(-AppleLanguages "($lang)" -AppleLocale "$locale")

    # Fresh install: the introduction is shown first.
    xcrun simctl uninstall "$DEVICE" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl install "$DEVICE" "$APP"
    shot "$lang-01-onboarding" "${common[@]}"

    ready=("${common[@]}" -hasCompletedOnboarding YES -debugSeedDemoData YES -debugFakeDetections YES)
    shot "$lang-02-today" "${ready[@]}"
    shot "$lang-03-yesterday" "${ready[@]}" -debugShowYesterday YES
    shot "$lang-04-editor-from-reminder" "${ready[@]}" -debugOpenEditor reminder
    shot "$lang-05-new-segment" "${ready[@]}" -debugShowYesterday YES -debugOpenEditor new
    shot "$lang-06-history" "${ready[@]}" -debugInitialTab history
    shot "$lang-07-export" "${ready[@]}" -debugInitialTab export
    shot "$lang-08-settings" "${ready[@]}" -debugInitialTab settings
done
