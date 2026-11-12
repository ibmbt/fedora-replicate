#!/usr/bin/env bash
# Restore this machine from the state captured in the repo by update.sh.
#
#   ./setup.sh                 run every step
#   ./setup.sh dconf dotfiles  run only some steps
#   ./setup.sh --list          show the steps
#
# Idempotent: every step checks what's already in place, so it's safe to re-run
# as many times as you like (e.g. after a failure or a partial run).
# Run it from inside your GNOME session (dconf needs it), as your normal user.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$REPO_DIR/lib/extras.sh"

ALL_STEPS="prereqs repos dnf flatpak extras dotfiles extensions dconf editors services system"

case "${1:-}" in
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    --list) echo "$ALL_STEPS"; exit 0 ;;
esac
select_steps "$ALL_STEPS" "$@"
refuse_root
require_fedora

# ---------------------------------------------------------------------------
setup_prereqs() {
    local need=() p
    for p in rsync curl git python3 dconf; do have "$p" || need+=("$p"); done
    rpm -q dnf5-plugins >/dev/null 2>&1 || need+=(dnf5-plugins)
    ((${#need[@]} == 0)) || sudo dnf install -y "${need[@]}"
}

# ---------------------------------------------------------------------------
setup_repos() {
    local f id

    if [[ -f "$STATE_DIR/dnf.conf" ]] && ! cmp -s "$STATE_DIR/dnf.conf" /etc/dnf/dnf.conf; then
        sudo install -m 644 "$STATE_DIR/dnf.conf" /etc/dnf/dnf.conf && echo "    dnf.conf updated"
    fi

    if ! rpm -q rpmfusion-free-release rpmfusion-nonfree-release >/dev/null 2>&1; then
        local v; v="$(rpm -E %fedora)"
        sudo dnf install -y \
            "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$v.noarch.rpm" \
            "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$v.noarch.rpm" || return 1
    fi

    # Third-party repos (VS Code, Docker, Tailscale, COPRs, ...) captured as plain files.
    for f in "$STATE_DIR"/yum.repos.d/*.repo; do
        [[ -e "$f" ]] || continue
        if ! cmp -s "$f" "/etc/yum.repos.d/$(basename "$f")"; then
            sudo install -m 644 "$f" /etc/yum.repos.d/ && echo "    added $(basename "$f")"
        fi
    done

    # Re-enable repos that ship disabled (e.g. google-chrome from fedora-workstation-repositories).
    local disabled
    disabled="$(dnf -q repo list --disabled 2>/dev/null | awk 'NR>1 {print $1}')"
    while read -r id; do
        if grep -qx "$id" <<<"$disabled"; then
            sudo dnf config-manager setopt "$id.enabled=1" && echo "    enabled $id"
        fi
    done < <(read_list "$STATE_DIR/dnf-repos-enabled.txt")

    sudo dnf makecache -y --refresh >/dev/null
}

# ---------------------------------------------------------------------------
setup_dnf() {
    sudo dnf upgrade -y --refresh || return 1

    local missing=() rc=0
    mapfile -t missing < <(comm -23 <(read_list "$STATE_DIR/dnf-packages.txt" | sort -u) \
                                    <(rpm -qa --qf '%{NAME}\n' | sort -u))
    if ((${#missing[@]})); then
        echo "    installing ${#missing[@]} packages"
        # --skip-unavailable: a package that vanished from the repos won't abort the rest.
        sudo dnf install -y --allowerasing --skip-unavailable --skip-broken "${missing[@]}" || rc=1
    else
        echo "    all packages already installed"
    fi

    # Packages you removed on purpose (dnf-remove.txt, maintained by hand).
    local pat installed=()
    while read -r pat; do
        mapfile -t -O "${#installed[@]}" installed < <(rpm -qa --qf '%{NAME}\n' "$pat")
    done < <(read_list "$STATE_DIR/dnf-remove.txt")
    if ((${#installed[@]})); then
        echo "    removing ${#installed[@]} unwanted packages"
        sudo dnf remove -y "${installed[@]}" || rc=1
    fi

    if [[ -n "$(read_list "$STATE_DIR/dnf-local-rpms.txt")" ]]; then
        warn "Install these local RPMs by hand: $(read_list "$STATE_DIR/dnf-local-rpms.txt" | paste -sd' ')"
    fi
    return $rc
}

# ---------------------------------------------------------------------------
setup_flatpak() {
    have flatpak || { err "flatpak missing"; return 1; }
    sudo flatpak remote-add --system --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

    local installed inst remote app rc=0
    installed="$(flatpak list --app --columns=application)"
    while read -r inst remote app; do
        [[ -n "$app" ]] || continue
        grep -qx "$app" <<<"$installed" && continue
        echo "    installing $app"
        if [[ "$inst" == user ]]; then
            flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
            flatpak install --user -y --noninteractive "$remote" "$app" || { warn "failed: $app"; rc=1; }
        else
            sudo flatpak install --system -y --noninteractive "$remote" "$app" || { warn "failed: $app"; rc=1; }
        fi
    done < <(read_list "$STATE_DIR/flatpak-apps.txt")
    return $rc
}

# ---------------------------------------------------------------------------
setup_extras() {
    local e rc=0
    for e in $EXTRAS; do
        "extra_$e" || { warn "extra '$e' failed"; rc=1; }
    done
    return $rc
}

# ---------------------------------------------------------------------------
setup_dotfiles() {
    [[ -d "$CONFIGS_DIR" ]] || return 0
    # --checksum: compare by content so a fresh clone doesn't rewrite identical files.
    # --backup:   any file that differs is kept as <file>.bak-dotfiles before overwriting.
    rsync -a --checksum --backup --suffix=.bak-dotfiles --itemize-changes "$CONFIGS_DIR/" "$HOME/" \
        | grep -v '^\.' | sed 's/^/    /'
    return "${PIPESTATUS[0]}"
}

# ---------------------------------------------------------------------------
setup_extensions() {
    have gnome-extensions || { err "gnome-extensions not found (not a GNOME system?)"; return 1; }
    local ver uuid url tmp rc=0
    ver="$(gnome-shell --version | grep -oE '[0-9]+' | head -1)"
    tmp="$(mktemp -d)"

    while read -r uuid; do
        if [[ -d "$HOME/.local/share/gnome-shell/extensions/$uuid" || -d "/usr/share/gnome-shell/extensions/$uuid" ]]; then
            continue
        fi
        url="$(curl -fsSL --get --data-urlencode "uuid=$uuid" --data "shell_version=$ver" \
                   https://extensions.gnome.org/extension-info/ |
               python3 -c 'import json,sys; print(json.load(sys.stdin).get("download_url",""))' 2>/dev/null)"
        if [[ -z "$url" ]]; then
            warn "$uuid: no version for GNOME $ver on extensions.gnome.org"; rc=1; continue
        fi
        if curl -fsSL "https://extensions.gnome.org$url" -o "$tmp/ext.zip" &&
           gnome-extensions install --force "$tmp/ext.zip"; then
            echo "    installed $uuid"
        else
            warn "$uuid: install failed"; rc=1
        fi
    done < <(read_list "$STATE_DIR/gnome-extensions.txt")

    rm -rf "$tmp"
    return $rc
}

# ---------------------------------------------------------------------------
setup_dconf() {
    local f="$STATE_DIR/dconf.ini"
    [[ -f "$f" ]] || { warn "no dconf.ini captured yet"; return 0; }
    if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
        err "No desktop session bus. Run this step from a terminal inside GNOME."; return 1
    fi
    # 'dconf load' is all-or-nothing: one key locked by system policy (authselect,
    # /etc/dconf/db/*.d/locks) aborts the whole load. Drop locked keys first.
    local locks; locks="$(mktemp)"
    cat /etc/dconf/db/*.d/locks/* 2>/dev/null | grep '^/' |
        sed -e 's|^/||' -e 's|[.]|[.]|g' -e 's|^|^|' -e 's|$|$|' >"$locks"
    # Loading on top of existing settings: keys not in the file are left alone.
    sed "s|@HOME@|$HOME|g" "$f" | filter_dconf "$locks" | dconf load /
    local rc=$?
    rm -f "$locks"
    return $rc
}

# ---------------------------------------------------------------------------
install_editor_exts() {   # <cli> <list-file>
    local cli="$1" list="$2" ext rc=0
    have "$cli" && [[ -f "$list" ]] || return 0
    while read -r ext; do
        if "$cli" --install-extension "$ext" >/dev/null; then
            echo "    $cli: $ext"
        else
            warn "$cli: $ext failed"; rc=1
        fi
    done < <(comm -23 <(read_list "$list" | tr '[:upper:]' '[:lower:]' | sort -u) \
                      <("$cli" --list-extensions 2>/dev/null | tr '[:upper:]' '[:lower:]' | sort -u))
    return $rc
}

setup_editors() {
    local rc=0
    install_editor_exts code "$STATE_DIR/vscode-extensions.txt" || rc=1
    install_editor_exts cursor "$STATE_DIR/cursor-extensions.txt" || rc=1
    return $rc
}

# ---------------------------------------------------------------------------
setup_services() {
    local unit rc=0
    while read -r unit; do
        if ! systemctl list-unit-files --no-legend "$unit" | grep -q .; then
            warn "$unit not installed, skipping"; continue
        fi
        systemctl is-enabled -q "$unit" 2>/dev/null && continue
        sudo systemctl enable --now "$unit" && echo "    enabled $unit" || rc=1
    done < <(read_list "$STATE_DIR/services-system.txt")

    while read -r unit; do
        systemctl --user is-enabled -q "$unit" 2>/dev/null && continue
        systemctl --user enable --now "$unit" && echo "    enabled (user) $unit" || rc=1
    done < <(read_list "$STATE_DIR/services-user.txt")
    return $rc
}

# ---------------------------------------------------------------------------
setup_system() {
    [[ -f "$STATE_DIR/system.conf" ]] || return 0
    # shellcheck disable=SC2034  # FEDORA_VERSION is set by system.conf, read at startup
    local FEDORA_VERSION="" LOGIN_SHELL="" TIMEZONE="" EXTRA_GROUPS="" me g
    # shellcheck source=/dev/null
    source "$STATE_DIR/system.conf"
    me="$(id -un)"

    if [[ -n "$LOGIN_SHELL" && "$(getent passwd "$me" | cut -d: -f7)" != "$LOGIN_SHELL" ]]; then
        if grep -qx "$LOGIN_SHELL" /etc/shells; then
            sudo usermod -s "$LOGIN_SHELL" "$me" && echo "    login shell -> $LOGIN_SHELL"
        else
            warn "shell $LOGIN_SHELL not installed"
        fi
    fi

    if [[ -n "$TIMEZONE" && "$(timedatectl show -p Timezone --value)" != "$TIMEZONE" ]]; then
        sudo timedatectl set-timezone "$TIMEZONE" && echo "    timezone -> $TIMEZONE"
    fi

    for g in $EXTRA_GROUPS; do
        id -nG "$me" | tr ' ' '\n' | grep -qx "$g" && continue
        if getent group "$g" >/dev/null; then
            sudo usermod -aG "$g" "$me" && echo "    added to group $g"
        else
            warn "group $g doesn't exist (its package may be missing)"
        fi
    done
}

# ---------------------------------------------------------------------------
log "Restoring from $REPO_DIR"
snap_ver="$(sed -n 's/^FEDORA_VERSION=//p' "$STATE_DIR/system.conf" 2>/dev/null)"
if [[ -n "$snap_ver" && "$snap_ver" != "$(rpm -E %fedora)" ]]; then
    warn "Snapshot was taken on Fedora $snap_ver, this is Fedora $(rpm -E %fedora)."
    warn "That's fine; packages that were renamed or dropped are skipped and listed."
fi
sudo_keepalive
for step in "${SELECTED_STEPS[@]}"; do
    run_step "$step" "setup_$step"
done

echo
echo "Log out and back in (or reboot) so new GNOME extensions, group membership"
echo "and login shell take effect. Re-run ./setup.sh any time; it only fixes what's missing."
summary
