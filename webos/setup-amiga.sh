#!/usr/bin/env bash
# Amiga setup for webOS RetroArch (PUAE 2021) — single tool.
#
# Paths on TV:
#   system/       → Kickstart BIOS ROMs only (kick34005.A500, …)
#   disks/amiga/  → floppy disk images (.adf) — NOT "roms"
#
# Free ADF catalog (Archive.org only — PD / freeware / demoscene):
#   PD games, Assassins packs, Fred Fish, Scope, MegaDisc, SOMC,
#   PD apps, demoscene packs/music/slideshows/animations.
#   Not commercial game dumps; “old” ≠ free for copyrighted titles.
#
# Flow:
#   1) Pick free/PD site (Archive.org)
#   2) Browse/pick ADFs (Enter = next page, m = site menu)
#   3) Confirm install to LG TV → upload → exit
#
# Kickstarts: your folder / TV folder / your URLs only (no pirate catalog).
#
# Usage:
#   ./webos/setup-amiga.sh
#   ./webos/setup-amiga.sh --site 1 --search solid --ids 1
#   ./webos/setup-amiga.sh --skip-free --kickstarts-local ~/kickstarts
#
# Env: WEBOS_HOST WEBOS_USER WEBOS_SSH_KEY WEBOS_SSH_PORT

set -euo pipefail

WEBOS_HOST="${WEBOS_HOST:-192.168.0.79}"
WEBOS_USER="${WEBOS_USER:-root}"
WEBOS_SSH_KEY="${WEBOS_SSH_KEY:-$HOME/.ssh/webos_deploy}"
WEBOS_SSH_PORT="${WEBOS_SSH_PORT:-22}"

APP_ID="com.retroarch.webos"
APP_DIR="/media/developer/apps/usr/palm/applications/${APP_ID}"
RA_DIR="${APP_DIR}/.config/retroarch"
REMOTE_SYSTEM="${RA_DIR}/system"       # Kickstart BIOS only
REMOTE_DISKS="${RA_DIR}/disks/amiga"   # .adf disk images

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/retroarch-webos-amiga"
mkdir -p "$CACHE_DIR"

SEARCH=""
LIMIT=40
OFFSET=0
LIST_ONLY=0
REFRESH=0
SITE_CHOICE=""
IDS=()
SKIP_FREE=0
SKIP_KICKSTARTS=0
KICKSTART_LOCAL=""
KICKSTART_TV=""
DO_KICKSTARTS=0
KICKSTART_URLS=()
VERIFY_KICKSTARTS=1

# Free / public-domain / freeware / demoscene on Archive.org only.
# These are redistributable PD libraries, magazine PD packs, and demos —
# not commercial TOSEC dumps. (Age alone does not free commercial titles.)
SITES=(
  # ── Games (PD / freeware packs) ──────────────────────────────────────────
  "commodore-amiga-games-public-domain-adf|PD / freeware games|Public domain & freeware Amiga games — ~4300 ADF titles"
  "commodore-amiga-collections-assassins-the|Assassins PD packs|Classic Assassins public-domain game packs — ~845 disks"
  "commodore-amiga-collections-best-of-public-domain-the|Best of Public Domain|Curated “Best of PD” disk sets — ~60 titles"
  "commodore-amiga-collections-pd-unicornics|PD Unicornics|PD Unicornics game/utility library — ~30 disks"
  "commodore-amiga-collections-amiga-public-domain-connection|Amiga PD Connection|Amiga Public Domain Connection library — ~20 disks"
  # ── Classic PD libraries ──────────────────────────────────────────────────
  "commodore-amiga-collections-fred-fish|Fred Fish disks|Fred Fish freely redistributable library — ~1000 disks"
  "commodore-amiga-collections-scope|Scope PD library|Scope public-domain library — ~220 disks"
  "commodore-amiga-collections-software-of-the-month-club-somc|Software of the Month Club|SOMC monthly PD club disks — ~150 disks"
  "commodore-amiga-collections-megadisc|MegaDisc PD|MegaDisc public-domain magazine disks — ~75 disks"
  # ── Apps ──────────────────────────────────────────────────────────────────
  "commodore-amiga-applications-public-domain-adf|PD applications|Public domain utilities & apps — ~800 titles"
  # ── Demoscene (freely distributed) ────────────────────────────────────────
  "commodore-amiga-demos-various-adf|Demoscene (various)|Amiga demoscene disks — ~4300 titles"
  "commodore-amiga-demos-packs|Demoscene packs|Multi-demo pack disks — ~7500 titles"
  "commodore-amiga-demos-music|Music demos|Music / trackmo demos — ~3500 titles"
  "commodore-amiga-demos-slideshows|Slideshow demos|Slideshow / music-disk demos — ~1400 titles"
  "commodore-amiga-demos-animations-and-videos|Animations & videos|Demo animations / video disks — ~1000 titles"
)

