#!/usr/bin/env bash
# Control RetroArch on a rooted webOS TV over SSH + luna-send.
#
# Usage:
#   ./webos/control-retroarch.sh status
#   ./webos/control-retroarch.sh launch | close | kill | restart
#   ./webos/control-retroarch.sh adfs              # list .adf on TV
#   ./webos/control-retroarch.sh play              # pick interactively → launch
#   ./webos/control-retroarch.sh play 2            # launch ADF #2
#   ./webos/control-retroarch.sh play Solid        # launch first match
#
# Env:
#   WEBOS_HOST WEBOS_USER WEBOS_SSH_KEY WEBOS_SSH_PORT
#   WEBOS_APP_DIR      RetroArch app install dir on TV
#   WEBOS_RA_DIR       retroarch config root on TV
#   WEBOS_DISKS_DIR    Amiga .adf (disk images) directory on TV
#   WEBOS_SYSTEM_DIR   Kickstart BIOS directory on TV
#   WEBOS_CORE_PATH    PUAE core .so on TV

set -euo pipefail

WEBOS_HOST="${WEBOS_HOST:-192.168.0.79}"
WEBOS_USER="${WEBOS_USER:-root}"
WEBOS_SSH_KEY="${WEBOS_SSH_KEY:-$HOME/.ssh/webos_deploy}"
WEBOS_SSH_PORT="${WEBOS_SSH_PORT:-22}"

APP_ID="com.retroarch.webos"
APP_DIR="${WEBOS_APP_DIR:-/media/developer/apps/usr/palm/applications/${APP_ID}}"
RA_DIR="${WEBOS_RA_DIR:-${APP_DIR}/.config/retroarch}"
DISKS_DIR="${WEBOS_DISKS_DIR:-${RA_DIR}/disks/amiga}"
SYSTEM_DIR="${WEBOS_SYSTEM_DIR:-${RA_DIR}/system}"
CORE_PATH="${WEBOS_CORE_PATH:-${RA_DIR}/cores/puae2021_libretro.so}"
CORE_NAME="Commodore - Amiga (PUAE 2021)"
# webOS armv7a emulator plugins (libretro "cores") — not game ROMs
CORE_UPDATER_URL="${WEBOS_CORE_URL:-http://retroarch-cores.webosbrew.org/armv7a/}"

