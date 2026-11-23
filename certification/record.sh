#!/bin/bash
#
# Record a certification as an annotated tag on the commit it certifies.
#
# A certification has two halves: certify.sh rebuilds a VM from nothing, and
# verify.sh passes on this Mac with the same commit applied. This script checks
# that both halves are about the same commit, runs the second half, and writes
# the result into a tag named
#
#   certified/<YYYY-MM-DD>-<short commit>
#
# on that commit. Nothing is typed by hand, no file changes, and no pull
# request is needed. A tag that exists always means a full certification.
#
# It then moves the branch `stable` to that commit. A Mac that is not being
# developed on follows stable, and a rebuild clones it, so a commit reaches
# them only once it is certified. stable only moves forward, and the tag and
# the branch are pushed together or not at all.
#
# Run it on the Mac being developed on, whose chezmoi source follows main, in
# the checkout certify.sh was run from, after `chezmoi update` has applied the
# commit here. That Mac takes a commit before it is certified: the second half
# of a certification is verify.sh passing on it. Either Mac will do, and the
# tag says which. It asks for the sudo password, because verify.sh reads
# sshd's settings as root.
#
# Usage:
#   ./certification/record.sh                         # record the newest full run
#   ./certification/record.sh --dry-run               # show the tag, create nothing
#   ./certification/record.sh --reason "<one line>"   # a trigger no commit records
#   ./certification/record.sh --log <bootstrap log>   # record another run
#   ./certification/record.sh --commit <sha>          # a commit other than main's tip
#
# What stops it, with no tag made:
#
#   - this Mac is not one of the Macs this repo configures
#   - the run was not CERTIFIED
#   - the commit is not on origin/main, or already has a certified/ tag
#   - stable holds a commit that is not a commit of main
#   - the tree of the commit is not the tree the VM built
#   - the verify.sh that checked the VM is not the commit's
#   - the chezmoi source on this Mac is at another commit, or has
#     uncommitted changes, before verify.sh runs or after it
#   - this session cannot push to GitHub
#   - verify.sh fails here, or does not run to its end
#
# The tree comparison is what lets a branch run count. A rebase merge gives the
# commits new SHAs, so the commit on main is never the commit the VM built. It
# is the same content when the trees are equal, and only then.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"

BOOTSTRAP_LOG=""
COMMIT_ARG=""
REASON=""
REASON_GIVEN=0
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --log)
      [ $# -ge 2 ] || { echo "--log needs the path of a bootstrap log" >&2; exit 64; }
      BOOTSTRAP_LOG="$2"
      shift
      ;;
    --commit)
      [ $# -ge 2 ] || { echo "--commit needs a commit" >&2; exit 64; }
      COMMIT_ARG="$2"
      shift
      ;;
    --reason)
      [ $# -ge 2 ] || { echo "--reason needs one line of text" >&2; exit 64; }
      REASON="$2"
      REASON_GIVEN=1
      shift
      ;;
    --help|-h) sed -n '2,49p' "$0" | sed 's/^#\{1,2\} \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 64 ;;
  esac
  shift
done

# The Macs whose verify.sh result a tag may record: the ones this repo
# configures. Either can be the Mac being developed on, so either can record,
# and the tag's Host line says which did. A commit gets one tag, from one of
# them. Anything else is a machine this repo was never applied to as itself,
# such as the certification VM, and its result is not a real-hardware one.
RECORD_HOSTS=("Neuromancer" "cortex")

log() { printf '\n\033[1m>> %s\033[0m\n' "$*" >&2; }
die() { printf '\033[31m❌ %s\033[0m\n' "$*" >&2; printf '   No tag was made.\n' >&2; exit 1; }

repo() { git -C "$REPO_ROOT" "$@"; }

# One line of text, with nothing a tag message or a terminal should not get.
one_line() {
  case "$1" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
  [ -n "$1" ]
}

# "51 passed 0 failed 0 warnings 2 excluded" from the last VERIFY-COMPLETE
# line of a verify log, or nothing. The whole file is read: no early exit, so
# nothing upstream is killed by SIGPIPE.
verify_counts() {
  sed -n 's/^VERIFY-COMPLETE //p' "$1" | tail -n 1
}

# The same four numbers as a sentence: "51 passed, 0 failed, 0 warnings, 2 excluded".
counts_sentence() {
  local passed failed warned excluded _w
  read -r passed _w failed _w warned _w excluded _w <<<"$1"
  printf '%s passed, %s failed, %s warnings, %s excluded' "$passed" "$failed" "$warned" "$excluded"
}