# name|bytes|md5 (identification only)
KICK_SPECS=(
  "kick34005.A500|262144|82a21c1890cae844b3df741f2762d48d"
  "kick37175.A500|524288|dc10d7bdd1b6f450773dfb558477c230"
  "kick40068.A1200|524288|"
  "kick40060.CD32|524288|"
  "kick40060.CD32.ext|524288|"
)

log()  { printf '==> %s\n' "$*" >&2; }
warn() { printf 'warn: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
say()  { printf '%s\n' "$*" >&2; }

# Always print full on-TV destinations (Kickstarts vs .adf disks).
print_tv_upload_paths() {
  local mode="${1:-both}" # adf | kickstarts | both
  say ""
  say "────────────────────────────────────────"
  say "LG TV upload locations (${WEBOS_USER}@${WEBOS_HOST}):"
  case "$mode" in
    adf)
      say "  Disk images (.adf):  ${REMOTE_DISKS}/"
      ;;
    kickstarts)
      say "  Kickstart BIOS ROMs: ${REMOTE_SYSTEM}/"
      ;;
    *)
      say "  Kickstart BIOS ROMs: ${REMOTE_SYSTEM}/"
      say "  Disk images (.adf):  ${REMOTE_DISKS}/"
      ;;
  esac
  say "────────────────────────────────────────"
}

usage() {
  cat <<'EOF'
Amiga setup for webOS RetroArch (one script).

  system/       Kickstart BIOS ROMs (kick*.A500)
  disks/amiga/  Floppy disk images (.adf) — not called "roms"

Interactive:
  ./webos/setup-amiga.sh
      site → pick ADFs → confirm install to TV → done

Options:
  --site N|id       Free-catalog site
  --search TEXT     Filter titles
  --limit N / --offset N
  --list            List only
  --ids N…          Install those numbers
  --refresh         Refresh catalog cache
  --skip-free       Skip free ADF browser
  --kickstarts-local DIR
  --kickstarts DIR            (folder ON the TV)
  --kickstart-url URL|NAME=URL  (repeatable; your URLs only)
  --no-verify / --skip-kickstarts

Env: WEBOS_HOST WEBOS_USER WEBOS_SSH_KEY WEBOS_SSH_PORT
EOF
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --search) SEARCH="${2:-}"; shift 2 || die "need text" ;;
    --limit) LIMIT="${2:-}"; shift 2 || die "need N" ;;
    --offset) OFFSET="${2:-}"; shift 2 || die "need N" ;;
    --list) LIST_ONLY=1; shift ;;
    --refresh) REFRESH=1; shift ;;
    --site) SITE_CHOICE="${2:-}"; shift 2 || die "need site" ;;
    --skip-free) SKIP_FREE=1; shift ;;
    --skip-kickstarts) SKIP_KICKSTARTS=1; shift ;;
    --no-verify) VERIFY_KICKSTARTS=0; shift ;;
    --kickstarts-local) KICKSTART_LOCAL="${2:-}"; DO_KICKSTARTS=1; shift 2 || die "need dir" ;;
    --kickstarts) KICKSTART_TV="${2:-}"; DO_KICKSTARTS=1; shift 2 || die "need dir" ;;
    --kickstart-url)
      KICKSTART_URLS+=("${2:-}"); DO_KICKSTARTS=1; shift 2 || die "need URL"
      ;;
    --ids)
      shift
      while [[ $# -gt 0 && "$1" != --* ]]; do IDS+=("$1"); shift; done
      ;;
    -*) die "unknown option: $1" ;;
    *) die "unexpected: $1" ;;
  esac
done

