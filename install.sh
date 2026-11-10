#!/usr/bin/env bash
# One-click deployment for the WeChat ClawBot bridge (Muse / Hatch runtime).
#
# What it does, in order:
#   1. Relocates this tree to ~/workspace/wechat-bridge (the fixed location
#      the hook scripts, the executor manual and the doctor all expect),
#      unless it is already there.
#   2. Checks the environment: Python >= 3.12, ffmpeg, openssl, jq, systemd.
#   3. Installs Python dependencies into vendor/py INSIDE the tree
#      (qrcode, cryptography, silk-python) so they survive VM replacement;
#      nothing is installed system-wide.
#   4. Writes state/proxy.env from this shell's proxy variables, so the
#      systemd service can use the same egress proxy as agent shells.
#   5. Installs and enables the systemd unit (starts only once credentials
#      exist - see ConditionPathExists - so enabling now is safe).
#   6. Copies the hook scripts to ~/hooks/scripts/ (registering the hooks
#      themselves is an agent step - see DEPLOY.md step 3).
#   7. Runs the offline test suite (skip with --skip-tests) and the doctor.
#
# After it finishes, an agent still has to: register the three hooks,
# generate the login QR, and start the service once the user has scanned.
# DEPLOY.md spells those steps out.
set -euo pipefail

BRIDGE_DIR="$HOME/workspace/wechat-bridge"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKIP_TESTS=0
for a in "$@"; do [ "$a" = "--skip-tests" ] && SKIP_TESTS=1; done
SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"
log() { printf '[install] %s\n' "$*"; }
die() { printf '[install] ERROR: %s\n' "$*" >&2; exit 1; }

# --- 1. location -----------------------------------------------------------
if [ "$SRC_DIR" != "$BRIDGE_DIR" ]; then
  log "relocating $SRC_DIR -> $BRIDGE_DIR"
  mkdir -p "$BRIDGE_DIR"
  (cd "$SRC_DIR" && tar --exclude='./.git' --exclude='./state' --exclude='./vendor' \
      --exclude='./inbox' --exclude='./logs' --exclude='./history' --exclude='./backups' \
      -cf - .) | (cd "$BRIDGE_DIR" && tar -xf -)
  cd "$BRIDGE_DIR"
else
  cd "$SRC_DIR"
fi

# --- 2. environment checks -------------------------------------------------
command -v python3 >/dev/null || die "python3 not found"
python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 12) else 1)' \
  || die "Python >= 3.12 required"
command -v ffmpeg >/dev/null || die "ffmpeg not found (needed for voice/video)"
command -v openssl >/dev/null || die "openssl not found (needed for media decryption)"
command -v jq >/dev/null || die "jq not found (needed by the hook scripts)"
command -v systemctl >/dev/null || die "systemctl not found (the service needs systemd)"
log "environment checks passed ($(python3 --version 2>&1), $(ffmpeg -version 2>/dev/null | head -1 | cut -d' ' -f1-3))"

# --- 3. python dependencies into vendor/py ---------------------------------
log "installing python dependencies into vendor/py (qrcode, cryptography, silk-python)"
python3 -m pip install --quiet --upgrade --target vendor/py 'qrcode[pil]' cryptography silk-python \
  || die "pip install failed - check network/proxy, then re-run"
python3 -c '
import sys; sys.path.insert(0, "vendor/py")
import qrcode, cryptography, pysilk
print("[install] vendor deps import cleanly")' || die "vendor deps do not import"

# --- 4. proxy env for the service ------------------------------------------
if python3 bridge.py write-proxy-env >/dev/null 2>&1; then
  log "state/proxy.env written from this shell's proxy variables"
else
  log "no proxy variables in this shell - the service will try a direct connection"
fi

# --- 5. systemd unit ---------------------------------------------------------
[ -f wechat-bridge.service.template ] || cp wechat-bridge.service wechat-bridge.service.template
sed -e "s|/home/USERNAME/workspace/wechat-bridge|$BRIDGE_DIR|g" \
    -e "s|^User=USERNAME|User=$(id -un)|" \
    -e "s|^Environment=PYTHONUNBUFFERED=1|Environment=PYTHONUNBUFFERED=1\nEnvironment=HOME=$HOME|" \
    wechat-bridge.service.template > wechat-bridge.service
$SUDO cp wechat-bridge.service /etc/systemd/system/wechat-bridge.service
$SUDO systemctl daemon-reload
$SUDO systemctl enable wechat-bridge >/dev/null 2>&1 || true
log "systemd unit installed and enabled (starts once credentials exist)"

# --- 6. hook scripts ---------------------------------------------------------
mkdir -p "$HOME/hooks/scripts"
cp hooks/wechat-bridge-inbox.sh hooks/wechat-long-task-watch.sh hooks/wechat-window-reminder.sh "$HOME/hooks/scripts/"
chmod +x "$HOME/hooks/scripts/wechat-bridge-inbox.sh" "$HOME/hooks/scripts/wechat-long-task-watch.sh" "$HOME/hooks/scripts/wechat-window-reminder.sh"
log "hook scripts copied to ~/hooks/scripts/ (registration is an agent step - DEPLOY.md step 3)"

# --- 7. tests + doctor -------------------------------------------------------
if [ "$SKIP_TESTS" -eq 0 ]; then
  log "running the offline test suite (about 4 minutes)..."
  python3 tests/run_all.py > /tmp/wechat-bridge-tests.log 2>&1 \
    && log "test suite: ALL OK (log: /tmp/wechat-bridge-tests.log)" \
    || log "test suite: some suites failed - see /tmp/wechat-bridge-tests.log and DEPLOY.md (known upstream notes)"
else
  log "test suite skipped (--skip-tests)"
fi
python3 ops/doctor.py 2>&1 | tail -3 || true

cat <<'EOF'
[install] done. Remaining steps need the agent + the owner (see DEPLOY.md):
  1. Register the three hooks from hooks/*.json (inbox 5 s, long-task 10 s, window-reminder 600 s), dry-run, enable.
  2. python3 bridge.py login  -> send qrcode.png to the owner (it really expires in about 2 minutes;
     wait-login auto-refreshes the same file), run python3 bridge.py wait-login in the background.
  3. After "connected": systemctl start wechat-bridge, re-run ops/doctor.py (expect 0 FAIL),
     and ask the owner to send the bot a first message right away.
EOF
