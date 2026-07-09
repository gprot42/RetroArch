#!/usr/bin/env bash
# Deploy RetroArch IPK to a rooted webOS TV so it appears in the dock / app list.
#
# Critical: apps must be installed through com.webos.appInstallService (same path
# as ares-install / Homebrew Channel). Plain opkg or file-copy leaves binaries on
# disk but SAM never lists them → missing from the dock.
#
# Usage:
#   ./webos/deploy.sh                         # newest webos/*.ipk
#   ./webos/deploy.sh path/to/app.ipk
#   ./webos/deploy.sh --build                 # gmake ipk then deploy
#   ./webos/deploy.sh --reboot                # reboot TV after install
#   WEBOS_HOST=192.168.0.50 ./webos/deploy.sh
#
# Env:
#   WEBOS_HOST      TV IP                   (default: 192.168.0.79)
#   WEBOS_USER      SSH user                (default: root)
#   WEBOS_SSH_KEY   private key             (default: ~/.ssh/webos_deploy)
#   WEBOS_SSH_PORT  SSH port                (default: 22)
#   WEBOS_SDK       toolchain root          (for --build)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEBOS_DIR="$ROOT_DIR/webos"

WEBOS_HOST="${WEBOS_HOST:-192.168.0.79}"
WEBOS_USER="${WEBOS_USER:-root}"
WEBOS_SSH_KEY="${WEBOS_SSH_KEY:-$HOME/.ssh/webos_deploy}"
WEBOS_SSH_PORT="${WEBOS_SSH_PORT:-22}"
WEBOS_SDK="${WEBOS_SDK:-$HOME/toolchains/arm-webos-linux-gnueabi_sdk-buildroot}"

APP_ID="com.retroarch.webos"
APP_DIR="/media/developer/apps/usr/palm/applications/${APP_ID}"
REMOTE_TEMP="/media/developer/temp"
REMOTE_IPK="${REMOTE_TEMP}/${APP_ID}.ipk"

DO_BUILD=0
DO_REBOOT=0
IPK_PATH=""

usage() {
  sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

log()  { printf '==> %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --build) DO_BUILD=1; shift ;;
    --reboot) DO_REBOOT=1; shift ;;
    -*) die "unknown option: $1" ;;
    *)
      [[ -n "$IPK_PATH" ]] && die "extra argument: $1"
      IPK_PATH="$1"
      shift
      ;;
  esac
done

ssh_base() {
  ssh -i "$WEBOS_SSH_KEY" \
    -o IdentitiesOnly=yes \
    -o ConnectTimeout=15 \
    -o StrictHostKeyChecking=accept-new \
    -p "$WEBOS_SSH_PORT" \
    "${WEBOS_USER}@${WEBOS_HOST}" \
    "$@"
}

scp_base() {
  scp -i "$WEBOS_SSH_KEY" \
    -o IdentitiesOnly=yes \
    -o ConnectTimeout=15 \
    -o StrictHostKeyChecking=accept-new \
    -P "$WEBOS_SSH_PORT" \
    "$@"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

build_ipk() {
  log "Building IPK (Makefile.webos)"
  [[ -d "$WEBOS_SDK" ]] || die "toolchain not found at WEBOS_SDK=$WEBOS_SDK"

  # shellcheck disable=SC1091
  source "$WEBOS_SDK/environment-setup"
  export PATH="/opt/homebrew/opt/make/libexec/gnubin:${PATH:-}"
  export CC="$WEBOS_SDK/bin/arm-webos-linux-gnueabi-gcc"
  export CXX="$WEBOS_SDK/bin/arm-webos-linux-gnueabi-g++"
  export CPP="$WEBOS_SDK/bin/arm-webos-linux-gnueabi-cpp"
  export STRIP="$WEBOS_SDK/bin/arm-webos-linux-gnueabi-strip"
  export AR="$WEBOS_SDK/bin/arm-webos-linux-gnueabi-gcc-ar"
  export AS="$WEBOS_SDK/bin/arm-webos-linux-gnueabi-as"
  export RANLIB="$WEBOS_SDK/bin/arm-webos-linux-gnueabi-gcc-ranlib"
  export LD="$WEBOS_SDK/bin/arm-webos-linux-gnueabi-ld"

  local make_bin=gmake
  command -v gmake >/dev/null 2>&1 || make_bin=make

  (
    cd "$ROOT_DIR"
    "$make_bin" -f Makefile.webos -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)" ipk
  )
}

resolve_ipk() {
  if [[ -n "$IPK_PATH" ]]; then
    [[ -f "$IPK_PATH" ]] || die "IPK not found: $IPK_PATH"
    IPK_PATH="$(cd "$(dirname "$IPK_PATH")" && pwd)/$(basename "$IPK_PATH")"
    return
  fi
  local latest
  latest="$(ls -t "$WEBOS_DIR"/"${APP_ID}"_*.ipk 2>/dev/null | head -1 || true)"
  [[ -n "$latest" ]] || die "no IPK in $WEBOS_DIR — run with --build or pass a path"
  IPK_PATH="$latest"
}