if [[ "$DO_KICKSTARTS" -eq 1 && "$SKIP_FREE" -eq 0 && -z "$SITE_CHOICE" && -z "$SEARCH" && "${#IDS[@]}" -eq 0 && "$LIST_ONLY" -eq 0 ]]; then
  if [[ -n "$KICKSTART_LOCAL" || -n "$KICKSTART_TV" || ${#KICKSTART_URLS[@]} -gt 0 ]]; then
    SKIP_FREE=1
  fi
fi

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing: $1"; }

# -n so SSH does not steal menu stdin
ssh_cmd() {
  ssh -n -i "$WEBOS_SSH_KEY" \
    -o IdentitiesOnly=yes \
    -o ConnectTimeout=15 \
    -o StrictHostKeyChecking=accept-new \
    -p "$WEBOS_SSH_PORT" \
    "${WEBOS_USER}@${WEBOS_HOST}" \
    "$@"
}

ssh_sh() {
  ssh -i "$WEBOS_SSH_KEY" \
    -o IdentitiesOnly=yes \
    -o ConnectTimeout=15 \
    -o StrictHostKeyChecking=accept-new \
    -p "$WEBOS_SSH_PORT" \
    "${WEBOS_USER}@${WEBOS_HOST}" \
    /bin/sh -s
}

scp_to() {
  scp -i "$WEBOS_SSH_KEY" \
    -o IdentitiesOnly=yes \
    -o ConnectTimeout=15 \
    -o StrictHostKeyChecking=accept-new \
    -P "$WEBOS_SSH_PORT" \
    "$@"
}

ask() {
  local prompt="$1" default="${2:-}" ans=""
  if [[ -n "$default" ]]; then
    printf '%s [%s]: ' "$prompt" "$default" >&2
  else
    printf '%s: ' "$prompt" >&2
  fi
  if ! IFS= read -r ans; then
    printf '\n' >&2
    printf '%s\n' ""
    return 0
  fi
  if [[ -z "${ans}" && -n "$default" ]]; then
    printf '%s\n' "$default"
  else
    printf '%s\n' "${ans}"
  fi
}

normalize_kickstart_url_arg() {
  local arg="$1" name="" url=""
  if [[ "$arg" == *"=http"* || ( "$arg" == *"="* && "$arg" != http* ) ]]; then
    name="${arg%%=*}"
    url="${arg#*=}"
  else
    url="$arg"
  fi
  if [[ "$url" =~ ^https?://github\.com/([^/]+)/([^/]+)/blob/([^/]+)/(.+)$ ]]; then
    url="https://raw.githubusercontent.com/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/${BASH_REMATCH[3]}/${BASH_REMATCH[4]}"
  fi
  if [[ -z "$name" ]]; then
    name="$(basename "${url%%\?*}")"
    name="${name%.rom}"
  fi
  case "$name" in
    kick*.a500) name="$(printf '%s' "$name" | sed 's/\.a500$/.A500/')" ;;
    kick*.a1200) name="$(printf '%s' "$name" | sed 's/\.a1200$/.A1200/')" ;;
  esac
  printf '%s=%s\n' "$name" "$url"
}

# ── Sites ──────────────────────────────────────────────────────────────────

select_site() {
  local choice i entry id rest label desc
  if [[ -n "$SITE_CHOICE" ]]; then
    if [[ "$SITE_CHOICE" =~ ^[0-9]+$ ]]; then
      i=$((SITE_CHOICE - 1))
      (( i >= 0 && i < ${#SITES[@]} )) || die "invalid --site"
      echo "${SITES[$i]%%|*}"
      return
    fi
    local lc
    lc="$(printf '%s' "$SITE_CHOICE" | tr '[:upper:]' '[:lower:]')"
    for entry in "${SITES[@]}"; do
      id="${entry%%|*}"
      rest="${entry#*|}"
      label="${rest%%|*}"
      if [[ "$id" == "$SITE_CHOICE" ]] \
        || printf '%s' "$id $label" | tr '[:upper:]' '[:lower:]' | grep -q -- "$lc"; then
        echo "$id"
        return
      fi
    done
    die "unknown --site: $SITE_CHOICE"
  fi

  say ""
  say "Free / public-domain / freeware Amiga disk images (.adf)"
  say "Sources: Archive.org PD libraries, magazine PD packs, demoscene."
  say "(Not commercial ROMs — use titles you may legally copy.)"
  say ""
  i=1
  for entry in "${SITES[@]}"; do
    id="${entry%%|*}"
    rest="${entry#*|}"
    label="${rest%%|*}"
    desc="${rest#*|}"
    printf '  %2d) %s\n' "$i" "$label" >&2
    printf '        %s\n' "$desc" >&2
    printf '        https://archive.org/details/%s\n' "$id" >&2
    say ""
    i=$((i + 1))
  done
  say "   q) Quit"
  say ""
  choice="$(ask "Site" "1")"
  case "$choice" in
    q|Q|quit|QUIT) echo "__QUIT__"; return 0 ;;
  esac
  [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#SITES[@]} )) \
    || die "invalid site: $choice"
  entry="${SITES[$((choice - 1))]}"
  echo "${entry%%|*}"
}

site_label() {
  local want="$1" entry id rest
  for entry in "${SITES[@]}"; do
    id="${entry%%|*}"
    if [[ "$id" == "$want" ]]; then
      rest="${entry#*|}"
      echo "${rest%%|*}"
      return
    fi
  done
  echo "$want"
}

# ── Catalog ────────────────────────────────────────────────────────────────

fetch_catalog() {
  local item="$1"
  local json="${CACHE_DIR}/${item}.json"
  local tsv="${CACHE_DIR}/${item}.tsv"
  if [[ "$REFRESH" -eq 1 || ! -s "$tsv" ]]; then
    log "Fetching catalog: $item …"
    need_cmd curl
    need_cmd python3
    curl -fsSL --connect-timeout 45 \
      -A "Mozilla/5.0 (compatible; RetroArch-webOS-setup/1.0)" \
      "https://archive.org/metadata/${item}" -o "$json"
    python3 - "$json" "$tsv" "https://archive.org/download/${item}" <<'PY'
import json, sys, urllib.parse
meta_path, tsv_path, dl_base = sys.argv[1:4]
with open(meta_path, encoding="utf-8") as f:
    data = json.load(f)
rows = []
for fi in data.get("files", []):
    name = fi.get("name") or ""
    low = name.lower()
    if not low.endswith((".zip", ".adf", ".adz", ".dms", ".lha", ".7z")):
        continue
    base = name.split("/")[-1]
    if base.lower() in ("thumbs.zip", "files.xml", "meta.sqlite"):
        continue
    size = str(fi.get("size") or "0")
    url = dl_base.rstrip("/") + "/" + urllib.parse.quote(name)
    title = base
    for ext in (".zip", ".adf", ".adz", ".dms", ".lha", ".7z",
                ".ZIP", ".ADF", ".ADZ", ".DMS", ".LHA", ".7Z"):
        if title.endswith(ext):
            title = title[: -len(ext)]
            break
    rows.append((title, base, size, url))
rows.sort(key=lambda r: r[0].lower())
with open(tsv_path, "w", encoding="utf-8") as out:
    for title, base, size, url in rows:
        def esc(s: str) -> str:
            return s.replace("\t", " ").replace("\n", " ")
        out.write(f"{esc(title)}\t{esc(base)}\t{esc(size)}\t{esc(url)}\n")
print(f"  entries: {len(rows)}", file=sys.stderr)
PY
  else
    log "Using cached catalog for $item (--refresh to update)"
  fi
  [[ -s "$tsv" ]] || die "empty catalog for $item"
  echo "$tsv"
}

filter_page() {
  local tsv="$1" out total
  out="$(mktemp)"
  if [[ -n "$SEARCH" ]]; then
    grep -i -- "$SEARCH" "$tsv" >"$out" || true
  else
    cp "$tsv" "$out"
  fi
  total="$(wc -l <"$out" | tr -d ' ')"
  if [[ "$OFFSET" -gt 0 ]]; then
    tail -n +"$((OFFSET + 1))" "$out" >"${out}.2" || true
    mv "${out}.2" "$out"
  fi
  head -n "$LIMIT" "$out" >"${out}.3"
  mv "${out}.3" "$out"
  echo "$out|$total"
}

human_size() {
  local n="${1:-0}"
  if ! [[ "$n" =~ ^[0-9]+$ ]]; then echo "?"; return; fi
  if [[ "$n" -ge 1048576 ]]; then
    awk -v n="$n" 'BEGIN{printf "%.1fM", n/1048576}'
  elif [[ "$n" -ge 1024 ]]; then
    echo "$((n / 1024))K"
  else
    echo "${n}B"
  fi
}

show_adf_menu() {
  local file="$1" total="$2" site_name="$3"
  local i=1 title base size url
  say ""
  say "────────────────────────────────────────"
  say "Site: $site_name"
  if [[ -n "$SEARCH" ]]; then
    say "Filter: \"$SEARCH\"  (limit $LIMIT, offset $OFFSET, ~$total matches)"
  else
    say "Showing $LIMIT titles (offset $OFFSET, ~$total total)"
  fi
  say "Disk images (.adf) → $REMOTE_DISKS"
  say "Kickstart BIOS     → $REMOTE_SYSTEM"
  say "────────────────────────────────────────"
  say ""
  while IFS=$'\t' read -r title base size url; do
    [[ -z "${title:-}" ]] && continue
    printf '  %3d) %s  (%s)\n' "$i" "$title" "$(human_size "$size")" >&2
    i=$((i + 1))
  done <"$file"
  say ""
  if [[ "$total" -gt $((OFFSET + LIMIT)) ]]; then
    say "More titles available — press Enter for next page"
  fi
}

# stdout: NEXT | PREV | MENU | CANCEL | IDS 1 3 5
select_adfs() {
  local page_file="$1" count has_more="${2:-0}" has_prev="${3:-0}"
  count="$(grep -c . "$page_file" 2>/dev/null || echo 0)"
  [[ "$count" -gt 0 ]] || die "no titles on this page"

  if [[ "${#IDS[@]}" -gt 0 ]]; then
    echo "IDS ${IDS[*]}"
    return 0
  fi

  say "What next?"
  say "  Enter / next     next page of ADFs"
  if [[ "$has_prev" -eq 1 ]]; then
    say "  p / prev         previous page of ADFs"
  fi
  say "  m / menu / back  back to main site list"
  say "  1 3 5            download those numbers (this page)"
  say "  1-10             download a range (this page)"
  say "  all              download all on this page"
  say "  q                quit"
  say ""
  local choice
  choice="$(ask "Selection" "next")"
  if [[ -z "$choice" ]]; then
    echo "CANCEL"
    return 0
  fi
  case "$choice" in
    n|N|next|NEXT|more|MORE|+) echo "NEXT"; return 0 ;;
    p|P|prev|PREV|previous) echo "PREV"; return 0 ;;
    m|M|menu|MENU|back|BACK|sites|SITES) echo "MENU"; return 0 ;;
    none|q|Q|quit|QUIT|cancel|CANCEL) echo "CANCEL"; return 0 ;;
    all|a|A)
      echo "IDS $(seq 1 "$count" | tr '\n' ' ')"
      return 0
      ;;
  esac

  local tok a b n
  local -a picked=()
  for tok in $choice; do
    if [[ "$tok" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"
      if (( a > b )); then local t="$a"; a="$b"; b="$t"; fi
      for ((n=a; n<=b; n++)); do
        if (( n >= 1 && n <= count )); then picked+=("$n")
        else warn "Out of range: $n"; fi
      done
    elif [[ "$tok" =~ ^[0-9]+$ ]]; then
      if (( tok >= 1 && tok <= count )); then picked+=("$tok")
      else warn "Out of range: $tok"; fi
    else
      warn "Ignoring: $tok"
    fi
  done
  if [[ "${#picked[@]}" -eq 0 ]]; then
    echo "CANCEL"
    return 0
  fi
  echo "IDS ${picked[*]}"
}

download_and_install() {
  local page_file="$1"
  shift
  local -a nums=("$@")
  [[ "${#nums[@]}" -gt 0 ]] || { warn "Nothing selected"; return; }

  need_cmd curl
  need_cmd unzip
  need_cmd scp
  need_cmd ssh

  local work
  work="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$work'" RETURN

  # Ensure parents are traversable by the jailed RetroArch process
  ssh_cmd "mkdir -p '${REMOTE_DISKS}' && chmod a+rwx '${RA_DIR}' '${RA_DIR}/disks' '${REMOTE_DISKS}'" || true

  local -a lines=()
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    lines+=("$line")
  done <"$page_file"

  local n idx title base size url zip_path extract adf rname sz
  for n in "${nums[@]}"; do
    idx=$((n - 1))
    if (( idx < 0 || idx >= ${#lines[@]} )); then
      warn "Out of range: $n"
      continue
    fi
    IFS=$'\t' read -r title base size url <<<"${lines[$idx]}"
    log "[${n}] $title"
    zip_path="${work}/dl_${n}.zip"
    if ! curl -fL --connect-timeout 30 --retry 5 --retry-delay 2 \
        -A "Mozilla/5.0 (compatible; RetroArch-webOS-setup/1.0)" \
        -o "$zip_path" "$url"; then
      warn "  download failed"
      continue
    fi
    sz="$(wc -c <"$zip_path" | tr -d ' ')"
    if [[ "${sz:-0}" -lt 1000 ]]; then
      warn "  too small (${sz} bytes) — skip"
      continue
    fi

    extract="${work}/ex_${n}"
    mkdir -p "$extract"
    adf=""
    case "$base" in
      *.adf|*.ADF|*.adz|*.ADZ)
        cp -f "$zip_path" "$extract/disk.adf"
        adf="$extract/disk.adf"
        ;;
      *)
        if unzip -l "$zip_path" >/dev/null 2>&1; then
          unzip -o -q "$zip_path" -d "$extract" || true
          adf="$(find "$extract" -type f \( -iname '*.adf' -o -iname '*.adz' \) | head -1 || true)"
        elif command -v 7z >/dev/null 2>&1; then
          7z x -y -o"$extract" "$zip_path" >/dev/null 2>&1 || true
          adf="$(find "$extract" -type f \( -iname '*.adf' -o -iname '*.adz' \) | head -1 || true)"
        fi
        ;;
    esac

    if [[ -z "$adf" || ! -f "$adf" ]]; then
      warn "  no .adf inside archive"
      continue
    fi

    rname="$(basename "$adf" | tr ' ' '_' | tr -cd 'A-Za-z0-9._-')"
    [[ -n "$rname" ]] || rname="disk_${n}.adf"
    case "$rname" in
      *.adf|*.ADF|*.adz|*.ADZ) ;;
      *) rname="${rname}.adf" ;;
    esac

    scp_to "$adf" "${WEBOS_USER}@${WEBOS_HOST}:${REMOTE_DISKS}/${rname}"
    # world-readable so jailer (non-root) can list/load content
    ssh_cmd "chmod a+r '${REMOTE_DISKS}/${rname}' 2>/dev/null || true; chown 6885:jailer '${REMOTE_DISKS}/${rname}' 2>/dev/null || true"
    log "  uploaded → ${WEBOS_USER}@${WEBOS_HOST}:${REMOTE_DISKS}/${rname}"
  done

  ssh_cmd "chmod a+rwx '${RA_DIR}/disks' '${REMOTE_DISKS}' 2>/dev/null || true; chmod a+r '${REMOTE_DISKS}'/* 2>/dev/null || true"
  # Keep browser pointing at disks/amiga and show all files (not core-filtered)
  ssh_cmd "CFG='${RA_DIR}/retroarch.cfg'; touch \"\$CFG\"; grep -v -E '^(rgui_browser_directory|menu_navigation_browser_filter_supported_extensions_enable|filter_by_current_core) ' \"\$CFG\" > \"\$CFG.n\" 2>/dev/null || true; mv \"\$CFG.n\" \"\$CFG\" 2>/dev/null || true; printf '%s\\n' 'rgui_browser_directory = \"${REMOTE_DISKS}\"' 'menu_navigation_browser_filter_supported_extensions_enable = \"false\"' 'filter_by_current_core = \"false\"' >> \"\$CFG\"" || true

  print_tv_upload_paths adf
  log "Disk images currently on TV at ${REMOTE_DISKS}/:"
  ssh_cmd "ls -lah '${REMOTE_DISKS}'" || true
  log "In RetroArch: fully close app → open → Load Core → PUAE 2021 → Load Content (starts in disks/amiga)."
}

run_free_catalog() {
  [[ "$SKIP_FREE" -eq 1 ]] && { log "Skipping free ADF catalog"; return; }

  need_cmd curl
  need_cmd python3

  local item="__RESELECT__" label tsv page_file total result count action has_more has_prev
  local -a nums=()
  local first_site=1

  while true; do
    if [[ -z "${item:-}" || "${item:-}" == "__RESELECT__" ]]; then
      if [[ "$first_site" -eq 1 && -n "${SITE_CHOICE:-}" ]]; then
        :
      else
        SITE_CHOICE=""
      fi
      first_site=0
      OFFSET=0
      item="$(select_site)"
      if [[ "$item" == "__QUIT__" ]]; then
        log "Quit"
        return
      fi
      label="$(site_label "$item")"
      log "Selected site: $label ($item)"
      tsv="$(fetch_catalog "$item")"
    fi

    if [[ "$LIST_ONLY" -eq 1 ]]; then
      result="$(filter_page "$tsv")"
      page_file="${result%%|*}"
      total="${result##*|}"
      show_adf_menu "$page_file" "$total" "$label"
      rm -f "$page_file"
      return
    fi

    while true; do
      result="$(filter_page "$tsv")"
      page_file="${result%%|*}"
      total="${result##*|}"
      count="$(grep -c . "$page_file" 2>/dev/null || echo 0)"

      if [[ "$count" -eq 0 ]]; then
        rm -f "$page_file"
        if [[ "$OFFSET" -gt 0 ]]; then
          warn "No more titles on this page."
          OFFSET=$((OFFSET - LIMIT))
          (( OFFSET < 0 )) && OFFSET=0
          continue
        fi
        die "No titles match. Try another --search or site."
      fi

      has_more=0
      has_prev=0
      (( OFFSET + LIMIT < total )) && has_more=1
      (( OFFSET > 0 )) && has_prev=1

      show_adf_menu "$page_file" "$total" "$label"
      if [[ "$has_more" -eq 1 ]]; then
        say "Page $((OFFSET / LIMIT + 1)) — press Enter for next page"
      else
        say "Page $((OFFSET / LIMIT + 1)) (last page)"
      fi

      action="$(select_adfs "$page_file" "$has_more" "$has_prev")"
      case "$action" in
        NEXT)
          rm -f "$page_file"
          if [[ "$has_more" -eq 0 ]]; then
            warn "Already on the last page."
            continue
          fi
          OFFSET=$((OFFSET + LIMIT))
          log "Next page (offset $OFFSET)…"
          continue
          ;;
        PREV)
          rm -f "$page_file"
          if [[ "$has_prev" -eq 0 ]]; then
            warn "Already on the first page."
            continue
          fi
          OFFSET=$((OFFSET - LIMIT))
          (( OFFSET < 0 )) && OFFSET=0
          log "Previous page (offset $OFFSET)…"
          continue
          ;;
        MENU)
          rm -f "$page_file"
          log "Back to main site list…"
          item="__RESELECT__"
          break
          ;;
        CANCEL|"")
          rm -f "$page_file"
          log "Cancelled"
          return
          ;;
        IDS\ *)
          # shellcheck disable=SC2206
          nums=(${action#IDS })
          ;;
        *)
          rm -f "$page_file"
          warn "Unknown action: $action"
          continue
          ;;
      esac

      if [[ "${#nums[@]}" -eq 0 ]]; then
        rm -f "$page_file"
        log "Cancelled / nothing selected"
        return
      fi

      say ""
      say "────────────────────────────────────────"
      say "Ready to install ${#nums[@]} disk image(s) to LG TV"
      say "  Host: ${WEBOS_USER}@${WEBOS_HOST}"
      say "  Disks (.adf) → ${REMOTE_DISKS}"
      say "  Kickstarts   → ${REMOTE_SYSTEM}  (unchanged)"
      say "────────────────────────────────────────"
      local conf
      conf="$(ask "Install to LG TV now?" "Y")"
      case "${conf}" in
        y|Y|yes|YES|"")
          log "Installing ${#nums[@]} ADF(s) → ${WEBOS_USER}@${WEBOS_HOST}:${REMOTE_DISKS}/"
          download_and_install "$page_file" "${nums[@]}"
          rm -f "$page_file"
          print_tv_upload_paths adf
          log "ADF upload complete — files are on the TV at the path above."
          return
          ;;
        *)
          log "Skipped install to TV"
          rm -f "$page_file"
          nums=()
          continue
          ;;
      esac
    done
  done
}

