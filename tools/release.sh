#!/bin/sh
# Release build and Homebrew cask. Run from the repository root, through make.
#   make release   Release build signed with Developer ID, in a DMG notarized and stapled by Apple, and the cask
#                  for it: build/release/Forewarn-<version>.dmg and build/release/forewarn.rb
#   make publish   the same, then GitHub release v<version> with the DMG and its CHANGELOG section, and the cask
#                  committed to Casks/ and pushed: this repository is its own tap.
# Without a Developer ID certificate it builds an ad-hoc DMG, to try the cask on this Mac only:
# Gatekeeper blocks it on any other.
set -eu

VERSION=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)
OUT=build/release
DMG="$OUT/Forewarn-$VERSION.dmg"
IDENTITY="Developer ID Application"
PROFILE=${NOTARY_PROFILE:-forewarn} # xcrun notarytool store-credentials forewarn

if [ "${1:-}" = publish ]; then
    if grep -q "^## $VERSION (unreleased)" CHANGELOG.md; then
        echo "error: CHANGELOG.md still calls $VERSION unreleased: give its section a date first" >&2
        exit 1
    fi
    git fetch -q origin
    if [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
        echo "error: the release is tagged on origin/main: commit and push first" >&2
        exit 1
    fi
fi

if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    # The team is the certificate's: "Developer ID Application: Name (TEAMID)".
    TEAM=$(security find-identity -v -p codesigning | sed -n "s/.*\"$IDENTITY: .* (\(.*\))\"/\1/p" | head -n 1)
    SIGN_FLAGS=--timestamp
else
    [ "${1:-}" = publish ] && { echo "error: publishing needs a Developer ID Application certificate" >&2; exit 1; }
    echo "warning: no Developer ID Application certificate: ad-hoc DMG, for this Mac only" >&2
    IDENTITY=
    TEAM=
    SIGN_FLAGS=
fi

rm -rf "$OUT"
mkdir -p "$OUT/dmg"
xcodegen generate --quiet
xcodebuild -project Forewarn.xcodeproj -scheme Forewarn -configuration Release -destination generic/platform=macOS \
    -derivedDataPath "$OUT/derived" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="${IDENTITY:--}" DEVELOPMENT_TEAM="$TEAM" \
    OTHER_CODE_SIGN_FLAGS="$SIGN_FLAGS" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO -quiet build # no get-task-allow: notarization refuses it
ditto "$OUT/derived/Build/Products/Release/Forewarn.app" "$OUT/dmg/Forewarn.app"
ln -s /Applications "$OUT/dmg/Applications" # for people who open the DMG themselves
hdiutil create -volname Forewarn -srcfolder "$OUT/dmg" -format UDZO -quiet "$DMG"

if [ -n "$IDENTITY" ]; then
    codesign --sign "$IDENTITY" --timestamp "$DMG"
    # One submission for the DMG covers the app inside; the app itself is not stapled, so its first
    # launch checks the ticket online (Homebrew has just downloaded it, so the Mac is online).
    xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose "$DMG"
fi

SHA=$(shasum -a 256 "$DMG" | cut -d " " -f 1)
cat > "$OUT/forewarn.rb" << EOF
cask "forewarn" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/lrzdeveloper/forewarn/releases/download/v#{version}/Forewarn-#{version}.dmg"
  name "Forewarn"
  desc "Menu bar app that warns before the battery, disk or mobile data run out"
  homepage "https://github.com/lrzdeveloper/forewarn"

  depends_on macos: :tahoe

  app "Forewarn.app"

  uninstall quit: "io.github.lrzdeveloper.forewarn"

  zap trash: [
    "~/Library/Application Support/Forewarn",
    "~/Library/Caches/io.github.lrzdeveloper.forewarn",
    "~/Library/Preferences/io.github.lrzdeveloper.forewarn.plist",
  ]
end
EOF
echo "$DMG"
echo "$OUT/forewarn.rb"

[ "${1:-}" = publish ] || exit 0
NOTES=$(awk -v heading="## $VERSION" 'index($0, heading) == 1 { found = 1; next } /^## / { found = 0 } found' CHANGELOG.md)
gh release create "v$VERSION" "$DMG" --target "$(git rev-parse HEAD)" --title "Forewarn $VERSION" --notes "$NOTES"
mkdir -p Casks
cp "$OUT/forewarn.rb" Casks/forewarn.rb
git add Casks/forewarn.rb
git commit --quiet -m "Cask: forewarn $VERSION"
git push --quiet origin main # the pre-push hook runs make check
echo "brew tap lrzdeveloper/forewarn https://github.com/lrzdeveloper/forewarn"
echo "brew install --cask lrzdeveloper/forewarn/forewarn"
