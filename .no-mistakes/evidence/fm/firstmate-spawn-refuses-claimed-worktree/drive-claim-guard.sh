#!/usr/bin/env bash
# Evidence driver: drives the REAL bin/fm-spawn.sh through the operator-visible
# lifecycle of the durable worktree-claim guard, over a hermetic temp git repo
# and a recording fake tmux. Nothing here asserts; it only prints the CLI
# transcript an operator would see.
set -u
WT_ROOT=${1:?worktree root}
. "$WT_ROOT/tests/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-claim-evidence)
fm_git_identity fmtest fmtest@example.invalid

. "$WT_ROOT/tests/fm-tangle-guard.test.sh.functions" 2>/dev/null || true

make_repo() {
  local dir=$1
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  fm_git_add_origin "$dir" "$dir.origin.git"
  printf '%s\n' "$dir"
}

# Recording fake tmux with real window liveness (same model the suite uses).
make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
FM_FAKE_TMUX_LIVE=\${FM_FAKE_TMUX_LIVE:-"$dir/live-windows"}
SH
  cat >> "$fakebin/tmux" <<'SH'
[ -n "${FM_TMUX_REC:-}" ] && printf 'tmux %s\n' "$*" >> "$FM_TMUX_REC"
: >> "$FM_FAKE_TMUX_LIVE"
live_names() { local n; for n in ${FM_FAKE_WINDOWS:-}; do printf '%s\n' "$n"; done; cat "$FM_FAKE_TMUX_LIVE"; }
flag_value() { local want=$1 prev=; shift; for a in "$@"; do [ "$prev" = "$want" ] && { printf '%s\n' "$a"; return 0; }; prev=$a; done; return 1; }
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{pane_current_command}"*) printf '%s\n' "${FM_FAKE_PANE_COMMAND:-zsh}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  new-window) name=$(flag_value -n "$@") || name=; [ -z "$name" ] || printf '%s\n' "$name" >> "$FM_FAKE_TMUX_LIVE"; printf '@spawnwid\n'; exit 0 ;;
  kill-window)
    if [ "${FM_FAKE_TMUX_KILL_NOOP:-0}" != 1 ]; then
      target=$(flag_value -t "$@") || target=; name=${target#*:}; name=${name#=}
      grep -vx "$name" "$FM_FAKE_TMUX_LIVE" > "$FM_FAKE_TMUX_LIVE.next" || true
      mv "$FM_FAKE_TMUX_LIVE.next" "$FM_FAKE_TMUX_LIVE"
    fi
    exit 0 ;;
  list-windows) live_names; exit 0 ;;
  has-session|new-session|send-keys|set-window-option) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state"
PROJ=$(make_repo "$TMP_ROOT/acme")
POOL_A="$TMP_ROOT/pool/wt1"
POOL_B="$TMP_ROOT/pool/wt2"
OWN="$TMP_ROOT/pool/wt3"
mkdir -p "$TMP_ROOT/pool"
git -C "$PROJ" worktree add -q --detach "$POOL_A" >/dev/null 2>&1
git -C "$PROJ" worktree add -q --detach "$POOL_B" >/dev/null 2>&1
git -C "$PROJ" worktree add -q --detach "$OWN" >/dev/null 2>&1
# The incumbent's record points at the SAME worktree through a symlink and a
# trailing slash - the canonicalization case.
ln -s "$POOL_A" "$TMP_ROOT/pool/wt1-alias"
FAKEBIN=$(make_fakebin "$TMP_ROOT/fake")
REC="$TMP_ROOT/tmux.log"
: > "$REC"

banner() { printf '\n\033[1m$ %s\033[0m\n' "$*"; }
say()    { printf '\n# %s\n' "$*"; }

