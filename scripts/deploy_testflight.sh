#!/usr/bin/env bash
#
# Build, sign, and upload Neutrino Drive to TestFlight.
#
#   scripts/deploy_testflight.sh              # bump build number by 1
#   scripts/deploy_testflight.sh 3            # set build number to 3
#   scripts/deploy_testflight.sh 3 1.1.0      # build 3, marketing version 1.1.0
#
# project.yml is the source of truth for CURRENT_PROJECT_VERSION / MARKETING_VERSION,
# so the script edits it there and regenerates the Xcode project with xcodegen. The app
# and both embedded extensions (share, file provider) each declare their own copy, and
# App Store Connect rejects an upload whose extension versions disagree with the app's —
# so the bump rewrites all three and the pre-bump check refuses to run if they had drifted.
#
# App Store Connect credentials are read from the environment, or from a
# scripts/.env file (gitignored). Two options, API key preferred:
#
#   ASC_KEY_ID=XXXXXXXXXX
#   ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
#   ASC_KEY_PATH=~/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8
#
# or an Apple ID with an app-specific password (appleid.apple.com -> Sign-In and Security):
#
#   ASC_APPLE_ID=you@example.com
#   ASC_APP_PASSWORD=abcd-efgh-ijkl-mnop
#
# Flags:
#   --skip-tests    don't run the unit test suite before archiving
#   --no-upload     archive and export the .ipa but stop short of uploading

set -euo pipefail

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SCHEME="NeutrinoDrive"
readonly PROJECT="NeutrinoDrive.xcodeproj"
readonly TEAM_ID="46KWJJ63FU"
readonly BUILD_DIR="$PROJECT_ROOT/build"
readonly ARCHIVE_PATH="$BUILD_DIR/$SCHEME.xcarchive"
readonly EXPORT_DIR="$BUILD_DIR/export"
readonly TEST_DESTINATION="platform=iOS Simulator,name=iPhone 17,OS=latest"
# Embedded extensions, verified inside the exported .ipa alongside the app itself.
readonly EXTENSIONS=(NeutrinoDriveShare NeutrinoDriveFileProvider)

RUN_TESTS=1
UPLOAD=1
BUILD_NUMBER=""
MARKETING_VERSION=""

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- arguments ---------------------------------------------------------------

for arg in "$@"; do
  case "$arg" in
    --skip-tests) RUN_TESTS=0 ;;
    --no-upload)  UPLOAD=0 ;;
    -h|--help)    sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)           die "unknown flag: $arg" ;;
    *)
      if [[ -z "$BUILD_NUMBER" ]]; then
        BUILD_NUMBER="$arg"
      elif [[ -z "$MARKETING_VERSION" ]]; then
        MARKETING_VERSION="$arg"
      else
        die "unexpected argument: $arg"
      fi
      ;;
  esac
done

cd "$PROJECT_ROOT"

# --- credentials -------------------------------------------------------------

if [[ -f "$PROJECT_ROOT/scripts/.env" ]]; then
  log "Loading credentials from scripts/.env"
  set -a; source "$PROJECT_ROOT/scripts/.env"; set +a
fi

ASC_KEY_ID="${ASC_KEY_ID:-}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-}"
ASC_KEY_PATH="${ASC_KEY_PATH:-}"
ASC_APPLE_ID="${ASC_APPLE_ID:-}"
ASC_APP_PASSWORD="${ASC_APP_PASSWORD:-}"
AUTH_MODE=""

if [[ -n "$ASC_KEY_ID" && -n "$ASC_ISSUER_ID" && -n "$ASC_KEY_PATH" ]]; then
  ASC_KEY_PATH="${ASC_KEY_PATH/#\~/$HOME}"
  [[ -f "$ASC_KEY_PATH" ]] || die "ASC_KEY_PATH does not exist: $ASC_KEY_PATH"
  AUTH_MODE="api-key"
elif [[ -n "$ASC_APPLE_ID" && -n "$ASC_APP_PASSWORD" ]]; then
  AUTH_MODE="apple-id"
fi

if [[ $UPLOAD -eq 1 && -z "$AUTH_MODE" ]]; then
  die "no App Store Connect credentials found.
  Set either ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH (App Store Connect API key),
  or ASC_APPLE_ID / ASC_APP_PASSWORD (Apple ID + app-specific password),
  in the environment or in scripts/.env. Re-run with --no-upload to build only."