# ── Kickstarts ─────────────────────────────────────────────────────────────

file_md5() {
  local f="$1"
  if command -v md5sum >/dev/null 2>&1; then
    md5sum "$f" | awk '{print $1}'
  elif command -v md5 >/dev/null 2>&1; then
    md5 -q "$f"
  else
    python3 -c "import hashlib,sys; print(hashlib.md5(open(sys.argv[1],'rb').read()).hexdigest())" "$f"
  fi
}

kick_spec_for() {
  local want="$1" spec name
  for spec in "${KICK_SPECS[@]}"; do
    name="${spec%%|*}"
    [[ "$name" == "$want" ]] && { echo "$spec"; return 0; }
  done
  return 1
}

verify_kick_file() {
  local path="$1" name="$2" spec exp_size exp_md5 got_size got_md5
  [[ "$VERIFY_KICKSTARTS" -eq 1 ]] || return 0
  [[ -f "$path" ]] || { warn "  missing: $path"; return 1; }
  got_size="$(wc -c <"$path" | tr -d ' ')"
  got_md5="$(file_md5 "$path")"
  log "  $name  size=$got_size  md5=$got_md5"
  if ! spec="$(kick_spec_for "$name")"; then
    return 0
  fi
  exp_size="$(echo "$spec" | cut -d'|' -f2)"
  exp_md5="$(echo "$spec" | cut -d'|' -f3)"
  if [[ -n "$exp_size" && "$got_size" != "$exp_size" ]]; then
    warn "  size mismatch: got $got_size expected $exp_size"
  fi
  if [[ -n "$exp_md5" && "$got_md5" != "$exp_md5" ]]; then
    warn "  MD5 mismatch (may still be a valid alternate dump)"
  elif [[ -n "$exp_md5" ]]; then
    log "  OK — matches known $name image"
  fi
}

