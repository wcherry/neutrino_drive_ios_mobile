#!/usr/bin/env bash
#
# Build, install, and launch Neutrino Drive on an iOS Simulator or a real device.
#
#   scripts/run_simulator.sh                        # iPhone 17 Pro, latest OS, Debug
#   scripts/run_simulator.sh --device "iPad Pro 13-inch (M4)"
#   scripts/run_simulator.sh --os 18.0 --release
#   scripts/run_simulator.sh --console              # stream the app's stdout/stderr
#   scripts/run_simulator.sh --reset --screenshot   # fresh install, then a PNG
#
#   scripts/run_simulator.sh --physical             # the paired iPhone/iPad
#   scripts/run_simulator.sh --physical --console   # ... attached to its output
#   scripts/run_simulator.sh --physical --device 00008140-001474C12E89801C
#
# Simulators are driven with simctl, real devices with devicectl (Xcode 15+).
# Everything either side shares — the scheme, the build, locating the .app — is
# the same code path, so the two stay in step.
#
# The bundle id and scheme come from project.yml, which stays the source of
# truth exactly as it is for scripts/deploy_testflight.sh.
#
# Flags:
#   --physical        build for and run on a paired iOS device rather than a
#                     simulator. The device must be paired with this Mac,
#                     unlocked, and have Developer Mode enabled
#                     (Settings > Privacy & Security > Developer Mode)
#   --device NAME     simulator to use (default: iPhone 17 Pro); with --physical,
#                     the device's name or UDID (default: the only one paired)
#   --os VERSION      runtime version, e.g. 18.0 (default: newest installed).
#                     Simulator only — a device runs the OS it runs
#   --release         build the Release configuration instead of Debug
#   --clean           clean the build directory first
#   --no-build        install and launch whatever was built last
#   --no-generate     skip xcodegen (use the .xcodeproj as it is on disk)
#   --reset           simulator: erase it before installing — wipes the Keychain
#                     and UserDefaults, so the app comes up at a signed-out first
#                     launch. This is the only way to retest login and key import.
#                     Device: uninstall the app, which takes its Keychain items
#                     and UserDefaults with it — the same signed-out first launch
#   --uninstall       remove the app first, keeping the rest of the device
#   --console         attach to the app's output and stay in the foreground
#   --screenshot[=P]  write a PNG after launch (default: build/screenshot.png).
#                     Simulator only — devicectl cannot capture a device's screen

set -euo pipefail

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SCHEME="NeutrinoDrive"
readonly PROJECT="NeutrinoDrive.xcodeproj"
readonly BUILD_DIR="$PROJECT_ROOT/build"

TARGET="simulator"          # or "device"
DEVICE_NAME="iPhone 17 Pro"
DEVICE_GIVEN=0              # distinguishes an explicit --device from the default
OS_VERSION=""
CONFIGURATION="Debug"
DO_BUILD=1
DO_GENERATE=1
DO_CLEAN=0
DO_RESET=0
DO_UNINSTALL=0
DO_CONSOLE=0
SCREENSHOT_PATH=""

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- arguments ---------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --physical|--real|--device-target) TARGET="device"; shift ;;
    --simulator)    TARGET="simulator"; shift ;;
    --device)       DEVICE_NAME="${2:-}"; [[ -n "$DEVICE_NAME" ]] || die "--device needs a name"; DEVICE_GIVEN=1; shift 2 ;;
    --device=*)     DEVICE_NAME="${1#*=}"; DEVICE_GIVEN=1; shift ;;
    --os)           OS_VERSION="${2:-}"; [[ -n "$OS_VERSION" ]] || die "--os needs a version"; shift 2 ;;
    --os=*)         OS_VERSION="${1#*=}"; shift ;;
    --release)      CONFIGURATION="Release"; shift ;;
    --clean)        DO_CLEAN=1; shift ;;
    --no-build)     DO_BUILD=0; shift ;;
    --no-generate)  DO_GENERATE=0; shift ;;
    --reset)        DO_RESET=1; shift ;;
    --uninstall)    DO_UNINSTALL=1; shift ;;
    --console)      DO_CONSOLE=1; shift ;;
    --screenshot)   SCREENSHOT_PATH="$BUILD_DIR/screenshot.png"; shift ;;
    --screenshot=*) SCREENSHOT_PATH="${1#*=}"; shift ;;
    -h|--help)      sed -n '2,43p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)              die "unknown argument: $1" ;;
  esac
