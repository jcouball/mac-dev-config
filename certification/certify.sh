#!/bin/bash
#
# Certify the rebuild: run the README's bootstrap procedure end to end against a
# throwaway macOS VM that has never seen this repo, then verify the outcome.
#
# A clean `chezmoi diff` proves the repo describes this machine. It says nothing
# about whether the repo can *produce* one. That is what this script tests.
#
# Runs on the host. Requires tart and a prepared base VM -- see "Certification"
# in the README for how to build one. Nothing here touches your real Mac.
#
# Usage:
#   ./certification/certify.sh                  # full run of main, from a fresh clone
#   ./certification/certify.sh --branch <name>  # full run of a pushed branch, before it merges
#   ./certification/certify.sh --verify-only    # re-run checks on the live cert VM
#   ./certification/certify.sh --keep           # do not delete a previous cert VM
#
# A CERTIFIED run is recorded afterwards with ./certification/record.sh.
#
# THE DEVIATIONS
#
# The point of certification is to run what the README says, not a convenient
# variant, so deviations have to be named. Every run has exactly three, all
# forced by the platform rather than chosen. A pre-merge run has a fourth:
#
#   1. --promptString  There is no human at the VM's console to answer chezmoi's
#                      one question, so the machine name is supplied up front.
#   2. SKIP_MAS=1      Apple's Virtualization framework does not support signing
#                      into the Mac App Store inside a VM, on any tool, at all.
#                      The 14 `mas` entries in .Brewfile therefore cannot be
#                      certified here and must be checked on real hardware.
#   3. CASK_SKIP=zoom  Zoom's installer does not merely fail in a VM, it hangs
#                      first: its postinstall script launches ZoomUpdater, which
#                      waits on a GUI session that does not exist, stalling the
#                      run for minutes at 0% CPU before erroring. Skipping it
#                      buys back that time. verify.sh still names zoom as an
#                      unverified entry, so it cannot be quietly forgotten.
#   4. --branch <name> Only in a run started with --branch. The README's
#                      command clones main; this one makes chezmoi clone the
#                      named branch, so a change to the bootstrap path can be
#                      certified before it merges. Without it the only way to
#                      certify a change is to merge it first. "Re-certify the
#                      rebuild" in the README says when such a run counts for
#                      the merged commit.
#
# Everything else runs exactly as the README publishes it. There is no deviation
# for staleness any more: chezmoi clones over git, which has no cache, so what
# the VM gets is always what was last pushed.

set -euo pipefail

BASE_VM="${BASE_VM:-neuromancer-base}"
CERT_VM="${CERT_VM:-neuromancer-cert}"
CERT_USER="${CERT_USER:-certuser}"
# A dedicated, passphrase-less key. Passphrase-less because certify.sh runs
# unattended over BatchMode SSH; dedicated because the alternative is handing a
# throwaway VM a key that also opens something real.
CERT_SSH_KEY="${CERT_SSH_KEY:-$HOME/.ssh/id_ed25519_neuromancer_certvm}"
REPO="${MAC_DEV_CONFIG_REPO:-jcouball/mac-dev-config}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"

VERIFY_ONLY=0
KEEP_OLD=0
BRANCH=""
BRANCH_GIVEN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --verify-only) VERIFY_ONLY=1 ;;
    --keep) KEEP_OLD=1 ;;
    --branch)
      [ $# -ge 2 ] || { echo "--branch needs a branch name" >&2; exit 64; }
      BRANCH="$2"
      BRANCH_GIVEN=1
      shift
      ;;
    --help|-h) sed -n '2,48p' "$0" | sed 's/^#\{1,2\} \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 64 ;;
  esac
  shift
done

# The branch name is pasted into a command that runs in the guest, so only the
# characters a branch name can have are let in. The class is written out
# because this runs under /bin/bash 3.2, where \w cannot be relied on, and the
# locale is pinned because a range like A-Z can take in other letters outside C.
valid_branch_name() {
  local LC_ALL=C
  local pattern='^[A-Za-z0-9_][A-Za-z0-9_./-]*$'
  [[ "$1" =~ $pattern ]]
}

