# PR 2 — webOS: Load Content fails to show files

## Title

```
webOS: fix Load Content not listing user files
```

## Problem

On webOS, **Load Content** often appears empty or does not open near user content:

1. **Extension filter defaults on** — files are hidden unless they match the current core’s extensions (or when no/wrong core is selected).
2. **Wrong default data paths** — `HOME` / `XDG_CONFIG_HOME` under jailer often do not point at the app package, so cores/system/browser defaults miss real storage.
3. **No useful default content directory** — `rgui_browser_directory` / “Start Directory” stays empty, so the UI does not land on internal storage or app config where content lives.
4. Drive list did not highlight **app `.config/retroarch`** or **downloads**, where content is commonly stored.

## Solution (visibility only — depends on PR 1 for root hang)

1. Default **“Filter content by supported extensions”** to **off** on webOS.
2. On webOS, set config base to **`<app>/.config/retroarch`** (not `$HOME`).
3. Set default **menu content / file browser** start to **`/media/internal`** when present, else app config dir.
4. In the drive list, expose **app `.config/retroarch`** and **downloads** when they exist.

## Out of scope (other PRs / local scripts)

- Hang on `/` → **PR 1**  
- Core Downloader / webosbrew buildbot URL → packaging or config scripts  
- Amiga ADF installers  

## Files

| File | Change |
|------|--------|
| `config.def.h` | `DEFAULT_NAVIGATION_BROWSER_FILTER_SUPPORTED_EXTENSIONS_ENABLE` false on WEBOS |
| `configuration.c` | Use that default |
| `frontend/drivers/platform_unix.c` | WEBOS `base_path` + `DEFAULT_DIR_MENU_CONTENT`; drive list content paths |

## Commit message

```
webOS: fix Load Content not listing user files

Jail HOME/XDG paths often miss the app package; extension filtering
hides disks when no matching core is selected. Point defaults at
package .config/retroarch and internal storage, disable extension
filter by default, and list app config/downloads in the drive list.
```

## Test plan

- [ ] Fresh config: Load Content shows **Start Directory / Favorites** toward `/media/internal` or app config  
- [ ] Files with various extensions visible without loading a core first  
- [ ] With a core loaded, user can still see non-matching extensions (filter off by default)  
- [ ] Can enable filter again in Settings → User Interface → File Browser  
- [ ] Cores/system defaults resolve under app `.config/retroarch` when present  
- [ ] Non-webOS defaults unchanged  

## Dependency

Prefer stacking on **PR 1** (`fix/webos-file-browser-hang`) so root hang is already fixed.  
Can land alone, but users may still freeze if they open `/`.

## Patch

`webos/patches/0002-webos-load-content-visibility.patch`  
(or generate from branch `fix/webos-load-content-visibility`)