log()  { printf '==> %s\n' "$*" >&2; }
warn() { printf 'warn: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
say()  { printf '%s\n' "$*" >&2; }

usage() {
  cat <<EOF
Control RetroArch on webOS TV (${WEBOS_USER}@${WEBOS_HOST}).

App control:
  $(basename "$0") status
  $(basename "$0") launch | close | kill | restart

List on the TV:
  $(basename "$0") cores             Emulator plugins (.so) on TV
  $(basename "$0") cores-machine     Installed cores (id|file|label|path)
  $(basename "$0") cores-available   All downloadable cores (webosbrew index)
  $(basename "$0") install-core NAME Install one core (e.g. puae2021_libretro.so)
  $(basename "$0") roms              Content + Kickstarts
  $(basename "$0") adfs              List Amiga .adf disks
  $(basename "$0") adfs-machine      Machine list: idx|name|path (one per line)
  $(basename "$0") adfs N|TEXT       List is skipped — same as play N|TEXT

Launch Amiga disk with PUAE:
  $(basename "$0") play              Interactive picker
  $(basename "$0") play 1            Launch ADF #1
  $(basename "$0") play Solid        Launch first name match
  $(basename "$0") 1                 Shortcut for: play 1
  $(basename "$0") remove 1          Delete ADF #1 from the TV disks dir
  $(basename "$0") remove Solid      Delete first name match

Play closes RetroArch (if open), then relaunches with the ADF in DF0
(auto-start via a small app launch wrapper).

Mouse (Magic Remote / ClickableMouse on TV):
  $(basename "$0") click-left          Left mouse button click
  $(basename "$0") click-right         Right mouse button click
  $(basename "$0") mouse-move DX DY    Relative move
  $(basename "$0") mouse-down left|right
  $(basename "$0") mouse-up left|right
  $(basename "$0") show-cursor         Force-show webOS pointer on TV

Keyboard / Magic Remote:
  $(basename "$0") key esc|enter       Send Escape or Return/Enter
  $(basename "$0") key-esc
  $(basename "$0") key-enter
  $(basename "$0") keyboard-key NAME   Virtual keyboard key (a–z, 0–9, space, enter, …)
  $(basename "$0") type-text "hello"   Type a string (ASCII; Shift applied as needed)
  $(basename "$0") remote-button NAME  Magic Remote button (UP/DOWN/LEFT/RIGHT/ENTER/BACK/HOME/…)
  $(basename "$0") volume-get          Current TV volume as JSON
  $(basename "$0") volume-up [N]       Volume up N steps (default 1) — shows TV OSD
  $(basename "$0") volume-down [N]     Volume down N steps
  $(basename "$0") volume-set N        Set absolute volume 0–100

Controller / Bluetooth gamepad:
  $(basename "$0") setup-controller    Auto-configure sdl2 + autoconfig + profiles
  $(basename "$0") setup-controller --refresh   Re-download joypad profiles
  $(basename "$0") pad-mouse-start BTN [ACTION]
                           Map pad button → mouse action on TV
                           BTN: l3|r3|select|start|l1|r1|l2|r2
                           ACTION: lmb|rmb|mmb (default lmb = left click)
  $(basename "$0") pad-mouse-stop      Stop pad→mouse mapper
  $(basename "$0") pad-mouse-status    Mapper running? button + action?

Env:
  WEBOS_HOST WEBOS_USER WEBOS_SSH_KEY WEBOS_SSH_PORT
  WEBOS_DISKS_DIR   Amiga .adf path on TV (default: …/disks/amiga)
  WEBOS_SYSTEM_DIR  Kickstart BIOS path   (default: …/system)
  WEBOS_RA_DIR      RetroArch config root
  WEBOS_CORE_PATH   PUAE libretro .so
EOF
  exit "${1:-0}"
}

[[ -f "$WEBOS_SSH_KEY" ]] || die "SSH key not found: $WEBOS_SSH_KEY"

# Reuse one SSH TCP connection for rapid mouse-move spam (ControlMaster).
# Path must stay short: AF_UNIX sun_path is ~104 bytes on macOS.
_ssh_control_path="/tmp/ra-ssh-%h-%p"

ssh_base() {
  # BatchMode + short timeouts so a dead TV cannot beachball the Mac UI for long.
  # ControlMaster=auto: first call opens master; later mouse moves reuse it (~ms).
  ssh -i "$WEBOS_SSH_KEY" \
    -o IdentitiesOnly=yes \
    -o BatchMode=yes \
    -o ConnectTimeout=5 \
    -o ServerAliveInterval=3 \
    -o ServerAliveCountMax=2 \
    -o StrictHostKeyChecking=accept-new \
    -o ControlMaster=auto \
    -o "ControlPath=$_ssh_control_path" \
    -o ControlPersist=60 \
    -p "$WEBOS_SSH_PORT" \
    "${WEBOS_USER}@${WEBOS_HOST}" \
    "$@"
}

# Independent of ControlMaster — use for quick status probes (gamepad detect, etc.)
# so they never stall behind a long muxed transfer (setup-controller, install, …).
ssh_quick() {
  ssh -i "$WEBOS_SSH_KEY" \
    -o IdentitiesOnly=yes \
    -o BatchMode=yes \
    -o ConnectTimeout=4 \
    -o ConnectionAttempts=1 \
    -o ServerAliveInterval=2 \
    -o ServerAliveCountMax=2 \
    -o StrictHostKeyChecking=accept-new \
    -o ControlMaster=no \
    -o ControlPath=none \
    -p "$WEBOS_SSH_PORT" \
    "${WEBOS_USER}@${WEBOS_HOST}" \
    "$@"
}

remote_luna() {
  local n="${1:-1}"
  local url="$2"
  local payload="$3"
  # Short timeout — long hangs were freezing the Mac app on Restart/Main menu
  # shellcheck disable=SC2087
  ssh_base "sh -s" <<EOS
( sleep 0.08; echo ) | timeout 8 luna-send -i -n '${n}' -f '${url}' '${payload}' 2>/dev/null || true
EOS
}

# ── App control ────────────────────────────────────────────────────────────

cmd_status() {
  log "TV ${WEBOS_USER}@${WEBOS_HOST}  app ${APP_ID}"

  if ssh_base "test -x '${APP_DIR}/retroarch'"; then
    printf 'installed:  yes  (%s)\n' "$APP_DIR"
  else
    printf 'installed:  no   (missing %s/retroarch)\n' "$APP_DIR"
  fi

  local info running
  info="$(remote_luna 1 "luna://com.webos.applicationManager/getAppInfo" "{\"id\":\"${APP_ID}\"}")"
  if printf '%s' "$info" | grep -q '"returnValue": true'; then
    printf 'registered: yes (SAM)\n'
  else
    printf 'registered: no / unknown\n'
  fi

  running="$(remote_luna 1 "luna://com.webos.applicationManager/running" "{}")"
  if printf '%s' "$running" | grep -q "\"id\": \"${APP_ID}\""; then
    printf 'running:    yes\n'
  else
    printf 'running:    no\n'
  fi

  local n
  n="$(ssh_base "ls -1 '${DISKS_DIR}'/*.adf '${DISKS_DIR}'/*.ADF 2>/dev/null | wc -l" | tr -d ' ')"
  printf 'adfs:       %s in %s\n' "${n:-0}" "$DISKS_DIR"
  printf 'disks_dir:  %s\n' "$DISKS_DIR"
  printf 'system_dir: %s\n' "$SYSTEM_DIR"
  printf 'ra_dir:     %s\n' "$RA_DIR"
}

cmd_launch() {
  log "Launching ${APP_ID}…"
  local out
  out="$(remote_luna 1 "luna://com.webos.applicationManager/launch" "{\"id\":\"${APP_ID}\"}")"
  printf '%s\n' "$out"
  if printf '%s' "$out" | grep -q '"returnValue": true'; then
    log "Launch requested OK"
    return 0
  fi
  die "launch failed (is the app installed? try ./webos/deploy.sh)"
}

cmd_close() {
  log "Closing ${APP_ID} (graceful)…"
  local out
  out="$(remote_luna 1 "luna://com.webos.applicationManager/closeByAppId" "{\"id\":\"${APP_ID}\"}")"
  printf '%s\n' "$out"
  if printf '%s' "$out" | grep -q '"returnValue": true'; then
    log "Closed"
    return 0
  fi
  if printf '%s' "$out" | grep -qiE 'not running|no app matched|is not running'; then
    warn "RetroArch was already stopped (nothing to close)"
    return 0
  fi
  warn "close may have failed — try: $0 kill"
  return 1
}

cmd_kill() {
  log "Force-stopping RetroArch (process + app)…"
  # SAM close first (best-effort)
  remote_luna 1 "luna://com.webos.applicationManager/closeByAppId" "{\"id\":\"${APP_ID}\"}" >/dev/null 2>&1 || true
  # Binary on webOS is retroarch.bin (not "retroarch") — kill both names + by path
  local out
  out="$(ssh_base "sh -s" <<'EOS'
set +e
# Named killall
killall -9 retroarch.bin 2>/dev/null
killall -9 retroarch 2>/dev/null
# Pattern match full cmdline (cores, content args, etc.)
pkill -9 -f '/com\.retroarch\.webos/retroarch' 2>/dev/null
pkill -9 -f 'retroarch\.bin' 2>/dev/null
# Any leftover by comm name
for pid in $(ps -eo pid,comm 2>/dev/null | awk '/retroarch/ {print $1}'); do
  kill -9 "$pid" 2>/dev/null
done
sleep 0.5
left=$(ps -eo pid,comm,args 2>/dev/null | grep -E 'retroarch(\.bin)?([[:space:]]|$)' | grep -v grep || true)
if [ -n "$left" ]; then
  echo "STILL_RUNNING"
  echo "$left"
  exit 1
fi
echo "stopped"
EOS
)" || true
  printf '%s\n' "$out"
  if printf '%s' "$out" | grep -q 'STILL_RUNNING'; then
    die "force kill failed — process still present"
  fi
  if printf '%s' "$out" | grep -q 'stopped'; then
    log "Force-stopped OK"
  else
    log "Kill finished (no retroarch process found)"
  fi
}

cmd_restart() {
  # Keep this short — long sleeps beachball the Mac UI while the app awaits SSH
  cmd_close || true
  cmd_kill || true
  sleep 0.35
  cmd_launch
}

# ── ADF list / play ────────────────────────────────────────────────────────

# Print numbered list to stdout as: index|basename|fullpath
# Human listing goes to stderr.
fetch_adf_list() {
  ssh_base "sh -s" <<'EOS'
DISKS='__DISKS__'
i=0
# prefer stable sort by name
ls -1 "$DISKS"/*.adf "$DISKS"/*.ADF 2>/dev/null | sort | while IFS= read -r p; do
  [ -f "$p" ] || continue
  i=$((i + 1))
  b=$(basename "$p")
  printf '%s|%s|%s\n' "$i" "$b" "$p"
done
EOS
}

# Fix DISKS path in remote script (busybox-safe, no env expand in quoted heredoc)
_fetch_adf_list() {
  ssh_base "sh -s" <<EOS
DISKS='${DISKS_DIR}'
i=0
ls -1 "\$DISKS"/*.adf "\$DISKS"/*.ADF 2>/dev/null | sort | while IFS= read -r p; do
  [ -f "\$p" ] || continue
  i=\$((i + 1))
  b=\$(basename "\$p")
  printf '%s|%s|%s\\n' "\$i" "\$b" "\$p"
done
EOS
}

# Friendly label for a libretro core basename
_core_label() {
  local b="$1"
  case "$b" in
    puae2021*) echo "Commodore Amiga (PUAE 2021)" ;;
    puae_*)    echo "Commodore Amiga (PUAE)" ;;
    amiberry*) echo "Commodore Amiga (Amiberry)" ;;
    snes9x2010*) echo "Super Nintendo (snes9x2010)" ;;
    snes9x*)   echo "Super Nintendo (snes9x)" ;;
    fceumm*)   echo "NES / Famicom (FCEUmm)" ;;
    nestopia*) echo "NES / Famicom (Nestopia)" ;;
    quicknes*) echo "NES (QuickNES)" ;;
    mupen64plus*) echo "Nintendo 64 (Mupen64Plus-Next)" ;;
    parallel_n64*) echo "Nintendo 64 (ParaLLEl N64)" ;;
    genesis_plus*) echo "Mega Drive / Genesis (Genesis Plus GX)" ;;
    picodrive*) echo "Mega Drive / Genesis / 32X (PicoDrive)" ;;
    pcsx_rearmed*) echo "PlayStation 1 (PCSX ReARMed)" ;;
    swanstation*) echo "PlayStation 1 (SwanStation)" ;;
    gpsp*)     echo "Game Boy Advance (gpSP)" ;;
    gambatte*) echo "Game Boy / Color (gambatte)" ;;
    fbneo*)    echo "Neo Geo / Arcade (FinalBurn Neo)" ;;
    fbalpha2012_neogeo*) echo "Neo Geo (FB Alpha 2012)" ;;
    geolith*)  echo "Neo Geo (Geolith)" ;;
    *)         echo "${b%_libretro.so}" ;;
  esac
}

cmd_cores() {
  log "Emulator plugins (cores) on TV: ${RA_DIR}/cores"
  say "(In RetroArch a \"core\" is an emulator .so — not a game ROM.)"
  say ""
  ssh_base "sh -s" <<EOS
CORES='${RA_DIR}/cores'
if ! ls "\$CORES"/*_libretro.so >/dev/null 2>&1; then
  echo "(none — install from Settings or: ./webos/setup-cores.sh --install-emulators)"
  exit 0
fi
i=0
ls -1 "\$CORES"/*_libretro.so 2>/dev/null | sort | while IFS= read -r p; do
  i=\$((i + 1))
  b=\$(basename "\$p")
  case "\$b" in
    puae2021*) label="Commodore Amiga (PUAE 2021)" ;;
    puae_*)    label="Commodore Amiga (PUAE)" ;;
    amiberry*) label="Commodore Amiga (Amiberry)" ;;
    snes9x2010*) label="Super Nintendo (snes9x2010)" ;;
    snes9x*)   label="Super Nintendo (snes9x)" ;;
    fceumm*)   label="NES / Famicom (FCEUmm)" ;;
    nestopia*) label="NES / Famicom (Nestopia)" ;;
    mupen64plus*) label="Nintendo 64 (Mupen64Plus-Next)" ;;
    parallel_n64*) label="Nintendo 64 (ParaLLEl N64)" ;;
    genesis_plus*) label="Mega Drive / Genesis (Genesis Plus GX)" ;;
    picodrive*) label="Mega Drive / Genesis / 32X (PicoDrive)" ;;
    pcsx_rearmed*) label="PlayStation 1 (PCSX ReARMed)" ;;
    swanstation*) label="PlayStation 1 (SwanStation)" ;;
    gpsp*)     label="Game Boy Advance (gpSP)" ;;
    gambatte*) label="Game Boy / Color (gambatte)" ;;
    fbneo*)    label="Neo Geo / Arcade (FinalBurn Neo)" ;;
    fbalpha2012_neogeo*) label="Neo Geo (FB Alpha 2012)" ;;
    geolith*)  label="Neo Geo (Geolith)" ;;
    *)         label="\$b" ;;
  esac
  sz=\$(ls -lh "\$p" | awk '{print \$5}')
  printf '  %2d) %-40s  %s  (%s)\\n' "\$i" "\$label" "\$b" "\$sz"
done
echo ""
echo "Path: \$CORES"
EOS
}

# Machine lines: id|file|label|path  (stdout only — for GUI)
# Uses ssh_quick so it never stalls behind a busy ControlMaster (boot parallel loads).
# Always exit 0 so the Mac UI never treats an empty cores dir as a hard failure.
cmd_cores_machine() {
  # Avoid set -e abort if the remote finds zero cores (ls fails with no match)
  set +e
  ssh_quick "sh -s" <<EOS
CORES='${RA_DIR}/cores'
i=0
# Prefer find (no "no match" error); fall back to ls
if [ -d "\$CORES" ]; then
  list=\$(find "\$CORES" -maxdepth 1 -type f -name '*_libretro.so' 2>/dev/null | sort)
else
  list=""
fi
if [ -z "\$list" ]; then
  # empty → no lines (GUI shows "none installed")
  exit 0
fi
printf '%s\n' "\$list" | while IFS= read -r p; do
  [ -n "\$p" ] || continue
  i=\$((i + 1))
  b=\$(basename "\$p")
  case "\$b" in
    puae2021*) label="Commodore Amiga (PUAE 2021)" ;;
    puae_*)    label="Commodore Amiga (PUAE)" ;;
    amiberry*) label="Commodore Amiga (Amiberry)" ;;
    snes9x2010*) label="Super Nintendo (snes9x2010)" ;;
    snes9x*)   label="Super Nintendo (snes9x)" ;;
    fceumm*)   label="NES / Famicom (FCEUmm)" ;;
    nestopia*) label="NES / Famicom (Nestopia)" ;;
    mupen64plus*) label="Nintendo 64 (Mupen64Plus-Next)" ;;
    parallel_n64*) label="Nintendo 64 (ParaLLEl N64)" ;;
    genesis_plus*) label="Mega Drive / Genesis (Genesis Plus GX)" ;;
    picodrive*) label="Mega Drive / Genesis / 32X (PicoDrive)" ;;
    pcsx_rearmed*) label="PlayStation 1 (PCSX ReARMed)" ;;
    swanstation*) label="PlayStation 1 (SwanStation)" ;;
    gpsp*)     label="Game Boy Advance (gpSP)" ;;
    gambatte*) label="Game Boy / Color (gambatte)" ;;
    fbneo*)    label="Neo Geo / Arcade (FinalBurn Neo)" ;;
    fbalpha2012_neogeo*) label="Neo Geo (FB Alpha 2012)" ;;
    geolith*)  label="Neo Geo (Geolith)" ;;
    *)         label="\${b%_libretro.so}" ;;
  esac
  # Strip | from labels so machine format stays 4 fields
  label=\$(printf '%s' "\$label" | tr '|' '/')
  printf '%d|%s|%s|%s\\n' "\$i" "\$b" "\$label" "\$p"
done
exit 0
EOS
  rc=$?
  set -e
  # Soft-fail: never kill the Mac invoke with a non-zero from a listing glitch
  if [ "$rc" -ne 0 ]; then
    warn "cores-machine: SSH list failed (exit $rc) — GUI will retry"
    return 0
  fi
  return 0
}

# List every core on the webosbrew armv7a index (downloadable).
# Machine: file|label   (file is e.g. puae2021_libretro.so)
cmd_cores_available() {
  local index_url="${CORE_UPDATER_URL}.index-extended"
  local filter="${1:-}"
  log "Available cores from ${CORE_UPDATER_URL}"
  # Fetch on the Mac (faster / less load on TV); fall back to TV wget
  local raw=""
  if command -v curl >/dev/null 2>&1; then
    raw="$(curl -fsSL --connect-timeout 20 --retry 2 "$index_url" 2>/dev/null || true)"
  fi
  if [[ -z "$raw" ]]; then
    raw="$(ssh_base "wget -q -O - '${index_url}' 2>/dev/null" || true)"
  fi
  [[ -n "$raw" ]] || die "could not fetch core index from ${index_url}"

  # index lines: DATE HASH name_libretro.so.zip
  # Parse with awk (no subshell locals)
  printf '%s\n' "$raw" | awk -v filt="$filter" '
    NF >= 3 {
      zip = $NF
      if (zip !~ /_libretro\.so\.zip$/) next
      file = zip
      sub(/\.zip$/, "", file)
      name = file
      sub(/_libretro\.so$/, "", name)
      if (file ~ /^puae2021/) label = "Commodore Amiga (PUAE 2021)"
      else if (file ~ /^puae_/) label = "Commodore Amiga (PUAE)"
      else if (file ~ /^amiberry/) label = "Commodore Amiga (Amiberry)"
      else if (file ~ /^snes9x2010/) label = "Super Nintendo (snes9x2010)"
      else if (file ~ /^snes9x/) label = "Super Nintendo (snes9x)"
      else if (file ~ /^fceumm/) label = "NES / Famicom (FCEUmm)"
      else if (file ~ /^nestopia/) label = "NES / Famicom (Nestopia)"
      else if (file ~ /^quicknes/) label = "NES (QuickNES)"
      else if (file ~ /^mupen64plus/) label = "Nintendo 64 (Mupen64Plus-Next)"
      else if (file ~ /^parallel_n64/) label = "Nintendo 64 (ParaLLEl N64)"
      else if (file ~ /^genesis_plus/) label = "Mega Drive / Genesis (Genesis Plus GX)"
      else if (file ~ /^picodrive/) label = "Mega Drive / Genesis / 32X (PicoDrive)"
      else if (file ~ /^pcsx_rearmed/) label = "PlayStation 1 (PCSX ReARMed)"
      else if (file ~ /^swanstation/) label = "PlayStation 1 (SwanStation)"
      else if (file ~ /^gpsp/) label = "Game Boy Advance (gpSP)"
      else if (file ~ /^gambatte/) label = "Game Boy / Color (gambatte)"
      else if (file ~ /^fbneo/) label = "Neo Geo / Arcade (FinalBurn Neo)"
      else if (file ~ /^fbalpha2012_neogeo/) label = "Neo Geo (FB Alpha 2012)"
      else if (file ~ /^geolith/) label = "Neo Geo (Geolith)"
      else label = name
      if (filt != "") {
        low = tolower(file " " label)
        if (index(low, tolower(filt)) == 0) next
      }
      printf "%s|%s\n", file, label
    }
  ' | sort -t'|' -k2,2f
}

# Install one core zip from webosbrew onto the TV.
# Arg: puae2021_libretro.so | puae2021_libretro | puae2021
cmd_install_core() {
  local raw="${1:-}"
  [[ -n "$raw" ]] || die "install-core needs a core name (e.g. puae2021_libretro.so)"
  local base file zip
  base="$(basename "$raw")"
  base="${base%.zip}"
  if [[ "$base" == *_libretro.so ]]; then
    file="$base"
  elif [[ "$base" == *_libretro ]]; then
    file="${base}.so"
  else
    file="${base}_libretro.so"
  fi
  zip="${file}.zip"
  local url="${CORE_UPDATER_URL}${zip}"
  if [[ "$file" == "mupen64plus_next_libretro.so" ]]; then
    warn "Current webosbrew Mupen64Plus-Next may need GLIBCXX_3.4.32;"
    warn "RetroArch 1.22.2 ships libstdc++ up to 3.4.30 → core fails to load."
    warn "Prefer: install-core parallel_n64_libretro.so  (N64 on webOS)"
  fi
  log "Installing core ${file}"
  log "  from ${url}"
  log "  → ${RA_DIR}/cores/"
  ssh_base "sh -s" <<EOS
set -e
CORES='${RA_DIR}/cores'
URL='${url}'
ZIP='${zip}'
FILE='${file}'
mkdir -p "\$CORES"
cd /tmp
rm -f "\$ZIP"
if command -v wget >/dev/null 2>&1; then
  wget -q -O "\$ZIP" "\$URL" || { echo "error: download failed: \$URL" >&2; exit 1; }
elif command -v curl >/dev/null 2>&1; then
  curl -fsSL -o "\$ZIP" "\$URL" || { echo "error: download failed: \$URL" >&2; exit 1; }
else
  echo "error: no wget/curl on TV" >&2
  exit 1
fi
# zip contains the .so
if command -v unzip >/dev/null 2>&1; then
  unzip -o -q "\$ZIP" -d "\$CORES/"
else
  # busybox unzip sometimes as 'unzip'
  echo "error: unzip not found on TV" >&2
  rm -f "\$ZIP"
  exit 1
fi
rm -f "\$ZIP"
if [ ! -f "\$CORES/\$FILE" ]; then
  # some zips use slightly different names — pick newest .so
  newest=\$(ls -t "\$CORES"/*_libretro.so 2>/dev/null | head -1 || true)
  if [ -n "\$newest" ]; then
    echo "ok installed \$(basename "\$newest") → \$newest"
    chmod 755 "\$newest" 2>/dev/null || true
    chown 6885:jailer "\$newest" 2>/dev/null || true
    exit 0
  fi
  echo "error: \$FILE not found after unzip" >&2
  exit 1
fi
chmod 755 "\$CORES/\$FILE" 2>/dev/null || true
chown 6885:jailer "\$CORES/\$FILE" 2>/dev/null || true
echo "ok installed \$FILE → \$CORES/\$FILE"
EOS
  log "Done"
}

# Machine lines: one basename per line (for GUI "already installed" checks)
# Arg: system id (amiga|snes|nes|genesis|gba|gbc|n64|psx|neogeo)
cmd_list_installed() {
  local sys
  sys="$(printf '%s' "${1:-amiga}" | tr '[:upper:]' '[:lower:]')"
  local dir=""
  case "$sys" in
    amiga) dir="${DISKS_DIR}" ;;
    snes) dir="${RA_DIR}/disks/snes" ;;
    nes) dir="${RA_DIR}/disks/nes" ;;
    genesis|megadrive|md) dir="${RA_DIR}/disks/genesis" ;;
    gba) dir="${RA_DIR}/disks/gba" ;;
    gbc|gb) dir="${RA_DIR}/disks/gb" ;;
    n64) dir="${RA_DIR}/disks/n64" ;;
    psx|ps1) dir="${RA_DIR}/disks/psx" ;;
    neogeo|neo-geo|neo_geo|ng) dir="${RA_DIR}/disks/neogeo" ;;
    *) dir="${RA_DIR}/disks/${sys}" ;;
  esac
  echo "# installed system=${sys} dir=${dir}"
  ssh_quick "sh -s" <<EOS
d='${dir}'
if [ ! -d "\$d" ]; then
  exit 0
fi
# basenames only; skip hidden
ls -1 "\$d" 2>/dev/null | while IFS= read -r f; do
  [ -n "\$f" ] || continue
  case "\$f" in
    .*|Thumbs.db) continue ;;
  esac
  printf '%s\n' "\$f"
done
EOS
}

cmd_roms() {
  log "Content on TV (game/disk images — not Kickstart BIOS)"
  say ""
  say "── Amiga disks (.adf)  ${DISKS_DIR}"
  local lines line idx name count=0
  lines="$(_fetch_adf_list)" || true
  if [[ -z "${lines// }" ]]; then
    say "  (none — ./webos/setup-amiga.sh)"
  else
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      idx="${line%%|*}"
      rest="${line#*|}"
      name="${rest%%|*}"
      printf '  %2s) %s\n' "$idx" "$name"
      count=$((count + 1))
    done <<<"$lines"
  fi
  say ""
  say "── Kickstart BIOS  ${SYSTEM_DIR}"
  ssh_base "ls -1 '${SYSTEM_DIR}'/kick* 2>/dev/null | while read -r p; do printf '  - %s\\n' \"\$(basename \"\$p\")\"; done; ls '${SYSTEM_DIR}'/kick* >/dev/null 2>&1 || echo '  (none)'"
  say ""
  say "── Other images under retroarch config (if any)"
  ssh_base "find '${RA_DIR}' -type f \( -iname '*.iso' -o -iname '*.sfc' -o -iname '*.smc' -o -iname '*.gba' -o -iname '*.gb' -o -iname '*.gbc' -o -iname '*.nes' -o -iname '*.zip' \) ! -path '*/cores/*' ! -path '*/info/*' 2>/dev/null | head -30 | while read -r p; do printf '  - %s\\n' \"\$p\"; done; echo '(end)'"
  say ""
  say "Amiga launch:  $0 play N   or   $0 play"
}

# Clean machine-readable ADF list for the macOS app (stdout only).
cmd_adfs_machine() {
  local lines
  lines="$(_fetch_adf_list)" || true
  if [[ -z "${lines// }" ]]; then
    # Empty stdout = none; no chatter so the GUI can show a clear empty state.
    return 0
  fi
  printf '%s\n' "$lines"
}

# All games/demos/media under disks/* for the GUI.
# Machine: system|idx|name|path
# system = amiga|snes|nes|genesis|gba|gb|n64|psx|neogeo|…
# Uses ssh_quick; always exit 0.
cmd_media_machine() {
  set +e
  ssh_quick "sh -s" <<EOS
RA='${RA_DIR}'
DISKS="\$RA/disks"
if [ ! -d "\$DISKS" ]; then
  exit 0
fi
is_media() {
  case "\$(printf '%s' "\$1" | tr 'A-Z' 'a-z')" in
    *.adf|*.adz|*.dms|*.ipf|*.hdf|*.hdz|*.lha|*.cue|*.chd|*.iso|\\
    *.sfc|*.smc|*.fig|*.swc|\\
    *.nes|*.fds|*.unf|*.unif|\\
    *.md|*.gen|*.smd|*.32x|*.sms|*.gg|\\
    *.gba|*.gb|*.gbc|*.sgb|\\
    *.n64|*.z64|*.v64|\\
    *.neo|\\
    *.pbp|*.img|*.mdf|*.toc|*.m3u|*.zip|*.7z|*.rar|*.bin|*.rom)
      return 0 ;;
    *) return 1 ;;
  esac
}
emit_dir() {
  sys="\$1"
  d="\$2"
  [ -d "\$d" ] || return 0
  i=0
  find "\$d" -maxdepth 1 -type f 2>/dev/null | sort | while IFS= read -r p; do
    [ -n "\$p" ] || continue
    b=\$(basename "\$p")
    case "\$b" in .*|Thumbs.db) continue ;; esac
    is_media "\$b" || continue
    i=\$((i + 1))
    b=\$(printf '%s' "\$b" | tr '|' '/')
    printf '%s|%d|%s|%s\\n' "\$sys" "\$i" "\$b" "\$p"
  done
}
for sys in amiga snes nes genesis gba gb gbc n64 psx neogeo; do
  emit_dir "\$sys" "\$DISKS/\$sys"
done
find "\$DISKS" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | while IFS= read -r d; do
  sys=\$(basename "\$d")
  case "\$sys" in
    amiga|snes|nes|genesis|gba|gb|gbc|n64|psx|neogeo) continue ;;
  esac
  emit_dir "\$sys" "\$d"
done
exit 0
EOS
  set -e
  return 0
}

cmd_adfs() {
  # If user passed a number or name, treat as play (./control-retroarch.sh adfs 1)
  if [[ -n "${1:-}" ]]; then
    cmd_play "$1"
    return
  fi

  log "ADFs on TV: ${DISKS_DIR}"
  local lines line idx name path count=0
  lines="$(_fetch_adf_list)" || true
  if [[ -z "${lines// }" ]]; then
    say "(none — run ./webos/setup-amiga.sh to install free/PD disks)"
    return 0
  fi
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    idx="${line%%|*}"
    rest="${line#*|}"
    name="${rest%%|*}"
    path="${rest#*|}"
    # Human-readable lines on stdout (app also accepts adfs-machine)
    printf '  %2s) %s\n' "$idx" "$name"
    count=$((count + 1))
  done <<<"$lines"
  say ""
  say "Launch with:"
  say "  $0 play 1"
  say "  $0 adfs 1"
  say "  $0 1"
  say "Path: ${DISKS_DIR}/"
}

_resolve_pick() {
  # args: optional N or TEXT — sets PICK_PATH PICK_NAME
  local want="${1:-}" lines line idx name path
  lines="$(_fetch_adf_list)" || true
  [[ -n "${lines// }" ]] || die "no .adf files on TV under ${DISKS_DIR}"

  if [[ -z "$want" ]]; then
    say ""
    say "Select an Amiga disk image (.adf):"
    say ""
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      idx="${line%%|*}"
      rest="${line#*|}"
      name="${rest%%|*}"
      printf '  %2s) %s\n' "$idx" "$name" >&2
    done <<<"$lines"
    say ""
    say "  q) Cancel"
    say ""
    local choice
    read -r -p "ADF # [1]: " choice </dev/tty || true
    choice="${choice:-1}"
    case "$choice" in
      q|Q|quit) die "cancelled" ;;
    esac
    want="$choice"
  fi

  # numeric?
  if [[ "$want" =~ ^[0-9]+$ ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      idx="${line%%|*}"
      rest="${line#*|}"
      name="${rest%%|*}"
      path="${rest#*|}"
      if [[ "$idx" == "$want" ]]; then
        PICK_PATH="$path"
        PICK_NAME="$name"
        return 0
      fi
    done <<<"$lines"
    die "no ADF with number $want (try: $0 adfs)"
  fi

  # substring match (case-insensitive)
  local lc want_lc
  want_lc="$(printf '%s' "$want" | tr '[:upper:]' '[:lower:]')"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    rest="${line#*|}"
    name="${rest%%|*}"
    path="${rest#*|}"
    lc="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
    if [[ "$lc" == *"$want_lc"* ]]; then
      PICK_PATH="$path"
      PICK_NAME="$name"
      return 0
    fi
  done <<<"$lines"
  die "no ADF matching \"$want\" (try: $0 adfs)"
}

# Pick the real Bluetooth/USB gamepad as RetroArch player 1.
#
# CRITICAL (webOS + input_joypad_driver = sdl2):
#   input_playerN_joypad_index is the SDL2 joystick index, NOT /dev/input/jsN.
#   LGE Magic Remotes appear as js0..js5 in the kernel but SDL often exposes
#   ONLY the real BT pad (e.g. "Wireless Controller" as SDL index 0).
#   Using kernel js6 while SDL only has index 0 → zero buttons reach the core.
_apply_best_gamepad_index() {
  # shell expands RA_DIR into the python script
  ssh_base "python3 -" <<PY
import os, re, glob, ctypes, ctypes.util

RA = """${RA_DIR}"""

# Sony DS4 v2 IDs — GameSir Nova / T4 / X2 etc. use these in *PS4 mode*
# and appear to Linux/SDL as exactly "Wireless Controller".
GAMESIR_PS4_VID = 0x054C
GAMESIR_PS4_PID = 0x09CC  # DualShock 4 v2 (most common GameSir PS4-mode clone)

def is_gamesir_name(name):
    low = (name or "").lower()
    return any(x in low for x in ("gamesir", "game-sir", "game_sir", "nova lite", "nova-lite"))

def identify_pad(name, vid=0, pid=0):
    """Return (kind, friendly_label). kind: gamesir|dualshock|xbox|other|virtual"""
    low = (name or "").lower()
    if not low:
        return ("other", name or "unknown")
    if is_gamesir_name(name):
        return ("gamesir", name.strip())
    # GameSir in PS4 mode: HID name is generic Sony "Wireless Controller"
    if "wireless controller" in low and (
        (vid == GAMESIR_PS4_VID and pid in (GAMESIR_PS4_PID, 0x05C4, 0x09CC))
        or (vid == 0 and pid == 0)  # VID unknown: still treat Wireless Controller as GameSir on this stack
    ):
        return ("gamesir", "GameSir (PS4 mode)")
    if any(x in low for x in ("dualshock", "dualsense", "sony interactive")):
        return ("dualshock", name.strip())
    if "ps4 controller" in low or "ps5 controller" in low:
        # RA often prints "PS4 Controller (DualShock 4 v2)" for the same GameSir
        if vid == GAMESIR_PS4_VID or vid == 0:
            return ("gamesir", "GameSir (PS4 mode)")
        return ("dualshock", name.strip())
    if any(x in low for x in ("xbox", "x-box", "xinput")):
        return ("xbox", name.strip())
    return ("other", name.strip() if name else "unknown")

def score_name(name, vid=0, pid=0):
    low = (name or "").lower()
    if not low:
        return -100
    # TV internals — never player 1
    for bad in (
        "lge ", "lge-", "m-rcu", "w-rcu", "tone", "simple premium",
        "clickable", "mouse", "keyboard", "check input", "iot keypad",
        "network input", "smart remote", "bluetooth-audio",
        "touchpad", "motion sensor",
    ):
        if bad in low:
            return -50
    kind, _ = identify_pad(name, vid, pid)
    s = 0
    if kind == "gamesir":
        s += 50  # preferred pad for this project
    if "wireless controller" in low:
        s += 40  # GameSir PS4-mode HID name
    if is_gamesir_name(name):
        s += 45
    if any(x in low for x in ("dualshock", "dualsense", "sony", "ps4", "ps5")):
        s += 35
    if any(x in low for x in ("xbox", "x-box", "8bit", "switch", "pro controller")):
        s += 30
    if any(x in low for x in ("gamepad", "joystick", "joypad", "controller")):
        s += 15
    if "wireless" in low or "bluetooth" in low:
        s += 5
    # Exact Sony DS4 clone IDs GameSir uses
    if vid == GAMESIR_PS4_VID and pid in (GAMESIR_PS4_PID, 0x05C4):
        s += 15
    return s

def list_sdl_joysticks():
    """Return [(sdl_index, name, vid, pid), ...] as RetroArch sdl2 driver sees them."""
    lib = None
    for name in ("libSDL2-2.0.so.0", "libSDL2.so", "libSDL2-2.0.so"):
        try:
            lib = ctypes.CDLL(name)
            break
        except OSError:
            continue
    if lib is None:
        return []
    SDL_INIT_JOYSTICK = 0x00000200
    lib.SDL_Init.argtypes = [ctypes.c_uint32]
    lib.SDL_Init.restype = ctypes.c_int
    lib.SDL_NumJoysticks.restype = ctypes.c_int
    lib.SDL_JoystickNameForIndex.argtypes = [ctypes.c_int]
    lib.SDL_JoystickNameForIndex.restype = ctypes.c_char_p
    # Optional: vendor/product (SDL 2.0.6+)
    try:
        lib.SDL_JoystickGetDeviceVendor.argtypes = [ctypes.c_int]
        lib.SDL_JoystickGetDeviceVendor.restype = ctypes.c_uint16
        lib.SDL_JoystickGetDeviceProduct.argtypes = [ctypes.c_int]
        lib.SDL_JoystickGetDeviceProduct.restype = ctypes.c_uint16
        have_vid = True
    except Exception:
        have_vid = False
    if lib.SDL_Init(SDL_INIT_JOYSTICK) != 0:
        return []
    out = []
    n = lib.SDL_NumJoysticks()
    for i in range(max(0, n)):
        raw = lib.SDL_JoystickNameForIndex(i)
        nm = raw.decode("utf-8", "replace") if raw else ("joystick-%d" % i)
        vid = pid = 0
        if have_vid:
            try:
                vid = int(lib.SDL_JoystickGetDeviceVendor(i) or 0)
                pid = int(lib.SDL_JoystickGetDeviceProduct(i) or 0)
            except Exception:
                vid = pid = 0
        out.append((i, nm, vid, pid))
    return out

def list_kernel_js():
    """Fallback: kernel /dev/input/jsN (WRONG for sdl2 index, last resort only)."""
    pads = []
    for npath in glob.glob("/sys/class/input/js*/device/name"):
        try:
            name = open(npath).read().strip()
        except OSError:
            continue
        m = re.search(r"/js(\d+)/", npath)
        if not m:
            continue
        # Try VID/PID next to the js node
        base = os.path.dirname(npath)
        vid = pid = 0
        try:
            vid = int(open(os.path.join(base, "id", "vendor")).read().strip(), 16)
            pid = int(open(os.path.join(base, "id", "product")).read().strip(), 16)
        except Exception:
            pass
        pads.append((int(m.group(1)), name, vid, pid))
    return pads

# Prefer SDL enumeration — matches RetroArch input_joypad_driver = "sdl2"
sdl_pads = list_sdl_joysticks()  # (idx, name, vid, pid)
pads = []  # (score, index, name, source, vid, pid)
for idx, name, vid, pid in sdl_pads:
    pads.append((score_name(name, vid, pid), idx, name, "sdl2", vid, pid))
if not pads:
    for idx, name, vid, pid in list_kernel_js():
        pads.append((score_name(name, vid, pid), idx, name, "kernel-js", vid, pid))

pads.sort(key=lambda t: (-t[0], t[1]))
best = None
for sc, idx, name, src, vid, pid in pads:
    if sc >= 10:
        best = (idx, name, sc, src, vid, pid)
        break
# If every device scored low but SDL has exactly one pad, use it
if best is None and len(sdl_pads) == 1:
    idx, name, vid, pid = sdl_pads[0]
    best = (idx, name, score_name(name, vid, pid), "sdl2-only", vid, pid)

# webOS quirk: RetroArch's SDL stack also exposes virtual pads that a
# standalone SDL_Init(JOYSTICK) often does NOT list:
#   joypad #0 Smart Remote RCU Input
#   joypad #1 LGE Network Input
#   joypad #2 Wireless Controller / GameSir (real pad)
# So our SDL index 0 becomes RA index 2 when those virtual devices exist.
def count_ra_virtual_joypads():
    n = 0
    for npath in glob.glob("/sys/class/input/event*/device/name"):
        try:
            name = open(npath).read().strip()
        except OSError:
            continue
        low = name.lower()
        if low in ("smart remote rcu input", "lge network input"):
            n += 1
    return n

ra_offset = count_ra_virtual_joypads()

cfg = os.path.join(RA, "retroarch.cfg")
if not os.path.isfile(cfg):
    print("no_cfg")
    raise SystemExit(0)

def set_cfg(key, val):
    lines = []
    found = False
    with open(cfg, "r", errors="replace") as f:
        for line in f:
            if re.match(r"^\s*" + re.escape(key) + r"\s*=", line):
                lines.append('%s = "%s"\n' % (key, val))
                found = True
            else:
                lines.append(line)
    if not found:
        lines.append('%s = "%s"\n' % (key, val))
    with open(cfg, "w") as f:
        f.writelines(lines)

if best:
    raw_idx, name, sc, src, vid, pid = best
    idx = raw_idx + ra_offset
    kind, friendly = identify_pad(name, vid, pid)
    # p1+p2 same pad: Amiga fire is often on control port 2 (joyport_order)
    set_cfg("input_player1_joypad_index", str(idx))
    set_cfg("input_player2_joypad_index", str(idx))
    # Park virtual LGE pads on p3/p4 so they do not steal the real pad
    if ra_offset >= 1:
        set_cfg("input_player3_joypad_index", "0")
    if ra_offset >= 2:
        set_cfg("input_player4_joypad_index", "1")
    set_cfg("input_player1_analog_dpad_mode", "1")
    set_cfg("input_player2_analog_dpad_mode", "1")
    set_cfg("input_joypad_driver", "sdl2")
    set_cfg("input_max_users", "4")
    # Prevent kill/close from rewriting joypad_index back to 0
    set_cfg("config_save_on_exit", "false")
    # CRITICAL: on webOS, autoconfig binds the pad to *port 3* (after
    # Smart Remote + LGE Network). Player 1 then keeps empty *_btn maps and
    # B/Start never reach the core. Force PS4-mode SDL button numbers onto p1+p2.
    # GameSir PS4 mode = same map as DualShock 4 (Cross=B, Circle=A, Options=Start).
    ds4 = {
        "a_btn": "1", "b_btn": "0", "x_btn": "3", "y_btn": "2",
        "select_btn": "4", "start_btn": "6",
        "up_btn": "11", "down_btn": "12", "left_btn": "13", "right_btn": "14",
        "l_btn": "9", "r_btn": "10", "l3_btn": "7", "r3_btn": "8",
        "l2_axis": "+4", "r2_axis": "+5",
        "l_x_plus_axis": "+0", "l_x_minus_axis": "-0",
        "l_y_plus_axis": "+1", "l_y_minus_axis": "-1",
        "r_x_plus_axis": "+2", "r_x_minus_axis": "-2",
        "r_y_plus_axis": "+3", "r_y_minus_axis": "-3",
    }
    for user in (1, 2):
        for key, val in ds4.items():
            set_cfg("input_player%d_%s" % (user, key), val)
        # Clear competing axis/btn nulls that block the maps above for face buttons
        for face in ("a", "b", "x", "y", "select", "start", "up", "down", "left", "right", "l", "r", "l3", "r3"):
            set_cfg("input_player%d_%s_axis" % (user, face), "nul")
        for trig in ("l2", "r2"):
            set_cfg("input_player%d_%s_btn" % (user, trig), "nul")
    # Disable autoconfig so Smart Remote profile cannot wipe p1 binds at startup.
    set_cfg("input_autodetect_enable", "false")
    print(
        "joypad_index=%d (raw_sdl=%d + webos_virtual=%d) hid=%s kind=%s label=%s "
        "vid=0x%04x pid=0x%04x score=%d source=%s (p1+p2)"
        % (idx, raw_idx, ra_offset, name, kind, friendly, vid, pid, sc, src)
    )
    print(
        "pad|%s|p1_index=%d|hid=%s|vid=0x%04x|pid=0x%04x|kind=%s"
        % (friendly.replace("|", "/"), idx, name.replace("|", "/"), vid, pid, kind)
    )
    print("forced GameSir/PS4-mode button map onto player1+player2 (B=0 A=1 Start=6); autodetect=off")
    if sdl_pads:
        print("sdl2_joysticks=%d" % len(sdl_pads))
        for i, n, v, p in sdl_pads:
            k, lab = identify_pad(n, v, p)
            print("  sdl[%d]=%s kind=%s label=%s vid=0x%04x pid=0x%04x" % (i, n, k, lab, v, p))
    if ra_offset:
        print("webos_virtual_joypads=%d (Smart Remote / LGE Network)" % ra_offset)
else:
    print("joypad_index=none (no real gamepad found; left unchanged)")
    for row in pads[:12]:
        sc, idx, name, src = row[0], row[1], row[2], row[3]
        vid = row[4] if len(row) > 4 else 0
        pid = row[5] if len(row) > 5 else 0
        print("  candidate %s idx=%d score=%d %s vid=0x%04x pid=0x%04x" % (src, idx, sc, name, vid, pid))

# Install sdl2 autoconfig profiles for GameSir (PS4 mode) + common aliases.
# HID reports as Sony DS4: name "Wireless Controller", VID 054c, PID 09cc.
sdl = os.path.join(RA, "autoconfig", "sdl2")
os.makedirs(sdl, exist_ok=True)

def write_pad_profile(path, device_name, display_name, vendor_id="1356", product_id="2508"):
    # 1356/2508 = decimal of 0x054c / 0x09cc (libretro autoconfig convention)
    body = (
        'input_driver = "sdl2"\n'
        'input_device = "%s"\n'
        'input_device_display_name = "%s"\n'
        'input_vendor_id = "%s"\n'
        'input_product_id = "%s"\n'
        'input_b_btn = "0"\n'
        'input_y_btn = "2"\n'
        'input_select_btn = "4"\n'
        'input_start_btn = "6"\n'
        'input_up_btn = "11"\n'
        'input_down_btn = "12"\n'
        'input_left_btn = "13"\n'
        'input_right_btn = "14"\n'
        'input_a_btn = "1"\n'
        'input_x_btn = "3"\n'
        'input_l_btn = "9"\n'
        'input_r_btn = "10"\n'
        'input_l2_axis = "+4"\n'
        'input_r2_axis = "+5"\n'
        'input_l3_btn = "7"\n'
        'input_r3_btn = "8"\n'
        'input_l_x_plus_axis = "+0"\n'
        'input_l_x_minus_axis = "-0"\n'
        'input_l_y_plus_axis = "+1"\n'
        'input_l_y_minus_axis = "-1"\n'
        'input_r_x_plus_axis = "+2"\n'
        'input_r_x_minus_axis = "-2"\n'
        'input_r_y_plus_axis = "+3"\n'
        'input_r_y_minus_axis = "-3"\n'
        'input_menu_toggle_btn = "5"\n'
    ) % (device_name, display_name, vendor_id, product_id)
    with open(path, "w") as f:
        f.write(body)
    print("wrote %s (%s)" % (path, display_name))

# Primary HID name GameSir uses in PS4 mode on webOS
write_pad_profile(
    os.path.join(sdl, "Wireless Controller.cfg"),
    "Wireless Controller",
    "GameSir (PS4 mode)",
)
# What RetroArch often prints after matching DS4
write_pad_profile(
    os.path.join(sdl, "PS4 Controller.cfg"),
    "PS4 Controller",
    "GameSir (PS4 mode)",
)
# Explicit GameSir product names (if pad is not in PS4 mode)
for alt, label in (
    ("GameSir Wireless Controller", "GameSir Wireless Controller"),
    ("GameSir-Nova Lite", "GameSir Nova Lite"),
    ("GameSir Nova Lite", "GameSir Nova Lite"),
    ("GameSir-Nova Lite 2", "GameSir Nova Lite 2"),
    ("GameSir Nova Lite 2", "GameSir Nova Lite 2"),
    ("GameSir-T4n", "GameSir T4n"),
    ("GameSir T4n", "GameSir T4n"),
    ("GameSir-X2", "GameSir X2"),
    ("GameSir X2 Bluetooth", "GameSir X2"),
):
    write_pad_profile(
        os.path.join(sdl, alt + ".cfg"),
        alt,
        label,
        vendor_id="0",  # match by name when VID varies by mode
        product_id="0",
    )
# Blacklist webOS virtual pads (no buttons) so they cannot "play" as p1
for device, v, p in (
    ("Smart Remote RCU Input", "39320", "39320"),
    ("LGE Network Input", "39320", "39320"),
):
    path = os.path.join(sdl, device + ".cfg")
    with open(path, "w") as f:
        f.write(
            'input_driver = "sdl2"\n'
            'input_device = "%s"\n'
            'input_vendor_id = "%s"\n'
            'input_product_id = "%s"\n'
            'input_b_btn = "nul"\n'
            'input_a_btn = "nul"\n'
            'input_y_btn = "nul"\n'
            'input_x_btn = "nul"\n'
            'input_start_btn = "nul"\n'
            'input_select_btn = "nul"\n'
            'input_up_btn = "nul"\n'
            'input_down_btn = "nul"\n'
            'input_left_btn = "nul"\n'
            'input_right_btn = "nul"\n'
            'input_l_btn = "nul"\n'
            'input_r_btn = "nul"\n' % (device, v, p)
        )
    print("blacklist %s" % device)
PY
}

_apply_puae_floppy_opts() {
  # Joystick-first defaults for Amiga action ADFs (title screens need FIRE, not mouse).
  # Important (PUAE 2021 libretro defaults):
  #  - B = Fire (start most games) · A = 2nd fire · X = Space · L2/R2 = mouse buttons
  #  - Do NOT force mapper_* = "---" — that wipes Fire/Space and makes menus unresponsive
  #  - puae_analogmouse must NOT be "left" (steals stick from joystick games)
  #  - puae_retropad_options "jump" maps A to UP (bad for shooters)
  #  - Mouse still via physical mouse inject / L2·R2 / right stick
  # Also bind RetroArch player1 to the real BT pad (not Magic Remote js0).
  _apply_best_gamepad_index || true

  ssh_base "sh -s" <<EOS
OPT_DIR='${RA_DIR}/config/PUAE 2021'
OPT="\$OPT_DIR/PUAE 2021.opt"
mkdir -p "\$OPT_DIR"
touch "\$OPT"
# Strip keys we manage — also drop old broken mapper--- overrides from prior app versions
grep -v -E '^(puae_model|puae_model_fd|puae_kickstart|puae_use_boot_hd|puae_use_whdload|puae_joyport|puae_joyport1|puae_retropad_options|puae_analogmouse|puae_physicalmouse|puae_physical_keyboard_pass_through|puae_joyport_order|puae_mapper_a|puae_mapper_b|puae_mapper_x|puae_mapper_y|puae_mapper_start|puae_mapper_l2|puae_mapper_r2) ' "\$OPT" > "\$OPT.tmp" 2>/dev/null || true
mv "\$OPT.tmp" "\$OPT"
cat >> "\$OPT" <<'EOF'
puae_model = "auto"
puae_model_fd = "A500"
puae_kickstart = "auto"
puae_use_boot_hd = "disabled"
puae_use_whdload = "disabled"
# D-Pad = joystick (not mouse). Most games read FIRE on Amiga control port 2.
puae_joyport = "joystick"
# 2143: RetroPad #1 → Amiga port 2 (player joystick), #2 → port 1
puae_joyport_order = "2143"
puae_retropad_options = "disabled"
puae_analogmouse = "right"
puae_physicalmouse = "enabled"
# Let host keyboard events reach Amiga (Fire/Start from Mac injects keys)
puae_physical_keyboard_pass_through = "enabled"
puae_mapper_x = "RETROK_SPACE"
puae_mapper_start = "RETROK_RETURN"
puae_mapper_l2 = "MOUSE_LEFT_BUTTON"
puae_mapper_r2 = "MOUSE_RIGHT_BUTTON"
EOF
chmod 666 "\$OPT" 2>/dev/null || true
chown 6885:jailer "\$OPT" 2>/dev/null || true
EOS
}

# List connected gamepad-like input devices (for GUI diagnostics).
# Machine lines:
#   pad|NAME|eventX|jsN|score   real / likely gamepad
#   none|msg / hint|msg         when nothing useful found
# BusyBox ash-safe (avoid spaces inside case patterns — they break ash).
# Uses ssh_quick so the Mac UI never stalls on a busy ControlMaster session.
cmd_list_gamepads() {
  ssh_quick "sh -s" <<'EOS'
echo "# gamepads"
found=0

for npath in /sys/class/input/event*/device/name; do
  [ -f "$npath" ] || continue
  name=$(cat "$npath" 2>/dev/null) || continue
  [ -n "$name" ] || continue
  low=$(printf '%s' "$name" | tr 'A-Z' 'a-z')
  ev=$(printf '%s' "$npath" | sed -n 's|.*/\(event[0-9][0-9]*\)/device/name|\1|p')
  base=$(dirname "$npath")

  # Skip TV internals / remotes / audio / pointer
  case "$low" in
    *mouse*|*clickable*|*keyboard*|*keypad*) continue ;;
    *audio*|*headset*|*speaker*) continue ;;
    *rcu*|*remote*|*tone*) continue ;;
    lge\ *|lge-*) continue ;;
    *check*input*|*iot*keypad*|*bluetooth-audio*) continue ;;
  esac

  handlers=""
  if [ -f "$base/uevent" ]; then
    handlers=$(grep '^HANDLERS=' "$base/uevent" 2>/dev/null | sed 's/^HANDLERS=//')
  fi
  js="none"
  for tok in $handlers; do
    case "$tok" in
      js[0-9]|js[0-9][0-9]) js=$tok; break ;;
    esac
  done

  score=0
  case "$low" in
    *gamepad*|*joystick*|*joypad*|*controller*) score=$((score + 5)) ;;
  esac
  case "$low" in
    *gamesir*|*nova*|*game-sir*|*game_sir*) score=$((score + 8)) ;;
  esac
  # GameSir Nova/T4/X2 in PS4 mode report HID name "Wireless Controller"
  case "$low" in
    *wireless*controller*) score=$((score + 10)) ;;
  esac
  case "$low" in
    *xbox*|*x-box*|*8bit*|*dualshock*|*dualsense*|*sony*|*nintendo*|*switch*)
      score=$((score + 6)) ;;
  esac
  case "$low" in
    *steam*|*logitech*|*powera*|*madcatz*|*hid*|*zikway*) score=$((score + 3)) ;;
  esac
  case "$low" in
    *wireless*|*bluetooth*) score=$((score + 1)) ;;
  esac
  # Skip pure touchpad / motion sensor nodes of DualSense / GameSir
  case "$low" in
    *touchpad*|*motion*|*sensor*) continue ;;
  esac
  if [ "$js" != "none" ]; then score=$((score + 4)); fi

  if [ -f "$base/capabilities/abs" ]; then
    abs=$(cat "$base/capabilities/abs" 2>/dev/null | tr -d ' \n')
    if [ -n "$abs" ] && [ "$abs" != "0" ]; then score=$((score + 2)); fi
  fi

  # VID/PID: GameSir PS4 mode = Sony 054c:09cc (or 05c4 older DS4)
  vid_s=""; pid_s=""; vid_dec=""; pid_dec=""
  if [ -f "$base/id/vendor" ] && [ -f "$base/id/product" ]; then
    vid_s=$(cat "$base/id/vendor" 2>/dev/null | tr -d ' \n')
    pid_s=$(cat "$base/id/product" 2>/dev/null | tr -d ' \n')
    # sysfs hex without 0x
    case "$vid_s" in
      054c|54c) score=$((score + 8)) ;;
    esac
    case "$pid_s" in
      09cc|9cc|05c4|5c4) score=$((score + 5)) ;;
    esac
  fi

  # Friendly label for UI: identify GameSir even when HID says Wireless Controller
  label="$name"
  case "$low" in
    *gamesir*|*nova*|*game-sir*|*game_sir*) label="$name" ;;
    *wireless*controller*)
      label="GameSir (PS4 mode)"
      ;;
    *ps4*controller*)
      label="GameSir (PS4 mode)"
      ;;
  esac

  # Threshold keeps Magic Remote ABS devices out; Wireless Controller / GameSir scores high
  if [ "$score" -ge 5 ]; then
    # pad|FRIENDLY|event|js|score|hid=RAW|vid=..|pid=..
    extra="hid=${name}"
    [ -n "$vid_s" ] && extra="${extra}|vid=${vid_s}|pid=${pid_s}"
    echo "pad|${label}|${ev:-?}|${js}|${score}|${extra}"
    found=1
  fi