# Checked whenever --branch was given, not only when its value is non-empty:
# an empty name, as from an unset variable, would otherwise be read as no
# option at all and start a full run of main.
if [ "$BRANCH_GIVEN" -eq 1 ] && ! valid_branch_name "$BRANCH"; then
  echo "Not a branch name: '$BRANCH'" >&2
  exit 64
fi

# --branch main is a run of main: same clone command, same log file names.
[ "$BRANCH" = "main" ] && BRANCH=""
TARGET_BRANCH="${BRANCH:-main}"
# A slash is the only character the pattern allows that a file name cannot hold.
LOG_SUFFIX="${BRANCH:+-${BRANCH//\//-}}"

# All three write to stderr. log() in particular must: wait_for_ssh's result is
# captured with $(...), so anything it prints to stdout is captured as part of
# the value. It printed its progress there, and the IP became the whole
# transcript -- log line, dots and address -- which ssh rejected as
# "hostname contains invalid characters".
log()  { printf '\n\033[1m>> %s\033[0m\n' "$*" >&2; }
warn() { printf '\033[33m!! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m❌ %s\033[0m\n' "$*" >&2; exit 1; }

# Whether tart has a local VM with exactly this name.
#
# The list is read to the end before it is searched, and nothing here is a
# pipeline. This used to be `tart list --format json | grep -q NAME`. grep -q
# exits at the first match; when tart was still writing, it was killed by
# SIGPIPE, and under pipefail the pipeline failed though the name had been
# found. The run then stopped with "Base VM not found" for a VM that was there,
# about three times in eight.
#
# A tart that cannot list its VMs stops the run. It is not an answer of "no".
#
# --quiet prints the names alone, one to a line, so the name is compared with
# a whole line and nothing has to be picked out of JSON. The old search matched
# the name anywhere in the JSON, as part of a longer name or as the value of
# some other field.
vm_exists() {
  local names
  [ -n "$1" ] || return 1
  names="$(tart list --quiet --source local)" || die "Could not list the tart VMs: 'tart list --quiet --source local' failed."
  grep -qxF -- "$1" <<<"$names"
}

# --- Preflight -------------------------------------------------------------

command -v tart >/dev/null 2>&1 \
  || die "tart not found. It is declared in .Brewfile: brew bundle --global"

[ -f "$CERT_SSH_KEY" ] \
  || die "No certification SSH key at $CERT_SSH_KEY.
     Create one:  ssh-keygen -t ed25519 -N '' -f $CERT_SSH_KEY
     then add $CERT_SSH_KEY.pub to ~$CERT_USER/.ssh/authorized_keys in the base VM."

# What the VM is about to build, asked of GitHub before anything boots.
#
# The guest clones $REPO from GitHub, and verify.sh is copied in from this
# checkout. If the two are at different revisions, one revision's files are
# tested against another revision's checks. A branch run stops on that. A run
# of main only warns, because the run of main that certifies a change to this
# script is made from that change's branch, before it merges.
#
# The URL is built from $REPO rather than taken from `origin`, because $REPO is
# what the guest clones. The ref is spelled out in full because a bare name
# given to ls-remote also matches refs/heads/x/<name>.
REPO_URL="https://github.com/$REPO.git"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EXPECTED_COMMIT=""
MAIN_NOTE=""

remote_commit() {
  # shellcheck disable=SC2016  # awk's $1 and $2 are awk's, not the shell's.
  printf '%s\n' "$REMOTE_REFS" | awk -v ref="refs/heads/$1" '$2 == ref { print $1 }'
}

