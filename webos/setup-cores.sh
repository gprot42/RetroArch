#!/usr/bin/env bash
# Prepare RetroArch on a rooted webOS TV for downloading/using emulators.
#
# In RetroArch, a "core" = an emulator plugin (.so), NOT a CPU core and NOT a game ROM.
# Game files (e.g. Amiga .adf) are "content"; Kickstarts are system BIOS.
#
# Default: fix Core Downloader config + install emulator name/info files.
# Optional: also install a few emulator plugins offline (Amiga + others).
#
# Usage:
#   ./webos/setup-cores.sh
#   ./webos/setup-cores.sh --install-emulators   # preferred name
#   ./webos/setup-cores.sh --with-cores          # same as --install-emulators (alias)
#   WEBOS_HOST=192.168.0.50 ./webos/setup-cores.sh

set -euo pipefail

WEBOS_HOST="${WEBOS_HOST:-192.168.0.79}"
WEBOS_USER="${WEBOS_USER:-root}"
WEBOS_SSH_KEY="${WEBOS_SSH_KEY:-$HOME/.ssh/webos_deploy}"
WEBOS_SSH_PORT="${WEBOS_SSH_PORT:-22}"

APP_ID="com.retroarch.webos"
APP_DIR="/media/developer/apps/usr/palm/applications/${APP_ID}"
CFG_DIR="${APP_DIR}/.config/retroarch"
CORE_URL="http://retroarch-cores.webosbrew.org/armv7a/"
INFO_URL="http://buildbot.libretro.com/assets/frontend/info.zip"
INSTALL_EMULATORS=0

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Prepare RetroArch on the TV so emulators can be listed and installed.

  A RetroArch "core" is an emulator plugin (e.g. PUAE for Amiga).
  It is NOT a CPU core and NOT a game/ROM file.

Usage:
  ./webos/setup-cores.sh
      Fix Online Updater / Core Downloader (paths, webosbrew URL, .info names).
      Does not download game files.

  ./webos/setup-cores.sh --install-emulators
      Same as above, plus install a starter set of emulator plugins:
        • PUAE 2021     — Commodore Amiga
        • snes9x2010    — Super Nintendo
        • gpsp          — Game Boy Advance
        • gambatte      — Game Boy / Color
      Still does NOT download games/ROMs/ADFs (use setup-amiga.sh for Amiga disks).

  --with-cores
      Alias for --install-emulators (kept for older docs).

Env: WEBOS_HOST WEBOS_USER WEBOS_SSH_KEY WEBOS_SSH_PORT
EOF
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-emulators|--with-cores) INSTALL_EMULATORS=1; shift ;;
    -h|--help) usage 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

[[ -f "$WEBOS_SSH_KEY" ]] || die "SSH key not found: $WEBOS_SSH_KEY"

ssh_base() {
  ssh -i "$WEBOS_SSH_KEY" \
    -o IdentitiesOnly=yes \
    -o ConnectTimeout=15 \
    -o StrictHostKeyChecking=accept-new \
    -p "$WEBOS_SSH_PORT" \
    "${WEBOS_USER}@${WEBOS_HOST}" \
    "$@"
}

log "Target ${WEBOS_USER}@${WEBOS_HOST}"
ssh_base "test -x '${APP_DIR}/retroarch'" || die "RetroArch not installed at ${APP_DIR}"

# Stop app so it cannot overwrite cfg while we write
log "Stopping RetroArch if running…"
ssh_base "killall retroarch 2>/dev/null || true; sleep 1" || true

log "Writing config + core info on device"
# shellcheck disable=SC2087
ssh_base bash -s <<REMOTE
set -euo pipefail
APP_DIR="$APP_DIR"
CFG_DIR="$CFG_DIR"
CORE_URL="$CORE_URL"
INFO_URL="$INFO_URL"

mkdir -p "\$CFG_DIR/cores" "\$CFG_DIR/info" "\$CFG_DIR/downloads" "\$CFG_DIR/logs" \
         "\$CFG_DIR/disks/amiga" "\$CFG_DIR/system" "\$CFG_DIR/saves" "\$CFG_DIR/states" \
         "\$CFG_DIR/playlists"

CFG="\$CFG_DIR/retroarch.cfg"

# Always rewrite the updater-critical keys (merge: keep other user keys if present)
if [ -f "\$CFG" ] && [ "\$(wc -c < "\$CFG")" -gt 2000 ]; then
  grep -v -E '^(libretro_directory|libretro_info_path|core_assets_directory|system_directory|rgui_browser_directory|log_dir|playlist_directory|savefile_directory|savestate_directory|core_updater_buildbot_cores_url|core_updater_buildbot_url|core_updater_buildbot_assets_url|core_updater_auto_extract_archive|core_updater_show_experimental_cores|menu_show_core_updater|menu_show_online_updater|menu_navigation_browser_filter_supported_extensions_enable|filter_by_current_core|log_verbosity|log_to_file|log_to_file_timestamp|frontend_log_level|libretro_log_level|config_save_on_exit) ' "\$CFG" > "\$CFG.keep" || true
