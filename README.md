# fedora-replicate

Move your Fedora Workstation (GNOME) setup to a new machine with one command.

`fedora-replicate` takes a snapshot of your current system and stores it in a
git repo: packages, repositories, Flatpaks, GNOME extensions, every GNOME
setting (theme, keyboard shortcuts, extension settings…), dotfiles, editor
extensions, services and more. On a freshly installed Fedora, one command
puts it all back.

```bash
./update.sh --push    # old machine: snapshot everything into your repo
./setup.sh            # new machine: restore it
```

It's plain Bash with no dependencies beyond what Fedora ships, and it is
**idempotent**: run `setup.sh` as many times as you like and it only changes
what is missing or different.

---

## Contents

- [Requirements](#requirements)
- [Getting started](#getting-started)
- [Moving to a new machine](#moving-to-a-new-machine)
- [Keeping your snapshot up to date](#keeping-your-snapshot-up-to-date)
- [What gets captured](#what-gets-captured)
- [Customising](#customising)
- [Privacy](#privacy)
- [How it works](#how-it-works)
- [Troubleshooting](#troubleshooting)
- [Getting updates to the tool](#getting-updates-to-the-tool)
- [Why Fedora only?](#why-fedora-only)
- [Contributing](#contributing)

---

## Requirements

- **Fedora Workstation 41 or newer** with GNOME (uses DNF5). Built on Fedora 44 / GNOME 50.
- A GNOME desktop session (needed to read and write GNOME settings).
- Not supported: other distros, and atomic Fedora (Silverblue, Kinoite, Bazzite…)
  because it installs packages with `rpm-ostree`. Both scripts check this and
  stop with a clear message instead of failing halfway.
- A normal user with `sudo` rights. Don't run the scripts as root.
- A **private** git repo to hold your snapshot (GitHub, GitLab, anywhere).

---

## Getting started

Your snapshot contains personal information (see [Privacy](#privacy)), so it
must live in **your own private repository**, never in a fork of this public
one. You do this setup once.

### 1. Clone the tool on your current machine

```bash
git clone https://github.com/ibmbt/fedora-replicate.git ~/dotfiles
cd ~/dotfiles
git remote rename origin upstream     # keep a link to this repo for tool updates
```

### 2. Create your private repo and point `origin` at it

With the GitHub CLI:

```bash
gh repo create my-dotfiles --private --source . --remote origin
```

Or create an **empty private** repo on the GitHub website, then:

```bash
git remote add origin https://github.com/<you>/my-dotfiles.git
```

### 3. Choose what to track (optional, you can do this later)

- `dotfiles.txt`: config files and folders to carry over (shell, editor, terminal…)
- `state/dnf-remove.txt`: default Fedora packages you always uninstall
- `lib/extras.sh`: software you install with curl scripts or tarballs

See [Customising](#customising).

### 4. Take your first snapshot

```bash
./update.sh            # captures everything into state/ and configs/
git diff --stat        # look at what was captured
./update.sh --push     # commit and push to your private repo
```

That's it. Your machine is now backed up as a repo.

`--push` always pushes to `origin` (your private repo), never to `upstream`,
and refuses if GitHub reports `origin` as public.

---

## Moving to a new machine

1. **On the old machine**, take a final snapshot:

   ```bash
   cd ~/dotfiles && ./update.sh --push
   ```

2. **On the new machine**, install Fedora Workstation, log in to GNOME,
   open a terminal and run:

   ```bash
   sudo dnf install -y git gh
   gh auth login                          # or set up an SSH key for GitHub
   git clone https://github.com/<you>/my-dotfiles.git ~/dotfiles
   cd ~/dotfiles
   ./setup.sh
   ```

   It asks for your `sudo` password once at the start. A full restore
   downloads a lot, so expect it to take a while.

3. **Log out and back in** (or reboot). New GNOME extensions, group
   membership and your login shell only take effect in a new session.

If any step fails, the rest still run and you get a summary at the end. Fix
the cause (often just a flaky network) and run `./setup.sh` again.

---

## Keeping your snapshot up to date

Run `update.sh` whenever you've changed something you'd want on a new
machine: installed an app, tweaked a shortcut, edited a config.

```bash
./update.sh --push         # everything
./update.sh dconf          # only GNOME settings
./update.sh dnf flatpak    # only packages
```

Both scripts take step names, so you can run just part of the work:

| Script | Steps |
|---|---|
| `update.sh` | `repos dnf flatpak extensions dconf dotfiles editors services system` |
| `setup.sh` | `prereqs repos dnf flatpak extras dotfiles extensions dconf editors services system` |

`./setup.sh --list` prints the steps, and `--help` shows usage for either script.

---

## What gets captured

| What | Captured into | How it is restored |
|---|---|---|
| DNF configuration | `state/dnf.conf` | copied to `/etc/dnf/dnf.conf` |
| Third-party repos (VS Code, Docker, COPRs, …) | `state/yum.repos.d/` | copied to `/etc/yum.repos.d/` |
| RPM Fusion | *always* | free + nonfree release packages installed |
| Which repos are enabled | `state/dnf-repos-enabled.txt` | repos that ship disabled (e.g. Google Chrome) are re-enabled |
| Packages you installed | `state/dnf-packages.txt` | only the missing ones are installed |
| Packages you don't want | `state/dnf-remove.txt` *(you edit this)* | removed |
| Packages from local `.rpm` files | `state/dnf-local-rpms.txt` | **listed only**, since they can't be re-downloaded |
| Flatpak apps | `state/flatpak-apps.txt` | installed from Flathub (system or user, as before) |
| GNOME extensions | `state/gnome-extensions.txt` | downloaded from extensions.gnome.org for the new machine's GNOME version |
| All GNOME / dconf settings | `state/dconf.ini` | loaded with `dconf load` |
| Dotfiles listed in `dotfiles.txt` | `configs/` (mirrors `~`) | copied into `~`, and existing files are backed up first |
| Wallpaper and lock-screen image | `configs/.local/share/backgrounds/` | restored with the dotfiles, and settings point at it |
| VS Code / Cursor extensions | `state/vscode-extensions.txt`, `state/cursor-extensions.txt` | only the missing ones are installed |
| Services you enabled | `state/services-system.txt`, `state/services-user.txt` | `systemctl enable --now` |
| Login shell, timezone, extra groups | `state/system.conf` | `usermod`, `timedatectl` |
| curl/tarball installs | `lib/extras.sh` *(you edit this)* | each runs only if the tool is missing |

**Not covered.** Do these by hand:

- SSH and GPG keys, passwords, browser profiles
- Signing in to accounts (GNOME Online Accounts, `gh auth login`, Tailscale, …)
- Your personal files (`~/Documents`, `~/Pictures`, …). Use a real backup tool for these.
- Anything listed in `state/dnf-local-rpms.txt`

---

## Customising

### Track more config files: `dotfiles.txt`

One path per line, relative to your home folder. It can be a file or a whole
folder.

```text
.zshrc
.config/nvim
.config/Code/User/settings.json
```

Then run `./update.sh dotfiles`. Folders are mirrored exactly: a file you
delete locally is also deleted from the snapshot on the next update.

On restore, any file that would be overwritten and is different is saved
first as `<file>.bak-dotfiles`, so nothing on the new machine is lost
silently.

### Remove default packages: `state/dnf-remove.txt`

```text
libreoffice*
rhythmbox
```

### Install things that aren't packages: `lib/extras.sh`

Write a function named `extra_<name>` and add `<name>` to `EXTRAS`. Return
early if the tool already exists, so re-runs don't reinstall it:

```bash
EXTRAS="starship mytool"

extra_mytool() {
    have mytool && return 0
    curl -fsSL https://example.com/install.sh | sh
}
```

The file ships with examples for Starship, JetBrains Toolbox and Ollama.

### Skip GNOME settings you don't want: `dconf-ignore.txt`

Each line is a regular expression. It is matched against `section/` for a
whole section, or `section/key` for a single setting:

```text
^org/gnome/shell/extensions/some-extension/    # a whole section
/window-size$                                  # one key, in any section
```

The defaults already skip history, window sizes, Wi-Fi details, your
auto-detected location and similar machine-specific noise.

---

## Privacy

Your snapshot is personal. Depending on what you track, it can include:

- the list of every app and package you use
- your keyboard shortcuts, recent settings, weather and world-clock locations
- your git name and email (from `.gitconfig`) and anything else in your dotfiles

So:

- **Keep your snapshot repo private.** `update.sh --push` refuses to push
  if the GitHub CLI reports that `origin` is public.
- **Never track secrets** in `dotfiles.txt`: SSH keys, `~/.config/gh/hosts.yml`,
  API tokens, `.env` files.
- Run `git diff` before pushing. `update.sh` shows you which files changed.
- If you contribute to this public repo, do it from a separate clone of the
  tool, not from your snapshot repo. See [Contributing](#contributing).

---

## How it works

```
your-private-repo/
├── setup.sh            # restore (run on the new machine)
├── update.sh           # capture (run on the old machine)
├── lib/
│   ├── common.sh       # shared helpers
│   └── extras.sh       # your non-package installs
├── dotfiles.txt        # which home files to track
├── dconf-ignore.txt    # which GNOME settings to skip
├── state/              # captured by update.sh (+ dnf-remove.txt you edit)
└── configs/            # copies of your dotfiles, laid out like ~
```

Some design decisions:

- **It captures what you chose, not everything.** Packages come from
  `dnf repoquery --userinstalled`, which leaves out dependencies. Services are
  the ones you enabled even though Fedora's preset has them off. Kernel and
  live-installer packages are skipped.
- **Restores are idempotent.** Every step compares the snapshot with the
  machine first. Dotfiles are compared by content (`rsync --checksum`), so a
  fresh clone doesn't rewrite identical files.
- **Settings work for any username.** Your home path is stored as `@HOME@`
  and replaced with the new machine's home folder.
- **Locked settings are skipped.** Fedora locks a few settings system-wide
  (for example login-screen options managed by authselect). `dconf load`
  rejects the *entire* file if it contains even one locked key, so `setup.sh`
  removes locked keys first.
- **Failures don't stop the run.** Each step runs independently, and you get
  a summary of anything that failed at the end.

---

## Troubleshooting

**`dconf: No desktop session bus`**
Run `setup.sh` from a terminal inside your GNOME session, not over SSH or
from a TTY.

**`<extension>: no version for GNOME NN on extensions.gnome.org`**
The extension hasn't been updated for your GNOME version yet. Try again
later, or install it manually. Its settings are already restored and apply
once it's installed.

**A package fails to install**
`setup.sh` skips packages that no longer exist in the repos and carries on.
Check the output for the name. It may have been renamed or dropped from Fedora.

**My extensions or shortcuts didn't change after `setup.sh`**
Log out and back in. GNOME on Wayland can't reload the shell in a running
session.

**I want to restore only some of it**
Pass step names: `./setup.sh dconf dotfiles`.

**The snapshot is from an older Fedora release**
That's fine. `setup.sh` warns about the version difference, then skips any
package that was renamed or dropped and carries on.

**I want to see what a restore would change in my home folder first**
`rsync -a --checksum --dry-run --itemize-changes configs/ ~/`

---

## Getting updates to the tool

If you set up your repo as described in [Getting started](#getting-started),
`upstream` points at this repo. To pull in new features and fixes:

```bash
git pull upstream main
```

Your snapshot (`state/`, `configs/`) never conflicts with tool updates. If
you edited `dotfiles.txt`, `dconf-ignore.txt` or `lib/extras.sh` and the
tool changed the same lines, git asks you to resolve the conflict. Keep
your own entries.

---

## Why Fedora only?

Restoring packages correctly depends on the package manager. `dnf`, `apt`,
`pacman` and `zypper` each handle repos, signing keys and "packages I
installed" differently, and package names differ between distros, so a
Fedora snapshot can never restore packages on Ubuntu anyway. Supporting one
distro properly beats supporting five half-tested ones.

## Contributing

Bug reports and pull requests are welcome. To keep your personal data out
of pull requests:

1. Fork this repo and clone **the fork** (not your snapshot repo).
2. Make your change and keep the scripts passing `shellcheck -x setup.sh update.sh lib/*.sh`.
3. If you can, test on a fresh Fedora VM (GNOME Boxes works well): run
   `./update.sh` on one machine and `./setup.sh` on the other.

## License

[MIT](LICENSE)