if [ "$VERIFY_ONLY" -eq 0 ]; then
  vm_exists "$BASE_VM" \
    || die "Base VM '$BASE_VM' not found. See 'Certification' in the README for how to build it."

  log "Asking GitHub what $TARGET_BRANCH is in $REPO..."
  REMOTE_REFS="$(git ls-remote "$REPO_URL" "refs/heads/$TARGET_BRANCH" refs/heads/main)" \
    || die "Could not read the branches of $REPO_URL."
  EXPECTED_COMMIT="$(remote_commit "$TARGET_BRANCH")"
  [ -n "$EXPECTED_COMMIT" ] \
    || die "Branch '$TARGET_BRANCH' is not on GitHub in $REPO. Push it first: the VM clones from GitHub."
  echo "   $TARGET_BRANCH is at $EXPECTED_COMMIT" >&2

  LOCAL_HEAD="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  VERIFY_CHANGES="$(git -C "$REPO_ROOT" status --porcelain -- certification/verify.sh)"

  if [ -n "$BRANCH" ]; then
    [ "$LOCAL_HEAD" = "$EXPECTED_COMMIT" ] \
      || die "This checkout is at $LOCAL_HEAD, but '$BRANCH' on GitHub is at $EXPECTED_COMMIT.
     verify.sh comes from this checkout, so the two have to be the same commit.
     Check out '$BRANCH' and push or pull until they match."
    [ -z "$VERIFY_CHANGES" ] \
      || die "certification/verify.sh has uncommitted changes.
     The VM would build '$BRANCH' as pushed and be checked by a verify.sh that
     is in no commit. Commit and push it, or discard the changes."

    # Whether the branch contains main's tip says how likely this run is to
    # count for the merged commit. When it does, and nothing else lands first,
    # the tree a rebase merge puts on main is the tree built here. When it does
    # not, the trees will usually differ, but they can still be equal, so this
    # is a report and not a ruling: the tree comparison after the merge
    # decides. Fetching by URL writes FETCH_HEAD and nothing else, so no local
    # ref moves.
    MAIN_COMMIT="$(remote_commit main)"
    if [ -n "$MAIN_COMMIT" ] \
        && git -C "$REPO_ROOT" fetch --quiet "$REPO_URL" refs/heads/main 2>/dev/null; then
      if git -C "$REPO_ROOT" merge-base --is-ancestor "$MAIN_COMMIT" "$EXPECTED_COMMIT" 2>/dev/null; then
        MAIN_NOTE="'$BRANCH' contains main's tip ($MAIN_COMMIT). If nothing else lands on main before the merge, the tree on main will be the tree built here."
      else
        MAIN_NOTE="'$BRANCH' does NOT contain main's tip ($MAIN_COMMIT). The tree on main after the merge will probably differ from the tree built here. The tree comparison after the merge decides whether this run counts."
      fi
    else
      MAIN_NOTE="Could not tell whether '$BRANCH' contains main's tip: main could not be fetched from $REPO_URL."
    fi
    echo "   $MAIN_NOTE" >&2
  else
    [ "$LOCAL_HEAD" = "$EXPECTED_COMMIT" ] \
      || warn "This checkout is at $LOCAL_HEAD, but main on GitHub is at $EXPECTED_COMMIT.
   The VM builds main; verify.sh comes from this checkout."
    [ -z "$VERIFY_CHANGES" ] \
      || warn "certification/verify.sh has uncommitted changes. The VM is checked by a verify.sh that is in no commit."
  fi
fi

mkdir -p "$LOG_DIR"

STAMP="$(date +%Y%m%d-%H%M%S)"
BOOTSTRAP_LOG="$LOG_DIR/bootstrap-$STAMP$LOG_SUFFIX.log"
VERIFY_LOG="$LOG_DIR/verify-$STAMP$LOG_SUFFIX.log"

# The verify.sh this run checks the VM with, copied now and kept beside the
# logs. The checks above describe the checkout as it is at this moment, and
# the VM is not verified until the bootstrap is over, many minutes later.
# Copying verify.sh from the checkout then would use whatever is there by
# then: an edit, or another branch checked out in the meantime, and the commit
# this run names would be certified by another revision's checks.
VERIFY_SNAPSHOT="$LOG_DIR/verify-$STAMP$LOG_SUFFIX.sh"
cp "$SCRIPT_DIR/verify.sh" "$VERIFY_SNAPSHOT" \
  || die "Could not copy verify.sh to $VERIFY_SNAPSHOT."