done

# Fallback: /proc devices with js handler, non-LGE names
if [ "$found" -eq 0 ] && [ -f /proc/bus/input/devices ]; then
  fb=$(awk '
    /^N: Name=/ {
      n=$0; sub(/^N: Name="/,"",n); sub(/"$/,"",n)
    }
    /^H: Handlers=/ {
      h=$0; sub(/^H: Handlers=/,"",h)
      low=tolower(n)
      if (low ~ /mouse|clickable|keyboard|keypad|audio|rcu|remote|tone/) next
      if (low ~ /^lge/ || low ~ /check input|iot keypad/) next
      if (h ~ /js[0-9]/ print "pad|" n "|from-proc|js|fallback"
    }
  ' /proc/bus/input/devices 2>/dev/null)
  if [ -n "$fb" ]; then
    printf '%s\n' "$fb"
    found=1
  fi
fi

if [ "$found" -eq 0 ]; then
  jsany=0
  for j in /dev/input/js0 /dev/input/js1 /dev/input/js2 /dev/input/js3; do
    [ -e "$j" ] && jsany=1
  done
  echo "none|No Bluetooth/USB gamepad detected on the TV"
  if [ "$jsany" -eq 1 ]; then
    echo "hint|TV has joystick nodes (often Magic Remote), but no GameSir/Xbox/8BitDo pad. Pair the GameSir in TV Bluetooth, wake it, wait 5s, Detect again."
  else
    echo "hint|Pair GameSir in TV Settings - Connections - Bluetooth. Wake the pad, wait 5s, Detect again. Re-open RetroArch after pairing."
  fi
fi
EOS
}

# Reconnect previously-paired Bluetooth HID gamepads (GameSir etc.) via webOS bluetooth2.
# Runs entirely on the TV in ONE ssh session (fast, no ControlMaster races).
# Also clears stale /dev/input/event* nodes that block bluetooth2 HID reconnect
# (same approach as webosbrew HID tools).
#
# Machine lines:
#   pad|NAME|eventX|jsN|score
#   bt|NAME|ADDRESS|paired|profiles
#   reconnect|ADDRESS|ok|try|wait|fail|msg
#   stale|N|removed
#   none| / hint|
cmd_reconnect_gamepad() {
  echo "# reconnect-gamepad"
  ssh_quick "python3 -" <<'PY'
import json, os, re, subprocess, sys, time

def luna(uri, payload=None, timeout=3):
    pl = json.dumps(payload if payload is not None else {})
    # luna-send interactive needs a newline on stdin
    # Keep timeouts tight — long hangs made the Mac badge feel like a beachball.
    cmd = (
        f"( sleep 0.06; echo ) | timeout {timeout} "
        f"luna-send -i -n 1 -f '{uri}' '{pl}' 2>/dev/null || true"
    )
    try:
        out = subprocess.check_output(cmd, shell=True, text=True, stderr=subprocess.DEVNULL)
    except Exception:
        return {}
    out = (out or "").strip()
    if not out:
        return {}
    try:
        return json.loads(out)
    except Exception:
        # sometimes multiple JSON objects; take first {
        i = out.find("{")
        if i < 0:
            return {}
        try:
            return json.loads(out[i:])
        except Exception:
            return {}

def list_pads():
    pads = []
    for root, dirs, files in os.walk("/sys/class/input"):
        pass
    for ent in sorted(os.listdir("/sys/class/input")):
        if not ent.startswith("event"):
            continue
        npath = f"/sys/class/input/{ent}/device/name"
        if not os.path.isfile(npath):
            continue
        try:
            name = open(npath).read().strip()
        except Exception:
            continue
        low = name.lower()
        if any(x in low for x in (
            "mouse", "clickable", "keyboard", "keypad", "audio", "headset",
            "speaker", "rcu", "remote", "tone", "check input", "iot keypad",
            "bluetooth-audio", "touchpad", "motion", "sensor",
        )):
            continue
        if low.startswith("lge ") or low.startswith("lge-"):
            continue
        score = 0
        if any(x in low for x in ("gamepad", "joystick", "joypad", "controller")):
            score += 5
        if any(x in low for x in ("gamesir", "nova", "game-sir", "game_sir")):
            score += 8
        if "wireless controller" in low:
            score += 10  # GameSir PS4-mode HID name
        if any(x in low for x in (
            "xbox", "x-box", "8bit", "dualshock", "dualsense", "sony",
            "nintendo", "switch",
        )):
            score += 6
        if any(x in low for x in ("steam", "logitech", "powera", "hid")):
            score += 3
        if any(x in low for x in ("wireless", "bluetooth")):
            score += 1
        # js handler?
        js = "none"
        uevent = f"/sys/class/input/{ent}/device/uevent"
        try:
            for line in open(uevent):
                if line.startswith("HANDLERS="):
                    for tok in line.split("=", 1)[1].split():
                        if re.fullmatch(r"js\d+", tok):
                            js = tok
                            score += 4
                            break
        except Exception:
            pass
        abs_path = f"/sys/class/input/{ent}/device/capabilities/abs"
        try:
            absv = open(abs_path).read().strip().replace(" ", "")
            if absv and absv != "0":
                score += 2
        except Exception:
            pass
        # VID/PID — GameSir PS4 mode clones Sony DS4
        vid = pid = ""
        try:
            vpath = f"/sys/class/input/{ent}/device/id/vendor"
            ppath = f"/sys/class/input/{ent}/device/id/product"
            vid = open(vpath).read().strip()
            pid = open(ppath).read().strip()
            if vid.lower() in ("054c", "54c"):
                score += 8
            if pid.lower() in ("09cc", "9cc", "05c4", "5c4"):
                score += 5
        except Exception:
            pass
        if score >= 5:
            # Friendly UI name: GameSir in PS4 mode looks like Wireless Controller
            label = name
            if any(x in low for x in ("gamesir", "nova", "game-sir", "game_sir")):
                label = name
            elif "wireless controller" in low or "ps4 controller" in low:
                label = "GameSir (PS4 mode)"
            extra = f"hid={name}"
            if vid:
                extra += f"|vid={vid}|pid={pid}"
            pads.append((label, ent, js, score, extra))
    return pads

def clean_stale_events():
    """Remove /dev/input/event* not listed in /proc/bus/input/devices.
    Stale nodes often block bluetooth2 HID reconnect on webOS."""
    try:
        raw = open("/proc/bus/input/devices").read()
    except Exception:
        return 0
    handlers = set()
    for m in re.finditer(r"Handlers=(.*)", raw):
        for h in m.group(1).split():
            if h.startswith("event"):
                handlers.add(h)
    removed = 0
    try:
        for name in os.listdir("/dev/input"):
            if not name.startswith("event"):
                continue
            if name in handlers:
                continue
            path = f"/dev/input/{name}"
            try:
                os.remove(path)
                removed += 1
            except Exception:
                pass
    except Exception:
        pass
    return removed

PAD_NAME = re.compile(
    r"wireless\s*controller|gamesir|game.?sir|nova|xbox|x-box|8bit|dualshock|"
    r"dualsense|sony|switch|pro controller|gamepad|joystick|joypad|controller",
    re.I,
)
SKIP = re.compile(r"^lge|magic remote|headset|speaker|audio|phone|watch|buds", re.I)

# 1) Already connected?
pads = list_pads()
if pads:
    for row in pads:
        name, ev, js, score = row[0], row[1], row[2], row[3]
        extra = row[4] if len(row) > 4 else ""
        if extra:
            print(f"pad|{name}|{ev}|{js}|{score}|{extra}")
        else:
            print(f"pad|{name}|{ev}|{js}|{score}")
    print("reconnect|none|ok|Gamepad already connected (input device present)")
    sys.exit(0)

# 2) Clear stale event nodes (critical for HID reconnect)
n_stale = clean_stale_events()
print(f"stale|{n_stale}|removed stale /dev/input event nodes")

# 3) Adapter ready + stop discovery (discovery can block HID page)
luna("luna://com.webos.service.bluetooth2/adapter/setState",
     {"powered": True, "pairable": True}, timeout=2)
luna("luna://com.webos.service.bluetooth2/adapter/cancelDiscovery", {}, timeout=2)

# 4) Find paired gamepad-like devices
dev = luna("luna://com.webos.service.bluetooth2/device/getStatus", {}, timeout=3)
if not dev.get("returnValue"):
    print("none|Could not query TV Bluetooth (luna bluetooth2)")
    print("hint|Is Dev Mode SSH working? Try Fix network, then click the gamepad icon again.")
    sys.exit(0)

candidates = []
for x in dev.get("devices") or []:
    if not x.get("paired"):
        continue
    name = (x.get("name") or "").strip() or "Unknown"
    if SKIP.search(name):
        continue
    addr = (x.get("address") or "").strip()
    if not addr:
        continue
    profiles = x.get("connectedProfiles") or []
    cod = int(x.get("classOfDevice") or 0)
    is_peripheral = ((cod >> 8) & 0x1F) == 0x05
    is_named = bool(PAD_NAME.search(name))
    if not (is_named or is_peripheral):
        continue
    prof = ",".join(str(p) for p in profiles) if profiles else ""
    hid_on = any(str(p).lower() == "hid" for p in profiles)
    name = name.replace("|", "/")
    candidates.append((name, addr, prof, hid_on))

if not candidates:
    print("none|No paired Bluetooth gamepad on the TV")
    print("hint|Pair the GameSir once in TV Settings → Connections → Bluetooth, then click the icon to reconnect.")
    sys.exit(0)

for name, addr, prof, hid_on in candidates:
    print(f"bt|{name}|{addr}|paired|profiles={prof or 'none'}")

# 5) Kick HID connect once per candidate — return quickly so the Mac UI never beachballs.
# The app polls list-gamepads for up to ~15s after this returns.
print("reconnect|none|wait|PRESS ANY BUTTON on the gamepad NOW to wake it")
any_connecting = False
for name, addr, prof, hid_on in candidates:
    if hid_on:
        print(f"reconnect|{addr}|try|HID already in profiles for {name}")
    else:
        print(f"reconnect|{addr}|try|hid/connect → {name} ({addr})")
    # Short timeouts: empty body is normal; connect still starts
    luna("luna://com.webos.service.bluetooth2/hid/connect", {"address": addr}, timeout=2)
    time.sleep(0.12)
    st = luna("luna://com.webos.service.bluetooth2/hid/getStatus", {"address": addr}, timeout=2)
    if st.get("connected"):
        print(f"reconnect|{addr}|try|HID link up for {name}")
    elif st.get("connecting"):
        any_connecting = True
        print(f"reconnect|{addr}|try|Connecting — press buttons on {name}")
    else:
        any_connecting = True
        print(f"reconnect|{addr}|try|Connect issued for {name}")

# Brief settle — long waits moved to the Mac app (poll list-gamepads)
time.sleep(0.35)
pads = list_pads()
if pads:
    for row in pads:
        name, ev, js, score = row[0], row[1], row[2], row[3]
        extra = row[4] if len(row) > 4 else ""
        if extra:
            print(f"pad|{name}|{ev}|{js}|{score}|{extra}")
        else:
            print(f"pad|{name}|{ev}|{js}|{score}")
    print("reconnect|none|ok|Gamepad input restored")
    sys.exit(0)

print("reconnect|none|wait|Connect kicked off — app will keep checking for the pad")
print("none|Gamepad paired; waiting for input device")
if any_connecting:
    print("hint|Press any button on the GameSir while the icon is blue.")
else:
    print("hint|Power on the GameSir and press a button.")
sys.exit(0)
PY
}

# SAM cannot pass CLI args to native apps, so install a thin shell wrapper as
# "retroarch" that injects: -L <core> -- <content> from next_launch (2 lines).
_ensure_launch_wrapper() {
  ssh_base "sh -s" <<EOS
set -e
APP='${APP_DIR}'
cd "\$APP" || exit 1
# Real binary lives as retroarch.bin
if [ -f retroarch ] && ! head -1 retroarch 2>/dev/null | grep -q '^#!'; then
  mv -f retroarch retroarch.bin
fi
[ -f retroarch.bin ] || { echo "error: missing retroarch.bin — redeploy IPK" >&2; exit 1; }
cat > retroarch << 'WRAP'
#!/bin/sh
BINDIR=\$(dirname "\$0")
REAL="\$BINDIR/retroarch.bin"
RA="\$BINDIR/.config/retroarch"
LAUNCH="\$RA/next_launch"
export LD_LIBRARY_PATH="\$BINDIR/lib:\${LD_LIBRARY_PATH:-}"
if [ -f "\$LAUNCH" ]; then
  CORE=\$(sed -n '1p' "\$LAUNCH")
  CONTENT=\$(sed -n '2p' "\$LAUNCH")
  rm -f "\$LAUNCH"
  if [ -n "\$CORE" ] && [ -n "\$CONTENT" ] && [ -f "\$CORE" ] && [ -f "\$CONTENT" ]; then
    # Keep SAM JSON (\$@) first for WEBOS argv shift; then load core + content.
    exec "\$REAL" "\$@" -L "\$CORE" -- "\$CONTENT"
  fi
fi
exec "\$REAL" "\$@"
WRAP
chmod 755 retroarch retroarch.bin
chown 6885:jailer retroarch retroarch.bin 2>/dev/null || true
EOS
}

# Resolve an Amiga emulator core for .adf launch.
# Never launch ADFs with a non-Amiga core (e.g. MAME) — that always fails.
_resolve_amiga_core() {
  local want="$CORE_PATH" base cores="${RA_DIR}/cores" resolved="" label=""
  base="$(basename "$want" 2>/dev/null || true)"
  case "$base" in
    puae2021*_libretro.so|puae*_libretro.so|amiberry*_libretro.so)
      if ssh_base "test -f $(printf '%q' "$want")" 2>/dev/null; then
        RESOLVED_CORE="$want"
        case "$base" in
          puae2021*) RESOLVED_CORE_NAME="Commodore - Amiga (PUAE 2021)" ;;
          puae*)     RESOLVED_CORE_NAME="Commodore - Amiga (PUAE)" ;;
          amiberry*) RESOLVED_CORE_NAME="Commodore - Amiga (Amiberry)" ;;
        esac
        return 0
      fi
      ;;
  esac

  # Prefer known Amiga cores on the TV (PUAE 2021 first)
  resolved="$(ssh_base "sh -s" <<EOS
