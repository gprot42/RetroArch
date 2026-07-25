#!/usr/bin/env bash
# Amiga setup for webOS RetroArch (PUAE 2021) — single tool.
#
# Paths on TV:
#   system/       → Kickstart BIOS ROMs only (kick34005.A500, …)
#   disks/amiga/  → floppy disk images (.adf) — NOT "roms"
#
# ADF catalog (Archive.org):
#   Classic Amiga games (A–Z libraries), coverdisks, PD/freeware packs,
#   Fred Fish / demoscene, plus any custom item id / URL you pass.
#
# Flow:
#   1) Pick a site (or --site id / Archive.org URL)
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
APP_DIR="${WEBOS_APP_DIR:-/media/developer/apps/usr/palm/applications/${APP_ID}}"
RA_DIR="${WEBOS_RA_DIR:-${APP_DIR}/.config/retroarch}"
REMOTE_SYSTEM="${WEBOS_SYSTEM_DIR:-${RA_DIR}/system}"       # Kickstart BIOS only
REMOTE_DISKS="${WEBOS_DISKS_DIR:-${RA_DIR}/disks/amiga}"   # .adf disk images
REMOTE_SNES="${WEBOS_SNES_DIR:-${RA_DIR}/disks/snes}"       # SNES ROMs
CONTENT_SYSTEM="${WEBOS_CONTENT_SYSTEM:-amiga}"             # amiga|snes|nes|genesis|gba|gbc|n64|psx|neogeo

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/retroarch-webos-amiga"
mkdir -p "$CACHE_DIR"

SEARCH=""
LIMIT=40
OFFSET=0
LIST_ONLY=0
LIST_SITES=0
SEARCH_ALL=0
CATEGORY=""
MACHINE=0
ASSUME_YES=0
REFRESH=0
SITE_CHOICE=""
IDS=()
SKIP_FREE=0
SKIP_KICKSTARTS=0
# Direct install: title\tfile\tsize\turl lines (or just urls via --install-url)
DIRECT_URLS=()
DIRECT_NAMES=()
KICKSTART_LOCAL=""
KICKSTART_TV=""
DO_KICKSTARTS=0
KICKSTART_URLS=()
VERIFY_KICKSTARTS=1

# Archive.org item catalogs: id|label|description|category
# category: games | demos | utils | pd  (used by UI filters / search-all)
# User may also pass any Archive.org item id via --site, or add custom sites in the app.
SITES=(
  # ── Classic games (historical libraries, A–Z by title) ───────────────────
  "commodore-amiga-games-adf-0-9_202202|Games 0–9|Classic Amiga games (titles starting 0–9)|games"
  "commodore-amiga-games-adf-a|Games A|Classic Amiga games — letter A|games"
  "commodore-amiga-games-adf-b|Games B|Classic Amiga games — letter B|games"
  "commodore-amiga-games-adf-c|Games C|Classic Amiga games — letter C|games"
  "commodore-amiga-games-adf-d|Games D|Classic Amiga games — letter D|games"
  "commodore-amiga-games-adf-e|Games E|Classic Amiga games — letter E|games"
  "commodore-amiga-games-adf-f_20220210|Games F|Classic Amiga games — letter F|games"
  "commodore-amiga-games-adf-g|Games G|Classic Amiga games — letter G|games"
  "commodore-amiga-games-adf-h|Games H|Classic Amiga games — letter H|games"
  "commodore-amiga-games-adf-i|Games I|Classic Amiga games — letter I|games"
  "commodore-amiga-games-adf-j|Games J|Classic Amiga games — letter J|games"
  "commodore-amiga-games-adf-k|Games K|Classic Amiga games — letter K|games"
  "commodore-amiga-games-adf-l_202202|Games L|Classic Amiga games — letter L|games"
  "commodore-amiga-games-adf-m|Games M|Classic Amiga games — letter M|games"
  "commodore-amiga-games-adf-n|Games N|Classic Amiga games — letter N|games"
  "commodore-amiga-games-adf-o|Games O|Classic Amiga games — letter O|games"
  "commodore-amiga-games-adf-p|Games P|Classic Amiga games — letter P|games"
  "commodore-amiga-games-adf-q|Games Q|Classic Amiga games — letter Q|games"
  "commodore-amiga-games-adf-r|Games R|Classic Amiga games — letter R|games"
  "commodore-amiga-games-adf-s|Games S|Classic Amiga games — letter S|games"
  # IA item id says \"r_202301\" but the collection is letter T
  "commodore-amiga-games-adf-r_202301|Games T|Classic Amiga games — letter T|games"
  "commodore-amiga-games-adf-u|Games U|Classic Amiga games — letter U|games"
  "commodore-amiga-games-adf-v|Games V|Classic Amiga games — letter V|games"
  "commodore-amiga-games-adf-w|Games W|Classic Amiga games — letter W|games"
  "commodore-amiga-games-adf-x|Games X|Classic Amiga games — letter X|games"
  # IA item id says \"v_202301\" but the collection is letter Y
  "commodore-amiga-games-adf-v_202301|Games Y|Classic Amiga games — letter Y|games"
  "commodore-amiga-games-adf-z|Games Z|Classic Amiga games — letter Z|games"
  "commodore-amiga-coverdisks-adf|Magazine coverdisks|Amiga magazine cover disks|games"
  "amiga-500-Collection|A500 games collection|Mixed Amiga 500 game set|games"
  # ── PD / freeware packs ───────────────────────────────────────────────────
  "commodore-amiga-games-public-domain-adf|PD / freeware games|Public domain & freeware Amiga games|games"
  "commodore-amiga-collections-assassins-the|Assassins PD packs|Assassins public-domain game packs|games"
  "commodore-amiga-collections-best-of-public-domain-the|Best of Public Domain|Curated Best of PD disk sets|pd"
  "commodore-amiga-collections-pd-unicornics|PD Unicornics|PD Unicornics library|pd"
  "commodore-amiga-collections-amiga-public-domain-connection|Amiga PD Connection|Amiga Public Domain Connection|pd"
  # ── Classic PD libraries ──────────────────────────────────────────────────
  "commodore-amiga-collections-fred-fish|Fred Fish disks|Fred Fish freely redistributable library|utils"
  "commodore-amiga-collections-scope|Scope PD library|Scope public-domain library|pd"
  "commodore-amiga-collections-software-of-the-month-club-somc|Software of the Month Club|SOMC monthly PD club disks|pd"
  "commodore-amiga-collections-megadisc|MegaDisc PD|MegaDisc public-domain magazine disks|pd"
  # ── Apps / utilities ──────────────────────────────────────────────────────
  "commodore-amiga-applications-public-domain-adf|PD applications|Public domain utilities & apps|utils"
  # ── Demoscene ─────────────────────────────────────────────────────────────
  # Virtual curated list (built from various-adf — see fetch_catalog)
  "popular-amiga-demos|★ Popular demos|Classic demoscene hits (State of the Art, 9 Fingers, Desert Dream, …)|demos"
  "commodore-amiga-demos-various-adf|All demos (A–Z)|Full demoscene library — thousands of disks|demos"
  "commodore-amiga-demos-packs|Demo packs|Multi-demo compilation disks|demos"
  "commodore-amiga-demos-music|Music / trackmos|Music demos and trackmos|demos"
  "commodore-amiga-demos-slideshows|Slideshow demos|Slideshow & music-disk demos|demos"
  "commodore-amiga-demos-animations-and-videos|Animations|Demo animations & video disks|demos"
)