vm_ip() { tart ip "$CERT_VM" --wait 1 2>/dev/null || true; }

wait_for_ssh() {
  local waited=0 ip=""
  log "Waiting for the VM to boot and accept SSH (up to ${BOOT_TIMEOUT}s)..."
  while [ "$waited" -lt "$BOOT_TIMEOUT" ]; do
    ip="$(vm_ip)"
    if [ -n "$ip" ] && ssh -i "$CERT_SSH_KEY" -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o IdentitiesOnly=yes -o BatchMode=yes \
        "$CERT_USER@$ip" true 2>/dev/null; then
      echo "$ip"
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
    printf "." >&2
  done
  echo >&2
  die "VM did not become reachable over SSH within ${BOOT_TIMEOUT}s.
     Check that the base image has Remote Login enabled and this host's
     public key in ~$CERT_USER/.ssh/authorized_keys."
}

# Host keys change with every clone, so they are deliberately not verified.
# This is a disposable VM on a local network, reachable only from this Mac.
guest() {
  ssh -i "$CERT_SSH_KEY" -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes \
      -o LogLevel=ERROR "$CERT_USER@$IP" "$@"
}

# --- Clone and boot --------------------------------------------------------

if [ "$VERIFY_ONLY" -eq 0 ]; then
  if vm_exists "$CERT_VM"; then
    if [ "$KEEP_OLD" -eq 1 ]; then
      die "Cert VM '$CERT_VM' already exists and --keep was given."
    fi
    log "Removing the previous cert VM..."
    tart stop "$CERT_VM" 2>/dev/null || true
    tart delete "$CERT_VM"
  fi

  # An APFS clone: seconds, and almost no additional disk. This is the
  # equivalent of reverting to a checkpoint -- the base image is never booted
  # again, so it cannot drift.
  log "Cloning $BASE_VM -> $CERT_VM..."
  tart clone "$BASE_VM" "$CERT_VM"

  log "Starting $CERT_VM..."
  # nohup, and deliberately no EXIT trap to kill it. A trap here stopped the VM
  # the moment the script finished, which contradicted the closing message,
  # made --verify-only impossible, and threw away the failed machine that is
  # the most useful thing a failed run produces.
  nohup tart run "$CERT_VM" --no-graphics >"$LOG_DIR/vm-console.log" 2>&1 &
fi

IP="$(wait_for_ssh)"
echo
log "VM reachable at $IP"

# Fail fast on a disk that cannot finish the job. Run 3 spent twenty minutes
# downloading before Homebrew ran out of space and reported it as 113 failed
# package installs -- a diagnosis that took longer than the run. The number was
# knowable in the first second.
#
# Only a full run installs anything. With --verify-only the Brewfile is already
# on the disk, so a built VM never has this much free and the check would stop
# every re-check.
# shellcheck disable=SC2016  # awk's $4 must reach the guest unexpanded.
AVAIL_GB="$(guest 'df -g / | awk "NR==2{print \$4}"' 2>/dev/null || echo 0)"
log "Guest has ${AVAIL_GB} GB free."
if [ "$VERIFY_ONLY" -eq 0 ] && [ "${AVAIL_GB:-0}" -lt 45 ]; then
  die "Only ${AVAIL_GB} GB free in the guest; the Brewfile needs roughly 35-40.
     Disk size can only be set when the VM is created:
       tart delete $BASE_VM
       tart create --from-ipsw=latest --disk-size 100 $BASE_VM"
fi

# --- Run the bootstrap -----------------------------------------------------

# Set when the commit the VM built is not known to be the one GitHub named.
COMMIT_PROBLEM=""
BUILT_COMMIT=""
BUILT_TREE=""

# A line for the terminal and for the end of the bootstrap log.
note() { printf '%s\n' "$*" | tee -a "$BOOTSTRAP_LOG" >&2; }