main() {
  need_cmd ssh
  need_cmd scp
  [[ -f "$WEBOS_SSH_KEY" ]] || die "SSH key not found: $WEBOS_SSH_KEY"

  if [[ "$DO_BUILD" -eq 1 ]]; then
    build_ipk
  fi

  resolve_ipk
  local ipk_name
  ipk_name="$(basename "$IPK_PATH")"
  log "IPK: $IPK_PATH ($(du -h "$IPK_PATH" | awk '{print $1}'))"
  log "Target: ${WEBOS_USER}@${WEBOS_HOST}:${WEBOS_SSH_PORT}"

  log "Checking SSH"
  ssh_base "echo ok" >/dev/null

  log "Uploading IPK → ${REMOTE_IPK}"
  ssh_base "mkdir -p '${REMOTE_TEMP}' && chmod 777 '${REMOTE_TEMP}'"
  scp_base "$IPK_PATH" "${WEBOS_USER}@${WEBOS_HOST}:${REMOTE_IPK}"
  ssh_base "chmod 666 '${REMOTE_IPK}'"

  log "Installing via appInstallService (registers app with SAM for dock)"
  # shellcheck disable=SC2087
  ssh_base bash -s <<REMOTE
set -euo pipefail
APP_ID="$APP_ID"
APP_DIR="$APP_DIR"
REMOTE_IPK="$REMOTE_IPK"
DO_REBOOT="$DO_REBOOT"

# luna-send only returns data in interactive mode when stdin is fed.
luna_i() {
  local n="\${1:-1}"
  shift
  ( sleep 0.3; echo ) | timeout 180 luna-send -i -n "\$n" -f "\$@" 2>/dev/null
}

wait_install_idle() {
  local i out
  for i in \$(seq 1 30); do
    out=\$(luna_i 1 luna://com.webos.appInstallService/status '{}')
    echo "\$out" | grep -q '"apps": \\[\\]' && return 0
    echo "\$out" | grep -qiE 'FAILED|errorText' && return 1
    sleep 1
  done
  return 0
}

echo "--- wait for any previous install/remove ---"
wait_install_idle || true

# Preserve user data (cores, ADFs, Kickstarts, cfg) across reinstall
CFG_BACKUP="/media/developer/temp/\${APP_ID}.config.bak"
rm -rf "\${CFG_BACKUP}" 2>/dev/null || true
if [ -d "\${APP_DIR}/.config" ]; then
  echo "--- backup .config (disks, system, cores, cfg) ---"
  cp -a "\${APP_DIR}/.config" "\${CFG_BACKUP}" || true
fi

echo "--- remove existing (if any) ---"
luna_i 40 luna://com.webos.appInstallService/dev/remove "{\\"id\\":\\"\${APP_ID}\\",\\"subscribe\\":true}" > /tmp/ra-remove.json || true
wait_install_idle || true
# ensure leftovers gone
rm -rf "\${APP_DIR}" "/media/developer/apps/usr/palm/packages/\${APP_ID}" 2>/dev/null || true

echo "--- install ---"
luna_i 80 luna://com.webos.appInstallService/dev/install \\
  "{\\"id\\":\\"\${APP_ID}\\",\\"ipkUrl\\":\\"\${REMOTE_IPK}\\",\\"subscribe\\":true}" \\
  > /tmp/ra-install.json || true

# Wait for terminal status if subscription truncated
wait_install_idle || true
sleep 1

if ! grep -qiE 'SUCCESS|installed|statusValue.: 30' /tmp/ra-install.json 2>/dev/null; then
  # Still check filesystem + SAM — install events may not include SUCCESS string
  if [[ ! -x "\${APP_DIR}/retroarch" ]]; then
    echo "install log (tail):"
    tail -c 2000 /tmp/ra-install.json 2>/dev/null || true
    echo "error: binary missing after install" >&2
    exit 1
  fi
fi

if [ -d "\${CFG_BACKUP}" ]; then
  echo "--- restore .config ---"
  mkdir -p "\${APP_DIR}"
  rm -rf "\${APP_DIR}/.config"
  mv "\${CFG_BACKUP}" "\${APP_DIR}/.config"
  chmod -R a+rX "\${APP_DIR}/.config" 2>/dev/null || true
fi

echo "--- verify SAM registration ---"
luna_i 1 luna://com.webos.applicationManager/getAppInfo "{\\"id\\":\\"\${APP_ID}\\"}" > /tmp/ra-info.json
if ! grep -q '"returnValue": true' /tmp/ra-info.json; then
  echo "getAppInfo failed:"
  cat /tmp/ra-info.json
  exit 1
fi

echo "--- files ---"
ls -la "\${APP_DIR}"
md5sum "\${APP_DIR}/retroarch" || true
cat "\${APP_DIR}/appinfo.json"
echo
echo "--- appInfo ---"
cat /tmp/ra-info.json

rm -f "\${REMOTE_IPK}"

if [[ "\${DO_REBOOT}" == "1" ]]; then
  echo "--- rebooting TV ---"
  luna_i 1 luna://com.webos.service.power/shutdown/machineReboot '{"reason":"remoteKey"}' >/dev/null 2>&1 \\
    || reboot || true
fi

echo "--- deploy complete ---"
REMOTE

  log "Done."
  cat <<EOF

Installed & registered:  ${APP_ID}
Path:                    ${APP_DIR}
Package:                 ${ipk_name}

RetroArch should now appear in:
  • Full app list (Home → move up / Apps)
  • Sometimes only after a moment; reboot if needed:  ./webos/deploy.sh --reboot

Note: the bottom dock strip only shows a subset / pinned apps.
      Check the full Apps grid if you do not see it on the dock.
EOF
}

main