# Curated classic demos (matched against commodore-amiga-demos-various-adf titles).
# Prefer clean dumps (no [b]/[h]/bamcopy) when several versions exist.
POPULAR_DEMO_TITLES=(
  "State of the Art"
  "9 Fingers"
  "Desert Dream"
  "Jesus on E's"
  "Hardwired"
  "Enigma"
  "Mental HangOver"
  "Joyride"
  "Global Trash"
  "Maximum Overdrive"
  "Copper Master"
  "World of Commodore"
  "Alcatraz Megademo"
  "Red Sector Megademo"
  "Cebit Demo 90"
  "Meetro 93"
  "D.O.S."
  "242"
  "Blue House 2"
  "Cat Computer Club"
  "Does Vectors Float in Water"
  "Breathing Vectors"
  "Color Emotion 91"
  "Acid Trip"
  "A500 Homage"
  "Art of Noise"
  "Odyssey v1.0"
  "Exorcism"
  "Spaceman"
  "Nightlight"
  "Sly Spy"
  "Vectorballs"
  "Babbages"
  "Megademo"
  "Crionics Megademo"
  "Phenomena Megademo"
  "Scoopex Megademo"
  "Rebels Megademo"
  "Silents Megademo"
  "Complex Fullmoon"
  "Fullmoon"
  "Friday at Eight"
  "Jesus on Es"
  "Jesus on E"
  "Rampage"
  "Guardian Dragon"
  "Voyage"
  "Substance"
  "Technological Death"
  "Protracker"
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
  --list            List ADFs only (needs --site)
  --list-sites      Print catalog sites only
  --search-all      Search across sites (use with --search; optional --category)
  --category CAT    games|demos|utils|pd|all  (filter sites / search-all)
  --machine         Machine-readable stdout (for GUI)
  --yes             Skip install confirmation
  --ids N…          Install those numbers (page-relative)
  --install-url URL Install this Archive.org file URL (repeatable; no re-search)
  --install-name N  Basename for previous --install-url (optional, repeatable)
  --content-system S  amiga (default) | snes | nes | genesis | gba | gbc | n64 | psx | neogeo
  --refresh         Refresh catalog cache
  --skip-free       Skip free ADF browser
  --kickstarts-local DIR
  --kickstarts DIR            (folder ON the TV)
  --kickstart-url URL|NAME=URL  (repeatable; your URLs only)
  --no-verify / --skip-kickstarts

Env: WEBOS_HOST WEBOS_USER WEBOS_SSH_KEY WEBOS_SSH_PORT
     WEBOS_RA_DIR WEBOS_DISKS_DIR WEBOS_SYSTEM_DIR
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
    --list-sites) LIST_SITES=1; shift ;;
    --search-all) SEARCH_ALL=1; shift ;;
    --category) CATEGORY="${2:-}"; shift 2 || die "need category" ;;
    --machine) MACHINE=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
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
    --install-url)
      DIRECT_URLS+=("${2:-}"); SKIP_FREE=1; shift 2 || die "need URL"
      ;;
    --install-name)
      DIRECT_NAMES+=("${2:-}"); shift 2 || die "need name"
      ;;
    --content-system)
      CONTENT_SYSTEM="$(printf '%s' "${2:-amiga}" | tr '[:upper:]' '[:lower:]')"
      shift 2 || die "need system"
      ;;
    --ids)
      shift
      while [[ $# -gt 0 && "$1" != --* ]]; do IDS+=("$1"); shift; done
      ;;
    -*) die "unknown option: $1" ;;
    *) die "unexpected: $1" ;;
  esac
done