if [ "$VERIFY_ONLY" -eq 0 ]; then
  log "Running the bootstrap. Transcript: $BOOTSTRAP_LOG"
  echo "   Certifying $REPO, branch $TARGET_BRANCH" >&2
  echo "   Without a log, failures have to be inferred from wreckage." >&2

  BRANCH_OPTION="${BRANCH:+--branch $BRANCH }"

  # The three commands from "Rebuild from nothing", verbatim, plus the
  # deviations named above: three in every run, and --branch in a pre-merge
  # run. Do not "improve" them here -- the point is to test what the README
  # says.
  #
  # NONINTERACTIVE=1 is Homebrew's own documented flag for unattended installs,
  # not a deviation: without a terminal its installer waits for a RETURN that
  # will never come.
  # shellcheck disable=SC2016  # $(...) must stay unexpanded: it runs in the guest.
  BOOTSTRAP='set -e
export SKIP_MAS=1 NONINTERACTIVE=1 HOMEBREW_BUNDLE_CASK_SKIP=zoom
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
eval "$(/opt/homebrew/bin/brew shellenv)"
brew install chezmoi
chezmoi init --apply '"$BRANCH_OPTION"'--promptString "Computer name='"$CERT_VM"'" '"$REPO"

  if guest "$BOOTSTRAP" 2>&1 | tee "$BOOTSTRAP_LOG"; then
    log "Bootstrap exited 0."
  else
    warn "Bootstrap exited non-zero. Verifying anyway -- the exit code is not the point."
  fi

  # Name what was built. The commit GitHub gave before the boot is only what
  # the VM was expected to clone: a push during the Homebrew install changes
  # what it gets, and without this comparison that would show nowhere.
  BUILT="$(guest 'git -C ~/.local/share/chezmoi rev-parse HEAD "HEAD^{tree}"' 2>/dev/null || true)"
  BUILT_COMMIT="$(printf '%s\n' "$BUILT" | sed -n '1p')"
  BUILT_TREE="$(printf '%s\n' "$BUILT" | sed -n '2p')"
  SHA_PATTERN='^[0-9a-f]{40}$'

  note ""
  note "== What this run built =="
  note "Repo:   $REPO"
  note "Branch: $TARGET_BRANCH"
  if [[ "$BUILT_COMMIT" =~ $SHA_PATTERN ]] && [[ "$BUILT_TREE" =~ $SHA_PATTERN ]]; then
    note "Commit: $BUILT_COMMIT"
    note "Tree:   $BUILT_TREE"
    if [ "$BUILT_COMMIT" != "$EXPECTED_COMMIT" ]; then
      COMMIT_PROBLEM="The VM built $BUILT_COMMIT, but $TARGET_BRANCH was at $EXPECTED_COMMIT on GitHub when the run started. The branch moved during the run."
    fi
  else
    BUILT_COMMIT=""
    BUILT_TREE=""
    COMMIT_PROBLEM="The commit the VM built could not be read. The bootstrap may have failed before the clone."
  fi
  [ -z "$COMMIT_PROBLEM" ] || note "$COMMIT_PROBLEM"
  [ -z "$MAIN_NOTE" ] || note "$MAIN_NOTE"

  # The machine that was built, for record.sh to put in the tag. The sizes are
  # what tart gave the VM; the version is asked of the guest.
  GUEST_OS="$(guest 'sw_vers -productVersion' 2>/dev/null || true)"
  GUEST_SIZE="$(tart get "$CERT_VM" 2>/dev/null \
    | awk 'NR == 2 { printf "%s CPU / %d GB / %s GB", $2, $3 / 1024, $4 }' || true)"
  note "Guest:  macOS ${GUEST_OS:-unknown}, ${GUEST_SIZE:-size unknown}, user $CERT_USER"
fi

# --- Verify ----------------------------------------------------------------

log "Verifying outcomes. Transcript: $VERIFY_LOG"