done

cd "$PROJECT_ROOT"

# --console replaces this process with the launch, so anything after it never
# runs. Said out loud rather than silently dropping the screenshot.
if [[ $DO_CONSOLE -eq 1 && -n "$SCREENSHOT_PATH" ]]; then
  die "--console and --screenshot cannot be combined: --console hands the terminal to the app
  and never returns. Run once with --screenshot, then again with --console --no-build."
fi

# Flags a simulator can honour and a device cannot. Refused rather than ignored:
# silently dropping --screenshot would report a PNG that was never written.
if [[ "$TARGET" == "device" ]]; then
  [[ -z "$SCREENSHOT_PATH" ]] || die "--screenshot works on the simulator only: devicectl has no
  screen-capture command. Take it on the device with the side + volume-up buttons."
  [[ -z "$OS_VERSION" ]] || die "--os works on the simulator only: a device runs the OS it runs."
fi

# --- preflight ---------------------------------------------------------------

command -v xcodebuild >/dev/null || die "xcodebuild not found — install Xcode"
command -v xcrun >/dev/null      || die "xcrun not found — install Xcode"
[[ $DO_GENERATE -eq 1 ]] && { command -v xcodegen >/dev/null || die "xcodegen not found — brew install xcodegen"; }

# The bundle id is read rather than hard-coded: project.yml is what actually
# decides it, and a copy here would be one more thing to forget when it changes.
BUNDLE_ID="$(awk -F': ' '/PRODUCT_BUNDLE_IDENTIFIER:/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' project.yml)"
[[ -n "$BUNDLE_ID" ]] || die "could not read PRODUCT_BUNDLE_IDENTIFIER from project.yml"

# --- device ------------------------------------------------------------------

# Resolves a simulator name to a UDID.
#
# `simctl list` groups devices under `-- iOS 26.0 --` runtime headers, so the
# runtime has to be tracked while scanning rather than read off the device line.
# Names are matched *exactly*: a prefix match would resolve "iPhone 17 Pro" to
# "iPhone 17 Pro Max" whenever the plain model happened to be listed second.
find_simulator() {
  local want_name="$1" want_os="$2"
  xcrun simctl list devices available | awk -v want_name="$want_name" -v want_os="$want_os" '
    /^-- / {
      runtime = $0
      gsub(/^-- | --$/, "", runtime)
      next
    }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      # "Name (UDID) (State)" — split off the trailing two parenthesised fields.
      if (match(line, /\([0-9A-Fa-f-]{36}\)/) == 0) next
      udid = substr(line, RSTART + 1, RLENGTH - 2)
      name = substr(line, 1, RSTART - 2)
      sub(/[[:space:]]+$/, "", name)
      if (name != want_name) next
      if (runtime !~ /^iOS/) next
      if (want_os != "" && runtime != "iOS " want_os) next
      print udid
    }
  ' | tail -1
}

# Lists paired iOS devices as UDID<TAB>name<TAB>osVersion<TAB>developerMode.
#
# devicectl's table output is unparseable — device names contain spaces, and the
# columns are padded, not delimited — so the JSON is asked for instead. Apple's
# own note in `devicectl --help` says the JSON file is the only supported
# interface for scripts. plutil reads it without pulling in jq or python.
list_devices() {
  local json udid name platform paired osver devmode i=0
  json="$(mktemp -t neutrino-devices)"
  # A device is queried over the network as well as USB, so this can take a
  # moment; the timeout keeps a sleeping iPhone from hanging the script.
  xcrun devicectl list devices --timeout 15 --quiet --json-output "$json" >/dev/null 2>&1 \
    || { rm -f "$json"; die "xcrun devicectl list devices failed — is Xcode 15 or newer installed?"; }

  while :; do
    udid="$(plutil -extract "result.devices.$i.hardwareProperties.udid" raw -o - "$json" 2>/dev/null)" || break
    platform="$(plutil -extract "result.devices.$i.hardwareProperties.platform" raw -o - "$json" 2>/dev/null || true)"
    name="$(plutil -extract "result.devices.$i.deviceProperties.name" raw -o - "$json" 2>/dev/null || true)"
    paired="$(plutil -extract "result.devices.$i.connectionProperties.pairingState" raw -o - "$json" 2>/dev/null || true)"
    osver="$(plutil -extract "result.devices.$i.deviceProperties.osVersionNumber" raw -o - "$json" 2>/dev/null || true)"
    devmode="$(plutil -extract "result.devices.$i.deviceProperties.developerModeStatus" raw -o - "$json" 2>/dev/null || true)"
    i=$((i + 1))
    [[ "$platform" == "iOS" ]] || continue
    [[ "$paired" == "paired" ]] || continue
    printf '%s\t%s\t%s\t%s\n' "$udid" "$name" "$osver" "$devmode"
  done
  rm -f "$json"
}

