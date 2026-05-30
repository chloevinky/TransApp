#!/usr/bin/env bash
#
# install-firefox.sh — Build and install the WhatsApp Translator extension on Firefox.
#
# Firefox cannot permanently install an unsigned Manifest V3 extension on the
# standard release channel — it must either be signed by Mozilla (AMO) or loaded
# temporarily. This script supports every practical path:
#
#   ./install-firefox.sh run      Launch Firefox with the extension loaded
#                                 (temporary, great for testing). [default]
#   ./install-firefox.sh build    Build an unsigned .xpi/.zip into ./dist
#   ./install-firefox.sh sign     Build a Mozilla-SIGNED .xpi you can install
#                                 permanently (needs AMO API credentials).
#   ./install-firefox.sh lint     Validate the extension with web-ext.
#
# Requirements: Node.js + npm (web-ext is fetched on demand via npx).
#               Firefox installed for the `run` mode.
#
# AMO credentials for `sign` (get them at
# https://addons.mozilla.org/developers/addon/api/key/):
#   export WEB_EXT_API_KEY="user:xxxxx:123"
#   export WEB_EXT_API_SECRET="xxxxxxxx"
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

MODE="${1:-run}"

# Color helpers (no-op if not a tty)
if [ -t 1 ]; then
  BOLD="$(printf '\033[1m')"; GREEN="$(printf '\033[32m')"
  YELLOW="$(printf '\033[33m')"; RED="$(printf '\033[31m')"; RESET="$(printf '\033[0m')"
else
  BOLD=""; GREEN=""; YELLOW=""; RED=""; RESET=""
fi
info()  { echo "${GREEN}==>${RESET} ${BOLD}$*${RESET}"; }
warn()  { echo "${YELLOW}!!${RESET} $*" >&2; }
die()   { echo "${RED}error:${RESET} $*" >&2; exit 1; }

command -v node >/dev/null 2>&1 || die "Node.js is required (https://nodejs.org). Not found on PATH."
command -v npx  >/dev/null 2>&1 || die "npm/npx is required. Not found on PATH."

# web-ext is run through npx so users don't need a global install.
WEB_EXT=(npx --yes web-ext@latest)

find_firefox() {
  for c in firefox firefox-developer-edition firefox-nightly firefox-esr \
           "/Applications/Firefox.app/Contents/MacOS/firefox" \
           "/Applications/Firefox Developer Edition.app/Contents/MacOS/firefox" \
           "/Applications/Firefox Nightly.app/Contents/MacOS/firefox"; do
    if command -v "$c" >/dev/null 2>&1 || [ -x "$c" ]; then
      echo "$c"; return 0
    fi
  done
  return 1
}

case "$MODE" in
  run)
    info "Launching Firefox with the WhatsApp Translator extension loaded (temporary install)…"
    FF="$(find_firefox || true)"
    EXTRA=()
    if [ -n "${FF:-}" ]; then
      EXTRA=(--firefox "$FF")
      info "Using Firefox at: $FF"
    else
      warn "Could not auto-detect Firefox; web-ext will try its own default."
    fi
    echo
    echo "  • A fresh Firefox profile opens with the extension installed."
    echo "  • Click the toolbar puzzle icon → WhatsApp Translator → enter your"
    echo "    Anthropic API key, pick the source language, and toggle Translation ON."
    echo "  • The extension stays installed until you close this Firefox window."
    echo
    exec "${WEB_EXT[@]}" run \
      --source-dir="$SCRIPT_DIR" \
      --start-url="https://web.whatsapp.com/" \
      "${EXTRA[@]}"
    ;;

  build|xpi|zip)
    info "Building unsigned package into ./dist …"
    "${WEB_EXT[@]}" build --source-dir="$SCRIPT_DIR" --artifacts-dir="$SCRIPT_DIR/dist" --overwrite-dest
    echo
    info "Done. Artifact is in ./dist/"
    echo
    echo "${BOLD}To install the unsigned build in Firefox:${RESET}"
    echo "  1. Open  about:debugging#/runtime/this-firefox"
    echo "  2. Click 'Load Temporary Add-on…' and pick the .zip in ./dist"
    echo "     (Temporary load works on ALL Firefox builds; it is removed on restart.)"
    echo
    echo "  For a PERMANENT unsigned install you need Firefox"
    echo "  Developer Edition / Nightly / ESR, then in about:config set:"
    echo "     xpinstall.signatures.required = false"
    echo "  and open the .zip via about:addons → gear → 'Install Add-on From File…'."
    echo
    echo "  For a permanent install on release Firefox, run: ./install-firefox.sh sign"
    ;;

  sign)
    [ -n "${WEB_EXT_API_KEY:-}" ]    || die "WEB_EXT_API_KEY is not set (AMO JWT issuer). See header of this script."
    [ -n "${WEB_EXT_API_SECRET:-}" ] || die "WEB_EXT_API_SECRET is not set (AMO JWT secret). See header of this script."
    info "Submitting to Mozilla (AMO) for signing — unlisted channel …"
    "${WEB_EXT[@]}" sign \
      --source-dir="$SCRIPT_DIR" \
      --artifacts-dir="$SCRIPT_DIR/dist" \
      --channel=unlisted \
      --api-key="$WEB_EXT_API_KEY" \
      --api-secret="$WEB_EXT_API_SECRET"
    echo
    info "Signed .xpi written to ./dist/"
    echo "Install it permanently: open the .xpi in Firefox, or drag it onto a Firefox window."
    ;;

  lint)
    info "Linting the extension with web-ext …"
    exec "${WEB_EXT[@]}" lint --source-dir="$SCRIPT_DIR"
    ;;

  -h|--help|help)
    sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    ;;

  *)
    die "Unknown mode '$MODE'. Use: run | build | sign | lint | help"
    ;;
esac