# Copy the snapshot taken before the boot over and run it as a file, rather
# than piping it to `bash -s`.
#
# Piping made stdin the script itself, so the first command inside it that read
# stdin -- `script`, used to get a pty for the interactive-shell check -- ate the
# remainder. bash hit EOF partway through, exited 0 because the last command it
# managed to run had succeeded, and ssh reported success. certify.sh believed it
# and printed CERTIFIED over a machine with no Homebrew, no chezmoi and no
# managed files at all.
scp -q -i "$CERT_SSH_KEY" -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes \
    "$VERIFY_SNAPSHOT" "$CERT_USER@$IP:/tmp/verify.sh" \
  || die "Could not copy verify.sh to the VM."

# set +e: the pipeline is expected to fail when verification fails, and with
# `set -e` plus pipefail that would abort the script here -- silently, before it
# could report anything.
set +e
guest "SKIP_MAS=1 bash /tmp/verify.sh" 2>&1 | tee "$VERIFY_LOG"
VERIFY_STATUS=${PIPESTATUS[0]}
set -e

# Never trust a zero exit on its own. verify.sh prints a sentinel as its final
# act, so a run that died partway through cannot be mistaken for a clean one --
# which is the entire lesson of the defect this harness exists to catch, and
# which this harness itself fell for.
if ! grep -q '^VERIFY-COMPLETE' "$VERIFY_LOG"; then
  warn "verify.sh did not run to completion -- its result cannot be trusted."
  VERIFY_STATUS=1
fi

# Passing every check certifies nothing if the commit that passed is unknown or
# is not the one this run set out to build.
if [ -n "$COMMIT_PROBLEM" ]; then
  VERIFY_STATUS=1
fi

echo
if [ "$VERIFY_STATUS" -eq 0 ]; then
  printf '\033[32m✅ CERTIFIED\033[0m -- %s rebuilt from nothing and passed every check.\n' "$CERT_VM"
else
  printf '\033[31m❌ NOT CERTIFIED\033[0m -- see %s\n' "$VERIFY_LOG"
  [ -z "$COMMIT_PROBLEM" ] || printf '   %s\n' "$COMMIT_PROBLEM"
fi

# The verdict and the name of the verify log, written to the end of the
# bootstrap log. record.sh reads them there: it tags a run only when this line
# says CERTIFIED, so it never has to work the verdict out again from the parts.
# A --verify-only run has no bootstrap log and is not something to record.
if [ "$VERIFY_ONLY" -eq 0 ]; then
  {
    printf 'Verify log: %s\n' "$(basename "$VERIFY_LOG")"
    if [ "$VERIFY_STATUS" -eq 0 ]; then
      printf 'Verdict: CERTIFIED\n'
    else
      printf 'Verdict: NOT CERTIFIED\n'
    fi
  } >>"$BOOTSTRAP_LOG"
fi

if [ "$VERIFY_ONLY" -eq 0 ] && [ -n "$BUILT_COMMIT" ]; then
  printf '   Branch: %s\n   Commit: %s\n   Tree:   %s\n' "$TARGET_BRANCH" "$BUILT_COMMIT" "$BUILT_TREE"
fi
if [ -n "$MAIN_NOTE" ]; then
  printf '   %s\n' "$MAIN_NOTE"
  printf '   Put the commit, the tree and the verdict in the pull request.\n'
fi

cat <<EOF

The VM is left running so you can inspect it:

  ssh -i $CERT_SSH_KEY $CERT_USER@$IP
  ./certification/certify.sh --verify-only${BRANCH:+ --branch $BRANCH}   # re-check without rebuilding
  tart stop $CERT_VM && tart delete $CERT_VM # when you are done

Write down any defect this found in the Certification section of the README. A
defect that is fixed but not written down will be rediscovered from scratch.
EOF

if [ "$VERIFY_STATUS" -eq 0 ] && [ "$VERIFY_ONLY" -eq 0 ]; then
  if [ -n "$BRANCH" ]; then
    cat <<EOF

To record this certification: merge '$BRANCH', run 'chezmoi update' on this
Mac, then run ./certification/record.sh
EOF
  else
    cat <<EOF

To record this certification: run 'chezmoi update' on this Mac if its source is
not at $BUILT_COMMIT, then run ./certification/record.sh
EOF
  fi
fi

exit "$VERIFY_STATUS"
