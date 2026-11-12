#!/usr/bin/env bash
# Capture the CURRENT machine's state into this repo.
#
#   ./update.sh               capture everything
#   ./update.sh dconf dnf     capture only some steps
#   ./update.sh --push        capture everything, then git commit + push
#
# Run this before wiping/selling a machine, then run ./setup.sh on the new one.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

ALL_STEPS="repos dnf flatpak extensions dconf dotfiles editors services system"

PUSH=0
args=()
for a in "$@"; do
    case "$a" in
        --push) PUSH=1 ;;
        -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
        *) args+=("$a") ;;
    esac
done
select_steps "$ALL_STEPS" "${args[@]+"${args[@]}"}"
refuse_root
require_fedora
mkdir -p "$STATE_DIR"

# ---------------------------------------------------------------------------
# DNF repositories: third-party .repo files + which repos are enabled
# ---------------------------------------------------------------------------
capture_repos() {
    local dir="$STATE_DIR/yum.repos.d" f
    rm -rf "$dir" && mkdir -p "$dir"
    for f in /etc/yum.repos.d/*.repo; do
        # Repo files owned by a package (fedora-repos, rpmfusion-*-release,
        # fedora-workstation-repositories) come back with that package.
        if ! rpm -qf "$f" >/dev/null 2>&1; then
            cp "$f" "$dir/"
        fi
    done
    dnf -q repo list --enabled 2>/dev/null | awk 'NR>1 && $1!="repo" {print $1}' | sort -u \
        >"$STATE_DIR/dnf-repos-enabled.txt"
    cp /etc/dnf/dnf.conf "$STATE_DIR/dnf.conf"
    echo "    $(find "$dir" -name "*.repo" | wc -l) third-party repo files, $(wc -l <"$STATE_DIR/dnf-repos-enabled.txt") enabled repos"
}

# ---------------------------------------------------------------------------
# DNF packages you explicitly installed (not dependencies)
# ---------------------------------------------------------------------------
# Live-ISO/installer leftovers and the running kernel never get restored.
DNF_EXCLUDE='^(kernel|kernel-core|kernel-modules.*|kernel-uki.*|anaconda.*|livesys-scripts|gnome-initial-setup|initial-setup.*|gpg-pubkey|dracut-live|.*-debuginfo|.*-debugsource)$'

capture_dnf() {
    local raw
    raw="$(dnf -q repoquery --userinstalled --qf '%{name} %{from_repo}\n' 2>/dev/null)" || return 1
    [[ -n "$raw" ]] || { err "dnf returned no packages"; return 1; }

    awk '$2!="@commandline" {print $1}' <<<"$raw" | grep -Ev "$DNF_EXCLUDE" | sort -u \
        >"$STATE_DIR/dnf-packages.txt"

    # Packages installed from a local .rpm can't be re-downloaded; list them as a reminder.
    {
        echo "# Installed from local .rpm files - NOT restored automatically."
        echo "# Re-download and 'sudo dnf install ./file.rpm' these by hand."
        awk '$2=="@commandline" {print $1}' <<<"$raw" | grep -Ev '^rpmfusion-(free|nonfree)-release$' | sort -u
    } >"$STATE_DIR/dnf-local-rpms.txt"

    echo "    $(wc -l <"$STATE_DIR/dnf-packages.txt") packages"
}

# ---------------------------------------------------------------------------
# Flatpak apps (+ per-app permission overrides are synced via dotfiles.txt)
# ---------------------------------------------------------------------------
capture_flatpak() {
    have flatpak || { warn "flatpak not installed"; return 0; }
    {
        echo "# installation  remote  app-id"
        flatpak list --app --columns=installation,origin,application | sort -u
    } >"$STATE_DIR/flatpak-apps.txt"
    echo "    $(grep -vc '^#' "$STATE_DIR/flatpak-apps.txt") apps"
}

# ---------------------------------------------------------------------------
# GNOME extensions installed in your home (system ones come from dnf)
# ---------------------------------------------------------------------------
capture_extensions() {
    local dir="$HOME/.local/share/gnome-shell/extensions"
    {
        echo "# User-installed GNOME Shell extensions (downloaded from extensions.gnome.org)."
        echo "# Enabled/disabled state and extension settings live in dconf.ini."
        [[ -d "$dir" ]] && find "$dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort
    } >"$STATE_DIR/gnome-extensions.txt"
    echo "    $(grep -vc '^#' "$STATE_DIR/gnome-extensions.txt") extensions"
}

# ---------------------------------------------------------------------------
# dconf: full dump of every GNOME/app setting, minus machine-specific noise
# ---------------------------------------------------------------------------
capture_dconf() {
    local out="$STATE_DIR/dconf.ini" bgdir="$CONFIGS_DIR/.local/share/backgrounds"
    dconf dump / | filter_dconf "$DCONF_IGNORE" | sed "s|$HOME|@HOME@|g" >"$out.tmp" || return 1
    [[ -s "$out.tmp" ]] || { err "dconf dump was empty"; rm -f "$out.tmp"; return 1; }

    # Make sure the wallpaper/lock-screen image travels with the repo.
    local uri path name
    while read -r uri; do
        path="${uri#file://}"; path="${path/@HOME@/$HOME}"
        [[ -f "$path" ]] || continue
        name="$(basename "$path")"
        mkdir -p "$bgdir"
        cmp -s "$path" "$bgdir/$name" || cp "$path" "$bgdir/$name"
        sed -i "s|$uri|file://@HOME@/.local/share/backgrounds/$name|g" "$out.tmp"
    done < <(grep -oE "^picture-uri(-dark)?='file://[^']+'" "$out.tmp" | sed -E "s/^[^']*'//; s/'$//" | sort -u)

    mv "$out.tmp" "$out"
    echo "    $(grep -c '^\[' "$out") dconf sections"
}

# ---------------------------------------------------------------------------
# Dotfiles listed in dotfiles.txt  ->  configs/
# ---------------------------------------------------------------------------
RSYNC_EXCLUDES=(--exclude=.git --exclude=mimeinfo.cache --exclude='*.log' --exclude='*.bak-dotfiles')

capture_dotfiles() {
    local entry src dst n=0
    while read -r entry; do
        src="$HOME/$entry"; dst="$CONFIGS_DIR/$entry"
        if [[ -d "$src" ]]; then
            mkdir -p "$dst"
            rsync -a --delete "${RSYNC_EXCLUDES[@]}" "$src/" "$dst/"
        elif [[ -f "$src" ]]; then
            mkdir -p "$(dirname "$dst")"
            rsync -a "$src" "$dst"
        else
            warn "$HOME/$entry does not exist here; keeping the copy already in the repo"
            continue
        fi
        n=$((n + 1))
    done < <(read_list "$MANIFEST")
    echo "    $n paths synced"
}

# ---------------------------------------------------------------------------
# Editor extensions (VS Code, Cursor)
# ---------------------------------------------------------------------------
capture_editors() {
    if have code; then
        code --list-extensions 2>/dev/null | sort >"$STATE_DIR/vscode-extensions.txt"
        echo "    VS Code: $(wc -l <"$STATE_DIR/vscode-extensions.txt") extensions"
    fi
    if have cursor; then
        cursor --list-extensions 2>/dev/null | sort >"$STATE_DIR/cursor-extensions.txt"
        echo "    Cursor: $(wc -l <"$STATE_DIR/cursor-extensions.txt") extensions"
    fi
}

# ---------------------------------------------------------------------------
# Services you enabled yourself (enabled, but the distro preset says disabled)
# ---------------------------------------------------------------------------
capture_services() {
    systemctl list-unit-files --type=service,socket,timer --state=enabled --no-legend 2>/dev/null \
        | awk '$3=="disabled" {print $1}' | grep -v '^systemd-' | sort -u >"$STATE_DIR/services-system.txt"
    systemctl --user list-unit-files --type=service,socket,timer --state=enabled --no-legend 2>/dev/null \
        | awk '$3=="disabled" {print $1}' | grep -v '^systemd-' | sort -u >"$STATE_DIR/services-user.txt"
    echo "    system: $(paste -sd' ' "$STATE_DIR/services-system.txt")"
    echo "    user:   $(paste -sd' ' "$STATE_DIR/services-user.txt")"
}

# ---------------------------------------------------------------------------
# Login shell, timezone, extra groups
# ---------------------------------------------------------------------------
capture_system() {
    local groups
    groups="$(id -nG | tr ' ' '\n' | grep -vx "$(id -un)" | paste -sd' ')"
    cat >"$STATE_DIR/system.conf" <<EOF
FEDORA_VERSION=$(rpm -E %fedora)
LOGIN_SHELL=$(getent passwd "$(id -un)" | cut -d: -f7)
TIMEZONE=$(timedatectl show -p Timezone --value 2>/dev/null)
EXTRA_GROUPS="$groups"
EOF
    sed 's/^/    /' "$STATE_DIR/system.conf"
}

for step in "${SELECTED_STEPS[@]}"; do
    run_step "capture $step" "capture_$step"
done

echo
log "Changes in the repo:"
git -C "$REPO_DIR" status --short

# Refuse to push personal data to a repo GitHub reports as public.
remote_is_public() {
    have gh || return 1
    local url; url="$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null)" || return 1
    [[ "$url" == *github.com* ]] || return 1
    # Pass the URL explicitly: without it gh prefers a remote named "upstream".
    [[ "$(gh repo view "$url" --json visibility --jq .visibility 2>/dev/null)" == PUBLIC ]]
}

if ((PUSH)) && remote_is_public; then
    err "origin is a PUBLIC GitHub repo. Your captured settings contain personal data."
    err "Make it private (gh repo edit --visibility private) and re-run, or push manually."
    PUSH=0
    FAILED_STEPS+=("push")
fi

if ((PUSH)); then
    if [[ -n "$(git -C "$REPO_DIR" status --porcelain)" ]]; then
        # Push to origin explicitly (never to upstream) and set it as the tracking branch.
        if git -C "$REPO_DIR" add -A &&
           git -C "$REPO_DIR" commit -q -m "sync: $(hostname) $(date +%F)" &&
           git -C "$REPO_DIR" push -q -u origin HEAD; then
            ok "Committed and pushed to origin."
        else
            err "Commit or push failed. Is 'origin' set to your private repo? (git remote -v)"
            FAILED_STEPS+=("push")
        fi
    else
        ok "Nothing changed, nothing to push."
    fi
else
    echo "Review with 'git diff', then commit and push (or re-run with --push)."
fi

summary