else
  : > "\$CFG.keep"
fi

cat > "\$CFG" <<EOF
# --- managed by webos/setup-cores.sh ---
libretro_directory = "\$CFG_DIR/cores"
libretro_info_path = "\$CFG_DIR/info"
core_assets_directory = "\$CFG_DIR/downloads"
system_directory = "\$CFG_DIR/system"
rgui_browser_directory = "\$CFG_DIR/disks/amiga"
log_dir = "\$CFG_DIR/logs"
playlist_directory = "\$CFG_DIR/playlists"
savefile_directory = "\$CFG_DIR/saves"
savestate_directory = "\$CFG_DIR/states"

# webOS cores (armv7a) — do NOT use buildbot.libretro.com for cores
core_updater_buildbot_cores_url = "\$CORE_URL"
core_updater_buildbot_assets_url = "http://buildbot.libretro.com/assets/"
core_updater_auto_extract_archive = "true"
core_updater_show_experimental_cores = "true"

menu_show_core_updater = "true"
menu_show_online_updater = "true"

menu_navigation_browser_filter_supported_extensions_enable = "false"
filter_by_current_core = "false"

log_verbosity = "true"
log_to_file = "true"
log_to_file_timestamp = "true"
frontend_log_level = "0"
libretro_log_level = "0"
config_save_on_exit = "true"
EOF
cat "\$CFG.keep" >> "\$CFG"
rm -f "\$CFG.keep"

echo "Fetching core info catalog…"
wget -q -O /tmp/ra-info.zip "\$INFO_URL"
rm -rf /tmp/ra-info-extract
mkdir -p /tmp/ra-info-extract
unzip -o -q /tmp/ra-info.zip -d /tmp/ra-info-extract
find /tmp/ra-info-extract -type f -name '*.info' -exec cp -f {} "\$CFG_DIR/info/" \;
rm -rf /tmp/ra-info-extract /tmp/ra-info.zip

echo "Probing Core Downloader index…"
wget -q -O /tmp/ra-index "\${CORE_URL}.index-extended"
lines=\$(wc -l < /tmp/ra-index)
echo "Core index lines: \$lines"
head -3 /tmp/ra-index
rm -f /tmp/ra-index
[ "\$lines" -gt 10 ] || { echo "error: core index empty — network blocked?" >&2; exit 1; }

# Jailed app (uid 6885 / prisoner) must read+write these
chmod -R a+rwX "\$CFG_DIR"
chown -R 6885:jailer "\$CFG_DIR" 2>/dev/null || true
chmod 666 "\$CFG"

echo "info files (emulator names): \$(ls "\$CFG_DIR/info" | wc -l)"
echo "emulator plugins installed: \$(ls "\$CFG_DIR/cores"/*.so 2>/dev/null | wc -l)"
echo "config: \$CFG"
REMOTE

if [[ "$INSTALL_EMULATORS" -eq 1 ]]; then
  log "Installing starter emulator plugins (not games) onto the TV…"
  log "  Amiga (PUAE 2021), SNES, GBA, Game Boy — still no ROMs/ADFs"
  ssh_base bash -s <<REMOTE
set -euo pipefail
CFG_DIR="$CFG_DIR"
CORE_URL="$CORE_URL"
mkdir -p "\$CFG_DIR/cores"
cd /tmp
# Each .so is an emulator plugin (libretro "core"), not a game image
for c in puae2021_libretro.so.zip snes9x2010_libretro.so.zip gpsp_libretro.so.zip gambatte_libretro.so.zip; do
  echo "  emulator: \$c"
  wget -q -O "\$c" "\${CORE_URL}\${c}" || continue
  unzip -o -q "\$c" -d "\$CFG_DIR/cores/"
  rm -f "\$c"
done
chmod 755 "\$CFG_DIR/cores"/*.so 2>/dev/null || true
chown 6885:jailer "\$CFG_DIR/cores"/* 2>/dev/null || true
echo "Installed emulators:"
ls -la "\$CFG_DIR/cores"
REMOTE
fi

log "Done."
cat <<EOF

Terminology:
  emulator / "core"  = plugin that runs a system (PUAE, snes9x, …)
  content / ROM/ADF  = the game or disk image (use setup-amiga.sh for Amiga ADFs)

On the TV:
  1. Fully close RetroArch (Home → close the app).
  2. Open RetroArch again.
  3. Online Updater → Core Downloader
     → list of ~180 emulator plugins (webosbrew armv7a).

  Or Load Core → pick an installed emulator
     (if you used --install-emulators / --with-cores:
      PUAE 2021 Amiga, snes9x2010, gpsp, gambatte).

Emulator plugins dir:  ${CFG_DIR}/cores
Info (names) dir:      ${CFG_DIR}/info
Buildbot URL:          ${CORE_URL}
Logs:                  ${CFG_DIR}/logs

If Core Downloader is still empty after a full restart:
  • Settings → Network → Buildbot cores URL =
      ${CORE_URL}
  • Online Updater → Update Core Info Files
  • Try Core Downloader again
EOF