if [[ "$TARGET" == "device" ]]; then
  # Asked for once and held: a `die` inside the function has to reach the shell,
  # and a process substitution would swallow it and leave an empty list behind.
  DEVICE_LIST="$(list_devices)"

  # Matching on the UDID too: device names carry a curly apostrophe ("William’s
  # iPhone") that is a nuisance to type correctly at a shell prompt.
  MATCHES=""
  MATCH_COUNT=0
  while IFS=$'\t' read -r d_udid d_name d_os d_devmode; do
    [[ -n "$d_udid" ]] || continue
    if [[ $DEVICE_GIVEN -eq 1 && "$d_name" != "$DEVICE_NAME" && "$d_udid" != "$DEVICE_NAME" ]]; then
      continue
    fi
    MATCHES+="$d_udid"$'\t'"$d_name"$'\t'"$d_os"$'\t'"$d_devmode"$'\n'
    MATCH_COUNT=$((MATCH_COUNT + 1))
  done <<< "$DEVICE_LIST"

  if [[ $MATCH_COUNT -eq 0 ]]; then
    if [[ $DEVICE_GIVEN -eq 1 ]]; then
      warn "no paired iOS device named or identified by \"$DEVICE_NAME\""
    else
      warn "no paired iOS device found"
    fi
    if [[ -n "$DEVICE_LIST" ]]; then
      printf 'Paired iOS devices (UDID / name / iOS / Developer Mode):\n' >&2
      printf '%s\n' "$DEVICE_LIST" >&2
    fi
    die "connect the device by cable, unlock it, and trust this Mac.
  Xcode > Window > Devices and Simulators shows the pairing state.
  Drop --physical to run in the simulator instead."
  fi

  if [[ $MATCH_COUNT -gt 1 ]]; then
    warn "more than one paired iOS device:"
    printf '%s' "$MATCHES" >&2
    die "pick one with --device NAME or --device UDID"
  fi

  IFS=$'\t' read -r UDID DEVICE_NAME DEVICE_OS DEVICE_DEVMODE <<< "$(printf '%s' "$MATCHES" | head -1)"

  # Developer Mode is a per-device toggle since iOS 16; without it the install
  # fails with an opaque error some way into the run.
  if [[ "$DEVICE_DEVMODE" != "enabled" ]]; then
    die "Developer Mode is not enabled on \"$DEVICE_NAME\".
  Turn it on in Settings > Privacy & Security > Developer Mode, then reboot the device.
  (The toggle only appears after the device has been connected to Xcode once.)"
  fi

  log "Device: $DEVICE_NAME — iOS $DEVICE_OS ($UDID)"
  PLATFORM_DIR="iphoneos"
else
  UDID="$(find_simulator "$DEVICE_NAME" "$OS_VERSION")"

  if [[ -z "$UDID" ]]; then
    warn "no available simulator named \"$DEVICE_NAME\"${OS_VERSION:+ on iOS $OS_VERSION}"
    printf 'Available iOS simulators:\n' >&2
    xcrun simctl list devices available | sed -n '/^-- iOS/,/^-- [^i]/p' | grep -E '^\s+\S' >&2 || true
    die "pick one with --device, or create it in Xcode > Window > Devices and Simulators"
  fi

  log "Simulator: $DEVICE_NAME ($UDID)"
  PLATFORM_DIR="iphonesimulator"
fi

# --- generate & build --------------------------------------------------------

if [[ $DO_GENERATE -eq 1 ]]; then
  log "Regenerating $PROJECT from project.yml"
  xcodegen generate