CORES='${cores}'
for c in puae2021_libretro.so puae_libretro.so amiberry_libretro.so; do
  if [ -f "\$CORES/\$c" ]; then
    echo "\$CORES/\$c"
    exit 0
  fi
done
# any other puae* / amiberry*
ls -1 "\$CORES"/puae*_libretro.so "\$CORES"/amiberry*_libretro.so 2>/dev/null | head -1
EOS
)" || true
  resolved="$(printf '%s' "$resolved" | tr -d '\r' | head -1)"
  [[ -n "$resolved" ]] || die "No Amiga core on TV. Install PUAE 2021 in Settings → Install selected core (puae2021_libretro.so)."

  if [[ -n "$base" && "$base" != "$(basename "$resolved")" ]]; then
    warn "Configured core is ${base:-none} (not Amiga) — using $(basename "$resolved") for this ADF"
  fi
  RESOLVED_CORE="$resolved"
  case "$(basename "$resolved")" in
    puae2021*) RESOLVED_CORE_NAME="Commodore - Amiga (PUAE 2021)" ;;
    puae*)     RESOLVED_CORE_NAME="Commodore - Amiga (PUAE)" ;;
    amiberry*) RESOLVED_CORE_NAME="Commodore - Amiga (Amiberry)" ;;
    *)         RESOLVED_CORE_NAME="Commodore - Amiga" ;;
  esac
}

# Host keyboard for PUAE pass-through: Game Focus + optional uinput keyboard
# that exists *before* RetroArch starts (SDL only opens keyboards at launch).
_ensure_keyboard_for_cores() {
  log "Ensuring host keyboard + Game Focus for core typing…"
  ssh_base "sh -s" <<EOS || true
set +e
RA='${RA_DIR}'
CFG="\$RA/retroarch.cfg"
mkdir -p "\$RA" 2>/dev/null || true
set_cfg() {
  local key="\$1" val="\$2" tmp
  tmp=\$(mktemp)
  if [ -f "\$CFG" ]; then
    grep -v -E "^[[:space:]]*\${key}[[:space:]]*=" "\$CFG" >"\$tmp" 2>/dev/null || true
  else
    : >"\$tmp"
  fi
  printf '%s = "%s"\\n' "\$key" "\$val" >>"\$tmp"
  mv "\$tmp" "\$CFG"
  chmod a+rw "\$CFG" 2>/dev/null || true
}
# Game Focus: full host keyboard is passed to cores (needed for Amiga typing)
set_cfg input_auto_game_focus "1"
# Don't remap host letters as a fake gamepad
set_cfg keyboard_gamepad_enable "false"
echo "KB_CFG_OK"
EOS

  # Start persistent uinput keyboard before RA so SDL can open it
  ssh_base "python3 -" <<'PY' || true
import os, struct, time, fcntl, glob, subprocess, sys
NAME = "RA Virtual Keyboard"
PIDF = "/tmp/ra-vkbd.pid"
EVF = "/tmp/ra-vkbd-ev"
HOLDER = "/tmp/ra-vkbd-holder.py"
def find_named(name):
    for np in glob.glob("/sys/class/input/event*/device/name"):
        try:
            if open(np).read().strip() == name:
                return "/dev/input/" + np.split("/")[4]
        except OSError:
            pass
    return None
if os.path.exists(PIDF):
    try:
        pid = int(open(PIDF).read().strip())
        os.kill(pid, 0)
        p = find_named(NAME)
        if p:
            open(EVF, "w").write(p)
            print("VKBD_OK existing", p)
            sys.exit(0)
    except Exception:
        pass
script = r'''
import os, struct, time, fcntl, glob, sys
UI_SET_EVBIT=0x40045564; UI_SET_KEYBIT=0x40045565
UI_DEV_SETUP=0x405c5503; UI_DEV_CREATE=0x5501; UI_DEV_DESTROY=0x5502
NAME="RA Virtual Keyboard"
def pack_setup(name):
    return struct.pack("HHHH", 0x03, 0x600d, 0x0a50, 1) + name.encode()[:79].ljust(80,b"\0") + struct.pack("I", 0)
def find_named(name):
    for np in glob.glob("/sys/class/input/event*/device/name"):
        try:
            if open(np).read().strip()==name:
                return "/dev/input/"+np.split("/")[4]
        except OSError: pass
    return None
if os.fork()!=0: sys.exit(0)
os.setsid()
if os.fork()!=0: sys.exit(0)
try:
    sys.stdin.close(); sys.stdout.close(); sys.stderr.close()
except Exception:
    pass
fd=os.open("/dev/uinput", os.O_WRONLY)
fcntl.ioctl(fd, UI_SET_EVBIT, 1)
for code in list(range(1,128))+[70,103,105,106,108,111,125,126]:
    try: fcntl.ioctl(fd, UI_SET_KEYBIT, code)
    except OSError: pass
fcntl.ioctl(fd, UI_DEV_SETUP, pack_setup(NAME))
fcntl.ioctl(fd, UI_DEV_CREATE)
time.sleep(0.4)
ev=find_named(NAME) or ""
open("/tmp/ra-vkbd-ev","w").write(ev)
open("/tmp/ra-vkbd.pid","w").write(str(os.getpid()))
try:
    while True: time.sleep(3600)
finally:
    try: fcntl.ioctl(fd, UI_DEV_DESTROY)
    except Exception: pass
    os.close(fd)
'''
open(HOLDER, "w").write(script)
subprocess.Popen(["python3", HOLDER], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
for _ in range(50):
    time.sleep(0.05)
    p = find_named(NAME)
    if p:
        open(EVF, "w").write(p)
        print("VKBD_OK created", p)
        sys.exit(0)
print("VKBD_FAIL")
PY
}

_prepare_and_launch() {
  local adf_path="$1"
  local adf_name="$2"
  local core core_name

  _resolve_amiga_core
  core="$RESOLVED_CORE"
  core_name="${RESOLVED_CORE_NAME:-Commodore - Amiga}"

  log "Launching: ${adf_name}"
  log "  path: ${adf_path}"
  log "  core: ${core_name}"
  log "  so:   ${core}"

  ssh_base "test -f $(printf '%q' "$core")" || die "Amiga core missing on TV: ${core}"
  ssh_base "test -f $(printf '%q' "$adf_path")" || die "ADF missing on TV: ${adf_path}"

  # Kickstart check (A500 needs kick34005 and/or kick37175)
  if ! ssh_base "ls '${SYSTEM_DIR}'/kick*.A500 '${SYSTEM_DIR}'/kick*.a500 2>/dev/null | head -1 | grep -q ." 2>/dev/null; then
    warn "No Kickstart ROM found in ${SYSTEM_DIR} — Amiga may not boot. Install via Settings → Kickstart BIOS."
  fi

  _ensure_launch_wrapper
  _apply_puae_floppy_opts
  # Game Focus + host keyboard device (must exist before RetroArch starts)
  _ensure_keyboard_for_cores || true

  # Queue content for the launch wrapper (line1=core, line2=adf)
  ssh_base "sh -s" <<EOS
set -e
RA='${RA_DIR}'
CORE='${core}'
ADF='${adf_path}'
CNAME='${core_name}'
mkdir -p "\$RA"
printf '%s\n%s\n' "\$CORE" "\$ADF" > "\$RA/next_launch"
chmod 666 "\$RA/next_launch"
chown 6885:jailer "\$RA/next_launch" 2>/dev/null || true
# keep favorites in sync for manual re-run from menu
mkdir -p "\$RA/playlists/builtin"
cat > "\$RA/playlists/builtin/content_favorites.lpl" <<PL
{
  "version": "1.5",
  "default_core_path": "\$CORE",
  "default_core_name": "\$CNAME",
  "items": [
    {
      "path": "\$ADF",
      "label": "▶ Now Playing — ${adf_name}",
      "core_path": "\$CORE",
      "core_name": "\$CNAME",
      "crc32": "00000000|crc",
      "db_name": "Amiga.lpl"
    }
  ]
}
PL
chmod a+r "\$RA/playlists/builtin/content_favorites.lpl" 2>/dev/null || true
EOS

  # Stop RA first. Graceful close + config_save_on_exit would overwrite joypad
  # index with the OLD in-memory value (e.g. kernel js6) — so apply pad index
  # AFTER kill, immediately before launch.
  cmd_close || true
  cmd_kill || true
  sleep 0.35
  # SDL2 index (usually 0 for the only BT pad) — not kernel /dev/input/jsN
  _apply_best_gamepad_index || true
  sleep 0.15
  cmd_launch

  # Restart pad→mouse mapper in background (nowait) — never block Play for 12s
  if ssh_base "test -f /tmp/ra-pad-mouse.btn" 2>/dev/null; then
    btn="$(ssh_base "cat /tmp/ra-pad-mouse.btn 2>/dev/null" | tr -d '\r\n' || true)"
    act="$(ssh_base "cat /tmp/ra-pad-mouse.action 2>/dev/null" | tr -d '\r\n' || true)"
    btn="${btn:-l3}"
    act="${act:-lmb}"
    cmd_pad_mouse_start "$btn" "$act" nowait >/dev/null 2>&1 \
      || warn "pad→mouse mapper not started (is a gamepad connected?)"
  fi

  # Quick verify only (no long sleep — keeps Mac UI free)
  sleep 0.6
  local verify
  verify="$(ssh_base "sh -s" <<EOS
if [ -f '${RA_DIR}/next_launch' ]; then echo PENDING; else echo CONSUMED; fi
for f in /proc/[0-9]*/cmdline; do
  tr '\\0' ' ' < "\$f" 2>/dev/null | grep -q retroarch.bin && tr '\\0' ' ' < "\$f" && break
done
EOS
)" || true

  say ""
  say "────────────────────────────────────────"
  if printf '%s' "$verify" | grep -q CONSUMED; then
    log "Auto-start OK — ADF should be in DF0 (PUAE running)."
  elif printf '%s' "$verify" | grep -q PENDING; then
    warn "next_launch not consumed — wrapper may be missing; try again or redeploy."
  fi
  if printf '%s' "$verify" | grep -q '\-L'; then
    say "Process includes -L core + content (good)."
  fi
  say "Disk: ${adf_name}"
  say ""
  say "How to leave the title / main menu:"
  say "  • Gamepad  B  = Fire (Amiga control port 2 — most games)"
  say "  • If B still does nothing: Mac app → While playing → Fire / Start"
  say "  • That injects real pad Fire + Space + Enter into the TV"
  say "  • Then Play the game again once so joyport/pad index reloads"
  say "  • Multi-disk: use RetroArch Disc Control when it asks for disk 2"
  say "────────────────────────────────────────"
}