download_kickstarts_from_urls() {
  local staging="$1" pair name url found=0 normalized sz
  need_cmd curl
  for pair in "${KICKSTART_URLS[@]}"; do
    normalized="$(normalize_kickstart_url_arg "$pair")"
    name="${normalized%%=*}"
    url="${normalized#*=}"
    log "Fetching $name"
    log "  URL: $url"
    if ! curl -fL --connect-timeout 30 --retry 4 --retry-delay 2 \
        -A "Mozilla/5.0 (compatible; RetroArch-webOS-setup/1.0)" \
        -o "$staging/$name" "$url"; then
      warn "  download failed"
      rm -f "$staging/$name"
      continue
    fi
    sz="$(wc -c <"$staging/$name" | tr -d ' ')"
    if [[ "${sz:-0}" -lt 10000 ]]; then
      warn "  too small — use raw file URL not github blob HTML"
      rm -f "$staging/$name"
      continue
    fi
    if head -c 32 "$staging/$name" | grep -qi '<!DOCTYPE\|<html'; then
      warn "  got HTML, not a ROM"
      rm -f "$staging/$name"
      continue
    fi
    verify_kick_file "$staging/$name" "$name"
    found=$((found + 1))
  done
  echo "$found"
}

collect_kickstarts_from_dir() {
  local src="$1" staging="$2" name f found=0
  for name in kick34005.A500 kick37175.A500 kick40068.A1200 kick40060.CD32 kick40060.CD32.ext; do
    f=""
    [[ -f "$src/$name" ]] && f="$src/$name"
    [[ -z "$f" ]] && f="$(find "$src" -maxdepth 3 -type f -iname "${name}*" 2>/dev/null | head -1 || true)"
    if [[ -n "$f" && -f "$f" ]]; then
      cp -f "$f" "$staging/$name"
      verify_kick_file "$staging/$name" "$name"
      found=$((found + 1))
    fi
  done
  echo "$found"
}

