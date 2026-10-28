#!/bin/sh
# Release build and Homebrew cask. Run from the repository root, through make.
#   make release   Release build signed with Developer ID, in a DMG notarized and stapled by Apple, and the cask
#                  for it: build/release/Forewarn-<version>.dmg and build/release/forewarn.rb
#   make publish   the same, then GitHub release v<version> with the DMG and its CHANGELOG section, and the cask
#                  committed to Casks/ and pushed: this repository is its own tap.
#                  The release stays a draft until the cask is on origin/main. Run again after a failure: an
#                  existing release is resumed from its uploaded DMG, never rebuilt.
# Without a Developer ID certificate it builds an ad-hoc DMG, to try the cask on this Mac only:
# Gatekeeper blocks it on any other.
set -eu

MODE=${1:-}
OUT=build/release
LOCK=build/.release.lock
IDENTITY="Developer ID Application"
PROFILE=${NOTARY_PROFILE:-forewarn} # xcrun notarytool store-credentials forewarn

die() {
    echo "error: $*" >&2
    exit 1
}

# One run at a time: each one empties build/release, and a second could swap the DMG between its checksum and its
# upload, publishing a cask that does not match.
mkdir -p build
mkdir "$LOCK" 2> /dev/null || die "another release is running (remove $LOCK if none is)"
trap 'rmdir "$LOCK"' EXIT
trap 'exit 130' INT TERM

VERSION=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)
[ "$(printf '%s\n' "$VERSION" | grep -c .)" -eq 1 ] && printf '%s\n' "$VERSION" | grep -Eqx '[0-9]+\.[0-9]+\.[0-9]+' ||
    die "project.yml needs exactly one MARKETING_VERSION like \"1.2.3\", found: '$VERSION'"
DMG="$OUT/Forewarn-$VERSION.dmg"

# The section of exactly this version, dated: "## 1.2.3 (2026-10-28)". Compared as text, never as a regex.
notes() {
    awk -v version="$VERSION" '
        BEGIN { heading = "## " version " (" }
        /^## / {
            inside = index($0, heading) == 1 && substr($0, length(heading) + 1) ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)$/
            found += inside
            next
        }
        inside { print }
        END { exit found == 1 ? 0 : 1 }
    ' CHANGELOG.md
}

# The cask for a DMG with this SHA-256.
cask() {
    cat << EOF
cask "forewarn" do
  version "$VERSION"
  sha256 "$1"

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
}

# Commits the cask for the DMG with this SHA (unless it is already there), pushes it to main, then makes the draft
# release public: the release is never out without its cask.
publish_cask() {
    mkdir -p Casks
    cask "$1" > Casks/forewarn.rb
    if ! git diff --quiet -- Casks/forewarn.rb; then
        git add Casks/forewarn.rb
        git commit --quiet -m "Cask: forewarn $VERSION"
    fi
    git push --quiet origin HEAD:refs/heads/main # the pre-push hook runs make check
    gh release edit "v$VERSION" --draft=false > /dev/null
    echo "brew tap lrzdeveloper/forewarn https://github.com/lrzdeveloper/forewarn"
    echo "brew install --cask lrzdeveloper/forewarn/forewarn"
}

if [ "$MODE" = publish ]; then
    NOTES=$(notes) && [ -n "$(printf '%s' "$NOTES" | tr -d '[:space:]')" ] ||
        die "CHANGELOG.md needs exactly one dated, non-empty section \"## $VERSION (YYYY-MM-DD)\""
    [ "$(git symbolic-ref --short -q HEAD || true)" = main ] || die "publish from the main branch"
    [ -z "$(git status --porcelain)" ] || die "commit everything first"
    git fetch -q origin
    SOURCE=$(git rev-parse HEAD)
    ORIGIN=$(git rev-parse origin/main)
    # A run whose push failed leaves its cask commit on top of origin/main: that one is resumed below.
    LEFTOVER=no
    if [ "$SOURCE" != "$ORIGIN" ]; then
        [ "$(git rev-parse -q --verify HEAD^ || true)" = "$ORIGIN" ] &&
            [ "$(git log -1 --format=%s)" = "Cask: forewarn $VERSION" ] ||
            die "the release is tagged on origin/main: commit and push first"
        LEFTOVER=yes
    fi

    DRAFT=$(gh release view "v$VERSION" --json isDraft -q .isDraft 2> /dev/null || echo none)
    if [ "$DRAFT" != none ]; then
        if [ "$DRAFT" = false ] && git show origin/main:Casks/forewarn.rb | grep -qF "version \"$VERSION\""; then
            echo "Forewarn $VERSION is already published, with its cask"
            exit 0
        fi
        # Resume from what was uploaded: its checksum is the one the cask must carry.
        echo "resuming v$VERSION from its uploaded DMG" >&2
        rm -rf "$OUT"
        mkdir -p "$OUT"
        gh release download "v$VERSION" -p "Forewarn-$VERSION.dmg" -D "$OUT" ||
            die "v$VERSION has no Forewarn-$VERSION.dmg: delete it (gh release delete v$VERSION) and run again"
        spctl --assess --type open --context context:primary-signature "$DMG"
        publish_cask "$(shasum -a 256 "$DMG" | cut -d " " -f 1)"
        exit 0
    fi
    [ "$LEFTOVER" = no ] || die "HEAD is a cask commit for v$VERSION, which does not exist: drop it (git reset HEAD^)"
fi

if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    # The team is the certificate's: "Developer ID Application: Name (TEAMID)".
    TEAM=$(security find-identity -v -p codesigning | sed -n "s/.*\"$IDENTITY: .* (\(.*\))\"/\1/p" | head -n 1)
    SIGN_FLAGS=--timestamp
else
    [ "$MODE" = publish ] && die "publishing needs a Developer ID Application certificate"
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
cask "$SHA" > "$OUT/forewarn.rb"
echo "$DMG"
echo "$OUT/forewarn.rb"

[ "$MODE" = publish ] || exit 0
# What was built is what gets tagged: nothing moved during the build and notarization.
[ "$(git rev-parse HEAD)" = "$SOURCE" ] && [ -z "$(git status --porcelain)" ] ||
    die "HEAD or the working tree changed during the build: run again"
gh release create "v$VERSION" "$DMG" --draft --target "$SOURCE" --title "Forewarn $VERSION" --notes "$NOTES"
publish_cask "$SHA"