cmd_play() {
  local want="${1:-}"
  PICK_PATH=""
  PICK_NAME=""
  _resolve_pick "$want"
  _prepare_and_launch "$PICK_PATH" "$PICK_NAME"
}

# Resolve preferred libretro core for a content system (must exist on TV).
# Sets RESOLVED_CORE + RESOLVED_CORE_NAME.
_resolve_core_for_system() {
  local sys="$1"
  local cores="${RA_DIR}/cores"
  local list="" c name path
  case "$sys" in
    amiga)
      _resolve_amiga_core
      return $?
      ;;
    snes)
      list="snes9x2010_libretro.so snes9x_libretro.so bsnes_libretro.so bsnes_mercury_performance_libretro.so"
      ;;
    nes)
      list="fceumm_libretro.so nestopia_libretro.so quicknes_libretro.so"
      ;;
    genesis|megadrive|md)
      list="genesis_plus_gx_libretro.so genesis_plus_gx_wide_libretro.so picodrive_libretro.so"
      ;;
    gba)
      list="gpsp_libretro.so mgba_libretro.so vba_next_libretro.so"
      ;;
    gb|gbc)
      list="gambatte_libretro.so sameboy_libretro.so tgbdual_libretro.so"
      ;;
    n64)
      # Prefer ParaLLEl N64: webOSbrew Mupen64Plus-Next (Dec 2025+) needs
      # GLIBCXX_3.4.32 which RetroArch 1.22.2's bundled libstdc++ lacks
      # (max 3.4.30), so dlopen fails and the app exits immediately.
      list="parallel_n64_libretro.so mupen64plus_next_libretro.so"
      ;;
    psx|ps1)
      list="pcsx_rearmed_libretro.so swanstation_libretro.so mednafen_psx_libretro.so"
      ;;
    neogeo|neo-geo|neo_geo|ng)
      # FinalBurn Neo is the main MVS/AES set core; Geolith for .neo cart dumps.
      list="fbneo_libretro.so geolith_libretro.so fbalpha2012_neogeo_libretro.so"
      ;;
    *)
      die "unknown system for play: $sys"
      ;;
  esac

  for c in $list; do
    path="${cores}/${c}"
    if ssh_base "test -f $(printf '%q' "$path")" 2>/dev/null; then
      RESOLVED_CORE="$path"
      RESOLVED_CORE_NAME="$(_core_label "$c")"
      return 0
    fi
  done
  die "No ${sys} engine on TV. Install one in Settings → Amiga & engines (e.g. ${list%% *})."
}

# Resolve media under disks/<sys>/ by list # or name substring.
# Sets PICK_PATH, PICK_NAME, PICK_SYS.
_resolve_media_pick() {
  local sys="$1"
  local want="${2:-}"
  local dir=""
  sys="$(printf '%s' "$sys" | tr '[:upper:]' '[:lower:]')"
  case "$sys" in
    amiga) dir="${DISKS_DIR}" ;;
    snes) dir="${RA_DIR}/disks/snes" ;;
    nes) dir="${RA_DIR}/disks/nes" ;;
    genesis|megadrive|md) dir="${RA_DIR}/disks/genesis"; sys=genesis ;;
    gba) dir="${RA_DIR}/disks/gba" ;;
    gb|gbc) dir="${RA_DIR}/disks/${sys}" ;;
    n64) dir="${RA_DIR}/disks/n64" ;;
    psx|ps1) dir="${RA_DIR}/disks/psx"; sys=psx ;;
    neogeo|neo-geo|neo_geo|ng) dir="${RA_DIR}/disks/neogeo"; sys=neogeo ;;
    *) dir="${RA_DIR}/disks/${sys}" ;;
  esac
  PICK_SYS="$sys"
  PICK_PATH=""
  PICK_NAME=""

  local lines line idx name path
  lines="$(ssh_quick "sh -s" <<EOS
d='${dir}'
[ -d "\$d" ] || exit 0
i=0
find "\$d" -maxdepth 1 -type f 2>/dev/null | sort | while IFS= read -r p; do
  [ -n "\$p" ] || continue
  b=\$(basename "\$p")
  case "\$b" in .*|Thumbs.db) continue ;; esac
  i=\$((i + 1))
  b=\$(printf '%s' "\$b" | tr '|' '/')
  printf '%s|%s|%s\\n' "\$i" "\$b" "\$p"