fi

# --- preflight ---------------------------------------------------------------

command -v xcodegen >/dev/null || die "xcodegen not found — brew install xcodegen"
command -v xcodebuild >/dev/null || die "xcodebuild not found — install Xcode"

# Note: don't preflight the Apple Distribution certificate with `security
# find-identity`. Xcode 26 keeps automatic-signing certificates in the
# data-protection keychain, which security(1) cannot enumerate, so that check
# reports a missing certificate even when signing works. The .ipa is inspected
# after export instead, which is authoritative.

# --- version bump ------------------------------------------------------------

# Every target's value, so drift between the app and its extensions is caught here
# rather than by App Store Connect after a ten-minute upload.
distinct_field() {
  awk -v key="$1:" '$1 == key { gsub(/"/, "", $2); print $2 }' project.yml | sort -u
}

current_build="$(distinct_field CURRENT_PROJECT_VERSION)"
[[ -n "$current_build" ]] || die "could not read CURRENT_PROJECT_VERSION from project.yml"
[[ "$(wc -l <<<"$current_build")" -eq 1 ]] || die "targets disagree on CURRENT_PROJECT_VERSION:
$(sed 's/^/    /' <<<"$current_build")
  The app and its embedded extensions must share one build number. Fix project.yml first."

if [[ -z "$BUILD_NUMBER" ]]; then
  BUILD_NUMBER=$((current_build + 1))
fi
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || die "build number must be an integer, got: $BUILD_NUMBER"

log "Build number: $current_build -> $BUILD_NUMBER (app + ${#EXTENSIONS[@]} extensions)"
/usr/bin/sed -i '' -E "s/(CURRENT_PROJECT_VERSION: )\"?[0-9]+\"?/\1\"$BUILD_NUMBER\"/" project.yml

if [[ -n "$MARKETING_VERSION" ]]; then
  log "Marketing version -> $MARKETING_VERSION"
  /usr/bin/sed -i '' -E "s/(MARKETING_VERSION: )\"?[0-9.]+\"?/\1\"$MARKETING_VERSION\"/" project.yml
fi
MARKETING_VERSION="$(distinct_field MARKETING_VERSION)"
[[ "$(wc -l <<<"$MARKETING_VERSION")" -eq 1 ]] || die "targets disagree on MARKETING_VERSION:
$(sed 's/^/    /' <<<"$MARKETING_VERSION")"

log "Regenerating $PROJECT from project.yml"
xcodegen generate

# --- tests -------------------------------------------------------------------

if [[ $RUN_TESTS -eq 1 ]]; then
  log "Running unit tests"
  xcodebuild test \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "$TEST_DESTINATION" \
    -derivedDataPath "$BUILD_DIR" \
    -quiet
else
  warn "skipping tests (--skip-tests)"
fi

# --- archive -----------------------------------------------------------------

log "Archiving $SCHEME $MARKETING_VERSION ($BUILD_NUMBER)"
rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR"

archive_args=(
  archive
  -project "$PROJECT"
  -scheme "$SCHEME"
  -configuration Release
  -destination "generic/platform=iOS"
  -archivePath "$ARCHIVE_PATH"
  -derivedDataPath "$BUILD_DIR"
  -allowProvisioningUpdates
  DEVELOPMENT_TEAM="$TEAM_ID"
)
if [[ "$AUTH_MODE" == "api-key" ]]; then
  archive_args+=(
    -authenticationKeyPath "$ASC_KEY_PATH"
    -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
  )
fi

xcodebuild "${archive_args[@]}"

# --- export ------------------------------------------------------------------

export_options="$BUILD_DIR/ExportOptions.plist"
cat > "$export_options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>uploadSymbols</key>
	<true/>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
	<key>destination</key>
	<string>export</string>
</dict>
</plist>
PLIST

log "Exporting .ipa"
export_args=(
  -exportArchive
  -archivePath "$ARCHIVE_PATH"
  -exportPath "$EXPORT_DIR"
  -exportOptionsPlist "$export_options"
  -allowProvisioningUpdates
)
if [[ "$AUTH_MODE" == "api-key" ]]; then
  export_args+=(
    -authenticationKeyPath "$ASC_KEY_PATH"
    -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
  )
