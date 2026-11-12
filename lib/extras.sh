# shellcheck shell=bash
# Software that doesn't come from DNF or Flatpak (curl installers, tarballs, ...).
# Sourced by setup.sh, which runs every extra_<name> listed in EXTRAS.
#
# Rules for an extra:
#   - Return 0 straight away if the tool is already installed (keeps re-runs safe).
#   - Return non-zero on failure; setup.sh reports it and carries on.
#
# The functions below are examples. Enable one by adding its name to EXTRAS,
# e.g. EXTRAS="starship jetbrains_toolbox"

# shellcheck disable=SC2034  # read by setup.sh
EXTRAS=""

extra_starship() {
    have starship && return 0
    curl -fsSL https://starship.rs/install.sh | sh -s -- -y
}

extra_jetbrains_toolbox() {
    local dest="$HOME/Applications/jetbrains-toolbox"
    [[ -x "$dest/bin/jetbrains-toolbox" ]] && return 0
    local tmp; tmp="$(mktemp -d)"
    if ! curl -fsSL "https://data.services.jetbrains.com/products/download?code=TBA&platform=linux" -o "$tmp/tb.tar.gz" ||
       ! tar -xzf "$tmp/tb.tar.gz" -C "$tmp"; then
        rm -rf "$tmp"; return 1
    fi
    mkdir -p "$dest"
    # Archive layout is jetbrains-toolbox-<version>/bin/jetbrains-toolbox
    cp -a "$tmp"/jetbrains-toolbox-*/. "$dest/"
    rm -rf "$tmp"
    mkdir -p "$HOME/.local/bin"
    ln -sf "$dest/bin/jetbrains-toolbox" "$HOME/.local/bin/jetbrains-toolbox"
    echo "    Launch 'jetbrains-toolbox' once to finish setup and re-install your IDEs."
}

extra_ollama() {
    have ollama && return 0
    curl -fsSL https://ollama.com/install.sh | sh
}