counts_failed() {
  local passed failed _w
  read -r passed _w failed _w <<<"$1"
  printf '%s' "$failed"
}

# Scratch files: the commit's verify.sh, and the tag message.
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

COUNTS_PATTERN='^[0-9]+ passed [0-9]+ failed [0-9]+ warnings [0-9]+ excluded$'
SHA_PATTERN='^[0-9a-f]{40}$'

HOST_NAME="$(scutil --get ComputerName 2>/dev/null || hostname -s)"
HOST_KNOWN=0
for known in "${RECORD_HOSTS[@]}"; do
  [ "$HOST_NAME" != "$known" ] || HOST_KNOWN=1
done
[ "$HOST_KNOWN" -eq 1 ] \
  || die "This machine is $HOST_NAME. A certification is recorded on one of: ${RECORD_HOSTS[*]}."

# --- 1. The VM result, from the logs of a certify.sh run ---------------------

if [ -z "$BOOTSTRAP_LOG" ]; then
  # A glob lists names in order, and the stamp in the name sorts by time, so
  # the last one is the newest. Only a full run writes a bootstrap log.
  for candidate in "$LOG_DIR"/bootstrap-*.log; do
    [ -e "$candidate" ] || continue
    BOOTSTRAP_LOG="$candidate"
  done
  [ -n "$BOOTSTRAP_LOG" ] || die "No bootstrap log in $LOG_DIR. Run ./certification/certify.sh first."
fi
[ -f "$BOOTSTRAP_LOG" ] || die "No such log: $BOOTSTRAP_LOG"

log "Reading the VM result from $(basename "$BOOTSTRAP_LOG")"

# A value certify.sh wrote after "== What this run built ==". The last one
# wins, and nothing above that heading is read: the lines before it are the
# guest's own output.
built() {
  awk -v key="$1" '
    /^== What this run built ==$/ { on = 1; next }
    on && index($0, key) == 1 { value = substr($0, length(key) + 1); sub(/^ +/, "", value) }
    END { print value }
  ' "$BOOTSTRAP_LOG"
}

VERDICT="$(built 'Verdict:')"
BUILT_BRANCH="$(built 'Branch:')"
BUILT_COMMIT="$(built 'Commit:')"
BUILT_TREE="$(built 'Tree:')"
GUEST="$(built 'Guest:')"
VERIFY_LOG_NAME="$(built 'Verify log:')"

[ -n "$VERDICT" ] \
  || die "$(basename "$BOOTSTRAP_LOG") has no verdict.
   The run did not finish, or it was made by a certify.sh from before record.sh existed."
[ "$VERDICT" = "CERTIFIED" ] \
  || die "That run was $VERDICT. Only a CERTIFIED run is recorded."
[[ "$BUILT_COMMIT" =~ $SHA_PATTERN ]] && [[ "$BUILT_TREE" =~ $SHA_PATTERN ]] \
  || die "$(basename "$BOOTSTRAP_LOG") does not name the commit and the tree the VM built."
[ -n "$BUILT_BRANCH" ] || die "$(basename "$BOOTSTRAP_LOG") does not name the branch the VM built."
[ -n "$GUEST" ] || die "$(basename "$BOOTSTRAP_LOG") does not describe the guest."