prompt_kickstart_urls() {
  say "Enter Kickstart URLs you control (empty line to finish)."
  local line
  while true; do
    line="$(ask "URL or NAME=URL" "")"
    [[ -z "${line:-}" ]] && break
    KICKSTART_URLS+=("$line")
  done
  [[ "${#KICKSTART_URLS[@]}" -gt 0 ]] || die "no URLs entered"
}

upload_staging_kickstarts() {
  local staging="$1"
  log "Uploading Kickstarts → ${WEBOS_USER}@${WEBOS_HOST}:${REMOTE_SYSTEM}/"
  ssh_cmd "mkdir -p '${REMOTE_SYSTEM}' && chmod a+rwx '${REMOTE_SYSTEM}'"
  scp_to "$staging"/* "${WEBOS_USER}@${WEBOS_HOST}:${REMOTE_SYSTEM}/"
  ssh_cmd "chmod a+r '${REMOTE_SYSTEM}'/kick* 2>/dev/null || true"
  print_tv_upload_paths kickstarts
  log "Kickstarts on TV at ${REMOTE_SYSTEM}/:"
  ssh_cmd "ls -lah '${REMOTE_SYSTEM}'" || true
}

tv_has_required_kickstarts() {
  ssh_cmd "test -f '${REMOTE_SYSTEM}/kick34005.A500' && test -f '${REMOTE_SYSTEM}/kick37175.A500'" 2>/dev/null
}

copy_kickstarts_on_tv() {
  local src="$1"
  log "Copying Kickstarts on TV: $src → ${REMOTE_SYSTEM}/"
  ssh_sh <<EOS
set -e
SRC="$src"
DST="${REMOTE_SYSTEM}"
[ -d "\$SRC" ] || { echo "error: not found: \$SRC" >&2; exit 1; }
mkdir -p "\$DST"
copied=0
for name in kick34005.A500 kick37175.A500 kick40068.A1200 kick40060.CD32 kick40060.CD32.ext; do
  f=""
  [ -f "\$SRC/\$name" ] && f="\$SRC/\$name"
  if [ -z "\$f" ]; then
    for cand in "\$SRC"/\$name "\$SRC"/\$name.*; do
      [ -f "\$cand" ] && { f="\$cand"; break; }
    done
  fi
  if [ -n "\$f" ] && [ -f "\$f" ]; then
    cp -f "\$f" "\$DST/\$name"
    echo "  + \$name → \$DST/\$name"
    copied=\$((copied + 1))
  fi
done
[ "\$copied" -gt 0 ] || { echo "error: no kickstarts in \$SRC" >&2; exit 1; }
ls -lah "\$DST"
EOS
  print_tv_upload_paths kickstarts
  log "Kickstarts installed on TV at ${REMOTE_SYSTEM}/"
}

install_kickstarts() {
  [[ "$SKIP_KICKSTARTS" -eq 1 ]] && return

  if [[ "$DO_KICKSTARTS" -eq 0 && ${#KICKSTART_URLS[@]} -eq 0 && "$LIST_ONLY" -eq 0 ]]; then
    if tv_has_required_kickstarts; then
      log "Kickstart BIOS already on TV — nothing more to do."
      print_tv_upload_paths kickstarts
      return
    elif [[ -t 0 ]]; then
      say ""
      say "Amiga needs Kickstart BIOS files to boot (like a console BIOS)."
      say "They are not free — use a dump you own or a licensed pack."
      say "1) Folder on this Mac"
      say "2) Folder already on the TV"
      say "3) URLs you provide"
      say "4) Skip"
      local c
      c="$(ask "Choice" "4")"
      case "$c" in
        1) KICKSTART_LOCAL="$(ask "Mac folder" "${HOME}/amiga/kickstarts")"; DO_KICKSTARTS=1 ;;
        2) KICKSTART_TV="$(ask "TV folder" "${REMOTE_SYSTEM}")"; DO_KICKSTARTS=1 ;;
        3) prompt_kickstart_urls; DO_KICKSTARTS=1 ;;
        *) log "Skipping Kickstarts"; return ;;
      esac
    else
      return
    fi
  fi

  if [[ -n "$KICKSTART_TV" ]]; then
    copy_kickstarts_on_tv "$KICKSTART_TV"
    return
  fi

  local staging found=0 n
  staging="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$staging'" RETURN

  if [[ ${#KICKSTART_URLS[@]} -gt 0 ]]; then
    n="$(download_kickstarts_from_urls "$staging")"
    found=$((found + n))
  fi
  if [[ -n "$KICKSTART_LOCAL" ]]; then
    [[ -d "$KICKSTART_LOCAL" ]] || die "not a directory: $KICKSTART_LOCAL"
    n="$(collect_kickstarts_from_dir "$KICKSTART_LOCAL" "$staging")"
    found=$((found + n))
  fi
  if [[ -n "$KICKSTART_LOCAL" || ${#KICKSTART_URLS[@]} -gt 0 ]]; then
    [[ "$found" -gt 0 ]] || die "no Kickstart files collected"
    upload_staging_kickstarts "$staging"
  fi
}

main() {
  need_cmd ssh
  need_cmd scp
  [[ -f "$WEBOS_SSH_KEY" ]] || die "SSH key not found: $WEBOS_SSH_KEY"

  log "TV ${WEBOS_USER}@${WEBOS_HOST}"
  ssh_cmd "test -x '${APP_DIR}/retroarch'" || die "RetroArch not found at ${APP_DIR}"

  run_free_catalog
  install_kickstarts

  say ""
  say "Done."
  print_tv_upload_paths both
  cat <<EOF >&2

RetroArch:
  Load Core → PUAE 2021
  Load Content → disks/amiga/
  (full path: ${REMOTE_DISKS}/)
EOF
}

main
