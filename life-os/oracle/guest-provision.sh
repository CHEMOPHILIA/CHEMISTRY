#!/usr/bin/env bash
# ARM64 first boot and post-reboot verification for Oracle Ubuntu 24.04.
set -Eeuo pipefail
umask 077
STATE=/var/lib/life-os
LOG=/var/log/life-os
mkdir -p "$STATE" "$LOG"
chmod 700 "$STATE" "$LOG"
exec >>"$LOG/provision.log" 2>&1
stamp(){ date -u '+%Y-%m-%dT%H:%M:%SZ'; }
status(){
  python3 - "$STATE/result.json" "$1" "$2" <<'PY'
import datetime,json,pathlib,platform,sys
pathlib.Path(sys.argv[1]).write_text(json.dumps(dict(
 state=sys.argv[2], detail=sys.argv[3],
 timestamp_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
 architecture=platform.machine(),
 boot_id=pathlib.Path("/proc/sys/kernel/random/boot_id").read_text().strip()
),indent=2)+"\n")
PY
}
failed(){
  code=$?
  echo "$(stamp) failed (exit $code)" >&2
  status FAIL "Check /var/log/life-os/provision.log (exit $code)" || true
  exit "$code"
}
trap failed ERR
[[ "$(id -u)" -eq 0 ]] || exit 1
[[ "$(uname -m)" == "aarch64" ]] || { status FAIL "Expected aarch64"; exit 1; }
[[ -d /home/ubuntu ]] || { status FAIL "Missing ubuntu account"; exit 1; }
BOOT="$(cat /proc/sys/kernel/random/boot_id)"
verify(){
  systemctl is-active --quiet docker
  docker info --format '{{.ServerVersion}} {{.Architecture}}'
  timeout 180 docker run --rm --platform linux/arm64 hello-world > "$LOG/docker-test.log"
  grep -Fq 'Hello from Docker!' "$LOG/docker-test.log"
  command -v Xvfb >/dev/null
  test -x /snap/bin/chromium
  dir=/home/ubuntu/life-os-validation
  install -d -o ubuntu -g ubuntu -m 0750 "$dir"
  printf '%s\n' '<!doctype html><html><body>LIFE_OS_RENDER_OK</body></html>' > "$dir/test.html"
  chown ubuntu:ubuntu "$dir/test.html"
  local uid
  uid="$(id -u ubuntu)"
  mkdir -p "/run/user/$uid"
  chown ubuntu:ubuntu "/run/user/$uid"
  chmod 700 "/run/user/$uid"
  timeout 180 runuser -u ubuntu -- env HOME=/home/ubuntu XDG_RUNTIME_DIR="/run/user/$uid" \
    /snap/bin/chromium --headless --disable-gpu --no-first-run --disable-dev-shm-usage \
    --user-data-dir="$dir/profile" --window-size=800,600 \
    --screenshot="$dir/render.png" "file://$dir/test.html"
  python3 - "$dir/render.png" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1])
assert p.read_bytes().startswith(b"\x89PNG\r\n\x1a\n") and p.stat().st_size>1000, "Screenshot invalid"
PY
  timeout 180 runuser -u ubuntu -- env HOME=/home/ubuntu XDG_RUNTIME_DIR="/run/user/$uid" \
    /snap/bin/chromium --headless --disable-gpu --no-first-run --disable-dev-shm-usage \
    --user-data-dir="$dir/dom-profile" --dump-dom "file://$dir/test.html" 2>/dev/null |
    grep -Fq LIFE_OS_RENDER_OK
}
stage="$(cat "$STATE/stage" 2>/dev/null || echo initial)"
echo "$(stamp) Life OS guest provisioning: $stage"
case "$stage" in
complete) exit 0 ;;
awaiting-reboot)
  if [[ "$(cat "$STATE/first-boot-id")" == "$BOOT" ]]; then
    status WAITING_FOR_REBOOT "First boot completed; waiting for new boot ID"
    exit 0
  fi
  verify
  echo complete > "$STATE/stage"
  status PASS "ARM64 Docker and Chromium rendering verified before and after reboot"
  echo "$(stamp) Post-reboot verification PASS" ;;
initial)
  status INSTALLING "Installing Docker, Xvfb and Chromium"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y docker.io snapd xvfb
  systemctl enable --now docker
  if ! snap list chromium >/dev/null 2>&1; then timeout 900 snap install chromium; fi
  verify
  printf '%s\n' "$BOOT" > "$STATE/first-boot-id"
  echo awaiting-reboot > "$STATE/stage"
  status WAITING_FOR_REBOOT "First tests passed; one reboot scheduled"
  shutdown -r +1 'Life OS one-time recovery verification' ;;
*) status FAIL "Unknown stage"; exit 1 ;;
esac