fi

xcodebuild "${export_args[@]}"

IPA_PATH="$(find "$EXPORT_DIR" -name '*.ipa' -maxdepth 1 | head -1)"
[[ -n "$IPA_PATH" ]] || die "export succeeded but no .ipa found in $EXPORT_DIR"
log "Exported $IPA_PATH"

# xcodebuild will happily export a development-signed, stale-versioned .ipa and
# report success; App Store Connect rejects it minutes later. Check here instead.
log "Verifying the exported .ipa"

signed_by="$(unzip -p "$IPA_PATH" 'Payload/*.app/embedded.mobileprovision' 2>/dev/null \
  | security cms -D 2>/dev/null \
  | plutil -extract Name raw - 2>/dev/null || true)"
case "$signed_by" in
  *Store*|*Distribution*|*AppStore*) log "  profile: $signed_by" ;;
  "") warn "  could not read the embedded provisioning profile" ;;
  *) die "  the .ipa is signed with '$signed_by', not an App Store distribution profile.
  TestFlight will reject it. This happens when no 'Apple Distribution' certificate
  exists in the keychain — open the project in Xcode with your Apple ID signed in
  under Settings > Accounts and archive once, so Xcode creates the certificate." ;;
esac

# Info.plist inside an .ipa is a binary plist, so route it through a file rather
# than a shell variable, which would truncate it at the first NUL byte.
check_bundle_version() {
  local label="$1" member="$2" plist="$BUILD_DIR/ipa-info.plist" build version
  unzip -p "$IPA_PATH" "$member" > "$plist" 2>/dev/null \
    || die "  $label is missing from the .ipa ($member)"
  build="$(plutil -extract CFBundleVersion raw -o - "$plist" 2>/dev/null || true)"
  version="$(plutil -extract CFBundleShortVersionString raw -o - "$plist" 2>/dev/null || true)"
  log "  $label: $version ($build)"
  [[ "$build" == "$BUILD_NUMBER" ]] || die "  $label reports build $build, expected $BUILD_NUMBER.
  Check that its Info.plist CFBundleVersion is \$(CURRENT_PROJECT_VERSION) in project.yml."
  [[ "$version" == "$MARKETING_VERSION" ]] || die "  $label reports version $version, expected $MARKETING_VERSION.
  Check that its Info.plist CFBundleShortVersionString is \$(MARKETING_VERSION) in project.yml."
}

check_bundle_version "app" 'Payload/*.app/Info.plist'
# A mismatched extension version is the single most common upload rejection for an app
# that embeds any, and it is invisible until Apple's validator sees it.
for ext in "${EXTENSIONS[@]}"; do
  check_bundle_version "$ext" "Payload/*.app/PlugIns/$ext.appex/Info.plist"
done

if [[ $UPLOAD -eq 0 ]]; then
  warn "stopping before upload (--no-upload)"
  exit 0
fi

# --- upload ------------------------------------------------------------------

log "Validating with App Store Connect"
validate_args=(altool --validate-app -f "$IPA_PATH" -t ios)
upload_args=(altool --upload-app -f "$IPA_PATH" -t ios)
if [[ "$AUTH_MODE" == "api-key" ]]; then
  # altool looks up the .p8 by key id in a fixed set of directories.
  mkdir -p "$HOME/.appstoreconnect/private_keys"
  expected_key="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
  [[ -f "$expected_key" ]] || cp "$ASC_KEY_PATH" "$expected_key"
  validate_args+=(--apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID")
  upload_args+=(--apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID")
else
  validate_args+=(-u "$ASC_APPLE_ID" -p "@env:ASC_APP_PASSWORD")
  upload_args+=(-u "$ASC_APPLE_ID" -p "@env:ASC_APP_PASSWORD")
fi
export ASC_APP_PASSWORD

xcrun "${validate_args[@]}"

log "Uploading to TestFlight"
xcrun "${upload_args[@]}"

log "Done — $SCHEME $MARKETING_VERSION ($BUILD_NUMBER) uploaded."
log "It will appear in TestFlight after Apple finishes processing (usually 5-15 min)."
log "Remember to commit the project.yml build-number bump."