done
EOS
)" || true

  [[ -n "${lines// }" ]] || die "no media in ${dir}"

  if [[ -z "$want" ]]; then
    # Interactive not available from GUI — require pick
    die "play-media needs a number or name (e.g. play-media snes 1)"
  fi

  if [[ "$want" =~ ^[0-9]+$ ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      idx="${line%%|*}"
      rest="${line#*|}"
      name="${rest%%|*}"
      path="${rest#*|}"
      if [[ "$idx" == "$want" ]]; then
        PICK_PATH="$path"
        PICK_NAME="$name"
        return 0
      fi
    done <<<"$lines"
    die "no ${sys} media with number $want"
  fi

  local want_lc
  want_lc="$(printf '%s' "$want" | tr '[:upper:]' '[:lower:]')"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    rest="${line#*|}"
    name="${rest%%|*}"
    path="${rest#*|}"
    lc="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
    if [[ "$lc" == *"$want_lc"* ]]; then
      PICK_PATH="$path"
      PICK_NAME="$name"
      return 0
    fi
  done <<<"$lines"
  die "no ${sys} media matching \"$want\""
}

# Generic launch: any content path + core (Amiga still gets PUAE opts when sys=amiga).
_prepare_and_launch_content() {
  local content_path="$1"
  local content_name="$2"
  local sys="${3:-amiga}"
  local core core_name

  _resolve_core_for_system "$sys"
  core="$RESOLVED_CORE"
  core_name="${RESOLVED_CORE_NAME:-$sys}"

  log "Launching: ${content_name}"
  log "  system: ${sys}"
  log "  path: ${content_path}"
  log "  core: ${core_name}"
  log "  so:   ${core}"

  ssh_base "test -f $(printf '%q' "$core")" || die "Core missing on TV: ${core}"
  ssh_base "test -f $(printf '%q' "$content_path")" || die "Content missing on TV: ${content_path}"

  if [[ "$sys" == "amiga" ]]; then
    if ! ssh_base "ls '${SYSTEM_DIR}'/kick*.A500 '${SYSTEM_DIR}'/kick*.a500 2>/dev/null | head -1 | grep -q ." 2>/dev/null; then
      warn "No Kickstart ROM found in ${SYSTEM_DIR} — Amiga may not boot."
    fi
    _apply_puae_floppy_opts
  fi

  _ensure_launch_wrapper
  # Host keyboard + Game Focus (before RetroArch process starts)
  _ensure_keyboard_for_cores || true

  ssh_base "sh -s" <<EOS
set -e
RA='${RA_DIR}'
CORE='${core}'
CONTENT='${content_path}'
CNAME='${core_name}'
mkdir -p "\$RA"
printf '%s\n%s\n' "\$CORE" "\$CONTENT" > "\$RA/next_launch"
chmod 666 "\$RA/next_launch"
chown 6885:jailer "\$RA/next_launch" 2>/dev/null || true
mkdir -p "\$RA/playlists/builtin"
cat > "\$RA/playlists/builtin/content_favorites.lpl" <<PL
{
  "version": "1.5",
  "default_core_path": "\$CORE",
  "default_core_name": "\$CNAME",
  "items": [
    {
      "path": "\$CONTENT",
      "label": "▶ Now Playing — ${content_name}",
      "core_path": "\$CORE",
      "core_name": "\$CNAME",
      "crc32": "00000000|crc",
      "db_name": "${sys}.lpl"
    }
  ]
}
PL
chmod a+r "\$RA/playlists/builtin/content_favorites.lpl" 2>/dev/null || true
EOS

  cmd_close || true
  cmd_kill || true
  sleep 0.35
  _apply_best_gamepad_index || true
  sleep 0.15
  cmd_launch

  if [[ "$sys" == "amiga" ]] && ssh_base "test -f /tmp/ra-pad-mouse.btn" 2>/dev/null; then
    btn="$(ssh_base "cat /tmp/ra-pad-mouse.btn 2>/dev/null" | tr -d '\r\n' || true)"
    act="$(ssh_base "cat /tmp/ra-pad-mouse.action 2>/dev/null" | tr -d '\r\n' || true)"
    btn="${btn:-l3}"
    act="${act:-lmb}"
    cmd_pad_mouse_start "$btn" "$act" nowait >/dev/null 2>&1 \
      || warn "pad→mouse mapper not started (is a gamepad connected?)"
  fi

  sleep 1.2
  local verify
  verify="$(ssh_base "sh -s" <<EOS
if [ -f '${RA_DIR}/next_launch' ]; then echo PENDING; else echo CONSUMED; fi
alive=0
for f in /proc/[0-9]*/cmdline; do
  cmd=\$(tr '\\0' ' ' < "\$f" 2>/dev/null || true)
  case "\$cmd" in
    *retroarch.bin*)
      echo "PROC \$cmd"
      alive=1
      break
      ;;
  esac
done
if [ "\$alive" = 0 ]; then
  echo DEAD
  NEW=\$(ls -t '${RA_DIR}/logs'/*.log 2>/dev/null | head -1)
  if [ -n "\$NEW" ]; then
    echo "LOG \$NEW"
    # Surface core load / GLIBCXX / crash clues
    grep -E 'ERROR|Failed to open libretro|GLIBCXX|not found|Segmentation|crash' "\$NEW" 2>/dev/null | tail -8 | sed 's/^/LOGERR /'
  fi
fi
EOS
)" || true

  say ""
  say "────────────────────────────────────────"
  if printf '%s' "$verify" | grep -q CONSUMED; then
    log "Auto-start OK — content should be loading (${sys})."
  elif printf '%s' "$verify" | grep -q PENDING; then
    warn "next_launch not consumed — wrapper may be missing; try again or redeploy."
  fi
  if printf '%s' "$verify" | grep -q '^PROC .*\-L'; then
    say "Process includes -L core + content (good)."
  elif printf '%s' "$verify" | grep -q DEAD; then
    warn "RetroArch exited right after launch — core or content failed to load."
    if printf '%s' "$verify" | grep -q GLIBCXX; then
      warn "Core needs a newer libstdc++ (GLIBCXX) than this RetroArch IPK ships."
      if [[ "$sys" == "n64" ]]; then
        warn "For N64 install ParaLLEl N64: install-core parallel_n64_libretro.so"
      fi
    fi
    printf '%s\n' "$verify" | sed -n 's/^LOGERR //p' | while IFS= read -r line; do
      [[ -n "$line" ]] && warn "$line"
    done
  fi
  say "Media: ${content_name}"
  say "System: ${sys} · Engine: ${core_name}"
  if [[ "$sys" == "amiga" ]]; then
    say ""
    say "Title screen: gamepad B = Fire · While playing → Fire / Start if needed"
  fi
  say "────────────────────────────────────────"
}

# play-media <system> <N|name>  — launch SNES/NES/… (or amiga) content
cmd_play_media() {
  local sys="${1:-}"
  local want="${2:-}"
  [[ -n "$sys" ]] || die "usage: play-media <system> <N|name>"
  PICK_PATH=""
  PICK_NAME=""
  PICK_SYS=""
  _resolve_media_pick "$sys" "$want"
  _prepare_and_launch_content "$PICK_PATH" "$PICK_NAME" "$PICK_SYS"
}

# Delete an ADF from the TV disks directory (by list # or name match).
cmd_remove() {
  local want="${1:-}"
  [[ -n "$want" ]] || die "remove needs ADF # or name (e.g. remove 1)"
  PICK_PATH=""
  PICK_NAME=""
  _resolve_pick "$want"

  # Safety: only delete files under DISKS_DIR that end in .adf
  local disks_norm pick_norm
  disks_norm="$(ssh_base "cd '${DISKS_DIR}' 2>/dev/null && pwd -P" || true)"
  pick_norm="$(ssh_base "cd \"\$(dirname '${PICK_PATH}')\" 2>/dev/null && pwd -P" || true)"
  [[ -n "$disks_norm" && -n "$pick_norm" ]] \
    || die "could not resolve disks/pick paths on TV"
  [[ "$pick_norm" == "$disks_norm" ]] \
    || die "refusing to delete outside disks dir (${PICK_PATH})"
  [[ "${PICK_PATH}" == *.adf || "${PICK_PATH}" == *.ADF ]] \
    || die "refusing to delete non-ADF: ${PICK_PATH}"

  log "Removing ADF from TV: ${PICK_NAME}"
  log "  path: ${PICK_PATH}"
  ssh_base "test -f '${PICK_PATH}' && rm -f -- '${PICK_PATH}'" \
    || die "failed to remove ${PICK_PATH}"
  ssh_base "test ! -e '${PICK_PATH}'" || die "file still present after rm"
  say "Removed: ${PICK_NAME}"
}

# Delete media for any system: remove-media <system> <N|name>
# Safety: only files under ${RA_DIR}/disks/<system>/ (or DISKS_DIR for amiga).
cmd_remove_media() {
  local sys="${1:-}"
  local want="${2:-}"
  [[ -n "$sys" && -n "$want" ]] || die "usage: remove-media <system> <N|name>"
  PICK_PATH=""
  PICK_NAME=""
  PICK_SYS=""
  _resolve_media_pick "$sys" "$want"
  sys="$PICK_SYS"

  local expect_dir=""
  case "$sys" in
    amiga) expect_dir="${DISKS_DIR}" ;;
    snes) expect_dir="${RA_DIR}/disks/snes" ;;
    nes) expect_dir="${RA_DIR}/disks/nes" ;;
    genesis|megadrive|md) expect_dir="${RA_DIR}/disks/genesis"; sys=genesis ;;
    gba) expect_dir="${RA_DIR}/disks/gba" ;;
    gb|gbc) expect_dir="${RA_DIR}/disks/${sys}" ;;
    n64) expect_dir="${RA_DIR}/disks/n64" ;;
    psx|ps1) expect_dir="${RA_DIR}/disks/psx"; sys=psx ;;
    neogeo|neo-geo|neo_geo|ng) expect_dir="${RA_DIR}/disks/neogeo"; sys=neogeo ;;
    *) expect_dir="${RA_DIR}/disks/${sys}" ;;
  esac

  local disks_norm pick_norm
  disks_norm="$(ssh_base "cd $(printf '%q' "$expect_dir") 2>/dev/null && pwd -P" || true)"
  pick_norm="$(ssh_base "cd \"\$(dirname $(printf '%q' "$PICK_PATH"))\" 2>/dev/null && pwd -P" || true)"
  [[ -n "$disks_norm" && -n "$pick_norm" ]] \
    || die "could not resolve disks/pick paths on TV"
  [[ "$pick_norm" == "$disks_norm" ]] \
    || die "refusing to delete outside disks/${sys} (${PICK_PATH})"
  # Amiga: keep old ADF-only rule for remove-media amiga as well
  if [[ "$sys" == "amiga" ]]; then
    [[ "${PICK_PATH}" == *.adf || "${PICK_PATH}" == *.ADF ]] \
      || die "refusing to delete non-ADF under amiga: ${PICK_PATH}"
  fi

  log "Removing ${sys} media from TV: ${PICK_NAME}"
  log "  path: ${PICK_PATH}"
  ssh_base "test -f $(printf '%q' "$PICK_PATH") && rm -f -- $(printf '%q' "$PICK_PATH")" \
    || die "failed to remove ${PICK_PATH}"
  ssh_base "test ! -e $(printf '%q' "$PICK_PATH")" || die "file still present after rm"
  say "Removed (${sys}): ${PICK_NAME}"
}

# ── Mouse via webOS pointer socket (com.webos.service.networkinput) ─────────
# Writing raw EV_REL to /dev/input/event* (ClickableMouse) does NOT move the
# on-screen pointer: RetroArch uses SDL2 and never opens those devices. The
# compositor only drives the cursor from network-input-service’s uinput writer.
# Protocol (LENGTH_PREFIX_32 big-endian + text body), same as PyWebOSTV/SSAP:
#   type:move\ndx:N\ndy:N\ndown:0\n\n
#   type:click\n\n
#
# We also mirror REL/BTN into ClickableMouse so cores that see raw input still
# get deltas (harmless when they do not).

# Python helpers run on the TV (stdin to remote python3).
_mouse_py_prelude() {
  cat <<'PY'
import glob, json, os, socket, struct, subprocess, sys, time

def find_mouse():
    for name_path in glob.glob("/sys/class/input/event*/device/name"):
        try:
            n = open(name_path).read().strip()
        except OSError:
            continue
        if n == "ClickableMouse":
            return "/dev/input/" + name_path.split("/")[4]
    for name_path in glob.glob("/sys/class/input/event*/device/name"):
        rel = name_path.replace("/name", "/capabilities/rel")
        try:
            if open(rel).read().strip() not in ("", "0"):
                return "/dev/input/" + name_path.split("/")[4]
        except OSError:
            pass
    return None

def pack_event(typ, code, value):
    # webOS python is 32-bit (long=4) → 16-byte input_event; kernel accepts it.
    now = time.time()
    sec = int(now)
    usec = int((now - sec) * 1e6)
    for fmt in ("llHHi", "IIHHi", "QQHHi"):
        try:
            return struct.pack(fmt, sec, usec, typ, code, value)
        except struct.error:
            continue
    raise RuntimeError("struct pack failed")

_POINTER_SOCK_CANDIDATES = (
    "/tmp/netinput.pointer.sock",
    "/tmp/networkinput.pointer.sock",
)

def pointer_socket_path(force_luna=False):
    """Return the Unix socket that feeds the system pointer.

    Prefer the well-known path (fast). Only call luna getPointerInputSocket
    if the socket is missing — that call costs ~200ms+ and is not needed once
    network-input-service has created the socket.
    """
    if not force_luna:
        for p in _POINTER_SOCK_CANDIDATES:
            if os.path.exists(p):
                return p
    cmd = (
        "( sleep 0.15; echo ) | timeout 8 luna-send -i -n 1 -f "
        "'luna://com.webos.service.networkinput/getPointerInputSocket' '{}' "
        "2>/dev/null || true"
    )
    try:
        out = subprocess.check_output(["sh", "-c", cmd], text=True, timeout=10)
    except Exception as e:
        raise RuntimeError("getPointerInputSocket failed: %s" % e)
    start, end = out.find("{"), out.rfind("}")
    if start < 0 or end < 0:
        raise RuntimeError("getPointerInputSocket: no JSON (%r)" % out[:200])
    data = json.loads(out[start : end + 1])
    if not data.get("returnValue"):
        raise RuntimeError("getPointerInputSocket: %s" % data)
    path = data.get("socketPath")
    if not path:
        raise RuntimeError("getPointerInputSocket: missing socketPath")
    return path

def _pointer_connect():
    """Connect to pointer socket; refresh via luna if connect fails."""
    last_err = None
    for force in (False, True):
        try:
            path = pointer_socket_path(force_luna=force)
        except Exception as e:
            last_err = e
            continue
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            s.settimeout(2)
            s.connect(path)
            return s
        except OSError as e:
            last_err = e
            try:
                s.close()
            except Exception:
                pass
    raise RuntimeError("pointer socket connect failed: %s" % last_err)

def pointer_send(body: str):
    """Send one framed pointer message (opens a short-lived connection)."""
    if not body.endswith("\n\n"):
        body = body.rstrip("\n") + "\n\n"
    raw = body.encode()
    s = _pointer_connect()
    try:
        # LENGTH_PREFIX_32 big-endian — required for multi-message; fine for one
        s.sendall(struct.pack(">I", len(raw)) + raw)
    finally:
        s.close()

def pointer_send_many(bodies):
    """Send several framed messages on one connection (much faster for bursts)."""
    s = _pointer_connect()
    try:
        s.settimeout(3)
        for body in bodies:
            if not body.endswith("\n\n"):
                body = body.rstrip("\n") + "\n\n"
            raw = body.encode()
            s.sendall(struct.pack(">I", len(raw)) + raw)
    finally:
        s.close()

def show_system_cursor(force=False):
    """Make the webOS Magic Remote / network pointer visible.

    Without this, moves still inject but the on-screen cursor stays hidden
    (especially inside fullscreen RetroArch). Throttled via a stamp file.
    """
    stamp = "/tmp/ra-pointer-shown"
    if not force:
        try:
            if os.path.exists(stamp) and (time.time() - os.path.getmtime(stamp)) < 25:
                return True
        except OSError:
            pass
    cmd = (
        "( sleep 0.08; echo ) | timeout 3 luna-send -i -n 1 -f "
        "'luna://com.webos.service.networkinput/sendSpecialKey' "
        "'{\"key\":\"LGE_CURSOR_SHOW\"}' 2>/dev/null || true"
    )
    try:
        subprocess.check_output(["sh", "-c", cmd], text=True, timeout=4)
    except Exception as e:
        sys.stderr.write("LGE_CURSOR_SHOW failed: %s\\n" % e)
        return False
    try:
        open(stamp, "w").close()
    except OSError:
        pass
    # Nudge so the compositor paints the cursor
    try:
        pointer_send("type:move\\ndx:1\\ndy:0\\ndown:0\\n\\n")
        pointer_send("type:move\\ndx:-1\\ndy:0\\ndown:0\\n\\n")
    except Exception:
        pass
    return True

def inject_rel(dx, dy):
    """Best-effort raw REL into ClickableMouse (for cores / fallback)."""
    ev = find_mouse()
    if not ev:
        return
    fd = os.open(ev, os.O_WRONLY)
    try:
        chunks = []
        if dx:
            chunks.append(pack_event(2, 0, int(dx)))  # EV_REL, REL_X
        if dy:
            chunks.append(pack_event(2, 1, int(dy)))  # EV_REL, REL_Y
        if chunks:
            chunks.append(pack_event(0, 0, 0))  # EV_SYN
            os.write(fd, b"".join(chunks))
    finally:
        os.close(fd)

def inject_btn(code, value):
    """Write EV_KEY to ClickableMouse.

    surface-manager keeps this device open and feeds the focused app (RetroArch
    / SDL). Pointer-socket type:click does NOT emit BTN on this webOS build —
    only CHECK INPUT activity — so raw inject is required for real LMB/RMB.
    """
    ev = find_mouse()
    if not ev:
        raise RuntimeError("no ClickableMouse / relative input device")
    fd = os.open(ev, os.O_WRONLY)
    try:
        # Single write of KEY + SYN so the compositor sees an atomic update
        os.write(fd, pack_event(1, int(code), int(value)) + pack_event(0, 0, 0))
    finally:
        os.close(fd)

def inject_btn_pulse(code, hold=0.12):
    """Press+release on one open fd (more reliable than open/close per edge)."""
    ev = find_mouse()
    if not ev:
        raise RuntimeError("no ClickableMouse / relative input device")
    fd = os.open(ev, os.O_WRONLY)
    try:
        os.write(fd, pack_event(1, int(code), 1) + pack_event(0, 0, 0))
        time.sleep(max(0.04, float(hold)))
        os.write(fd, pack_event(1, int(code), 0) + pack_event(0, 0, 0))
    finally:
        os.close(fd)

def find_keyboards():
    """Host keyboard-like event nodes (CHECK INPUT first). Prefer a single device for typing."""
    prefer = (
        "CHECK INPUT",
        "LGE Network Input",
        "Smart Remote RCU Input",
        "LGE RCU",
        "IoT keypad",
    )
    by_name = {}
    for name_path in glob.glob("/sys/class/input/event*/device/name"):
        try:
            n = open(name_path).read().strip()
        except OSError:
            continue
        by_name[n] = "/dev/input/" + name_path.split("/")[4]
    ordered = []
    for n in prefer:
        if n in by_name and by_name[n] not in ordered:
            ordered.append(by_name[n])
    if ordered:
        return ordered
    # any device with EV_KEY (bit 1 of ev capabilities)
    for name_path in glob.glob("/sys/class/input/event*/device/name"):
        base = name_path.rsplit("/name", 1)[0]
        try:
            ev_caps = open(base + "/capabilities/ev").read().strip().split()
            low = int(ev_caps[0], 16) if ev_caps else 0
            if low & 0x2:  # EV_KEY
                p = "/dev/input/" + name_path.split("/")[4]
                if p not in ordered:
                    ordered.append(p)
        except (OSError, ValueError):
            continue
    return ordered

def find_keyboard():
    """Best single keyboard for letter typing (multi-device blasts mangled Amiga text)."""
    kbs = find_keyboards()
    return kbs[0] if kbs else None

def inject_key(code, value):
    """Inject EV_KEY on the preferred host keyboard (single device)."""
    ev = find_keyboard()
    if not ev:
        raise RuntimeError("no keyboard input device on TV")
    payload = pack_event(1, int(code), int(value)) + pack_event(0, 0, 0)
    try:
        fd = os.open(ev, os.O_WRONLY)
    except OSError as e:
        raise RuntimeError("cannot open keyboard: %s" % e)
    try:
        os.write(fd, payload)
    finally:
        try:
            os.close(fd)
        except OSError:
            pass

def key_tap(code, hold=0.09):
    inject_key(code, 1)
    time.sleep(hold)
    inject_key(code, 0)
    time.sleep(0.02)

# Linux input-event-codes.h (subset for virtual keyboard + navigation)
KEY_ESC, KEY_1, KEY_2, KEY_3, KEY_4, KEY_5 = 1, 2, 3, 4, 5, 6
KEY_6, KEY_7, KEY_8, KEY_9, KEY_0 = 7, 8, 9, 10, 11
KEY_MINUS, KEY_EQUAL, KEY_BACKSPACE = 12, 13, 14
KEY_TAB, KEY_Q, KEY_W, KEY_E, KEY_R, KEY_T = 15, 16, 17, 18, 19, 20
KEY_Y, KEY_U, KEY_I, KEY_O, KEY_P = 21, 22, 23, 24, 25
KEY_LEFTBRACE, KEY_RIGHTBRACE, KEY_ENTER = 26, 27, 28
KEY_LEFTCTRL, KEY_A, KEY_S, KEY_D, KEY_F = 29, 30, 31, 32, 33
KEY_G, KEY_H, KEY_J, KEY_K, KEY_L = 34, 35, 36, 37, 38
KEY_SEMICOLON, KEY_APOSTROPHE, KEY_GRAVE = 39, 40, 41
KEY_LEFTSHIFT, KEY_BACKSLASH, KEY_Z, KEY_X = 42, 43, 44, 45
KEY_C, KEY_V, KEY_B, KEY_N, KEY_M = 46, 47, 48, 49, 50
KEY_COMMA, KEY_DOT, KEY_SLASH, KEY_RIGHTSHIFT = 51, 52, 53, 54
KEY_SPACE = 57
KEY_CAPSLOCK = 58
KEY_F1, KEY_F2, KEY_F3, KEY_F4, KEY_F5 = 59, 60, 61, 62, 63
KEY_F6, KEY_F7, KEY_F8, KEY_F9, KEY_F10 = 64, 65, 66, 67, 68
KEY_F11, KEY_F12 = 87, 88
KEY_UP, KEY_LEFT, KEY_RIGHT, KEY_DOWN = 103, 105, 106, 108
KEY_DELETE = 111
KEY_LEFTMETA = 125

# Character → (keycode, needs_shift)
CHAR_KEYS = {
    "a": (KEY_A, False), "b": (KEY_B, False), "c": (KEY_C, False), "d": (KEY_D, False),
    "e": (KEY_E, False), "f": (KEY_F, False), "g": (KEY_G, False), "h": (KEY_H, False),
    "i": (KEY_I, False), "j": (KEY_J, False), "k": (KEY_K, False), "l": (KEY_L, False),
    "m": (KEY_M, False), "n": (KEY_N, False), "o": (KEY_O, False), "p": (KEY_P, False),
    "q": (KEY_Q, False), "r": (KEY_R, False), "s": (KEY_S, False), "t": (KEY_T, False),
    "u": (KEY_U, False), "v": (KEY_V, False), "w": (KEY_W, False), "x": (KEY_X, False),
    "y": (KEY_Y, False), "z": (KEY_Z, False),
    "A": (KEY_A, True), "B": (KEY_B, True), "C": (KEY_C, True), "D": (KEY_D, True),
    "E": (KEY_E, True), "F": (KEY_F, True), "G": (KEY_G, True), "H": (KEY_H, True),
    "I": (KEY_I, True), "J": (KEY_J, True), "K": (KEY_K, True), "L": (KEY_L, True),
    "M": (KEY_M, True), "N": (KEY_N, True), "O": (KEY_O, True), "P": (KEY_P, True),
    "Q": (KEY_Q, True), "R": (KEY_R, True), "S": (KEY_S, True), "T": (KEY_T, True),
    "U": (KEY_U, True), "V": (KEY_V, True), "W": (KEY_W, True), "X": (KEY_X, True),
    "Y": (KEY_Y, True), "Z": (KEY_Z, True),
    "1": (KEY_1, False), "2": (KEY_2, False), "3": (KEY_3, False), "4": (KEY_4, False),
    "5": (KEY_5, False), "6": (KEY_6, False), "7": (KEY_7, False), "8": (KEY_8, False),
    "9": (KEY_9, False), "0": (KEY_0, False),
    "!": (KEY_1, True), "@": (KEY_2, True), "#": (KEY_3, True), "$": (KEY_4, True),
    "%": (KEY_5, True), "^": (KEY_6, True), "&": (KEY_7, True), "*": (KEY_8, True),
    "(": (KEY_9, True), ")": (KEY_0, True),
    "-": (KEY_MINUS, False), "_": (KEY_MINUS, True),
    "=": (KEY_EQUAL, False), "+": (KEY_EQUAL, True),
    "[": (KEY_LEFTBRACE, False), "{": (KEY_LEFTBRACE, True),
    "]": (KEY_RIGHTBRACE, False), "}": (KEY_RIGHTBRACE, True),
    ";": (KEY_SEMICOLON, False), ":": (KEY_SEMICOLON, True),
    "'": (KEY_APOSTROPHE, False), '"': (KEY_APOSTROPHE, True),
    "`": (KEY_GRAVE, False), "~": (KEY_GRAVE, True),
    "\\": (KEY_BACKSLASH, False), "|": (KEY_BACKSLASH, True),
    ",": (KEY_COMMA, False), "<": (KEY_COMMA, True),
    ".": (KEY_DOT, False), ">": (KEY_DOT, True),
    "/": (KEY_SLASH, False), "?": (KEY_SLASH, True),
    " ": (KEY_SPACE, False),
}

# Named keys (lowercase) → keycode
NAMED_KEYS = {
    "esc": KEY_ESC, "escape": KEY_ESC,
    "enter": KEY_ENTER, "return": KEY_ENTER, "ok": KEY_ENTER,
    "backspace": KEY_BACKSPACE, "bksp": KEY_BACKSPACE, "bs": KEY_BACKSPACE,
    "tab": KEY_TAB,
    "space": KEY_SPACE, "spc": KEY_SPACE,
    "shift": KEY_LEFTSHIFT, "leftshift": KEY_LEFTSHIFT, "rightshift": KEY_RIGHTSHIFT,
    "ctrl": KEY_LEFTCTRL, "control": KEY_LEFTCTRL,
    "caps": KEY_CAPSLOCK, "capslock": KEY_CAPSLOCK,
    "delete": KEY_DELETE, "del": KEY_DELETE,
    "up": KEY_UP, "down": KEY_DOWN, "left": KEY_LEFT, "right": KEY_RIGHT,
    "f1": KEY_F1, "f2": KEY_F2, "f3": KEY_F3, "f4": KEY_F4,
    "f5": KEY_F5, "f6": KEY_F6, "f7": KEY_F7, "f8": KEY_F8,
    "f9": KEY_F9, "f10": KEY_F10, "f11": KEY_F11, "f12": KEY_F12,
    "meta": KEY_LEFTMETA, "cmd": KEY_LEFTMETA, "win": KEY_LEFTMETA,
    # letters / digits as named keys
    **{c: CHAR_KEYS[c][0] for c in "abcdefghijklmnopqrstuvwxyz0123456789"},
}

def type_char(ch, hold=0.09):
    if ch not in CHAR_KEYS:
        raise RuntimeError("unsupported char %r" % ch)
    code, need_shift = CHAR_KEYS[ch]
    if need_shift:
        inject_key(KEY_LEFTSHIFT, 1)
        time.sleep(0.03)
    key_tap(code, hold=hold)
    if need_shift:
        time.sleep(0.02)
        inject_key(KEY_LEFTSHIFT, 0)
    time.sleep(0.05)

def type_named(name, shift=False, hold=0.04):
    n = name.strip().lower()
    if n not in NAMED_KEYS:
        raise RuntimeError("unknown key %r" % name)
    code = NAMED_KEYS[n]
    if shift:
        inject_key(KEY_LEFTSHIFT, 1)
        time.sleep(0.01)
    key_tap(code, hold=hold)
    if shift:
        time.sleep(0.01)
        inject_key(KEY_LEFTSHIFT, 0)

# webOS pointer-socket button names (SSAP / networkinput / Magic Remote)
POINTER_BTN = {
    "esc": ("BACK", "ESC", "ESCAPE"),
    "escape": ("BACK", "ESC", "ESCAPE"),
    "enter": ("ENTER", "RETURN"),
    "return": ("ENTER", "RETURN"),
    "ok": ("ENTER", "RETURN"),
    "back": ("BACK",),
    "home": ("HOME",),
    "menu": ("MENU", "QMENU"),
    "info": ("INFO",),
    "up": ("UP",),
    "down": ("DOWN",),
    "left": ("LEFT",),
    "right": ("RIGHT",),
    "red": ("RED",),
    "green": ("GREEN",),
    "yellow": ("YELLOW",),
    "blue": ("BLUE",),
    "volumeup": ("VOLUMEUP",),
    "volumedown": ("VOLUMEDOWN",),
    "mute": ("MUTE",),
    "channelup": ("CHANNELUP",),
    "channeldown": ("CHANNELDOWN",),
    "play": ("PLAY",),
    "pause": ("PAUSE",),
    "stop": ("STOP",),
    "rewind": ("REWIND",),
    "fastforward": ("FASTFORWARD",),
    "exit": ("EXIT",),
    "guide": ("GUIDE",),
    "settings": ("SETTINGS",),
    "dash": ("DASH",),
    "asterisk": ("ASTERISK",),
    "cc": ("CC",),
}
LINUX_KEY = {
    "esc": KEY_ESC,
    "escape": KEY_ESC,
    "enter": KEY_ENTER,
    "return": KEY_ENTER,
    "ok": KEY_ENTER,
    "back": KEY_ESC,
    "up": KEY_UP,
    "down": KEY_DOWN,
    "left": KEY_LEFT,
    "right": KEY_RIGHT,
    **NAMED_KEYS,
}

EV_SYN, EV_KEY, EV_REL = 0, 1, 2
SYN_REPORT = 0
REL_X, REL_Y = 0, 1
BTN = {"left": 0x110, "right": 0x111, "middle": 0x112}
PY
}

cmd_click() {
  local button="${1:-left}"
  local times="${2:-1}"
  local btn_code hold=0.12

  case "$button" in
    l|left|L|LEFT|1)   btn_code=0x110; button=left ;;   # BTN_LEFT
    r|right|R|RIGHT|3) btn_code=0x111; button=right ;;  # BTN_RIGHT
    m|middle|2)        btn_code=0x112; button=middle ;; # BTN_MIDDLE
    *) die "click button must be left|right|middle (got: $button)" ;;
  esac
  [[ "$times" =~ ^[0-9]+$ ]] && (( times >= 1 && times <= 50 )) \
    || die "times must be 1–50 (got: $times)"

  log "Mouse ${button}-click ×${times} on TV…"
  # shellcheck disable=SC2087
  ssh_base "python3 -" <<PY
$(_mouse_py_prelude)
btn = ${btn_code}
times = ${times}
hold = ${hold}
button = "${button}"

# Do NOT show_system_cursor here — system pointer UI pauses fullscreen audio.
via = []

# Required path: BTN on ClickableMouse (surface-manager → RetroArch / SDL mouse)
try:
    for i in range(times):
        ev = find_mouse()
        if not ev:
            raise RuntimeError("no ClickableMouse")
        fd = os.open(ev, os.O_WRONLY)
        try:
            # Tiny REL so the pointer looks active, then KEY down/up on one fd
            os.write(fd, pack_event(2, 0, 1) + pack_event(0, 0, 0))
            os.write(fd, pack_event(1, btn, 1) + pack_event(0, 0, 0))
            time.sleep(hold)
            os.write(fd, pack_event(1, btn, 0) + pack_event(0, 0, 0))
            os.write(fd, pack_event(2, 0, -1) + pack_event(0, 0, 0))
        finally:
            os.close(fd)
        if i + 1 < times:
            time.sleep(0.08)
    via.append("evdev")
except Exception as e:
    sys.stderr.write("evdev click failed: %s\\n" % e)

if "evdev" not in via:
    sys.stderr.write("error: mouse click failed (no BTN inject)\\n")
    sys.exit(1)
print("ok click button=%s count=%d via=%s" % (button, times, "+".join(via)))
PY
  log "Done"
}

cmd_show_cursor() {
  ssh_base "python3 -" <<PY
$(_mouse_py_prelude)
if show_system_cursor(force=True):
    print("ok cursor=shown")
else:
    sys.stderr.write("error: could not show cursor\\n")
    sys.exit(1)
PY
}

cmd_mouse_move() {
  local dx="${1:-0}" dy="${2:-0}"
  # mode: game (default) = inject into ClickableMouse only — no webOS system
  # cursor (that overlay pauses fullscreen apps / music). pointer = Magic Remote path.
  local mode="${3:-game}"
  [[ "$dx" =~ ^-?[0-9]+$ && "$dy" =~ ^-?[0-9]+$ ]] || die "mouse-move needs integer DX DY"
  # clamp extreme values
  (( dx > 500 )) && dx=500
  (( dx < -500 )) && dx=-500
  (( dy > 500 )) && dy=500
  (( dy < -500 )) && dy=-500
  case "$mode" in
    pointer|system|ui) mode=pointer ;;
    *) mode=game ;;
  esac
  # Never call show_system_cursor here — luna-send + system pointer steals focus
  # and stops RetroArch audio. Use explicit show-cursor only when needed for menus.
  ssh_base "python3 -" <<PY
$(_mouse_py_prelude)
dx, dy = int(${dx}), int(${dy})
mode = "${mode}"
if mode == "pointer":
    try:
        pointer_send("type:move\\ndx:%d\\ndy:%d\\ndown:0\\n\\n" % (dx, dy))
        print("ok move dx=%d dy=%d via=pointer" % (dx, dy))
    except Exception as e:
        sys.stderr.write("pointer socket move failed: %s — falling back to evdev\\n" % e)
        inject_rel(dx, dy)
        print("ok move dx=%d dy=%d via=evdev" % (dx, dy))
else:
    # In-game path: only ClickableMouse REL (SDL / RetroArch). No system cursor.
    try:
        inject_rel(dx, dy)
        print("ok move dx=%d dy=%d via=evdev" % (dx, dy))
    except Exception as e:
        # Fallback if no ClickableMouse
        try:
            pointer_send("type:move\\ndx:%d\\ndy:%d\\ndown:0\\n\\n" % (dx, dy))
            print("ok move dx=%d dy=%d via=pointer" % (dx, dy))
        except Exception as e2:
            sys.stderr.write("error: mouse move failed: %s / %s\\n" % (e, e2))
            sys.exit(1)
PY
}

cmd_mouse_button() {
  local action="${1:-down}" # down|up
  local button="${2:-left}"
  local btn_code
  case "$button" in
    l|left|L|1)  btn_code=0x110; button=left ;;
    r|right|R|3) btn_code=0x111; button=right ;;
    m|middle|2)  btn_code=0x112; button=middle ;;
    *) die "button must be left|right|middle" ;;
  esac
  local value=1
  [[ "$action" == "up" ]] && value=0
  ssh_base "python3 -" <<PY
