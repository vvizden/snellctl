#!/usr/bin/env bash
# Disposable systemd container ONLY; never run on a production server.
set -Eeuo pipefail
[[ ${SNELLCTL_DISPOSABLE_TEST:-} == YES && -f /.dockerenv ]] || { printf 'Requires a disposable container\n' >&2; exit 1; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/snell.sh"
[[ ! -e "$BASE" ]] || { printf 'Requires a fresh container\n' >&2; exit 1; }
wait_upgrade() {
  local i
  for ((i=0; i<600; i++)); do
    if ! upgrade_running; then return; fi
    sleep 0.1
  done
  printf 'Upgrade timed out\n' >&2; exit 1
}
assert_version() { [[ $(jq -r .version "$BASE/current/metadata.json") == "$1" ]]; }
bash "$ROOT/snell.sh" install --version 5.0.1 --server 127.0.0.1 --non-interactive --yes
old=$(current_id)
# script(1) supplies a real controlling terminal and interactive confirmation.
printf 'y\n' | script -qec 'echo $$ >/tmp/snellctl-frontend.pid; exec snellctl upgrade --version 6.0.0' /tmp/snellctl-interactive.log &
terminal=$!
for ((i=0; i<1200; i++)); do
  [[ ! -e "$BASE/transaction.json" ]] || break
  sleep 0.05
done
[[ -e "$BASE/transaction.json" ]]
# Status must observe the task instead of trying recovery or taking its lock.
snellctl status >/tmp/snellctl-progress.log
grep -q 'in progress' /tmp/snellctl-progress.log
if snellctl upgrade --version 6.0.0 --yes >/tmp/snellctl-duplicate.log 2>&1; then
  printf 'Concurrent upgrade unexpectedly succeeded\n' >&2; exit 1
fi
kill -HUP "$(cat /tmp/snellctl-frontend.pid)"
wait "$terminal" || true
wait_upgrade
[[ $(systemctl show "$UPGRADE_UNIT" -p Result --value) == success ]]
assert_version 6.0.0
health_check "$(current_id)"
[[ ! -e "$BASE/transaction.json" ]]
cmp -s "$BASE/generations/$old/snell-server.conf" "$BASE/current/snell-server.conf"
journalctl -u "$UPGRADE_UNIT" --no-pager -o cat | grep -q 'Installed Snell 6.0.0'
printf 'PASS: interactive terminal hangup did not interrupt upgrade\n'
# A connected caller gets a successful exit; the retained unit can be reused.
snellctl upgrade --version 5.0.1 --allow-downgrade --yes
assert_version 5.0.1
[[ $(jq -r .channel "$BASE/current/metadata.json") == stable ]]
# Inject a startup health-check failure into a trusted test-only script.
sed '/^health_check() {/a\  [[ "$1" != "$NEW_GEN" ]] || return 1' "$ROOT/snell.sh" >/root/snellctl-fail-health.sh
chmod 0700 /root/snellctl-fail-health.sh
if bash /root/snellctl-fail-health.sh upgrade --version 6.0.0 --yes; then
  printf 'Unhealthy upgrade unexpectedly succeeded\n' >&2; exit 1
fi
assert_version 5.0.1
health_check "$(current_id)"
[[ ! -e "$BASE/transaction.json" ]]
[[ $(systemctl show "$UPGRADE_UNIT" -p Result --value) != success ]]
snellctl status >/tmp/snellctl-failed-status.log
grep -q 'failed (exit' /tmp/snellctl-failed-status.log
printf 'PASS: worker failure restores old deployment and returns failure\n'
# Failed tasks can be retried, and uninstall must remove the retained task.
snellctl upgrade --version 6.0.0 --yes
assert_version 6.0.0
snellctl uninstall --yes
[[ ! -e "$BASE" ]]
[[ $(systemctl show "$UPGRADE_UNIT" -p LoadState --value) == not-found ]]
bash "$ROOT/snell.sh" install --version 5.0.1 --server 127.0.0.1 --non-interactive --yes
health_check "$(current_id)"
snellctl uninstall --yes
printf 'PASS: failed-task retry, uninstall and reinstall\n'
