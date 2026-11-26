#!/bin/bash
#
# Fail the apply if anything declared in .Brewfile is not installed.
#
# Script 02 is deliberately not fatal: one package that will not install must
# not stop the runtimes below it. The cost of that was a failure nobody saw.
# Telegram was added to .Brewfile, the apply exited 0, and the app was not
# there -- along with six other casks and tart, which had been missing for
# weeks. The cause was a broken Command Line Tools install: tart builds from
# source, `brew bundle` installs everything missing as one batch, and tart's
# failure took the six casks down with it. The only trace was a line in the
# middle of a long transcript.
#
# This is the other half of that design. It runs last, so nothing is skipped by
# its failure, and it turns "some entries failed" into a non-zero apply that
# names them.
#
# run_ rather than run_onchange_, so it runs on every apply. chezmoi records an
# onchange script as done once it exits 0, and script 02 always exits 0, so a
# failed install is never retried until .Brewfile changes again. This check has
# no such memory: it keeps failing until the machine matches the Brewfile.
#
# after_ and numbered 99 so it runs once every other script has finished.

set -euo pipefail

# Homebrew refuses to run as root. See script 02 for why the apply should not.
if [ "$(id -u)" -eq 0 ]; then
  echo "❌ Do not run 'sudo chezmoi apply'. Instead:  sudo -v && chezmoi apply" >&2
  exit 1
fi

eval "$(/opt/homebrew/bin/brew shellenv)"

BREWFILE="$HOME/.Brewfile"
[ -f "$BREWFILE" ] || { echo "❌ $BREWFILE not found." >&2; exit 1; }

# The Mac App Store apps are left out, always. They need the App Store to be
# signed in, script 02 already treats them as optional, and a missing one is
# not worth failing every apply over. Same derivation as script 02.
mas_ids=$(awk -F'id:' '/^mas /{gsub(/[^0-9]/, "", $2); if ($2 != "") print $2}' "$BREWFILE" | tr '\n' ' ')

# The check is run through brew-bundle-this-mac, which leaves out the one
# Tailscale entry this Mac does not run, as it does for script 02's install.
# .Brewfile declares both, and script 09 says why.
BUNDLE="$HOME/.local/bin/brew-bundle-this-mac"
[ -x "$BUNDLE" ] || { echo "❌ $BUNDLE not found or not executable." >&2; exit 1; }

# Both entries have to stay declared. `brew bundle dump` writes what is
# installed, so a dump on either Mac drops the entry that Mac does not run, and
# the other Mac would lose Tailscale at its next rebuild.
lost=""
for want in 'brew "tailscale"' 'cask "tailscale-app"'; do
  grep -qxF "$want" "$BREWFILE" || lost="$lost
     $want"
done
if [ -n "$lost" ]; then
  echo "❌ .Brewfile no longer declares:$lost" >&2
  echo "   A 'brew bundle dump' on this Mac leaves out the Tailscale entry it" >&2
  echo "   does not run. Put the line back in ~/.Brewfile before 'chezmoi re-add'." >&2
  exit 1
fi

# HOMEBREW_BUNDLE_NO_UPGRADE makes this a check for presence, not freshness.
# Without it every outdated package reports as unsatisfied, and upgrades are
# topgrade's job.
if check_out="$(HOMEBREW_BUNDLE_NO_UPGRADE=1 HOMEBREW_BUNDLE_MAS_SKIP="$mas_ids" \
                "$BUNDLE" check --file="$BREWFILE" --verbose 2>&1)"; then
  exit 0
fi

missing="$(printf '%s\n' "$check_out" | grep '^→' || true)"

echo "❌ .Brewfile declares packages that are not installed:" >&2
if [ -n "$missing" ]; then
  printf '%s\n' "$missing" | sed 's/^/   /' >&2
else
  # The check failed without naming an entry, so show everything it said.
  printf '%s\n' "$check_out" | sed 's/^/   /' >&2
fi
echo "   Everything else in this apply has already run." >&2
echo "   To see why, rerun the install and read its output:" >&2
echo "     HOMEBREW_BUNDLE_NO_UPGRADE=1 brew-bundle-this-mac --file=\"\$HOME/.Brewfile\"" >&2
exit 1
