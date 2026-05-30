#!/usr/bin/env bash
#
# install-firefox.sh — Install/update the WhatsApp Translator extension in Firefox.
#
# Default mode `install` performs a PERMANENT install into your real (default)
# Firefox profile by sideloading the packaged extension. The add-on then loads
# automatically every time you start Firefox, and because it lives in your real
# profile your WhatsApp Web login persists — no re-login on every launch.
#
# Permanent install of an UNSIGNED extension only works on Firefox Developer
# Edition, Nightly, ESR, or Unbranded builds (release/beta enforce Mozilla
# signing and cannot be overridden). The script sets
# xpinstall.signatures.required=false and auto-enables the sideloaded add-on.
#
# Modes:
#   ./install-firefox.sh install    Install/update into your default profile. [default]
#   ./install-firefox.sh uninstall  Remove the extension from your default profile.
#   ./install-firefox.sh run        Launch a throwaway profile with the ext (testing).
#   ./install-firefox.sh build      Build an unsigned .xpi/.zip into ./dist.
#   ./install-firefox.sh sign       Build a Mozilla-SIGNED .xpi (needs AMO creds).
#   ./install-firefox.sh lint       Validate the extension with web-ext.
#
# Options (install / uninstall):
#   -y, --yes           Don't prompt; close Firefox automatically if it is running.
#   --no-launch         Don't relaunch Firefox after installing.
#   --profile <path>    Use this profile directory instead of auto-detecting.
#
# Env overrides:
#   FIREFOX_BIN         Path to the firefox binary to launch.
#   WEB_EXT_API_KEY / WEB_EXT_API_SECRET   AMO credentials for `sign`.
#
# Requirements: Node.js + npm (web-ext via npx); a Firefox Dev/ESR/Nightly build.
set -euo pipefail

ADDON_ID="whatsapp-translator@transapp"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ---- argument parsing ----
MODE=""
ASSUME_YES=0
NO_LAUNCH=0
PROFILE_OVERRIDE=""
args=("$@")
i=0
while [ $i -lt ${#args[@]} ]; do
  a="${args[$i]}"
  case "$a" in
    -y|--yes)      ASSUME_YES=1 ;;
    --no-launch)   NO_LAUNCH=1 ;;
    --profile)     i=$((i+1)); PROFILE_OVERRIDE="${args[$i]:-}" ;;
    -h|--help)     MODE="help" ;;
    install|uninstall|run|build|xpi|zip|sign|lint|help)
                   [ -z "$MODE" ] && MODE="$a" ;;
    *)             echo "warning: ignoring unknown argument '$a'" >&2 ;;
  esac
  i=$((i+1))
done
[ -z "$MODE" ] && MODE="install"

# ---- output helpers ----
if [ -t 1 ]; then
  BOLD="$(printf '\033[1m')"; GREEN="$(printf '\033[32m')"
  YELLOW="$(printf '\033[33m')"; RED="$(printf '\033[31m')"; RESET="$(printf '\033[0m')"
else
  BOLD=""; GREEN=""; YELLOW=""; RED=""; RESET=""
fi
info() { echo "${GREEN}==>${RESET} ${BOLD}$*${RESET}"; }
warn() { echo "${YELLOW}!!${RESET} $*" >&2; }
die()  { echo "${RED}error:${RESET} $*" >&2; exit 1; }

WEB_EXT=(npx --yes web-ext@latest)
XPI_PATH=""

need_node() {
  command -v node >/dev/null 2>&1 || die "Node.js is required (https://nodejs.org). Not found on PATH."
  command -v npx  >/dev/null 2>&1 || die "npm/npx is required. Not found on PATH."
}

# ---- Firefox discovery ----
find_firefox() {
  if [ -n "${FIREFOX_BIN:-}" ] && { command -v "$FIREFOX_BIN" >/dev/null 2>&1 || [ -x "$FIREFOX_BIN" ]; }; then
    echo "$FIREFOX_BIN"; return 0
  fi
  for c in firefox-developer-edition firefox-nightly firefox-esr firefox \
           "/Applications/Firefox Developer Edition.app/Contents/MacOS/firefox" \
           "/Applications/Firefox Nightly.app/Contents/MacOS/firefox" \
           "/Applications/Firefox.app/Contents/MacOS/firefox"; do
    if command -v "$c" >/dev/null 2>&1 || [ -x "$c" ]; then echo "$c"; return 0; fi
  done
  return 1
}

# ---- profile discovery ----
detect_profiles_ini() {
  for p in "$HOME/.mozilla/firefox/profiles.ini" \
           "$HOME/Library/Application Support/Firefox/profiles.ini"; do
    [ -f "$p" ] && { echo "$p"; return 0; }
  done
  return 1
}

