#!/usr/bin/env bash
# Notarizes and staples build/NotchBuddy.app. Requires a Developer ID signature and a
# notarytool keychain profile: xcrun notarytool store-credentials notchbuddy --apple-id … --team-id …
set -euo pipefail
cd "$(dirname "$0")/.."
PROFILE="${NB_NOTARY_PROFILE:-notchbuddy}"
ditto -c -k --keepParent build/NotchBuddy.app build/NotchBuddy.zip
xcrun notarytool submit build/NotchBuddy.zip --keychain-profile "$PROFILE" --wait
xcrun stapler staple build/NotchBuddy.app
ditto -c -k --keepParent build/NotchBuddy.app build/NotchBuddy.zip
echo "Notarized build/NotchBuddy.zip"