fi

[[ -d "$PROJECT" ]] || die "$PROJECT not found — run without --no-generate, or run xcodegen"

if [[ $DO_CLEAN -eq 1 ]]; then
  log "Cleaning $BUILD_DIR"
  rm -rf "$BUILD_DIR"
fi

if [[ $DO_BUILD -eq 1 ]]; then
  log "Building $SCHEME ($CONFIGURATION) for the $TARGET"
  mkdir -p "$BUILD_DIR"
  # `id=` rather than `name=` so the build targets the same device that is about
  # to run it, even when two runtimes offer the same device name. devicectl and
  # xcodebuild agree on the hardware UDID, so one identifier drives both.
  build_args=(
    build
    -project "$PROJECT"
    -scheme "$SCHEME"
    -configuration "$CONFIGURATION"
    -destination "id=$UDID"
    -derivedDataPath "$BUILD_DIR"
  )
  # A device build has to be signed. -allowProvisioningUpdates lets Xcode
  # register the device and fetch a development profile the first time round;
  # the team comes from DEVELOPMENT_TEAM in project.yml.
  [[ "$TARGET" == "device" ]] && build_args+=(-allowProvisioningUpdates)

  # The full transcript goes to a log and only the interesting lines to the
  # terminal. No `|| true` on the end: it would run in place of the failing
  # pipeline and reset PIPESTATUS to 0, hiding a broken build behind a launch
  # of the previous binary. `set +e` is what keeps grep's empty-match exit from
  # ending the script instead.
  set +e
  xcodebuild "${build_args[@]}" \
    2>&1 | tee "$BUILD_DIR/xcodebuild.log" | grep -E "error:|warning:.*\.swift|BUILD"
  build_status="${PIPESTATUS[0]}"
  set -e
  if [[ "$build_status" -ne 0 ]]; then
    [[ "$TARGET" == "device" ]] && warn "a device build must be code-signed: check that Xcode is signed
  in under Settings > Accounts with access to team DEVELOPMENT_TEAM from project.yml."
    die "build failed — full output in ${BUILD_DIR#$PROJECT_ROOT/}/xcodebuild.log"
  fi
fi

# --- locate the .app ---------------------------------------------------------

APP_PATH="$BUILD_DIR/Build/Products/$CONFIGURATION-$PLATFORM_DIR/$SCHEME.app"
if [[ ! -d "$APP_PATH" ]]; then
  # A custom SYMROOT or a stale layout — search rather than guess. The
  # configuration and platform stay pinned: one derived-data directory holds
  # products for all four combinations, and a loose match happily picks up the
  # unsigned Release-iphoneos app left behind by an archive, which the device
  # then refuses to install ("no code signature found").
  APP_PATH="$(find "$BUILD_DIR" -type d -path "*/$CONFIGURATION-$PLATFORM_DIR/$SCHEME.app" 2>/dev/null | head -1)"
fi
[[ -n "$APP_PATH" && -d "$APP_PATH" ]] || die "$SCHEME.app not found in $CONFIGURATION-$PLATFORM_DIR — build first (drop --no-build)"

log "App: ${APP_PATH#$PROJECT_ROOT/}"

# --- boot --------------------------------------------------------------------

if [[ "$TARGET" == "simulator" ]]; then
  if [[ $DO_RESET -eq 1 ]]; then
    # Erasing takes the Keychain and UserDefaults with it, which is the point:
    # the signed-in session and the imported encryption key both survive a plain
    # reinstall, so this is the only way to see a true first launch.
    log "Erasing the simulator (signs out, and removes the imported encryption key)"
    xcrun simctl shutdown "$UDID" 2>/dev/null || true
    xcrun simctl erase "$UDID"
  fi

  log "Booting"
  xcrun simctl boot "$UDID" 2>/dev/null || true
  # Waits for the device to finish booting rather than sleeping and hoping; an
  # install issued against a half-booted device fails intermittently.
  xcrun simctl bootstatus "$UDID" -b >/dev/null

  open -a Simulator --args -CurrentDeviceUDID "$UDID" 2>/dev/null || warn "could not bring Simulator.app to the front"