# The verify log is named in the bootstrap log, and is looked for beside it.
case "$VERIFY_LOG_NAME" in
  ''|*/*) die "$(basename "$BOOTSTRAP_LOG") does not name its verify log." ;;
esac
VM_VERIFY_LOG="$(dirname "$BOOTSTRAP_LOG")/$VERIFY_LOG_NAME"
[ -f "$VM_VERIFY_LOG" ] || die "The run's verify log is missing: $VM_VERIFY_LOG"

VM_COUNTS="$(verify_counts "$VM_VERIFY_LOG")"
[[ "$VM_COUNTS" =~ $COUNTS_PATTERN ]] \
  || die "$VERIFY_LOG_NAME has no VERIFY-COMPLETE line: verify.sh did not run to its end in the VM."
[ "$(counts_failed "$VM_COUNTS")" = "0" ] \
  || die "$VERIFY_LOG_NAME reports failures: $(counts_sentence "$VM_COUNTS")."

echo "   The VM built $BUILT_BRANCH at $BUILT_COMMIT" >&2
echo "   Tree $BUILT_TREE" >&2
echo "   $(counts_sentence "$VM_COUNTS")" >&2

# --- 2. The commit to certify ------------------------------------------------

log "Fetching main and the certified/ tags from origin"
repo fetch --quiet origin \
    '+refs/heads/main:refs/remotes/origin/main' \
    'refs/tags/certified/*:refs/tags/certified/*' \
  || die "Could not fetch from origin."

COMMIT="$(repo rev-parse --verify --quiet "${COMMIT_ARG:-origin/main}^{commit}")" \
  || die "Not a commit: ${COMMIT_ARG:-origin/main}"
repo merge-base --is-ancestor "$COMMIT" origin/main \
  || die "$COMMIT is not on origin/main. Only a commit on main is certified."
SHORT="$(repo rev-parse --short=7 "$COMMIT")"
echo "   The commit to certify is $COMMIT" >&2

EXISTING="$(repo tag --points-at "$COMMIT" --list 'certified/*')"
[ -z "$EXISTING" ] || die "$SHORT is already recorded: $EXISTING"

TODAY="$(date +%Y-%m-%d)"
TAG="certified/$TODAY-$SHORT"

# Where stable is on origin, and whether this commit moves it.
#
# stable is the branch the Macs follow. It only ever moves forward, to a commit
# this script has just tagged, so it should always be a commit of main that is
# behind the one being recorded. Three cases are fine: there is no stable yet
# and this creates it, stable is behind and moves here, or stable is already
# at or ahead of this commit (an older commit recorded with --commit) and is
# left alone. Anything else, a stable that is not a commit of main above all,
# means stable has been pushed to by hand, and the script stops before it adds
# to that.
STABLE_LINE="$(GIT_TERMINAL_PROMPT=0 git -C "$REPO_ROOT" ls-remote --heads origin refs/heads/stable)" \
  || die "Could not ask origin where stable is."
STABLE_AT="${STABLE_LINE%%[[:space:]]*}"
MOVE_STABLE=1
if [ -z "$STABLE_AT" ]; then
  echo "   There is no stable branch yet. Recording this creates it." >&2
elif ! [[ "$STABLE_AT" =~ $SHA_PATTERN ]]; then
  die "Could not read where stable is from: $STABLE_LINE"
elif ! repo cat-file -e "$STABLE_AT^{commit}" 2>/dev/null; then
  die "stable is at $STABLE_AT, a commit this checkout does not have. It is not on main."
elif ! repo merge-base --is-ancestor "$STABLE_AT" origin/main; then
  # Asked before stable is compared with this commit. A commit on a branch
  # that was made from main's tip is ahead of this one and is still not a
  # commit of main: without this it would pass as "at or ahead".
  die "stable is at $STABLE_AT, which is not a commit of main.
   stable should hold only commits of main. Find out who moved it before recording."
elif [ "$STABLE_AT" = "$COMMIT" ] || repo merge-base --is-ancestor "$COMMIT" "$STABLE_AT"; then
  MOVE_STABLE=0
  echo "   stable is at ${STABLE_AT:0:7}, at or ahead of this commit. It stays there." >&2
elif repo merge-base --is-ancestor "$STABLE_AT" "$COMMIT"; then
  echo "   stable is at ${STABLE_AT:0:7} and will move to $SHORT." >&2
else
  die "stable is at $STABLE_AT, which is neither behind nor ahead of $SHORT.
   stable should hold only commits of main. Find out who moved it before recording."
fi

# What gets pushed: the tag, and stable when it moves.
#
# Two lists, because the tag does not exist until step 8. The dry run in step 5
# has only the commit to offer for the tag's name. The real push names the tag
# itself: pushing the commit to refs/tags/ would make a tag on origin that has
# no message, in place of the annotated one made here.
PUSH_CHECK_REFS=("$COMMIT:refs/tags/$TAG")
PUSH_REFS=("refs/tags/$TAG:refs/tags/$TAG")
if [ "$MOVE_STABLE" -eq 1 ]; then
  PUSH_CHECK_REFS+=("$COMMIT:refs/heads/stable")
  PUSH_REFS+=("$COMMIT:refs/heads/stable")
fi

# --- 3. The trees -------------------------------------------------------------

TREE="$(repo rev-parse "$COMMIT^{tree}")"
[ "$TREE" = "$BUILT_TREE" ] \
  || die "The trees differ, so the VM did not build what is at $SHORT.
   Tree of $SHORT:  $TREE
   Tree the VM built: $BUILT_TREE
   Certify main: ./certification/certify.sh"

# The same question about the checks. certify.sh keeps the verify.sh it ran in
# the VM beside the logs. A branch run stops unless that copy is the branch's
# own, but a run of main only warns when the checkout it was started from was
# at another commit or had an edited verify.sh. Such a run is CERTIFIED by
# checks that are not this commit's, so it is refused here.
VM_VERIFY_SNAPSHOT="${VM_VERIFY_LOG%.log}.sh"
[ -f "$VM_VERIFY_SNAPSHOT" ] \
  || die "The verify.sh that checked the VM is missing: $VM_VERIFY_SNAPSHOT"
repo show "$COMMIT:certification/verify.sh" >"$WORK_DIR/verify-at-commit.sh" \
  || die "Could not read certification/verify.sh at $SHORT."
cmp -s "$WORK_DIR/verify-at-commit.sh" "$VM_VERIFY_SNAPSHOT" \
  || die "The VM was checked by a verify.sh that is not the one at $SHORT.
   Compare: git show $SHORT:certification/verify.sh | diff - $VM_VERIFY_SNAPSHOT
   Certify again from a checkout that is at the commit, with no uncommitted changes."

# --- 4. The chezmoi source on this Mac ----------------------------------------

command -v chezmoi >/dev/null 2>&1 || die "chezmoi not found."
SOURCE="$(chezmoi source-path)" || die "Could not ask chezmoi for its source path."

# The source is at the commit, with nothing uncommitted anywhere in it and
# nothing untracked. chezmoi applies the files, not the commit: an edited
# dot_Brewfile, applied, gives a ~/.Brewfile that verify.sh passes and a
# `chezmoi status` that is empty, for a tree the VM never built.
#
# Asked twice: here, and again just before the tag is made. verify.sh takes
# minutes. A `chezmoi update` in that time would have verify.sh check a newer
# commit, and its result would be recorded against this one.
check_source() {
  local head changes branch advice
  head="$(git -C "$SOURCE" rev-parse HEAD)" || die "The chezmoi source at $SOURCE is not a git checkout."
  if [ "$head" != "$COMMIT" ]; then
    # Say what to do about it. A source on stable cannot get there with an
    # update: stable does not have the commit until this script has run.
    branch="$(git -C "$SOURCE" symbolic-ref --quiet --short HEAD || true)"
    if [ "$branch" = "stable" ]; then
      advice="This Mac follows stable, which gets the commit only when it is recorded.
   Record from the Mac being developed on, or make this one that Mac:
     chezmoi git -- fetch origin && chezmoi git -- switch main && chezmoi update"
    else
      advice="Run: chezmoi update"
    fi
    die "The chezmoi source on this Mac is at $head, not $COMMIT.$1
   verify.sh here would check another commit. $advice"
  fi
  changes="$(git -C "$SOURCE" status --porcelain)" \
    || die "Could not read the state of the chezmoi source at $SOURCE."
  [ -z "$changes" ] \
    || die "The chezmoi source at $SOURCE has uncommitted changes:$1
$changes
   What is applied on this Mac is then not what is at $SHORT."
}
check_source ""

# --- 5. Whether the tag can be pushed, before the slow part -------------------

# The script only runs git push. How the push authenticates is the machine's
# business. GIT_TERMINAL_PROMPT=0 makes a missing credential fail here, and
# not wait for a password nobody is watching for.
log "Checking that $TAG can be pushed"
PUSH_CHECK="$(GIT_TERMINAL_PROMPT=0 git -C "$REPO_ROOT" push --dry-run --atomic origin "${PUSH_CHECK_REFS[@]}" 2>&1)" \
  || die "This session cannot push the tag$([ "$MOVE_STABLE" -eq 0 ] || echo " and stable") to origin:
$PUSH_CHECK"

# --- 6. verify.sh on this Mac -------------------------------------------------

HOST_OS="$(sw_vers -productVersion)"
STAMP="$(date +%Y%m%d-%H%M%S)"
HOST_LOG="$LOG_DIR/verify-$STAMP-host-$HOST_NAME.log"
mkdir -p "$LOG_DIR"

log "Running verify.sh on $HOST_NAME. Transcript: $HOST_LOG"
echo "   verify.sh reads sshd's settings as root, so sudo asks for the password." >&2
sudo -v || die "sudo was refused. verify.sh needs it to read sshd's settings."

# The commit's own verify.sh, taken from git in step 3, and not the copy in the
# chezmoi source: the checks are then the commit's whatever happens to that
# checkout. Without SKIP_MAS: nothing is excluded on real hardware. Never trust
# the exit status alone; the VERIFY-COMPLETE line is what says verify.sh
# reached its end.
set +e
env -u SKIP_MAS /bin/bash "$WORK_DIR/verify-at-commit.sh" 2>&1 | tee "$HOST_LOG"
HOST_STATUS=${PIPESTATUS[0]}
set -e

HOST_COUNTS="$(verify_counts "$HOST_LOG")"
[[ "$HOST_COUNTS" =~ $COUNTS_PATTERN ]] \
  || die "verify.sh did not run to its end on $HOST_NAME. See $HOST_LOG"
[ "$(counts_failed "$HOST_COUNTS")" = "0" ] && [ "$HOST_STATUS" -eq 0 ] \
  || die "verify.sh failed on $HOST_NAME: $(counts_sentence "$HOST_COUNTS"). See $HOST_LOG"

# --- 7. What triggered the run, when no commit says ---------------------------

# Not asked for. What changed since the last certification is in the commits
# between the two tags: git log <previous tag>..<this tag>. --reason is for a
# trigger that is in no commit, such as a macOS upgrade, a new base VM, or a
# second run of a commit that has not changed. The tag then gets one more
# line, "Triggered by:".
if [ "$REASON_GIVEN" -eq 1 ]; then
  one_line "$REASON" || die "The reason has to be one line of text, and not empty."
fi

# --- 8. The tag ---------------------------------------------------------------

check_source "
   It changed while this script ran, so the verify.sh result above may be for another commit."

if [ "$BUILT_BRANCH" = "main" ]; then
  BUILT_FROM="main"
else
  BUILT_FROM="branch $BUILT_BRANCH at ${BUILT_COMMIT:0:7}"
fi

MESSAGE_FILE="$WORK_DIR/message"

cat >"$MESSAGE_FILE" <<EOF
Certified $SHORT on $TODAY

VM result:            $(counts_sentence "$VM_COUNTS")
Real-hardware result: $(counts_sentence "$HOST_COUNTS")

Guest:        $GUEST
Host:         $HOST_NAME, macOS $HOST_OS
Built from:   $BUILT_FROM
Tree:         $TREE
EOF
[ "$REASON_GIVEN" -eq 0 ] || printf 'Triggered by: %s\n' "$REASON" >>"$MESSAGE_FILE"

log "The tag"
printf '   %s -> %s\n' "$TAG" "$COMMIT" >&2
[ "$MOVE_STABLE" -eq 0 ] || printf '   stable -> %s\n' "$COMMIT" >&2
printf '\n' >&2
sed 's/^/   /' "$MESSAGE_FILE" >&2

if [ "$DRY_RUN" -eq 1 ]; then
  printf '\nDry run: no tag was made and nothing was pushed.\n' >&2
  exit 0
fi

# On the commit, by name. The chezmoi source has just been found at the same
# commit a second time, but the tag must not depend on that check, or on any
# checkout staying where it is. --no-sign, because these tags are
# not signed whatever tag.gpgSign says.
repo tag --annotate --no-sign --file "$MESSAGE_FILE" "$TAG" "$COMMIT" \
  || die "Could not create the tag $TAG."

# That one tag, by name, never --tags, and stable with it when it moves.
# --atomic: both arrive or neither does, so stable is never at a commit that
# has no tag. Without --force, so stable can only move forward.
if ! GIT_TERMINAL_PROMPT=0 git -C "$REPO_ROOT" push --atomic origin "${PUSH_REFS[@]}"; then
  repo tag --delete "$TAG" >/dev/null 2>&1 || true
  die "Could not push $TAG. The local tag was removed, so this can be run again."
fi

printf '\n\033[32m✅ Recorded\033[0m -- %s on %s\n' "$TAG" "$SHORT"
printf '   git tag -n99 -l %s\n' "'$TAG'"
if [ "$MOVE_STABLE" -eq 1 ]; then
  printf '   stable is now at %s. On each Mac that follows stable: chezmoi update\n' "$SHORT"
fi