$(_mouse_py_prelude)
value = ${value}
btn = ${btn_code}
button = "${button}"
action = "${action}"
down = 1 if value else 0
via = []
# Game path only — no system cursor (avoids pausing music / unfocusing RetroArch)
try:
    inject_btn(btn, value)
    via.append("evdev")
except Exception as e:
    sys.stderr.write("evdev button failed: %s\\n" % e)
if "evdev" not in via:
    sys.stderr.write("error: mouse button failed (no BTN inject)\\n")
    sys.exit(1)
print("ok button=%s action=%s via=%s" % (button, action, "+".join(via)))
PY
}

# Send Escape or Enter/Return (and aliases) to the TV.
cmd_key() {
  local name="${1:-}"
  name="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
  case "$name" in
    esc|escape|enter|return|ret|ok) ;;
    *) die "key must be esc|enter (got: ${1:-})" ;;
  esac
  case "$name" in
    ret|ok) name=enter ;;
  esac
  cmd_remote_button "$name"
}

# Virtual keyboard: one named key (a, enter, space, f1, …) or single character.
# Optional 2nd arg: shift=1 for shift-modified named keys.
cmd_keyboard_key() {
  local raw="${1:-}" shift_flag="${2:-0}"
  [[ -n "$raw" ]] || die "keyboard-key needs a name or character"
  local b64 py_shift=0
  b64="$(printf '%s' "$raw" | base64 | tr -d '\n')"
  case "$shift_flag" in
    1|true|TRUE|yes|YES|shift|SHIFT) py_shift=1 ;;
  esac
  ssh_base "python3 -" <<PY
$(_mouse_py_prelude)
import base64
raw = base64.b64decode("${b64}").decode("utf-8", errors="replace")
shift = bool(${py_shift})
via = []
try:
    if len(raw) == 1 and raw in CHAR_KEYS:
        if shift and not CHAR_KEYS[raw][1]:
            type_named(raw.lower() if raw.isalpha() else raw, shift=True)
        else:
            type_char(raw)
        via.append("evdev")
    else:
        type_named(raw, shift=shift)
        via.append("evdev")
        n = raw.strip().lower()
        if n in POINTER_BTN:
            for btn_name in POINTER_BTN[n]:
                try:
                    pointer_send("type:button\\nname:%s\\n\\n" % btn_name)
                    via.append("pointer:%s" % btn_name)
                    break
                except Exception:
                    pass
except Exception as e:
    sys.stderr.write("error: keyboard-key failed: %s\\n" % e)
    sys.exit(1)
print("ok key=%r shift=%s via=%s" % (raw, shift, "+".join(via)))
PY
}

# Type an ASCII string (best-effort; non-mapped chars are skipped with a warning).
# One character at a time with long holds — webOS SDL often drops burst typing.
cmd_type_text() {
  local text="${1-}"
  [[ -n "$text" ]] || die "type-text needs a string"
  local b64
  b64="$(printf '%s' "$text" | base64 | tr -d '\n')"
  ssh_base "python3 -" <<PY
$(_mouse_py_prelude)
import base64
text = base64.b64decode("${b64}").decode("utf-8", errors="replace")
ok = 0
skip = 0
kb = find_keyboard()
# Release modifiers first
try:
    inject_key(KEY_LEFTSHIFT, 0)
except Exception:
    pass
for ch in text:
    try:
        type_char(ch, hold=0.14)
        ok += 1
        time.sleep(0.12)
    except Exception as e:
        skip += 1
        sys.stderr.write("skip %r: %s\\n" % (ch, e))
print("ok typed=%d skipped=%d via=%s mode=per-char" % (ok, skip, kb or "?"))
if ok == 0:
    sys.exit(1)
PY
}

# Run luna-send on the TV and return the JSON body (best-effort).
_remote_luna_json() {
  local uri="$1"
  # Note: ${2:-{}} is wrong in bash — the } ends the expansion early.
  local payload="${2-}"
  [[ -n "$payload" ]] || payload='{}'
  # shellcheck disable=SC2087
  ssh_base "sh -s" <<EOS
( sleep 0.12; echo ) | timeout 5 luna-send -i -n 1 -f '${uri}' '${payload}' 2>/dev/null || true
EOS
}

# Parse volume JSON from getVolume response → print {"volume":N,"muted":bool}
_print_volume_json_from_raw() {
  local out="$1" vol muted
  out="$(printf '%s' "$out" | tr -d '\r' | sed -n '/{/,/}/p' | tr -d '\n' | sed 's/  */ /g')"
  [[ -n "$out" ]] || die "volume-get: empty response from TV"
  if ! printf '%s' "$out" | grep -q '"returnValue"[[:space:]]*:[[:space:]]*true'; then
    die "volume-get failed: $out"
  fi
  vol="$(printf '%s' "$out" | sed -n 's/.*"volume"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)"
  muted="$(printf '%s' "$out" | sed -n 's/.*"muteStatus"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p' | head -1)"
  [[ -n "$vol" ]] || die "volume-get: no volume field in $out"
  [[ -n "$muted" ]] || muted=false
  printf '{"volume":%s,"muted":%s}\n' "$vol" "$muted"
}

# Current master volume via luna (stdout: {"volume":N,"muted":bool}).
cmd_volume_get() {
  local out
  out="$(_remote_luna_json 'luna://com.webos.audio/getVolume' '{}')"
  _print_volume_json_from_raw "$out"
}

# Set absolute volume 0–100 (stdout: JSON after set).
cmd_volume_set() {
  local level="${1:-}"
  [[ "$level" =~ ^[0-9]+$ ]] && (( level >= 0 && level <= 100 )) \
    || die "volume-set needs 0–100 (got: ${1:-})"
  log "TV volume set → ${level}"
  _remote_luna_json 'luna://com.webos.audio/setVolume' "{\"volume\":${level}}" >/dev/null 2>&1 \
    || die "volume-set failed"
  sleep 0.2
  cmd_volume_get
}

# Step volume using paths that actually change level + show the TV OSD.
# NOTE: pointer-socket type:button VOLUMEUP does NOT change volume on webOS
# (verified: level stays the same). Use networkinput sendSpecialKey instead
# (Magic Remote–style key) and fall back to com.webos.audio/volumeUp|Down.
cmd_volume_step() {
  local dir="${1:-up}" n="${2:-1}" i key audio_uri
  dir="$(printf '%s' "$dir" | tr '[:upper:]' '[:lower:]')"
  case "$dir" in
    up|+)   key=VOLUMEUP;   audio_uri='luna://com.webos.audio/volumeUp' ;;
    down|-) key=VOLUMEDOWN; audio_uri='luna://com.webos.audio/volumeDown' ;;
    *) die "volume step dir must be up|down (got: $dir)" ;;
  esac
  [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= 20 )) || die "steps must be 1–20"

  log "TV volume ${dir} ×${n}…"
  local before after before_vol after_vol
  before="$(cmd_volume_get 2>/dev/null || true)"
  before_vol="$(printf '%s' "$before" | sed -n 's/.*"volume":\([0-9]*\).*/\1/p')"

  for ((i = 0; i < n; i++)); do
    # Magic Remote–style key — this is what makes the on-TV volume OSD appear.
    # (pointer-socket type:button VOLUMEUP does NOT change volume here.)
    _remote_luna_json \
      'luna://com.webos.service.networkinput/sendSpecialKey' \
      "{\"key\":\"${key}\"}" >/dev/null 2>&1 || true
    sleep 0.12
  done
  sleep 0.35
  after="$(cmd_volume_get 2>/dev/null || true)"
  after_vol="$(printf '%s' "$after" | sed -n 's/.*"volume":\([0-9]*\).*/\1/p')"

  # Fallback: audio service step if special key was ignored (level unchanged)
  if [[ -n "$before_vol" && -n "$after_vol" && "$before_vol" == "$after_vol" ]]; then
    warn "sendSpecialKey ${key} did not change level — using audio service"
    for ((i = 0; i < n; i++)); do
      _remote_luna_json "$audio_uri" '{}' >/dev/null 2>&1 || true
      sleep 0.1
    done
    sleep 0.25
  fi
  cmd_volume_get
}

# Magic Remote / SSAP-style button (UP, BACK, HOME, VOLUMEUP, RED, …).
cmd_remote_button() {
  local raw="${1:-}"
  [[ -n "$raw" ]] || die "remote-button needs a name (e.g. UP, BACK, ENTER)"
  local name
  name="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
  # digits 0-9
  if [[ "$name" =~ ^[0-9]$ ]]; then
    :
  elif [[ "$name" =~ ^[a-z][a-z0-9_]*$ ]]; then
    :
  else
    die "invalid remote button: $raw"
  fi
  ssh_base "python3 -" <<PY
$(_mouse_py_prelude)
name = "${name}"
via = []
# Map aliases → canonical lookup keys
aliases = {
    "ok": "enter", "select": "enter", "center": "enter",
    "ret": "enter", "return": "enter",
    "esc": "back", "escape": "back",
    "vol+": "volumeup", "volup": "volumeup", "v+": "volumeup",
    "vol-": "volumedown", "voldown": "volumedown", "v-": "volumedown",
    "ch+": "channelup", "chup": "channelup",
    "ch-": "channeldown", "chdown": "channeldown",
    "ff": "fastforward", "fwd": "fastforward",
    "rw": "rewind", "rew": "rewind",
    "opt": "menu", "options": "menu", "qmenu": "menu",
}
key = aliases.get(name, name)
# Digit buttons
if len(key) == 1 and key.isdigit():
    btn_names = (key,)
else:
    btn_names = POINTER_BTN.get(key)
    if not btn_names:
        # Pass through as uppercase SSAP name (e.g. NETFLIX)
        btn_names = (key.upper(),)

show_system_cursor(force=False)

for btn_name in btn_names:
    try:
        pointer_send("type:button\\nname:%s\\n\\n" % btn_name)
        via.append("pointer:%s" % btn_name)
        break
    except Exception as e:
        sys.stderr.write("pointer button %s failed: %s\\n" % (btn_name, e))

# EV_KEY for RetroArch navigation when we have a mapping
code = LINUX_KEY.get(key)
if code is None and key in ("esc", "escape"):
    code = KEY_ESC
if code is not None:
    try:
        key_tap(code)
        via.append("evdev:key%d" % code)
    except Exception as e:
        sys.stderr.write("evdev key failed: %s\\n" % e)

if not via:
    sys.stderr.write("error: remote-button %s failed\\n" % name)
    sys.exit(1)
print("ok button=%s via=%s" % (key, "+".join(via)))
PY
}

# ── Bluetooth / gamepad auto-setup (webOS SDL2) ────────────────────────────
# Interactive "Bind All" cannot be scripted; autoconfig profiles cover known pads.
cmd_setup_controller() {
  local refresh=0
  local a
  for a in "$@"; do
    case "$a" in
      --refresh|-r) refresh=1 ;;
    esac
  done

  local cfg="${RA_DIR}/retroarch.cfg"
  local ac_dir="${RA_DIR}/autoconfig"
  local sdl_dir="${ac_dir}/sdl2"

  log "Auto-configuring RetroArch controller support on TV…"
  log "  config: ${cfg}"
  log "  autoconfig: ${ac_dir}"

  ssh_base "sh -s" <<EOS
set -e
RA='${RA_DIR}'
CFG="\$RA/retroarch.cfg"
AC="\$RA/autoconfig"
SDL="\$AC/sdl2"
mkdir -p "\$RA" "\$AC" "\$SDL" "\$AC/udev" 2>/dev/null || true

# Upsert key = "value" in retroarch.cfg (quoted string values)
set_cfg() {
  local key="\$1" val="\$2" tmp
  tmp=\$(mktemp)
  if [ -f "\$CFG" ]; then
    # Drop existing key lines (any spacing / quoting)
    grep -v -E "^[[:space:]]*\${key}[[:space:]]*=" "\$CFG" >"\$tmp" 2>/dev/null || true
  else
    : >"\$tmp"
  fi
  printf '%s = "%s"\n' "\$key" "\$val" >>"\$tmp"
  mv "\$tmp" "\$CFG"
  chmod a+rw "\$CFG" 2>/dev/null || true
}

# Drivers (webOS build: SDL2 only — udev is not available)
set_cfg input_driver "sdl2"
set_cfg input_joypad_driver "sdl2"
# Autoconfig maps known BT/USB pads → RetroPad (replaces manual Bind All for most controllers)
set_cfg input_autodetect_enable "true"
# Game Focus ON = full host keyboard is passed to cores (PUAE typing).
# "off"/"0" blocks Mac virtual keyboard → Amiga text fields.
set_cfg input_auto_game_focus "1"
# Host letters must not be remapped as a fake gamepad (breaks typing "hello")
set_cfg keyboard_gamepad_enable "false"
set_cfg input_all_users_control_menu "true"
set_cfg input_remap_binds_enable "true"
set_cfg input_max_users "4"
set_cfg joypad_autoconfig_dir "\$AC"
# Default index; _apply_best_gamepad_index overwrites with real BT pad (not Magic Remote)
set_cfg input_player1_analog_dpad_mode "1"
# Keep audio/game running if focus blips (e.g. system pointer / luna)
set_cfg pause_nonactive "false"
set_cfg audio_sync "true"

echo "CFG_OK"
# Count existing sdl2 profiles
n=0
if [ -d "\$SDL" ]; then
  n=\$(ls -1 "\$SDL"/*.cfg 2>/dev/null | wc -l | tr -d ' ')
fi
echo "PROFILES_BEFORE=\${n:-0}"
EOS

  # Download joypad autoconfig (sdl2 + udev packs) if missing or --refresh
  local need_dl=0
  if [[ "$refresh" -eq 1 ]]; then
    need_dl=1
  else
    local n
    n="$(ssh_base "ls -1 '${sdl_dir}'/*.cfg 2>/dev/null | wc -l" | tr -d ' \r' || echo 0)"
    n="${n:-0}"
    if [[ "$n" -lt 20 ]]; then
      need_dl=1
    fi
  fi

  if [[ "$need_dl" -eq 1 ]]; then
    log "Downloading controller profiles (libretro joypad-autoconfig)…"
    # Prefer GitHub archive (has sdl2/ + udev/); fall back to buildbot zip
    ssh_base "sh -s" <<EOS
set -e
RA='${RA_DIR}'
AC="\$RA/autoconfig"
TMP=\$(mktemp -d)
cd "\$TMP"
ok=0
if command -v curl >/dev/null 2>&1; then
  if curl -fsSL --connect-timeout 40 --retry 3 \
      -A "RetroArch-webOS-control/1.0" \
      -o autoconfig.tgz \
      "https://github.com/libretro/retroarch-joypad-autoconfig/archive/refs/heads/master.tar.gz"; then
    tar -xzf autoconfig.tgz 2>/dev/null || tar -xzf autoconfig.tgz
    SRC=\$(find . -maxdepth 1 -type d -name 'retroarch-joypad-autoconfig-*' | head -1)
    if [ -n "\$SRC" ]; then
      mkdir -p "\$AC/sdl2" "\$AC/udev"
      if [ -d "\$SRC/sdl2" ]; then
        cp -f "\$SRC"/sdl2/*.cfg "\$AC/sdl2/" 2>/dev/null || true
      fi
      if [ -d "\$SRC/udev" ]; then
        cp -f "\$SRC"/udev/*.cfg "\$AC/udev/" 2>/dev/null || true
      fi
      find "\$SRC" -type f -name '*.cfg' | while read -r f; do
        case "\$f" in
          */sdl2/*) cp -f "\$f" "\$AC/sdl2/" 2>/dev/null || true ;;
          */udev/*) cp -f "\$f" "\$AC/udev/" 2>/dev/null || true ;;
        esac
      done
      ok=1
    fi
  fi
  if [ "\$ok" -eq 0 ]; then
    if curl -fsSL --connect-timeout 40 --retry 3 \
        -A "RetroArch-webOS-control/1.0" \
        -o autoconfig.zip \
        "http://buildbot.libretro.com/assets/frontend/autoconfig.zip"; then
      mkdir -p "\$AC/sdl2" unpack
      unzip -qo autoconfig.zip -d unpack 2>/dev/null || true
      find unpack -type f -name '*.cfg' | while read -r f; do
        case "\$f" in
          */sdl2/*) cp -f "\$f" "\$AC/sdl2/" 2>/dev/null || true ;;
          */udev/*) mkdir -p "\$AC/udev"; cp -f "\$f" "\$AC/udev/" 2>/dev/null || true ;;
          *) cp -f "\$f" "\$AC/sdl2/" 2>/dev/null || true ;;
        esac
      done
      ok=1
    fi
  fi
fi
rm -rf "\$TMP"
n=\$(ls -1 "\$AC/sdl2"/*.cfg 2>/dev/null | wc -l | tr -d ' ')
echo "PROFILES_AFTER=\${n:-0}"
[ "\${n:-0}" -gt 0 ] || { echo "WARN_NO_PROFILES"; exit 0; }
echo "PROFILES_OK"
EOS
  else
    log "Controller profiles already present (use --refresh to re-download)"
    ssh_base "ls -1 '${sdl_dir}'/*.cfg 2>/dev/null | wc -l" | awk '{print "PROFILES_AFTER="$1}'
  fi

  # Summarize for the GUI (values only — avoid "key=key = value" doubled lines)
  local summary
  summary="$(ssh_base "sh -s" <<EOS
CFG='${cfg}'
AC='${ac_dir}'
val() { grep -E "^[[:space:]]*\$1[[:space:]]*=" "\$CFG" 2>/dev/null | tail -1 | sed -E 's/^[^=]+=[[:space:]]*//; s/^\"//; s/\"[[:space:]]*\$//'; }
echo "---"
echo "input_driver=\$(val input_driver)"
echo "input_joypad_driver=\$(val input_joypad_driver)"
echo "input_autodetect_enable=\$(val input_autodetect_enable)"
echo "joypad_autoconfig_dir=\$(val joypad_autoconfig_dir)"
echo "sdl2_profiles=\$(ls -1 '${sdl_dir}'/*.cfg 2>/dev/null | wc -l | tr -d ' ')"
# List connected input devices (best-effort)
echo "input_devices:"
for n in /sys/class/input/event*/device/name; do
  [ -f "\$n" ] || continue
  printf '  - %s\n' "\$(cat "\$n" 2>/dev/null)"
done 2>/dev/null | head -40
EOS
)" || summary="---
WARN_SUMMARY_SSH_FAILED"
  printf '%s\n' "$summary"

  # Point player 1 at GameSir/DualSense (jsN), not LGE Magic Remote on js0
  local jidx
  jidx="$(_apply_best_gamepad_index 2>/dev/null || true)"
  printf '%s\n' "$jidx"
  log "Controller setup done. Restart RetroArch if it was already running so drivers reload."
  log "Pair the Bluetooth pad on the TV, then launch RetroArch — autoconfig should map it."
  log "Note: interactive 'Bind All' cannot be scripted; profiles replace it for known controllers."
}

# ── Map a spare gamepad button → mouse action (Amiga etc.) ─────────────────
# PUAE/webOS often won't map pad→mouse reliably; we poll the pad and inject
# ClickableMouse BTN_LEFT/RIGHT/MIDDLE (same path as click-left). Default: L3→LMB.
PAD_MOUSE_PID="/tmp/ra-pad-mouse.pid"
PAD_MOUSE_BTN="/tmp/ra-pad-mouse.btn"
PAD_MOUSE_ACTION="/tmp/ra-pad-mouse.action"
PAD_MOUSE_LOG="/tmp/ra-pad-mouse.log"