cat <<EOT
================================================================================
 fm-spawn durable worktree-claim guard - operator transcript
 backend: tmux (recording fake)   project: $PROJ
 pool worktrees: $POOL_A (claimed)  $POOL_B (free)  $OWN (task auth-relaunch's own)
================================================================================
EOT

say "Existing crewmate 'auth-fix' durably records pool slot wt1 - through a"
say "symlink with a trailing slash, to show path canonicalization."
{
  echo 'window=firstmate:fm-auth-fix'
  echo 'endpoint_task_id=auth-fix'
  echo "worktree=$TMP_ROOT/pool/wt1-alias/"
  echo "project=$PROJ"
  echo 'harness=codex'
  echo 'kind=ship'
} > "$HOME_DIR/state/auth-fix.meta"
banner "cat \$FM_HOME/state/auth-fix.meta"
cat "$HOME_DIR/state/auth-fix.meta"

run() {  # <id> <pane-path> [extra fm-spawn args...]
  local id=$1 pane=$2; shift 2
  fm_test_spawn_brief "$HOME_DIR" "$id" brief
  FM_TMUX_REC="$REC" fm_test_run_spawn "$HOME_DIR" "$pane" "$FAKEBIN" \
    "$id" "$PROJ" codex --mode no-mistakes --yolo off "$@"
}

say "1) Treehouse hands the SAME slot (real path, no trailing slash) to a new"
say "   task 'auth'. The guard refuses before any branch creation or launch."
banner "fm-spawn.sh auth $PROJ codex --mode no-mistakes --yolo off"
: > "$REC"
run auth "$POOL_A"; echo "exit status: $?"

banner "ls \$FM_HOME/state/"
ls "$HOME_DIR/state/"
say "-> no auth.meta: the refused contender published no durable record."

banner "grep -E 'new-window|kill-window|send-keys' \$FM_TMUX_REC"
grep -E 'new-window|kill-window|send-keys' "$REC" || echo '(none)'
say "-> the endpoint it created was retired; no agent launch was ever typed."

say "2) Retry the SAME task into the SAME slot - no manual cleanup in between."
say "   It is refused again (the claim still stands), not by a leftover window."
banner "fm-spawn.sh auth $PROJ ... (retry)"
run auth "$POOL_A" 2>&1 | sed -n '1,4p'; echo "exit status: ${PIPESTATUS[0]}"

say "3) The owner finished but its teardown aborted, leaving the record behind."
say "   The operator removes the record the refusal named, then retries."
banner "rm \$FM_HOME/state/auth-fix.meta && fm-spawn.sh auth ..."
rm "$HOME_DIR/state/auth-fix.meta"
: > "$REC"
run auth "$POOL_A"; echo "exit status: $?"
banner "grep -c 'send-keys' \$FM_TMUX_REC"
grep -c 'send-keys' "$REC"
say "-> the slot was reusable with zero manual endpoint cleanup."

say "4) A genuinely free pool slot is unaffected."
banner "fm-spawn.sh billing $PROJ ... (into $POOL_B)"
run billing "$POOL_B"; echo "exit status: $?"

say "5) --relaunch into the task's OWN recorded worktree stays allowed."
{
  echo 'window=firstmate:fm-auth-relaunch'
  echo 'endpoint_task_id=auth-relaunch'
  echo "worktree=$OWN/"
  echo "project=$PROJ"
  echo 'harness=codex'
  echo 'kind=ship'
  echo 'mode=no-mistakes'
  echo 'yolo=off'
  echo "tasktmp=/tmp/fm-auth-relaunch"
  echo 'model=default'
  echo 'effort=default'
} > "$HOME_DIR/state/auth-relaunch.meta"
fm_test_spawn_brief "$HOME_DIR" auth-relaunch brief
banner "fm-spawn.sh auth-relaunch --relaunch"
FM_TMUX_REC="$REC" FM_FAKE_WINDOWS='fm-auth-relaunch' FM_FAKE_PANE_COMMAND=zsh \
  fm_test_run_spawn "$HOME_DIR" "$OWN" "$FAKEBIN" auth-relaunch --relaunch
echo "exit status: $?"

say "6) When the best-effort backend close silently fails, the survivor is"
say "   NAMED instead of being reported as a clean retirement."
{
  echo 'window=firstmate:fm-auth-fix'
  echo "worktree=$POOL_A"
  echo "project=$PROJ"
  echo 'harness=codex'
  echo 'kind=ship'
} > "$HOME_DIR/state/auth-fix.meta"
: > "$REC"
banner "FM_FAKE_TMUX_KILL_NOOP=1 fm-spawn.sh stuck $PROJ ..."
fm_test_spawn_brief "$HOME_DIR" stuck brief
FM_TMUX_REC="$REC" FM_FAKE_TMUX_KILL_NOOP=1 \
  fm_test_run_spawn "$HOME_DIR" "$POOL_A" "$FAKEBIN" stuck "$PROJ" codex --mode no-mistakes --yolo off
echo "exit status: $?"
say "   and the named leftover is exactly what refuses the next attempt:"
banner "fm-spawn.sh stuck $PROJ ... (next attempt)"
FM_TMUX_REC="$REC" fm_test_run_spawn "$HOME_DIR" "$POOL_A" "$FAKEBIN" stuck "$PROJ" codex --mode no-mistakes --yolo off
echo "exit status: $?"

printf '\n================================ end of transcript =============================\n'