elif [[ $DO_RESET -eq 1 ]]; then
  # There is no erase for a real device, and nobody wants one. Deleting the app
  # is the equivalent that matters: since iOS 10.3 it takes the app's Keychain
  # items with it, so login and key import both start over.
  log "Uninstalling $BUNDLE_ID (--reset on a device: signs out, and removes the imported encryption key)"
  DO_UNINSTALL=1
fi

# --- install & launch --------------------------------------------------------

if [[ "$TARGET" == "device" ]]; then
  if [[ $DO_UNINSTALL -eq 1 ]]; then
    log "Uninstalling $BUNDLE_ID"
    xcrun devicectl device uninstall app --device "$UDID" --quiet "$BUNDLE_ID" 2>/dev/null || true
  fi

  log "Installing $BUNDLE_ID"
  xcrun devicectl device install app --device "$UDID" --quiet "$APP_PATH" \
    || die "install failed — unlock the device and keep it unlocked, then try again.
  A first install also needs the developer certificate trusted on the device:
  Settings > General > VPN & Device Management."

  if [[ $DO_CONSOLE -eq 1 ]]; then
    # Unlike simctl, devicectl's console owns the app's lifetime: Ctrl-C is
    # forwarded, so the app exits with the terminal. Said plainly here.
    log "Launching (attached — Ctrl-C stops the app)"
    exec xcrun devicectl device process launch --device "$UDID" --console --terminate-existing "$BUNDLE_ID"
  fi

  log "Launching"
  launch_json="$BUILD_DIR/device-launch.json"
  mkdir -p "$BUILD_DIR"
  xcrun devicectl device process launch --device "$UDID" --terminate-existing \
    --quiet --json-output "$launch_json" "$BUNDLE_ID" \
    || die "launch failed — unlock the device and try again"
  LAUNCH_PID="$(plutil -extract result.process.processIdentifier raw -o - "$launch_json" 2>/dev/null || true)"

  log "Running — $SCHEME ($CONFIGURATION) on $DEVICE_NAME"
  # os_log from a real device is not readable with `log stream` the way it is
  # from a simulator, so the honest answer is --console or Console.app.
  printf '\n  Logs:      scripts/%s --physical --console --no-build\n' "$(basename "${BASH_SOURCE[0]}")"
  printf '             (or Console.app, with %s picked in the sidebar)\n' "$DEVICE_NAME"
  if [[ -n "$LAUNCH_PID" ]]; then
    printf '  Stop:      xcrun devicectl device process terminate --device %s --pid %s\n\n' "$UDID" "$LAUNCH_PID"
  else
    printf '\n'
  fi
  exit 0
fi

if [[ $DO_UNINSTALL -eq 1 ]]; then
  log "Uninstalling $BUNDLE_ID"
  xcrun simctl uninstall "$UDID" "$BUNDLE_ID" 2>/dev/null || true
fi

log "Installing $BUNDLE_ID"
xcrun simctl install "$UDID" "$APP_PATH"

# A running copy would otherwise keep the old binary until it was killed.
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true

if [[ $DO_CONSOLE -eq 1 ]]; then
  log "Launching (attached — Ctrl-C to detach; the app keeps running)"
  # --console-pty forwards stdout/stderr and stays in the foreground. Note this
  # shows print()/NSLog only: the app's own diagnostics go through os.log, which
  # is read with `xcrun simctl spawn $UDID log stream --predicate ...`.
  exec xcrun simctl launch --console-pty "$UDID" "$BUNDLE_ID"
fi

log "Launching"
xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null

if [[ -n "$SCREENSHOT_PATH" ]]; then
  mkdir -p "$(dirname "$SCREENSHOT_PATH")"
  # A moment for the first frame; a screenshot taken the instant after launch
  # catches the launch screen rather than the app.
  sleep 3
  xcrun simctl io "$UDID" screenshot "$SCREENSHOT_PATH" >/dev/null 2>&1
  log "Screenshot: ${SCREENSHOT_PATH#$PROJECT_ROOT/}"
fi

log "Running — $SCHEME ($CONFIGURATION) on $DEVICE_NAME"
printf '\n  Logs:      xcrun simctl spawn %s log stream --predicate '"'"'subsystem == "%s"'"'"'\n' "$UDID" "$BUNDLE_ID"
printf '  Stop:      xcrun simctl terminate %s %s\n\n' "$UDID" "$BUNDLE_ID"
