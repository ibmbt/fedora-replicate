# shellcheck shell=bash
# Shared helpers for setup.sh and update.sh. Source this file, don't run it.

# Paths used by the scripts that source this file.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC2034
{
    STATE_DIR="$REPO_DIR/state"
    CONFIGS_DIR="$REPO_DIR/configs"
    MANIFEST="$REPO_DIR/dotfiles.txt"
    DCONF_IGNORE="$REPO_DIR/dconf-ignore.txt"
}

if [[ -t 1 ]]; then
    C_BLUE=$'\e[1;34m' C_GREEN=$'\e[1;32m' C_YELLOW=$'\e[1;33m' C_RED=$'\e[1;31m' C_RESET=$'\e[0m'
else
    C_BLUE='' C_GREEN='' C_YELLOW='' C_RED='' C_RESET=''
fi

log()  { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf '%s  ✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s  !%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s  ✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }

# Print non-empty, non-comment lines of a list file (silently nothing if missing).
read_list() {
    [[ -f "$1" ]] || return 0
    sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^[[:space:]]*$/d' "$1"
}

# This tool targets Fedora Workstation (dnf5) with GNOME. Stop early and clearly
# anywhere else instead of failing halfway through.
MIN_FEDORA=41
require_fedora() {
    local id ver
    read -r id ver < <( . /etc/os-release 2>/dev/null; echo "${ID:-unknown} ${VERSION_ID:-0}" )
    if [[ "$id" != fedora ]]; then
        err "Only Fedora is supported (this system is '$id')."
        exit 1
    fi
    if [[ -e /run/ostree-booted ]]; then
        err "Atomic Fedora (Silverblue, Kinoite, Bazzite, ...) isn't supported: it uses rpm-ostree, not dnf."
        exit 1
    fi
    if [[ "$ver" =~ ^[0-9]+$ ]] && ((ver < MIN_FEDORA)); then
        err "Fedora $MIN_FEDORA or newer is required (this is Fedora $ver)."
        exit 1
    fi
    if ! have gnome-shell; then
        warn "GNOME Shell not found. The extensions and dconf steps are built for Fedora Workstation (GNOME)."
    fi
}

refuse_root() {
    if [[ $EUID -eq 0 ]]; then
        err "Run this as your normal user, not root/sudo. It will ask for sudo when needed."
        exit 1
    fi
}

# Ask for sudo once and keep the ticket alive until the script exits.
sudo_keepalive() {
    sudo -v || exit 1
    ( while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) 2>/dev/null &
    SUDO_KEEPALIVE_PID=$!
    trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null' EXIT
}

# Step runner: runs every requested step, records failures, keeps going.
FAILED_STEPS=()
run_step() {
    local name="$1"; shift
    log "$name"
    if "$@"; then
        ok "$name done"
    else
        err "$name failed (continuing)"
        FAILED_STEPS+=("$name")
    fi
}

summary() {
    echo
    if ((${#FAILED_STEPS[@]})); then
        err "Finished with failures in: ${FAILED_STEPS[*]}"
        err "Fix the cause and re-run; every step is safe to repeat."
        return 1
    fi
    ok "All steps completed."
}

# Pick steps: no args -> all steps, otherwise only the named ones.
# Usage: select_steps "all steps..." "$@"  -> fills SELECTED_STEPS
select_steps() {
    local all="$1"; shift
    SELECTED_STEPS=()
    if (($# == 0)); then
        read -ra SELECTED_STEPS <<<"$all"
        return
    fi
    local s
    for s in "$@"; do
        if [[ " $all " == *" $s "* ]]; then
            SELECTED_STEPS+=("$s")
        else
            err "Unknown step '$s'. Valid steps: $all"
            exit 1
        fi
    done
}

# Patterns in dconf-ignore.txt are matched against "section/" for sections and
# "section/key" for keys. Sections left empty after filtering are dropped.
filter_dconf() {   # <ignore-file>  (reads a dconf dump on stdin)
    awk -v ignfile="$1" '
        BEGIN {
            while ((getline l < ignfile) > 0) {
                sub(/[[:space:]]*#.*/, "", l)
                if (l != "") pats[n++] = l
            }
        }
        function ignored(s,   i) { for (i = 0; i < n; i++) if (s ~ pats[i]) return 1; return 0 }
        /^\[.*\]$/ {
            sec = substr($0, 2, length($0) - 2)
            skip = ignored(sec "/"); printed = 0; next
        }
        /^$/ || skip { next }
        {
            key = $0; sub(/=.*/, "", key)
            if (ignored(sec "/" key)) next
            if (!printed) { if (any) print ""; print "[" sec "]"; printed = 1; any = 1 }
            print
        }'
}