if [[ "$DO_KICKSTARTS" -eq 1 && "$SKIP_FREE" -eq 0 && -z "$SITE_CHOICE" && -z "$SEARCH" && "${#IDS[@]}" -eq 0 && "$LIST_ONLY" -eq 0 && ${#DIRECT_URLS[@]} -eq 0 ]]; then
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

# Accept item id or https://archive.org/details/ID[…] / download/ID[…]
parse_archive_org_id() {
  local raw="${1:-}" id=""
  raw="$(printf '%s' "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [[ -n "$raw" ]] || return 1
  if [[ "$raw" =~ archive\.org/(details|download)/([^/?#]+) ]]; then
    id="${BASH_REMATCH[2]}"
  elif [[ "$raw" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    id="$raw"
  else
    return 1
  fi
  id="${id%%/*}"
  [[ -n "$id" ]] || return 1
  printf '%s\n' "$id"
}

# Split site entry → id label desc category (category defaults to "pd")
_site_fields() {
  local entry="$1"
  SITE_ID="${entry%%|*}"
  local rest="${entry#*|}"
  SITE_LABEL="${rest%%|*}"
  rest="${rest#*|}"
  if [[ "$rest" == *"|"* ]]; then
    SITE_DESC="${rest%%|*}"
    SITE_CAT="${rest#*|}"
  else
    SITE_DESC="$rest"
    SITE_CAT="pd"
  fi
  SITE_CAT="$(printf '%s' "$SITE_CAT" | tr '[:upper:]' '[:lower:]')"
}

_site_matches_category() {
  local cat="$1" want
  want="$(printf '%s' "${CATEGORY:-all}" | tr '[:upper:]' '[:lower:]')"
  case "$want" in
    ""|all) return 0 ;;
    game|games) want=games ;;
    demo|demos|demoscene) want=demos ;;
    util|utils|utility|utilities|apps|app|applications) want=utils ;;
    pd|public|freeware) want=pd ;;
  esac
  case "$want" in
    games) [[ "$cat" == "games" ]] ;;
    demos) [[ "$cat" == "demos" ]] ;;
    utils) [[ "$cat" == "utils" ]] ;;
    pd) [[ "$cat" == "pd" || "$cat" == "utils" ]] ;;
    *) return 0 ;;
  esac
}

# stdout: machine lines  N|id|label|desc|category
list_sites() {
  local i=1 entry
  if [[ "$MACHINE" -eq 1 ]]; then
    for entry in "${SITES[@]}"; do
      _site_fields "$entry"
      _site_matches_category "$SITE_CAT" || continue
      printf '%d|%s|%s|%s|%s\n' "$i" "$SITE_ID" "$SITE_LABEL" "$SITE_DESC" "$SITE_CAT"
      i=$((i + 1))
    done
  else
    say "Amiga disk sites (Archive.org) — games, demos, utilities:"
    say ""
    for entry in "${SITES[@]}"; do
      _site_fields "$entry"
      _site_matches_category "$SITE_CAT" || continue
      printf '  %2d) [%s] %s\n' "$i" "$SITE_CAT" "$SITE_LABEL" >&2
      printf '        %s\n' "$SITE_DESC" >&2
      printf '        https://archive.org/details/%s\n' "$SITE_ID" >&2
      say ""
      i=$((i + 1))
    done
  fi
}

# Search title/filename across all (or category-filtered) site catalogs.
# Machine lines: idx|title|file|size|url|siteId|siteLabel
search_all_sites() {
  local want="${SEARCH:-}" entry tsv matched total=0 page i=0
  [[ -n "$want" ]] || die "--search-all needs --search TEXT"
  need_cmd curl
  need_cmd python3
  matched="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$matched'" RETURN

  log "Searching catalogs for \"$want\" (category=${CATEGORY:-all})…"
  for entry in "${SITES[@]}"; do
    _site_fields "$entry"
    _site_matches_category "$SITE_CAT" || continue
    tsv="$(fetch_catalog "$SITE_ID")" || continue
    # Grep matches into combined file; prefix site id/label for machine mode
    while IFS=$'\t' read -r title base size url; do
      [[ -z "${title:-}" ]] && continue
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$title" "$base" "$size" "$url" "$SITE_ID" "$SITE_LABEL"
    done < <(grep -Fi -- "$want" "$tsv" 2>/dev/null || true) >>"$matched"
  done

  raw_total="$(wc -l <"$matched" | tr -d ' ')"
  raw_total="${raw_total:-0}"
  [[ "$raw_total" -gt 0 ]] || {
    if [[ "$MACHINE" -eq 1 ]]; then
      printf '# site=search total=0 limit=%s offset=%s category=%s query=%s\n' \
        "$LIMIT" "$OFFSET" "${CATEGORY:-all}" "$want"
    else
      say "No matches for \"$want\"."
    fi
    return 0
  }

  # Collapse TOSEC variants, page by unique title, emit preferred multi-disk sets
  page="$(mktemp)"
  collapse_tosec_tsv "$matched" "$page" "$OFFSET" "$LIMIT"
  if [[ -f "${page}.total" ]]; then
    total="$(tr -d ' \n' <"${page}.total")"
    rm -f "${page}.total"
  else
    total="$(wc -l <"$page" | tr -d ' ')"
  fi
  total="${total:-0}"
  log "Search \"$want\": ${raw_total} dumps → ${total} unique titles (offset $OFFSET, limit $LIMIT)"

  if [[ "$MACHINE" -eq 1 ]]; then
    printf '# site=search total=%s limit=%s offset=%s category=%s query=%s\n' \
      "$total" "$LIMIT" "$OFFSET" "${CATEGORY:-all}" "$want"
    i=1
    while IFS=$'\t' read -r title base size url sid slabel; do
      [[ -z "${title:-}" ]] && continue
      printf '%d|%s|%s|%s|%s|%s|%s\n' "$i" "$title" "$base" "$size" "$url" "$sid" "$slabel"
      i=$((i + 1))
    done <"$page"
  else
    say "Search \"$want\" — ${total} unique title(s), page limit $LIMIT (offset $OFFSET)"
    i=1
    while IFS=$'\t' read -r title base size url sid slabel; do
      printf '  %3d) %s  (%s)  [%s]\n' "$i" "$title" "$(human_size "$size")" "$slabel" >&2
      i=$((i + 1))
    done <"$page"
  fi
  rm -f "$page"
}

