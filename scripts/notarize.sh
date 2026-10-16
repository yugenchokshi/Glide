#!/usr/bin/env bash
# Notarizes and staples build/Glide.app. Requires a Developer ID signature and a
# notarytool keychain profile: xcrun notarytool store-credentials glide --apple-id … --team-id …
set -euo pipefail
cd "$(dirname "$0")/.."
PROFILE="${NB_NOTARY_PROFILE:-glide}"
ditto -c -k --keepParent build/Glide.app build/Glide.zip
xcrun notarytool submit build/Glide.zip --keychain-profile "$PROFILE" --wait
xcrun stapler staple build/Glide.app
ditto -c -k --keepParent build/Glide.app build/Glide.zip
echo "Notarized build/Glide.zip"
