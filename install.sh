#!/usr/bin/env bash
# install.sh — one-liner installer for kctx-fuzzy bash script
#
# Usage:
#   curl -sSfL https://raw.githubusercontent.com/thegkops/kctx-fuzzy/main/install.sh | bash
#
# What it does:
#   1. Downloads kctx-fuzzy.sh from the latest GitHub release (or main branch)
#   2. Installs it to /usr/local/bin/kctx-fuzzy (uses sudo if needed)
#   3. Creates a kns-fuzzy symlink

set -euo pipefail

REPO="thegkops/kctx-fuzzy"
INSTALL_DIR="${KCTX_INSTALL_DIR:-/usr/local/bin}"
SCRIPT_NAME="kctx-fuzzy"
SYMLINK_NAME="kns-fuzzy"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()  { printf "${CYAN}[kctx-fuzzy]${RESET} %s\n" "$*"; }
ok()    { printf "${GREEN}[kctx-fuzzy]${RESET} %s\n" "$*"; }
error() { printf "${RED}[kctx-fuzzy] ERROR:${RESET} %s\n" "$*" >&2; exit 1; }

# ── Detect download tool ───────────────────────────────────────────────────────
if command -v curl &>/dev/null; then
    download() { curl -sSfL "$1" -o "$2"; }
elif command -v wget &>/dev/null; then
    download() { wget -qO "$2" "$1"; }
else
    error "curl or wget is required to download kctx-fuzzy"
fi

# ── Resolve download URL ───────────────────────────────────────────────────────
# Try latest GitHub release first; fall back to main branch
RELEASE_URL="https://github.com/${REPO}/releases/latest/download/kctx-fuzzy.sh"
FALLBACK_URL="https://raw.githubusercontent.com/${REPO}/main/kctx-fuzzy.sh"

TMPFILE="$(mktemp /tmp/kctx-fuzzy-XXXXXX.sh)"
trap 'rm -f "$TMPFILE"' EXIT

info "Downloading kctx-fuzzy..."
if ! download "$RELEASE_URL" "$TMPFILE" 2>/dev/null; then
    info "Release not found — falling back to main branch"
    download "$FALLBACK_URL" "$TMPFILE" || error "Failed to download kctx-fuzzy.sh"
fi

# Basic sanity check
grep -q "kctx-fuzzy" "$TMPFILE" || error "Downloaded file does not look like kctx-fuzzy.sh"
bash -n "$TMPFILE" || error "Downloaded script has syntax errors"

# ── Install ───────────────────────────────────────────────────────────────────
DEST="${INSTALL_DIR}/${SCRIPT_NAME}"
SYMLINK="${INSTALL_DIR}/${SYMLINK_NAME}"

_install_file() {
    if [[ -w "$INSTALL_DIR" ]]; then
        install -m 755 "$TMPFILE" "$DEST"
        ln -sf "$DEST" "$SYMLINK"
    elif command -v sudo &>/dev/null; then
        info "Requesting sudo to install to ${INSTALL_DIR}..."
        sudo install -m 755 "$TMPFILE" "$DEST"
        sudo ln -sf "$DEST" "$SYMLINK"
    else
        error "Cannot write to ${INSTALL_DIR} and sudo is not available. Try: KCTX_INSTALL_DIR=~/bin $0"
    fi
}

mkdir -p "$INSTALL_DIR" 2>/dev/null || true
_install_file

# ── Verify ────────────────────────────────────────────────────────────────────
if command -v "$SCRIPT_NAME" &>/dev/null; then
    ok "Installed successfully: $(command -v "$SCRIPT_NAME")"
else
    ok "Installed to ${DEST}"
    printf "\n${BOLD}Add ${INSTALL_DIR} to your PATH:${RESET}\n"
    printf '  export PATH="%s:$PATH"\n\n' "$INSTALL_DIR"
fi

printf "\n${BOLD}Quick start:${RESET}\n"
printf "  kctx-fuzzy        # switch kubectl context\n"
printf "  kctx-fuzzy -n     # switch namespace\n"
printf "  kctx-fuzzy -c     # show current context\n"
printf "  kctx-fuzzy -l     # list all contexts\n"
printf "  kns-fuzzy         # switch namespace (alias)\n\n"