select_site() {
  local choice i entry id rest label desc
  if [[ -n "$SITE_CHOICE" ]]; then
    if [[ "$SITE_CHOICE" =~ ^[0-9]+$ ]]; then
      i=$((SITE_CHOICE - 1))
      (( i >= 0 && i < ${#SITES[@]} )) || die "invalid --site"
      echo "${SITES[$i]%%|*}"
      return
    fi
    # Archive.org URL or raw item id
    local parsed
    if parsed="$(parse_archive_org_id "$SITE_CHOICE")"; then
      # Prefer exact builtin match (same id)
      for entry in "${SITES[@]}"; do
        id="${entry%%|*}"
        if [[ "$id" == "$parsed" ]]; then
          echo "$id"
          return
        fi
      done
      echo "$parsed"
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
    die "unknown --site: $SITE_CHOICE (use item id or archive.org/details/… URL)"
  fi

  say ""
  say "Amiga disk images (.adf) from Archive.org"
  say "Classic games, PD packs, coverdisks, demoscene — or paste an item id."
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
  say "   Or type an Archive.org item id / details URL"
  say ""
  choice="$(ask "Site" "1")"
  case "$choice" in
    q|Q|quit|QUIT) echo "__QUIT__"; return 0 ;;
  esac
  if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#SITES[@]} )); then
    entry="${SITES[$((choice - 1))]}"
    echo "${entry%%|*}"
    return 0
  fi
  # Free-form Archive.org id or URL
  local parsed
  parsed="$(parse_archive_org_id "$choice" 2>/dev/null || true)"
  if [[ -n "$parsed" ]]; then
    echo "$parsed"
    return 0
  fi
  die "invalid site: $choice"
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

# Build curated popular-demos list from the full demoscene ADF catalog.
build_popular_demos_catalog() {
  local src_tsv out_tsv
  src_tsv="$(fetch_catalog commodore-amiga-demos-various-adf)" || die "could not load demos catalog"
  out_tsv="${CACHE_DIR}/popular-amiga-demos.tsv"
  if [[ "$REFRESH" -ne 1 && -s "$out_tsv" ]]; then
    # Rebuild if source is newer than popular list
    if [[ "$src_tsv" -nt "$out_tsv" ]]; then
      :
    else
      log "Using cached popular demos list"
      echo "$out_tsv"
      return 0
    fi
  fi
  log "Building popular demos list from demoscene catalog…"
  need_cmd python3
  # Pass title queries via env (newline-separated)
  POPULAR_TITLES="$(printf '%s\n' "${POPULAR_DEMO_TITLES[@]}")" \
  python3 - "$src_tsv" "$out_tsv" <<'PY'
import os, re, sys

src, dst = sys.argv[1:3]
queries = [q.strip() for q in os.environ.get("POPULAR_TITLES", "").splitlines() if q.strip()]

def penalty(title: str) -> int:
    t = title.lower()
    p = 0
    # Prefer clean dumps
    for tag in (
        "[b ", "[b]", "[baddump]", "baddump", "[h ", "[h]",
        "[m ", "bamcopy", "doscopy", "errdms", "[o]", "[o ",
        "[f ", "[cr ", "cracked", "fixed version", "[a]",
    ):
        if tag in t:
            p += 12
    # Prefer disk 1 of multi-disk sets
    if re.search(r"disk\s*1\s*of", t):
        p -= 4
    elif re.search(r"disk\s*[2-9]\s*of", t):
        p += 8
    return p

def title_stem(title: str) -> str:
    # "Foo (1992)(Group)[tags]" → "foo"
    s = re.split(r"\s*[\(\[]", title, 1)[0].strip().lower()
    return re.sub(r"\s+", " ", s)

rows = []
with open(src, encoding="utf-8", errors="replace") as f:
    for line in f:
        line = line.rstrip("\n")
        if not line:
            continue
        parts = line.split("\t")
        if len(parts) < 4:
            continue
        title, base, size, url = parts[0], parts[1], parts[2], parts[3]
        try:
            sz = int(size)
        except ValueError:
            sz = 0
        rows.append((title, base, sz, url))

picked = []
seen_keys = set()
for q in queries:
    ql = q.lower()
    matches = []
    for title, base, sz, url in rows:
        tl = title.lower()
        if ql not in tl:
            continue
        stem = title_stem(title)
        boost = 0
        # Exact stem match is best ("Enigma" not "Enigma 2")
        if stem == ql:
            boost -= 25
        elif stem.startswith(ql + " "):
            # sequel / subtitle after space — only OK if query also has it
            rest = stem[len(ql):].strip()
            if rest[:1].isdigit() or rest.startswith(("ii", "iii", "2", "3", "v2")):
                boost += 20
            else:
                boost -= 5
        elif tl.startswith(ql + " (") or tl.startswith(ql + "("):
            boost -= 18
        elif tl.startswith(ql):
            boost -= 4
        else:
            # query only appears mid-title
            boost += 10
        score = penalty(title) + boost
        if sz > 0:
            if 100_000 <= sz <= 1_200_000:
                score -= 2
            elif sz < 30_000:
                score += 15
        matches.append((score, -sz, title, base, sz, url))
    if not matches:
        continue
    matches.sort()
    score, _nsz, title, base, sz, url = matches[0]
    key = title_stem(title)
    if key in seen_keys:
        continue
    seen_keys.add(key)
    picked.append((title, base, str(sz), url))

# Stable-ish order: keep query order (already), write TSV
with open(dst, "w", encoding="utf-8") as out:
    for title, base, size, url in picked:
        def esc(s: str) -> str:
            return s.replace("\t", " ").replace("\n", " ")
        out.write(f"{esc(title)}\t{esc(base)}\t{esc(size)}\t{esc(url)}\n")
print(f"  popular demos: {len(picked)}", file=sys.stderr)
if not picked:
    sys.exit(2)
PY
  [[ -s "$out_tsv" ]] || die "could not build popular demos list"
  echo "$out_tsv"
}

fetch_catalog() {
  local item="$1"
  # Curated virtual catalog
  if [[ "$item" == "popular-amiga-demos" ]]; then
    build_popular_demos_catalog
    return
  fi
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
    # Amiga + multi-system ROMs (SNES/NES/Genesis/GBA/N64/PSX, …)
    # Prefer single-file playable types for PS1 (.chd/.pbp/.iso/.zip) — skip raw .bin
    # (BIN without CUE is unusable; listing both doubles every Redump title).
    if not low.endswith((
        ".zip", ".7z", ".rar",
        ".adf", ".adz", ".dms", ".lha",
        ".sfc", ".smc", ".fig", ".swc",
        ".nes", ".unf", ".unif",
        ".gba", ".gb", ".gbc",
        ".md", ".gen", ".smd",
        ".z64", ".n64", ".v64",
        ".chd", ".cue", ".iso", ".pbp",
    )):
        continue
    base = name.split("/")[-1]
    if base.lower() in ("thumbs.zip", "files.xml", "meta.sqlite", "__macosx"):
        continue
    # skip tiny junk / screenshots
    try:
        if int(fi.get("size") or 0) and int(fi.get("size") or 0) < 1024:
            continue
    except Exception:
        pass
    size = str(fi.get("size") or "0")
    url = dl_base.rstrip("/") + "/" + urllib.parse.quote(name)
    title = base
    for ext in (
        ".zip", ".7z", ".rar",
        ".adf", ".adz", ".dms", ".lha",
        ".sfc", ".smc", ".fig", ".swc",
        ".nes", ".unf", ".unif",
        ".gba", ".gb", ".gbc",
        ".md", ".gen", ".smd",
        ".z64", ".n64", ".v64",
        ".chd", ".cue", ".iso", ".pbp",
        ".ZIP", ".7Z", ".RAR",
        ".ADF", ".ADZ", ".DMS", ".LHA",
        ".SFC", ".SMC", ".FIG", ".SWC",
        ".NES", ".UNF", ".UNIF",
        ".GBA", ".GB", ".GBC",
        ".MD", ".GEN", ".SMD",
        ".Z64", ".N64", ".V64",
        ".CHD", ".CUE", ".ISO", ".PBP",
    ):
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
  if [[ ! -s "$tsv" ]]; then
    warn "empty catalog for $item (skipping)"
    # Empty file so callers can continue (search-all should not abort)
    : >"$tsv"
    echo "$tsv"
    return 0
  fi
  echo "$tsv"
}

# Collapse TOSEC dump variants → unique games, then page by unique title.
# For each unique game on the page, emit all disks of the preferred dump family
# so multi-disk installs stay complete.
# Args: inp outp [offset] [limit]
# Input/output TSV: title\tfile\tsize\turl  (optional \tsiteId\tsiteLabel)
# Writes total unique count to outp.total (sibling file).
collapse_tosec_tsv() {
  local inp="$1" outp="$2" off="${3:-0}" lim="${4:-0}"
  need_cmd python3
  python3 - "$inp" "$outp" "$off" "$lim" <<'PY'
import re, sys
from collections import defaultdict

inp, outp = sys.argv[1:3]
offset = int(sys.argv[3] or 0)
limit = int(sys.argv[4] or 0)

def game_key(title: str) -> str:
    t = re.sub(r"\[[^\]]*\]", "", title)
    t = re.sub(r"\(Disk\s*\d+\s*of\s*\d+\)", "", t, flags=re.I)
    t = re.sub(r"\(Disk\s*\d+\)", "", t, flags=re.I)
    t = re.sub(r"\((?:Intro|Game|Program|Data|Disk)\)", "", t, flags=re.I)
    t = re.sub(r"\s+", " ", t).replace("()", "").strip().lower()
    return t

def score(title: str) -> int:
    s = 100
    if "[!]" in title:
        s += 50
    if re.search(r"\[b[\s\]]", title, re.I) or "checksum error" in title.lower() or re.search(r"\[b\d*\]", title, re.I):
        s -= 90
    if re.search(r"\[a\d*\]", title, re.I):
        s -= 20
    if re.search(r"\[o\d*\]", title, re.I):
        s -= 25
    if re.search(r"\[cr\b", title, re.I):
        s += 8
    if re.search(r"\(Disk\s*1\s*of", title, re.I):
        s += 15
    elif re.search(r"\(Disk\s*[2-9]\s*of", title, re.I):
        s -= 5
    if not re.search(r"\[[^\]]+\]", title):
        s += 12
    return s

def disk_no(title: str) -> int:
    m = re.search(r"Disk\s*(\d+)", title, re.I)
    return int(m.group(1)) if m else 0

rows = []
with open(inp, encoding="utf-8", errors="replace") as f:
    for line in f:
        line = line.rstrip("\n")
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 4:
            continue
        rows.append(parts)

groups = defaultdict(list)
for parts in rows:
    key = game_key(parts[0]) or parts[1].lower()
    groups[key].append(parts)

# Per unique game: pick best dump for each disk number (complete multi-disk set)
games = []  # list of (sort_title, preferred_disk_rows)
for key, variants in groups.items():
    by_disk = defaultdict(list)
    for p in variants:
        by_disk[disk_no(p[0])].append(p)
    preferred = []
    for d in sorted(by_disk.keys(), key=lambda n: n if n > 0 else 999):
        best = max(by_disk[d], key=lambda p: score(p[0]))
        preferred.append(best)
    preferred.sort(key=lambda p: (disk_no(p[0]) or 99, -score(p[0])))
    sort_title = preferred[0][0]
    games.append((sort_title.lower(), preferred))

games.sort(key=lambda x: x[0])
unique_total = len(games)
if offset:
    games = games[offset:]
if limit and limit > 0:
    games = games[:limit]

out_rows = []
for _, fam in games:
    # Preferred dumps for each disk — install gets the full game
    out_rows.extend(fam)

with open(outp, "w", encoding="utf-8") as out:
    for p in out_rows:
        out.write("\t".join(p) + "\n")
with open(outp + ".total", "w", encoding="utf-8") as tf:
    tf.write(str(unique_total))
print(
    f"  collapsed {len(rows)} dumps → {unique_total} unique titles"
    f" (page emits {len(out_rows)} disk files)",
    file=sys.stderr,
)
PY
}

filter_page() {
  local tsv="$1" out total filtered
  out="$(mktemp)"
  filtered="$(mktemp)"
  if [[ -n "$SEARCH" ]]; then
    # -F: fixed string (titles/filenames have $ [] () etc.)
    grep -Fi -- "$SEARCH" "$tsv" >"$filtered" || true
  else
    cp "$tsv" "$filtered"
  fi
  # Deduplicate TOSEC variants, page by unique title, emit preferred multi-disk sets
  collapse_tosec_tsv "$filtered" "$out" "$OFFSET" "$LIMIT"
  rm -f "$filtered"
  if [[ -f "${out}.total" ]]; then
    total="$(tr -d ' \n' <"${out}.total")"
    rm -f "${out}.total"
  else
    total="$(wc -l <"$out" | tr -d ' ')"
  fi
  total="${total:-0}"
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
  if [[ "$MACHINE" -eq 1 ]]; then
    # Header for GUI parsers (stderr stays clean of data).
    # Prefer site id without spaces; keep human label in site_label=
    local site_key="$site_name"
    site_key="${site_key// /_}"
    printf '# site=%s total=%s limit=%s offset=%s site_label=%s\n' \
      "$site_key" "$total" "$LIMIT" "$OFFSET" "$site_name"
    while IFS=$'\t' read -r title base size url; do
      [[ -z "${title:-}" ]] && continue
      # idx|title|filename|bytes|url
      printf '%d|%s|%s|%s|%s\n' "$i" "$title" "$base" "$size" "$url"
      i=$((i + 1))
    done <"$file"
    return
  fi
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
  count="$(wc -l <"$page_file" | tr -d ' ')"
  count="${count:-0}"
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

# Install ADFs from direct Archive.org download URLs (GUI path).
# Uses the same extract/upload pipeline as page-based install.
install_direct_urls() {
  [[ "${#DIRECT_URLS[@]}" -gt 0 ]] || return 0
  local page i url name title nlines j
  local -a nums=()
  page="$(mktemp)"
  i=0
  for url in "${DIRECT_URLS[@]}"; do
    [[ -n "$url" ]] || continue
    name="${DIRECT_NAMES[$i]:-}"
    if [[ -z "$name" ]]; then
      name="$(basename "${url%%\?*}")"
      # URL-decode common %20 etc. for a readable name
      name="$(printf '%s' "$name" | python3 -c 'import sys,urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))' 2>/dev/null || printf '%s' "$name")"
    fi
    title="${name%.*}"
    # TSV: title base size url  (size unknown → 0)
    printf '%s\t%s\t%s\t%s\n' "$title" "$name" "0" "$url" >>"$page"
    i=$((i + 1))
  done
  nlines="$(wc -l <"$page" | tr -d ' ')"
  nlines="${nlines:-0}"
  [[ "$nlines" -gt 0 ]] || { rm -f "$page"; die "no --install-url entries"; }
  log "Direct-install ${nlines} ADF URL(s) → ${WEBOS_USER}@${WEBOS_HOST}:${REMOTE_DISKS}/"
  for ((j = 1; j <= nlines; j++)); do
    nums+=("$j")
  done
  download_and_install "$page" "${nums[@]}"
  rm -f "$page"
  log "Direct install finished (${nlines} requested)."
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

  local dest_dir="$REMOTE_DISKS"
  local sys
  sys="$(printf '%s' "${CONTENT_SYSTEM:-amiga}" | tr '[:upper:]' '[:lower:]')"
  case "$sys" in
    snes) dest_dir="${WEBOS_SNES_DIR:-${RA_DIR}/disks/snes}" ;;
    nes) dest_dir="${RA_DIR}/disks/nes" ;;
    genesis|megadrive|md) sys=genesis; dest_dir="${RA_DIR}/disks/genesis" ;;
    gba) dest_dir="${RA_DIR}/disks/gba" ;;
    gbc|gb) sys=gbc; dest_dir="${RA_DIR}/disks/gb" ;;
    n64) dest_dir="${RA_DIR}/disks/n64" ;;
    psx|ps1) sys=psx; dest_dir="${RA_DIR}/disks/psx" ;;
    neogeo|neo-geo|neo_geo|ng) sys=neogeo; dest_dir="${RA_DIR}/disks/neogeo" ;;
    amiga|*) sys=amiga; dest_dir="$REMOTE_DISKS" ;;
  esac

  # Ensure parents are traversable by the jailed RetroArch process
  ssh_cmd "mkdir -p '${dest_dir}' && chmod a+rwx '${RA_DIR}' '${RA_DIR}/disks' '${dest_dir}'" || true

  local -a lines=()
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    lines+=("$line")
  done <"$page_file"

  # Prefer real extensions per system when searching inside archives.
  # IMPORTANT: do not put shell quotes inside these patterns — find gets them literally.
  find_rom_in() {
    local dir="$1"
    case "$sys" in
      amiga)
        find "$dir" -type f \( -iname '*.adf' -o -iname '*.adz' \) 2>/dev/null | head -1
        ;;
      snes)
        find "$dir" -type f \( -iname '*.sfc' -o -iname '*.smc' -o -iname '*.fig' -o -iname '*.swc' \) 2>/dev/null | head -1
        ;;
      nes)
        find "$dir" -type f \( -iname '*.nes' -o -iname '*.unf' -o -iname '*.unif' \) 2>/dev/null | head -1
        ;;
      genesis)
        find "$dir" -type f \( -iname '*.md' -o -iname '*.gen' -o -iname '*.smd' \) 2>/dev/null | head -1
        ;;
      gba)
        find "$dir" -type f -iname '*.gba' 2>/dev/null | head -1
        ;;
      gbc)
        find "$dir" -type f \( -iname '*.gbc' -o -iname '*.gb' \) 2>/dev/null | head -1
        ;;
      n64)
        find "$dir" -type f \( -iname '*.z64' -o -iname '*.n64' -o -iname '*.v64' \) 2>/dev/null | head -1
        ;;
      psx)
        find "$dir" -type f \( -iname '*.chd' -o -iname '*.pbp' -o -iname '*.iso' -o -iname '*.cue' \) 2>/dev/null | head -1
        ;;
      neogeo)
        # FBNeo wants MAME-style .zip sets; Geolith uses .neo cart dumps.
        # Prefer leaving archives intact (cores open zip); only pick .neo inside.
        find "$dir" -type f -iname '*.neo' 2>/dev/null | head -1
        ;;
      *)
        find "$dir" -type f ! -name '*.txt' ! -name '*.nfo' ! -name '.*' 2>/dev/null | head -1
        ;;
    esac
  }

  local n idx title base size url zip_path extract content rname sz
  for n in "${nums[@]}"; do
    idx=$((n - 1))
    if (( idx < 0 || idx >= ${#lines[@]} )); then
      warn "Out of range: $n"
      continue
    fi
    IFS=$'\t' read -r title base size url <<<"${lines[$idx]}"
    log "[${n}] $title  (${sys})"
    # Keep a useful extension on the temp file for unzip detection
    local tmp_ext="bin"
    case "$base" in
      *.*) tmp_ext="${base##*.}" ;;
    esac
    zip_path="${work}/dl_${n}.${tmp_ext}"
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
    content=""
    case "$base" in
      *.adf|*.ADF|*.adz|*.ADZ)
        cp -f "$zip_path" "$extract/disk.adf"
        content="$extract/disk.adf"
        ;;
      *.sfc|*.SFC|*.smc|*.SMC|*.fig|*.FIG|*.swc|*.SWC|\
      *.nes|*.NES|*.unf|*.UNF|\
      *.gba|*.GBA|*.gb|*.GB|*.gbc|*.GBC|\
      *.md|*.MD|*.gen|*.GEN|*.smd|*.SMD|\
      *.z64|*.Z64|*.n64|*.N64|*.v64|*.V64|\
      *.chd|*.CHD|*.cue|*.CUE|*.iso|*.ISO|*.pbp|*.PBP|\
      *.neo|*.NEO)
        # Preserve catalog basename
        cp -f "$zip_path" "$extract/$base"
        content="$extract/$base"
        ;;
      *.zip|*.ZIP|*.7z|*.7Z|*.rar|*.RAR|*)
        if unzip -l "$zip_path" >/dev/null 2>&1; then
          unzip -o -q "$zip_path" -d "$extract" || true
          content="$(find_rom_in "$extract" || true)"
        elif command -v 7z >/dev/null 2>&1; then
          7z x -y -o"$extract" "$zip_path" >/dev/null 2>&1 || true
          content="$(find_rom_in "$extract" || true)"
        fi
        # Still nothing: keep archive only for non-Amiga (cores can open zip)
        if [[ -z "$content" || ! -f "$content" ]]; then
          if [[ "$sys" != "amiga" ]]; then
            content="$zip_path"
          fi
        fi
        ;;
    esac

    if [[ -z "$content" || ! -f "$content" ]]; then
      warn "  no playable content found for ${sys}"
      continue
    fi

    # Prefer real ROM name from archive; if still the temp download, use catalog basename
    rname="$(basename "$content" | tr ' ' '_' | tr -cd 'A-Za-z0-9._-')"
    case "$rname" in
      dl_[0-9]*|dl_[0-9]*.*)
        rname="$(printf '%s' "$base" | tr ' ' '_' | tr -cd 'A-Za-z0-9._-')"
        ;;
    esac
    if [[ -z "$rname" ]]; then
      case "$sys" in
        amiga) rname="disk_${n}.adf" ;;
        snes) rname="rom_${n}.sfc" ;;
        nes) rname="rom_${n}.nes" ;;
        genesis) rname="rom_${n}.md" ;;
        gba) rname="rom_${n}.gba" ;;
        gbc) rname="rom_${n}.gbc" ;;
        n64) rname="rom_${n}.z64" ;;
        psx) rname="rom_${n}.chd" ;;
        neogeo) rname="rom_${n}.zip" ;;
        *) rname="rom_${n}.bin" ;;
      esac
    fi
    if [[ "$sys" == "amiga" ]]; then
      case "$rname" in
        *.adf|*.ADF|*.adz|*.ADZ) ;;
        *) rname="${rname}.adf" ;;
      esac
    fi

    scp_to "$content" "${WEBOS_USER}@${WEBOS_HOST}:${dest_dir}/${rname}"
    # world-readable so jailer (non-root) can list/load content
    ssh_cmd "chmod a+r '${dest_dir}/${rname}' 2>/dev/null || true; chown 6885:jailer '${dest_dir}/${rname}' 2>/dev/null || true"
    log "  uploaded → ${WEBOS_USER}@${WEBOS_HOST}:${dest_dir}/${rname}"
  done

  ssh_cmd "chmod a+rwx '${RA_DIR}/disks' '${dest_dir}' 2>/dev/null || true; chmod a+r '${dest_dir}'/* 2>/dev/null || true"
  # Keep browser pointing at disks/amiga and show all files (not core-filtered)
  ssh_cmd "CFG='${RA_DIR}/retroarch.cfg'; touch \"\$CFG\"; grep -v -E '^(rgui_browser_directory|menu_navigation_browser_filter_supported_extensions_enable|filter_by_current_core) ' \"\$CFG\" > \"\$CFG.n\" 2>/dev/null || true; mv \"\$CFG.n\" \"\$CFG\" 2>/dev/null || true; printf '%s\\n' 'rgui_browser_directory = \"${REMOTE_DISKS}\"' 'menu_navigation_browser_filter_supported_extensions_enable = \"false\"' 'filter_by_current_core = \"false\"' >> \"\$CFG\"" || true

  print_tv_upload_paths adf
  log "Content installed under ${dest_dir}/ (${sys}):"
  ssh_cmd "ls -lah '${dest_dir}'" || true
  log "In RetroArch: Load Core for ${sys} → Load Content from disks/${sys}."
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
      total="${total:-0}"
      # Never use `grep -c || echo 0` — on 0 matches grep prints 0 and fails,
      # so `|| echo 0` yields "0\n0" and breaks arithmetic.
      count="$(wc -l <"$page_file" | tr -d ' ')"
      count="${count:-0}"

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
      local conf="Y"
      if [[ "$ASSUME_YES" -eq 0 ]]; then
        conf="$(ask "Install to LG TV now?" "Y")"
      else
        log "Auto-confirm install (--yes)"
      fi
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
  # Sites list needs no network / SSH
  if [[ "$LIST_SITES" -eq 1 ]]; then
    list_sites
    exit 0
  fi

  # Cross-site search (no TV)
  if [[ "$SEARCH_ALL" -eq 1 ]]; then
    search_all_sites
    exit 0
  fi

  # Catalog list (no TV) — still needs curl/python for archive.org
  if [[ "$LIST_ONLY" -eq 1 ]]; then
    [[ -n "$SITE_CHOICE" ]] || die "--list requires --site N|id"
    need_cmd curl
    need_cmd python3
    local item label tsv result page_file total
    item="$(select_site)"
    label="$(site_label "$item")"
    tsv="$(fetch_catalog "$item")"
    result="$(filter_page "$tsv")"
    page_file="${result%%|*}"
    total="${result##*|}"
    show_adf_menu "$page_file" "$total" "$label"
    rm -f "$page_file"
    exit 0
  fi

  need_cmd ssh
  need_cmd scp
  [[ -f "$WEBOS_SSH_KEY" ]] || die "SSH key not found: $WEBOS_SSH_KEY"

  log "TV ${WEBOS_USER}@${WEBOS_HOST}"
  ssh_cmd "test -x '${APP_DIR}/retroarch'" || die "RetroArch not found at ${APP_DIR}"

  # GUI / direct URL install — never re-search the catalog (avoids broken grep on $[] names)
  if [[ "${#DIRECT_URLS[@]}" -gt 0 ]]; then
    install_direct_urls
    if [[ "$DO_KICKSTARTS" -eq 0 && ${#KICKSTART_URLS[@]} -eq 0 ]]; then
      SKIP_KICKSTARTS=1
    fi
    install_kickstarts
    say ""
    say "Done."
    print_tv_upload_paths adf
    return 0
  fi

  run_free_catalog
  # Non-interactive ADF installs (--ids / --yes) should not prompt for Kickstarts,
  # but explicit --kickstart-url / --kickstarts* must still run.
  if [[ "$ASSUME_YES" -eq 1 || "${#IDS[@]}" -gt 0 ]]; then
    if [[ "$DO_KICKSTARTS" -eq 0 && ${#KICKSTART_URLS[@]} -eq 0 ]]; then
      SKIP_KICKSTARTS=1
    fi
  fi
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
