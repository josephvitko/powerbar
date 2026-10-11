#!/bin/zsh
# Builds a signed, notarized release: dist/PowerBar-<version>.zip
#
#   scripts/release.sh 1.0.0 [--publish]
#
# Signing: SIGN_IDENTITY, or the first "Developer ID Application" identity in the keychain.
# Notarization credentials, either:
#   NOTARY_PROFILE  a keychain profile from `xcrun notarytool store-credentials` (local), or
#   APPLE_ID, APPLE_APP_PASSWORD (app-specific password), APPLE_TEAM_ID  (CI)
# --publish creates the GitHub release v<version> with the zip attached (needs `gh`).
set -euo pipefail
cd "${0:A:h}/.."

VERSION="${1:?usage: scripts/release.sh <version> [--publish]}"
VERSION="${VERSION#v}"
PUBLISH="${2:-}"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning | grep -m1 'Developer ID Application' | sed -E 's/.*"(.*)"/\1/' || true)"
fi
[[ -n "$SIGN_IDENTITY" ]] || { echo "No Developer ID Application identity found (set SIGN_IDENTITY)." >&2; exit 1; }

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
  NOTARY_ARGS=(--apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" --team-id "$APPLE_TEAM_ID")
else
  echo "Set NOTARY_PROFILE, or APPLE_ID + APPLE_APP_PASSWORD + APPLE_TEAM_ID." >&2; exit 1
fi

echo "==> Building $VERSION, signed by: $SIGN_IDENTITY"
VERSION="$VERSION" SIGN_IDENTITY="$SIGN_IDENTITY" scripts/build-app.sh

mkdir -p dist
ZIP="dist/PowerBar-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/PowerBar.app "$ZIP"

echo "==> Notarizing (usually a few minutes)"
xcrun notarytool submit "$ZIP" "${NOTARY_ARGS[@]}" --wait
xcrun stapler staple build/PowerBar.app
spctl --assess --type execute -vv build/PowerBar.app

# Re-zip so the download carries the stapled ticket (works offline on first launch).
rm -f "$ZIP"
ditto -c -k --keepParent build/PowerBar.app "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo "$SHA" > "$ZIP.sha256"
echo "==> $ZIP"
echo "    sha256 $SHA"

if [[ "$PUBLISH" == "--publish" ]]; then
  gh release create "v$VERSION" "$ZIP" --title "PowerBar $VERSION" --generate-notes
fi
