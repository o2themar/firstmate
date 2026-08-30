#!/usr/bin/env bash
# Evidence driver: the zellij backend path of the claim refusal. Drives the REAL
# bin/fm-spawn.sh with a recording fake `zellij` whose pane->tab lookup starts
# failing mid-spawn (the transient CLI failure that used to degrade the close to
# close-pane and strand an empty tab). Prints the operator output plus the exact
# zellij commands firstmate issued.
set -u
WT_ROOT=${1:?worktree root}
. "$WT_ROOT/tests/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-zj-evidence)
fm_git_identity fmtest fmtest@example.invalid

PROJ="$TMP_ROOT/acme"
git init -q -b main "$PROJ"; git -C "$PROJ" commit -q --allow-empty -m init
fm_git_add_origin "$PROJ" "$PROJ.origin.git"
WT="$TMP_ROOT/pool/wt1"; mkdir -p "$TMP_ROOT/pool"
git -C "$PROJ" worktree add -q --detach "$WT" >/dev/null 2>&1
HOME_DIR="$TMP_ROOT/home"; mkdir -p "$HOME_DIR/data" "$HOME_DIR/state"

dir="$TMP_ROOT/fake"; FAKEBIN=$(fm_fakebin "$dir")
cat > "$FAKEBIN/zellij" <<SH
#!/usr/bin/env bash
set -u
FM_FAKE_ZJ_STATE=\${FM_FAKE_ZJ_STATE:-"$dir/zjstate"}
SH
cat >> "$FAKEBIN/zellij" <<'SH'
mkdir -p "$FM_FAKE_ZJ_STATE"; tabs="$FM_FAKE_ZJ_STATE/tabs"; dumps="$FM_FAKE_ZJ_STATE/dumps"
: >> "$tabs"; [ -f "$dumps" ] || echo 0 > "$dumps"
[ -z "${FM_ZJ_REC:-}" ] || printf 'zellij %s\n' "$*" >> "$FM_ZJ_REC"
zj_flag_value() { local want=$1 prev= a; shift; for a in "$@"; do [ "$prev" = "$want" ] && { printf '%s\n' "$a"; return 0; }; prev=$a; done; return 1; }
zj_tabs_json() { local id name first=1; printf '['; while IFS=$'\t' read -r id name; do [ -n "$id" ] || continue; [ "$first" = 1 ] || printf ','; printf '{"tab_id":%s,"name":"%s","active":false}' "$id" "$name"; first=0; done < "$tabs"; printf ']\n'; }
case "${1:-}" in
  --version) printf 'zellij 0.44.0\n'; exit 0 ;;
  list-sessions) printf '%s\n' "${FM_FAKE_ZJ_SESSION:-firstmate}"; exit 0 ;;
  attach) exit 0 ;;
esac
case "${4:-}" in
  list-tabs) zj_tabs_json; exit 0 ;;
  new-tab) name=$(zj_flag_value --name "$@") || name=; printf '4\t%s\n' "$name" >> "$tabs"; printf '4\n'; exit 0 ;;
  list-panes) [ "$(cat "$dumps")" -lt "${FM_FAKE_ZJ_PANES_FAIL_AFTER_DUMPS:-9999}" ] || exit 1; printf '[{"id":7,"tab_id":4,"is_plugin":false}]\n'; exit 0 ;;
  dump-screen) echo $(( $(cat "$dumps") + 1 )) > "$dumps"; printf '%s\n%s\n%s\n' '__FM_ZELLIJ_CWD_BEGIN__' "${FM_FAKE_PANE_PATH:-}" '__FM_ZELLIJ_CWD_END__'; exit 0 ;;
  close-tab-by-id) grep -v "^${5:-}$(printf '\t')" "$tabs" > "$tabs.next" || true; mv "$tabs.next" "$tabs"; exit 0 ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/zellij"; fm_fake_exit0 "$FAKEBIN" treehouse
REC="$TMP_ROOT/zellij.log"; : > "$REC"

{
  echo 'window=firstmate:9'
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo 'harness=codex'; echo 'kind=ship'; echo 'backend=zellij'
} > "$HOME_DIR/state/docs-sweep.meta"
fm_test_spawn_brief "$HOME_DIR" search-fix brief

cat <<EOT
================================================================================
 fm-spawn claim refusal on the zellij backend
 The pane->tab lookup fails transiently mid-spawn; the refusal must still retire
 the TAB (the name a retry collides on), not just the pane.
================================================================================
EOT
printf '\n\033[1m$ fm-spawn.sh search-fix %s codex --backend zellij --mode no-mistakes --yolo off\033[0m\n' "$PROJ"
FM_ZJ_REC="$REC" FM_FAKE_ZJ_PANES_FAIL_AFTER_DUMPS=2 \
  fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" \
    search-fix "$PROJ" codex --backend zellij --mode no-mistakes --yolo off
echo "exit status: $?"

printf '\n\033[1m$ grep -E "new-tab|close-tab-by-id|close-pane|list-panes" $FM_ZJ_REC\033[0m\n'
grep -E 'new-tab|close-tab-by-id|close-pane|list-panes' "$REC" || echo '(none)'
printf '\n# -> the tab it created (id 4) was closed by id; close-pane was never used,\n'
printf '#    so no empty tab named fm-search-fix survives to refuse the retry.\n'

printf '\n\033[1m$ zellij -s firstmate action query-tab-names   # live tab inventory after the refusal\033[0m\n'
PATH="$FAKEBIN:$PATH" zellij --session firstmate action list-tabs

LABEL=$(sed -n 's/.*--name \(.*\)$/\1/p' "$REC" | head -1)
printf '\n\033[1m$ fm_backend_endpoint_blocks_respawn zellij firstmate:7 %s\033[0m\n' "$LABEL"
PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' bash -c '
  . "$0/bin/fm-backend.sh"
  if fm_backend_endpoint_blocks_respawn zellij firstmate:7 "$1"; then
    echo "blocks respawn: YES (manual cleanup required)"
  else
    echo "blocks respawn: NO  (the slot is retryable as-is)"
  fi' "$WT_ROOT" "$LABEL"
printf '\n============================== end of transcript ===============================\n'
