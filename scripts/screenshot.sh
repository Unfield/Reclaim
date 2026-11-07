#!/bin/sh
# Captures the Reclaim window on a given screen, without UI scripting.
#   ./scripts/screenshot.sh <screen> <output.png> [language] [seconds]
# Screens: overview apps explorer large memory projects leftovers duplicates models icloud cpu login history removed
# Requires Screen Recording permission for your terminal. Quits any running Reclaim first.
set -eu
cd "$(dirname "$0")/.."

SCREEN="$1"
OUTPUT="$2"
LANGUAGE="${3:-en}"
WAIT="${4:-12}"

osascript -e 'quit app "Reclaim"' >/dev/null 2>&1 || true
sleep 1
open -g build/Reclaim.app --args -ReclaimScreen "$SCREEN" -AppleLanguages "($LANGUAGE)"
sleep "$WAIT"

WINDOW="$(swift - <<'EOF'
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
for window in list where (window["kCGWindowOwnerName"] as? String) == "Reclaim" && (window["kCGWindowLayer"] as? Int) == 0 {
    let bounds = window["kCGWindowBounds"] as? [String: Any] ?? [:]
    if (bounds["Height"] as? Double ?? 0) > 300 { print(window["kCGWindowNumber"] ?? ""); break }
}
EOF
)"
screencapture -x -l "$WINDOW" "$OUTPUT"
sips -Z 1600 "$OUTPUT" >/dev/null
echo "$OUTPUT"