cmd_pad_mouse_stop() {
  log "Stopping pad→mouse mapper on TV…"
  ssh_base "sh -s" <<'EOS'
PIDF=/tmp/ra-pad-mouse.pid
if [ -f "$PIDF" ]; then
  pid=$(cat "$PIDF" 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    sleep 0.2
    kill -9 "$pid" 2>/dev/null || true
    echo "stopped pid=$pid"
  else
    echo "not_running"
  fi
  rm -f "$PIDF"
else
  # best-effort cleanup
  pkill -f 'ra-pad-mouse-mapper' 2>/dev/null || true
  echo "not_running"
fi
EOS
}

cmd_pad_mouse_status() {
  # ssh_quick: don't queue behind ControlMaster during long TV transfers
  ssh_quick "sh -s" <<'EOS'
PIDF=/tmp/ra-pad-mouse.pid
BTNF=/tmp/ra-pad-mouse.btn
ACTF=/tmp/ra-pad-mouse.action
btn=$(cat "$BTNF" 2>/dev/null || echo "")
act=$(cat "$ACTF" 2>/dev/null || echo "lmb")
if [ -f "$PIDF" ]; then
  pid=$(cat "$PIDF" 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    echo "running pid=$pid button=${btn:-?} action=${act:-lmb}"
    exit 0
  fi
fi
echo "stopped button=${btn:-none} action=${act:-none}"
EOS
}

cmd_pad_mouse_start() {
  local btn_name action_name action_code nowait=0
  btn_name="$(printf '%s' "${1:-l3}" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
  action_name="$(printf '%s' "${2:-lmb}" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
  # Optional 3rd arg: nowait — start mapper and return immediately (used by Play)
  case "${3:-}" in
    nowait|no-wait|bg|background) nowait=1 ;;
  esac
  case "$btn_name" in
    l3|thumb_l|thumbl|ls) btn_name=l3 ;;
    r3|thumb_r|thumbr|rs) btn_name=r3 ;;
    select|back|view) btn_name=select ;;
    start|menu|options) btn_name=start ;;
    l1|lb|leftshoulder) btn_name=l1 ;;
    r1|rb|rightshoulder) btn_name=r1 ;;
    l2|lt|lefttrigger) btn_name=l2 ;;
    r2|rt|righttrigger) btn_name=r2 ;;
    *) die "pad-mouse button must be l3|r3|select|start|l1|r1|l2|r2 (got: $btn_name)" ;;
  esac
  case "$action_name" in
    lmb|left|l|btn_left|click|leftclick|left-click) action_name=lmb; action_code=0x110 ;;
    rmb|right|r|btn_right|rightclick|right-click) action_name=rmb; action_code=0x111 ;;
    mmb|middle|m|btn_middle|mid|middleclick|middle-click) action_name=mmb; action_code=0x112 ;;
    *) die "pad-mouse action must be lmb|rmb|mmb (got: $action_name)" ;;
  esac

  log "Starting pad→${action_name} mapper on TV (button=$btn_name)…"
  cmd_pad_mouse_stop >/dev/null 2>&1 || true

  # Mapper script lives next to this control script (supports analog L2/R2).
  local mapper_src
  mapper_src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ra-pad-mouse-mapper.py"
  [[ -f "$mapper_src" ]] || die "missing mapper script: $mapper_src"

  # Upload mapper + start on TV
  scp -i "$WEBOS_SSH_KEY" \
    -o IdentitiesOnly=yes \
    -o BatchMode=yes \
    -o ConnectTimeout=8 \
    -o StrictHostKeyChecking=accept-new \
    -P "$WEBOS_SSH_PORT" \
    "$mapper_src" \
    "${WEBOS_USER}@${WEBOS_HOST}:/tmp/ra-pad-mouse-mapper.py" \
    >/dev/null

  if [[ "$nowait" -eq 1 ]]; then
    # Fast path for Play: do not poll for gamepad (avoids Mac UI beachball)
    ssh_base "sh -s" <<EOS
set -e
BTN_NAME='${btn_name}'
ACTION_NAME='${action_name}'
echo "\$BTN_NAME" > /tmp/ra-pad-mouse.btn
echo "\$ACTION_NAME" > /tmp/ra-pad-mouse.action
: > /tmp/ra-pad-mouse.log
chmod 755 /tmp/ra-pad-mouse-mapper.py 2>/dev/null || true
export PAD_MOUSE_WAIT=12
nohup python3 -u /tmp/ra-pad-mouse-mapper.py "\$BTN_NAME" "\$ACTION_NAME" >>/tmp/ra-pad-mouse.log 2>&1 &
echo \$! > /tmp/ra-pad-mouse.pid
echo "ok started pid=\$(cat /tmp/ra-pad-mouse.pid) button=\$BTN_NAME action=\$ACTION_NAME (background)"
EOS
    return 0
  fi

  ssh_base "sh -s" <<EOS
set -e
BTN_NAME='${btn_name}'
ACTION_NAME='${action_name}'
echo "\$BTN_NAME" > /tmp/ra-pad-mouse.btn
echo "\$ACTION_NAME" > /tmp/ra-pad-mouse.action
: > /tmp/ra-pad-mouse.log
chmod 755 /tmp/ra-pad-mouse-mapper.py 2>/dev/null || true
# Wait for a real pad (fail fast if none) — do NOT report success while still searching
export PAD_MOUSE_WAIT=8
nohup python3 -u /tmp/ra-pad-mouse-mapper.py "\$BTN_NAME" "\$ACTION_NAME" >>/tmp/ra-pad-mouse.log 2>&1 &
echo \$! > /tmp/ra-pad-mouse.pid
pid=\$(cat /tmp/ra-pad-mouse.pid)

# Poll until ready line or process death (up to ~12s)
i=0
while [ "\$i" -lt 24 ]; do
  if grep -q '^ok mapper' /tmp/ra-pad-mouse.log 2>/dev/null; then
    echo "ok started pid=\$pid button=\$BTN_NAME action=\$ACTION_NAME"
    tail -12 /tmp/ra-pad-mouse.log 2>/dev/null || true
    exit 0
  fi
  if ! kill -0 "\$pid" 2>/dev/null; then
    echo "error: mapper exited without finding a gamepad" >&2
    cat /tmp/ra-pad-mouse.log 2>/dev/null || true
    rm -f /tmp/ra-pad-mouse.pid
    exit 1
  fi
  sleep 0.5
  i=\$((i + 1))
done
# Still running but not ready — kill and fail
kill "\$pid" 2>/dev/null || true
echo "error: mapper timed out waiting for gamepad" >&2
cat /tmp/ra-pad-mouse.log 2>/dev/null || true
rm -f /tmp/ra-pad-mouse.pid
exit 1
EOS
}

# Inject Amiga "Fire / start" the hard way:
#  1) EV_KEY gamepad face buttons on the real BT pad event node (RA/SDL sees them)
#  2) Space + Enter on host keyboard devices (PUAE keyboard pass-through)
#  3) Left mouse click (ClickableMouse) for mouse-title menus
# Used when physical B seems dead (wrong joyport, focus, etc.).
cmd_amiga_fire() {
  echo "# amiga-fire"
  ssh_quick "python3 -" <<'PY'
import glob, os, struct, time, sys

EV_KEY, EV_SYN, SYN_REPORT = 1, 0, 0
# BTN_SOUTH/EAST/NORTH/WEST, BTN_TRIGGER, BTN_0..3
PAD_CODES = (
    (0x130, "BTN_SOUTH/B-Fire"),
    (0x131, "BTN_EAST/A"),
    (0x132, "BTN_NORTH/X"),
    (0x133, "BTN_WEST/Y"),
    (0x120, "BTN_TRIGGER"),
    (0x100, "BTN_0"),
    (0x101, "BTN_1"),
    (0x102, "BTN_2"),
    (0x103, "BTN_3"),
)
KEY_CODES = (
    (57, "SPACE"),
    (28, "ENTER"),
    (44, "Z"),   # RetroArch default keyboard binding for player1 B (Fire)
    (45, "X"),   # player1 A
)
# Amiga mice are 2-button (L/R). Middle is an emulator extra — some titles ignore it.
MOUSE_BTNS = (
    (0x110, "BTN_LEFT/LMB"),
    (0x111, "BTN_RIGHT/RMB"),
    (0x112, "BTN_MIDDLE/MMB"),
)

def pack(t, c, v):
    now = time.time()
    sec = int(now)
    usec = int((now - sec) * 1e6)
    for fmt in ("llHHi", "IIHHi", "QQHHi"):
        try:
            return struct.pack(fmt, sec, usec, int(t), int(c), int(v))
        except struct.error:
            pass
    return struct.pack("llHHi", sec, usec, int(t), int(c), int(v))

def pulse(path, code, hold=0.07):
    try:
        fd = os.open(path, os.O_WRONLY | os.O_NONBLOCK)
    except OSError as e:
        return False, str(e)
    try:
        os.write(fd, pack(EV_KEY, code, 1) + pack(EV_SYN, SYN_REPORT, 0))
        time.sleep(hold)
        os.write(fd, pack(EV_KEY, code, 0) + pack(EV_SYN, SYN_REPORT, 0))
        return True, None
    except OSError as e:
        return False, str(e)
    finally:
        try:
            os.close(fd)
        except OSError:
            pass

# Human-readable firing string for the Mac activity log
fire_steps = []
print("fire|begin|Injecting Fire burst into TV input (for RetroArch / PUAE)")

# Score pad event nodes (prefer Wireless Controller / GameSir, skip LGE remotes)
cands = []
for np in glob.glob("/sys/class/input/event*/device/name"):
    try:
        name = open(np).read().strip()
    except OSError:
        continue
    low = name.lower()
    if any(x in low for x in (
        "lge ", "m-rcu", "w-rcu", "tone", "clickable", "mouse", "keyboard",
        "keypad", "audio", "headset", "motion", "touchpad", "sensor", "check input",
    )):
        continue
    sc = 0
    if "wireless controller" in low:
        sc += 20
    if any(x in low for x in ("gamesir", "nova", "dualshock", "dualsense", "xbox", "8bit")):
        sc += 15
    if any(x in low for x in ("gamepad", "joystick", "controller")):
        sc += 8
    if sc < 8:
        continue
    ev = "/dev/input/" + np.split("/")[4]
    cands.append((sc, name, ev))
cands.sort(reverse=True)

n_pad = 0
for sc, name, ev in cands[:2]:
    ok_names = []
    for code, label in PAD_CODES:
        ok, err = pulse(ev, code)
        if ok:
            n_pad += 1
            ok_names.append(label)
    if ok_names:
        seq = " → ".join(ok_names)
        print(f"pad|{name}|{ev}|ok|{seq}")
        print(f"fire|pad|{name} @ {ev}: {seq}")
        fire_steps.append(f"pad Fire [{name}]: {seq}")
    else:
        print(f"pad|{name}|{ev}|fail|could not write")
        print(f"fire|pad|{name} @ {ev}: WRITE FAILED")
        fire_steps.append(f"pad Fire [{name}]: WRITE FAILED")

if not cands:
    print("pad|none|none|fail|no Bluetooth gamepad event node")
    print("fire|pad|(none) — no Wireless Controller / GameSir event node")
    fire_steps.append("pad Fire: (no gamepad device)")

# Keyboard path (host keys → Amiga when pass-through is on)
kb_names = (
    "CHECK INPUT", "LGE Network Input", "Smart Remote RCU Input",
    "LGE RCU", "IoT keypad",
)
kb_done = False
for np in glob.glob("/sys/class/input/event*/device/name"):
    try:
        name = open(np).read().strip()
    except OSError:
        continue
    if name not in kb_names:
        continue
    ev = "/dev/input/" + np.split("/")[4]
    ok_keys = []
    for code, label in KEY_CODES:
        ok, _ = pulse(ev, code, hold=0.06)
        if ok:
            ok_keys.append(label)
        time.sleep(0.04)
    seq = " → ".join(ok_keys) if ok_keys else "(failed)"
    print(f"key|{name}|{ev}|{seq}")
    print(f"fire|key|{name} @ {ev}: {seq}")
    fire_steps.append(f"keys [{name}]: {seq}")
    kb_done = True
    break
if not kb_done:
    print("key|none|no host keyboard device")
    print("fire|key|(none) — no host keyboard device")
    fire_steps.append("keys: (no host keyboard device)")

# Mouse L/R/M (Amiga is 2-button; MMB is emulated extra)
mouse_done = False
for np in glob.glob("/sys/class/input/event*/device/name"):
    try:
        name = open(np).read().strip()
    except OSError:
        continue
    if "clickable" not in name.lower() and name != "ClickableMouse":
        continue
    ev = "/dev/input/" + np.split("/")[4]
    ok_labels = []
    for code, label in MOUSE_BTNS:
        ok, _ = pulse(ev, code, hold=0.07)
        if ok:
            ok_labels.append(label)
        time.sleep(0.05)
    st = " → ".join(ok_labels) if ok_labels else "FAILED"
    print(f"mouse|{name}|{ev}|{st}")
    print(f"fire|mouse|{name} @ {ev}: {st}")
    fire_steps.append(f"mouse [{name}]: {st}")
    mouse_done = True
    break
if not mouse_done:
    print("fire|mouse|(none) — no ClickableMouse device")
    fire_steps.append("mouse: (no ClickableMouse)")

# One-line summary string for the activity log
summary = " | ".join(fire_steps)
print(f"fire|string|{summary}")
print(f"ok|Fire burst complete ({n_pad} pad pulses)")
print("hint|If still stuck: Play again (reloads joyport), wake pad, press B. Multi-disk games need disk 2 via RetroArch Disc Control.")
sys.exit(0)
PY
}


# ── LG webOS screensaver (general.screenSaverEnabled) ─────────────────────
# Disable while Mac app is active; restore previous values on quit.
SSAVE_STATE_TV="/tmp/ra-screensaver-prev.json"

cmd_screensaver_status() {
  ssh_quick "sh -s" <<'EOS'
( sleep 0.1; echo ) | timeout 6 luna-send -i -n 1 -f \
  luna://com.webos.settingsservice/getSystemSettings \
  '{"category":"general","keys":["screenSaverEnabled","noSignalScreenSaver"]}' 2>/dev/null || true
EOS
}

cmd_screensaver_disable() {
  echo "# screensaver-disable"
  ssh_quick "sh -s" <<'EOS'
SSAVE_STATE=/tmp/ra-screensaver-prev.json
luna() {
  uri="$1"; payload="$2"
  ( sleep 0.1; echo ) | timeout 6 luna-send -i -n 1 -f "$uri" "$payload" 2>/dev/null || true
}
cur=$(luna luna://com.webos.settingsservice/getSystemSettings \
  '{"category":"general","keys":["screenSaverEnabled","noSignalScreenSaver"]}')
echo "status|get|$cur"
python3 - <<PY
import json, os, re, sys
raw = """$cur"""
prev_ss, prev_ns = "on", "on"
try:
    i = raw.find("{")
    j = raw.rfind("}")
    if i >= 0 and j > i:
        d = json.loads(raw[i:j+1])
        s = d.get("settings") or {}
        prev_ss = str(s.get("screenSaverEnabled") or "on")
        prev_ns = str(s.get("noSignalScreenSaver") or "on")
except Exception as e:
    print("warn|parse|%s" % e)
path = "/tmp/ra-screensaver-prev.json"
if not os.path.isfile(path):
    open(path, "w").write(json.dumps({
        "screenSaverEnabled": prev_ss if prev_ss in ("on", "off") else "on",
        "noSignalScreenSaver": prev_ns if prev_ns in ("on", "off") else "on",
        "by": "macos-retroarch-control",
    }))
    print("saved|%s|%s" % (prev_ss, prev_ns))
else:
    print("saved|keep-existing")
print("prev|screenSaverEnabled=%s noSignalScreenSaver=%s" % (prev_ss, prev_ns))
PY
out1=$(luna luna://com.webos.settingsservice/setSystemSettings \
  '{"category":"general","settings":{"screenSaverEnabled":"off","noSignalScreenSaver":"off"}}')
echo "set|$out1"
out2=$(luna luna://com.webos.settingsservice/getSystemSettings \
  '{"category":"general","keys":["screenSaverEnabled","noSignalScreenSaver"]}')
echo "verify|$out2"
echo "ok|screensaver disabled for play"
EOS
}

cmd_screensaver_restore() {
  echo "# screensaver-restore"
  ssh_quick "sh -s" <<'EOS'
python3 - <<'PY'
import json, os, subprocess
state_path = "/tmp/ra-screensaver-prev.json"
ss, ns = "on", "on"
if os.path.isfile(state_path):
    try:
        d = json.load(open(state_path))
        ss = str(d.get("screenSaverEnabled") or "on")
        ns = str(d.get("noSignalScreenSaver") or "on")
        print("loaded|%s|%s" % (ss, ns))
    except Exception as e:
        print("warn|load|%s" % e)
else:
    print("loaded|default|on|on")
if ss not in ("on", "off"):
    ss = "on"
if ns not in ("on", "off"):
    ns = "on"
payload = json.dumps({
    "category": "general",
    "settings": {"screenSaverEnabled": ss, "noSignalScreenSaver": ns},
})
# escape for single-quoted shell
pl = payload.replace("'", "'\"'\"'")
cmd = (
    "( sleep 0.1; echo ) | timeout 6 luna-send -i -n 1 -f "
    "luna://com.webos.settingsservice/setSystemSettings '%s' 2>/dev/null || true"
) % pl
out = subprocess.check_output(["sh", "-c", cmd], text=True, stderr=subprocess.DEVNULL)
print("set|%s" % (out.strip().replace("\n", " ")[:200],))
try:
    os.remove(state_path)
    print("cleared|state")
except Exception:
    pass
print("ok|screensaver restored to screenSaverEnabled=%s noSignalScreenSaver=%s" % (ss, ns))
PY
EOS
}


main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    ""|-h|--help) usage 0 ;;
    status)  cmd_status ;;
    launch|start|open) cmd_launch ;;
    close|stop|quit) cmd_close ;;
    kill|force) cmd_kill ;;
    restart|reload) cmd_restart ;;
    setup-controller|controller-setup|setup-gamepad|configure-controller)
      cmd_setup_controller "$@"
      ;;
    amiga-fire|fire|start-game|press-fire)
      cmd_amiga_fire
      ;;
    pad-mouse-start|amiga-pad-mouse-start)
      cmd_pad_mouse_start "${1:-l3}" "${2:-lmb}"
      ;;
    pad-mouse-stop|amiga-pad-mouse-stop)
      cmd_pad_mouse_stop
      ;;
    pad-mouse-status|amiga-pad-mouse-status)
      cmd_pad_mouse_status
      ;;
    list-gamepads|gamepads)
      cmd_list_gamepads
      ;;
    reconnect-gamepad|connect-gamepad|bt-reconnect-pad|restore-gamepad)
      # Always exit 0 so the app receives machine lines even when pad is asleep
      cmd_reconnect_gamepad || true
      ;;
    adfs|list|ls) cmd_adfs "${1:-}" ;;
    adfs-machine|list-adfs-machine|adfs_machine) cmd_adfs_machine ;;
    cores|emulators) cmd_cores ;;
    cores-machine|list-cores-machine)
      cmd_cores_machine
      ;;
    cores-available|list-available-cores|available-cores)
      cmd_cores_available "${1:-}"
      ;;
    install-core|core-install)
      cmd_install_core "${1:-}"
      ;;
    roms|content|games) cmd_roms ;;
    list-installed|installed)
      cmd_list_installed "${1:-amiga}"
      ;;
    media-machine|list-media-machine|media_machine)
      cmd_media_machine
      ;;
    screensaver-status|ssaver-status)
      cmd_screensaver_status
      ;;
    screensaver-disable|ssaver-disable|ssaver-off)
      cmd_screensaver_disable
      ;;
    screensaver-restore|ssaver-restore|ssaver-on)
      cmd_screensaver_restore
      ;;
    play|run|adf) cmd_play "${1:-}" ;;
    play-media|playmedia|play_media)
      cmd_play_media "${1:-}" "${2:-}"
      ;;
    remove|rm|delete|del) cmd_remove "${1:-}" ;;
    remove-media|removemedia|remove_media)
      cmd_remove_media "${1:-}" "${2:-}"
      ;;
    click)
      cmd_click "${1:-left}" "${2:-1}"
      ;;
    click-left|left-click|lmb)
      cmd_click left "${1:-1}"
      ;;
    click-right|right-click|rmb)
      cmd_click right "${1:-1}"
      ;;
    mouse-move|move)
      cmd_mouse_move "${1:-0}" "${2:-0}"
      ;;
    mouse-down|down)
      cmd_mouse_button down "${1:-left}"
      ;;
    mouse-up|up)
      cmd_mouse_button up "${1:-left}"
      ;;
    show-cursor|cursor-show|show-pointer)
      cmd_show_cursor
      ;;
    key)
      cmd_key "${1:-}"
      ;;
    key-esc|esc|escape)
      cmd_key esc
      ;;
    key-enter|enter|return|ret)
      cmd_key enter
      ;;
    keyboard-key|kb|type-key)
      cmd_keyboard_key "${1:-}" "${2:-0}"
      ;;
    type-text|type|text)
      cmd_type_text "${1-}"
      ;;
    remote-button|remote|btn|button)
      cmd_remote_button "${1:-}"
      ;;
    volume-get|vol-get|get-volume)
      cmd_volume_get
      ;;
    volume-up|vol-up|vol+)
      cmd_volume_step up "${1:-1}"
      ;;
    volume-down|vol-down|vol-)
      cmd_volume_step down "${1:-1}"
      ;;
    volume-set|vol-set|set-volume)
      cmd_volume_set "${1:-}"
      ;;
    # Bare number or free text → play
    [0-9]|[0-9][0-9]|[0-9][0-9][0-9]) cmd_play "$cmd" ;;
    *)
      if [[ "$cmd" == *.* || "$cmd" =~ [A-Za-z] ]]; then
        case "$cmd" in
          status|launch|close|kill|play|cores|roms|adfs|click*) die "unknown command: $cmd" ;;
          *) cmd_play "$cmd" ;;
        esac
      else
        die "unknown command: $cmd (try --help)"
      fi
      ;;
  esac
}

main "$@"