# Resolve the default profile directory. Prefers a channel that allows unsigned
# add-ons (dev-edition/esr/nightly/unbranded) when several profiles exist.
resolve_profile() {
  if [ -n "$PROFILE_OVERRIDE" ]; then
    [ -d "$PROFILE_OVERRIDE" ] || die "Profile dir not found: $PROFILE_OVERRIDE"
    echo "$PROFILE_OVERRIDE"; return 0
  fi
  local ini inidir
  ini="$(detect_profiles_ini)" || die "Could not find profiles.ini — start Firefox once first."
  inidir="$(dirname "$ini")"

  # [Install*] Default= entries (per-install default, the authoritative modern one)
  local installs profdefaults
  installs="$(awk 'BEGIN{RS="";FS="\n"} /\[Install/{for(i=1;i<=NF;i++){if($i ~ /^Default=/){d=$i;sub(/^Default=/,"",d);print d}}}' "$ini")"
  # [Profile*] sections flagged Default=1 (legacy fallback)
  profdefaults="$(awk 'BEGIN{RS="";FS="\n"} /\[Profile/{path="";def=0;for(i=1;i<=NF;i++){if($i ~ /^Path=/){p=$i;sub(/^Path=/,"",p);path=p}if($i ~ /^Default=1/){def=1}}if(def&&path)print path}' "$ini")"

  local candidates=()
  while IFS= read -r l; do [ -n "$l" ] && candidates+=("$l"); done <<< "$installs"
  while IFS= read -r l; do [ -n "$l" ] && candidates+=("$l"); done <<< "$profdefaults"
  [ ${#candidates[@]} -gt 0 ] || die "No default profile found in $ini"

  local chosen=""
  for c in "${candidates[@]}"; do
    if echo "$c" | grep -Eqi 'dev-edition|esr|nightly|unbranded'; then chosen="$c"; break; fi
  done
  [ -z "$chosen" ] && chosen="${candidates[0]}"

  case "$chosen" in
    /*) echo "$chosen" ;;
    *)  echo "$inidir/$chosen" ;;
  esac
}

# ---- running-instance handling ----
firefox_running() { pgrep -i firefox >/dev/null 2>&1; }

confirm_close() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  printf "%s" "${YELLOW}Firefox is running and must be closed to install. Close it now? [Y/n] ${RESET}"
  local ans=""
  read -r ans </dev/tty 2>/dev/null || ans="y"
  case "$ans" in n|N|no|No) return 1 ;; *) return 0 ;; esac
}

close_firefox() {
  info "Closing Firefox…"
  pkill -TERM -i firefox 2>/dev/null || true
  local n=0
  while [ $n -lt 30 ]; do
    firefox_running || return 0
    sleep 0.5; n=$((n+1))
  done
  warn "Firefox did not exit gracefully; sending SIGKILL."
  pkill -KILL -i firefox 2>/dev/null || true
  sleep 1
}

wait_profile_unlocked() {
  local prof="$1" n=0
  while [ $n -lt 20 ]; do
    [ -e "$prof/.parentlock" ] || [ -L "$prof/lock" ] || return 0
    sleep 0.5; n=$((n+1))
  done
  return 0
}

# ---- managed user.js block ----
USERJS_BEGIN="// >>> WhatsApp Translator (managed) - do not edit this block >>>"
USERJS_END="// <<< WhatsApp Translator (managed) <<<"

strip_user_js() {
  local userjs="$1"
  [ -f "$userjs" ] || return 0
  awk -v b="$USERJS_BEGIN" -v e="$USERJS_END" '
    $0==b{skip=1} skip==0{print} $0==e{skip=0}
  ' "$userjs" > "$userjs.tmp" && mv "$userjs.tmp" "$userjs"
}

write_user_js() {
  local prof="$1" userjs="$prof/user.js"
  strip_user_js "$userjs"
  {
    echo "$USERJS_BEGIN"
    echo 'user_pref("xpinstall.signatures.required", false);'
    echo 'user_pref("extensions.autoDisableScopes", 0);'
    echo 'user_pref("extensions.startupScanScopes", 1);'
    echo "$USERJS_END"
  } >> "$userjs"
}

# ---- build ----
build_xpi() {
  need_node
  info "Building extension package…"
  rm -rf "$SCRIPT_DIR/dist"
  "${WEB_EXT[@]}" build --source-dir="$SCRIPT_DIR" --artifacts-dir="$SCRIPT_DIR/dist" --overwrite-dest >/dev/null
  XPI_PATH="$(ls "$SCRIPT_DIR"/dist/*.zip 2>/dev/null | head -1 || true)"
  [ -n "$XPI_PATH" ] || die "Build failed: no package produced in ./dist"
}

relaunch_firefox() {
  local prof="$1" ff
  ff="$(find_firefox || true)"
  [ -n "$ff" ] || { warn "Firefox binary not found; start Firefox yourself."; return 0; }
  info "Launching Firefox on WhatsApp Web…"
  nohup "$ff" --profile "$prof" "https://web.whatsapp.com/" >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

# ---- modes ----
case "$MODE" in
  install)
    PROFILE="$(resolve_profile)"
    [ -d "$PROFILE" ] || die "Resolved profile does not exist: $PROFILE"
    info "Target Firefox profile: $PROFILE"
    echo "  (override with: ./install-firefox.sh install --profile /path/to/profile)"
    echo

    build_xpi

    if firefox_running; then
      confirm_close || die "Firefox must be closed to install. Re-run with -y to auto-close."
      close_firefox
    fi
    wait_profile_unlocked "$PROFILE"

    write_user_js "$PROFILE"
    mkdir -p "$PROFILE/extensions"
    cp -f "$XPI_PATH" "$PROFILE/extensions/$ADDON_ID.xpi"

    echo
    info "Installed/updated into your profile."
    echo "  • ${BOLD}$ADDON_ID.xpi${RESET} sideloaded into the profile's extensions/ folder."
    echo "  • user.js: signature enforcement off + sideloaded add-on auto-enabled."
    echo "  • Re-run this command any time to update after code changes."
    echo
    warn "Unsigned add-ons only load on Firefox Developer Edition / Nightly / ESR /"
    warn "Unbranded. On release/beta Firefox this will NOT load — use './install-firefox.sh sign'."
    echo

    if [ "$NO_LAUNCH" -eq 0 ]; then
      relaunch_firefox "$PROFILE"
      echo "  • Firefox is starting. Open the toolbar puzzle icon → WhatsApp Translator,"
      echo "    enter your Anthropic API key, pick the language, toggle Translation ON."
    else
      echo "  • Start Firefox to load the extension (relaunch skipped: --no-launch)."
    fi
    ;;

  uninstall)
    PROFILE="$(resolve_profile)"
    info "Target Firefox profile: $PROFILE"
    if firefox_running; then
      confirm_close || die "Firefox must be closed to uninstall. Re-run with -y to auto-close."
      close_firefox
    fi
    wait_profile_unlocked "$PROFILE"
    rm -f "$PROFILE/extensions/$ADDON_ID.xpi"
    strip_user_js "$PROFILE/user.js"
    info "Removed $ADDON_ID and cleared managed prefs from $PROFILE."
    echo "  (The prefs were only in the managed user.js block; your other settings are untouched.)"
    ;;

  run)
    need_node
    info "Launching a throwaway Firefox profile with the extension (testing)…"
    FF="$(find_firefox || true)"
    EXTRA=()
    if [ -n "${FF:-}" ]; then EXTRA=(--firefox "$FF"); info "Using Firefox at: $FF"; else
      warn "Could not auto-detect Firefox; web-ext will try its own default."; fi
    echo "  • A fresh profile opens (you'll need to log into WhatsApp here)."
    echo "  • For a persistent install into your real profile, use: ./install-firefox.sh install"
    echo
    exec "${WEB_EXT[@]}" run --source-dir="$SCRIPT_DIR" \
      --start-url="https://web.whatsapp.com/" "${EXTRA[@]}"
    ;;

  build|xpi|zip)
    build_xpi
    info "Done. Artifact: $XPI_PATH"
    echo
    echo "${BOLD}To install it permanently in your main profile:${RESET} ./install-firefox.sh install"
    echo "To load temporarily: about:debugging#/runtime/this-firefox → 'Load Temporary Add-on…'"
    ;;

  sign)
    need_node
    [ -n "${WEB_EXT_API_KEY:-}" ]    || die "WEB_EXT_API_KEY is not set (AMO JWT issuer)."
    [ -n "${WEB_EXT_API_SECRET:-}" ] || die "WEB_EXT_API_SECRET is not set (AMO JWT secret)."
    info "Submitting to Mozilla (AMO) for signing — unlisted channel …"
    "${WEB_EXT[@]}" sign --source-dir="$SCRIPT_DIR" --artifacts-dir="$SCRIPT_DIR/dist" \
      --channel=unlisted --api-key="$WEB_EXT_API_KEY" --api-secret="$WEB_EXT_API_SECRET"
    info "Signed .xpi written to ./dist/. Open it in Firefox to install permanently (works on release too)."
    ;;

  lint)
    need_node
    info "Linting the extension with web-ext …"
    exec "${WEB_EXT[@]}" lint --source-dir="$SCRIPT_DIR"
    ;;

  help)
    sed -n '2,46p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    ;;

  *)
    die "Unknown mode '$MODE'. Use: install | uninstall | run | build | sign | lint | help"
    ;;
esac
