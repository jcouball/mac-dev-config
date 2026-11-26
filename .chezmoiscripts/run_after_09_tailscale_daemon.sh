#!/bin/bash
#
# Run Tailscale as a system daemon on a Mac that has no battery.
#
# Tailscale comes two ways. The app, cask tailscale-app, starts when someone
# logs in at the desktop. The daemon, tailscaled from formula tailscale, starts
# at boot. A Mac with no battery is one that is reached over ssh with nobody at
# it, so it runs the daemon: after a restart it is back on the tailnet as soon
# as the disk is unlocked. A MacBook runs the app, which has the menu bar item
# and can use an exit node, and this script leaves it alone.
#
# .Brewfile declares both. brew-bundle-this-mac, which scripts 02 and 99 run
# `brew bundle` through, leaves out the one this Mac does not run, and so does
# verify.sh, by the same battery test as here and in script 06.
#
# `tailscaled install-system-daemon` is used, not `sudo brew services start`.
# brew services hands the formula's files to root, and the next `brew upgrade`
# then cannot remove them without sudo, which is how topgrade's weekly run
# would fail. install-system-daemon copies the binary to
# /usr/local/bin/tailscaled, owned by root, and loads
# /Library/LaunchDaemons/com.tailscale.tailscaled.plist. Homebrew's copy stays
# the user's, and root runs a binary the user cannot write.
#
# The copy does not follow an upgrade of the formula, so this script compares
# the two versions and installs again when they differ. That restarts the
# daemon. A session that came in over the tailnet stalls for the seconds it
# takes.
#
# It also installs again when launchd has the job and the job is not running.
# The plist install-system-daemon writes has no KeepAlive, so launchd does not
# start the daemon again after it exits, and it keeps the job either way:
# having the job says nothing about whether tailscaled is up.
#
# run_ rather than run_onchange_, so it runs on every apply: what it checks is
# on the machine, not in this file. It asks for sudo only when it has something
# to install, and prints nothing when there is nothing to do.
#
# SIGNING IN IS NOT DONE HERE. It needs a person and a browser:
# `sudo tailscale up`. The script says so while the Mac is signed out, and does
# not fail the apply over it.

set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "❌ Do not run 'sudo chezmoi apply'. Instead:  sudo -v && chezmoi apply" >&2
  exit 1
fi

# A MacBook runs the app.
if pmset -g ps | grep -q "InternalBattery"; then
  exit 0
fi

FORMULA_BIN=/opt/homebrew/opt/tailscale/bin
DAEMON=/usr/local/bin/tailscaled
LABEL=com.tailscale.tailscaled
BREW_LABEL=sh.brew.tailscale

# Script 02 does not stop the apply when an entry fails to install, and script
# 99 names what is missing. Nothing to start until the formula is there.
if [ ! -x "$FORMULA_BIN/tailscaled" ]; then
  echo "!! The tailscale formula is not installed, so the daemon was not started." >&2
  echo "!! Script 99 reports the missing entry." >&2
  exit 0
fi

# Two variants on one Mac fight over the tunnel. The app is not removed here:
# taking a Mac off the tailnet is not something an apply should do unasked.
if [ -d /Applications/Tailscale.app ]; then
  echo "❌ Tailscale.app is installed, and this Mac runs the daemon." >&2
  echo "   Remove the app and restart, then apply again:" >&2
  echo "     brew uninstall --cask tailscale-app" >&2
  echo "   README.md, \"Tailscale\", has the steps. The Mac is off the tailnet" >&2
  echo "   from the uninstall until 'sudo tailscale up', so do it at the console." >&2
  exit 1
fi

# A daemon started with `sudo brew services start tailscale` has to be stopped
# by hand, because stopping it drops a session that came in over the tailnet.
if launchctl print "system/$BREW_LABEL" >/dev/null 2>&1; then
  echo "❌ The Tailscale daemon is running under brew services." >&2
  echo "   That leaves files in Homebrew owned by root, and 'brew upgrade' fails on them." >&2
  echo "   At the console, not over the tailnet:" >&2
  echo "     sudo brew services stop tailscale" >&2
  echo "     sudo chown -R -h \"\$(id -un)\":admin /opt/homebrew/Cellar/tailscale /opt/homebrew/opt/tailscale /opt/homebrew/var/homebrew/linked/tailscale" >&2
  echo "     sudo -v && chezmoi apply" >&2
  exit 1
fi

version_of() { "$1" --version 2>/dev/null | head -1; }

# Loaded and running, not only loaded. A here-string, not a pipe into grep -q:
# under pipefail, grep leaving early can fail the pipe and read as "stopped".
daemon_running() {
  grep -q '^[[:space:]]*state = running' <<<"$(launchctl print "system/$LABEL" 2>/dev/null || true)"
}

want="$(version_of "$FORMULA_BIN/tailscaled")"
have=""
[ -x "$DAEMON" ] && have="$(version_of "$DAEMON")"

if [ "$have" != "$want" ] || ! daemon_running; then
  if ! sudo -n true 2>/dev/null && [ ! -t 0 ]; then
    echo "❌ Installing the Tailscale daemon needs sudo, and there is no terminal to prompt on." >&2
    echo "   Run 'sudo -v' first, then 'chezmoi apply' -- NOT 'sudo chezmoi apply'." >&2
    exit 1
  fi
  if [ -z "$have" ]; then
    echo ">> Installing the Tailscale daemon ${want}..."
  elif [ "$have" != "$want" ]; then
    echo ">> Replacing the Tailscale daemon ${have} with ${want}..."
  else
    echo ">> The Tailscale daemon ${have} is not running. Installing it again..."
  fi
  # A new Mac with Apple silicon has no /usr/local/bin until something makes it.
  sudo mkdir -p /usr/local/bin
  sudo "$FORMULA_BIN/tailscaled" install-system-daemon

  for _ in 1 2 3 4 5 6 7 8 9 10; do
    daemon_running && break
    sleep 1
  done
  if ! daemon_running; then
    echo "❌ $LABEL is not running after install-system-daemon." >&2
    echo "   Look at:  launchctl print system/$LABEL" >&2
    exit 1
  fi
  if [ "$(version_of "$DAEMON")" != "$want" ]; then
    echo "❌ $DAEMON is not version ${want} after install-system-daemon." >&2
    exit 1
  fi
  echo ">> The Tailscale daemon starts at boot."
fi

# The daemon takes a moment to answer after it starts, and until it does
# `tailscale status` fails. `|| true`: under pipefail a failed probe would end
# the script at the assignment, before the next try and before the message
# below.
state=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  state="$("$FORMULA_BIN/tailscale" status --json 2>/dev/null \
            | sed -n 's/^[[:space:]]*"BackendState":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || true)"
  [ -n "$state" ] && break
  sleep 1
done

# Running and silent for 15 seconds is a daemon that is not working, and the
# Mac is off the tailnet. That fails the apply. Signed out, below, does not.
if [ -z "$state" ]; then
  echo "❌ The Tailscale daemon is running and does not answer 'tailscale status'." >&2
  echo "   Look at:  launchctl print system/$LABEL" >&2
  exit 1
fi

if [ "$state" != "Running" ]; then
  echo "!! Tailscale is not signed in on this Mac (state: ${state})." >&2
  echo "!! Sign in, and approve the address it prints in a browser:" >&2
  echo "!!   sudo tailscale up" >&2
  echo "!! Then turn off key expiry for this Mac in the admin console." >&2
fi
