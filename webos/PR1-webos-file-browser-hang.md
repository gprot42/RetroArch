# PR 1 — webOS: Load Content hang on filesystem root

## Title

```
webOS: fix file browser hang when opening filesystem root
```

## Problem

On webOS, RetroArch runs under **jailer**. **Load Content → `/`** (or Parent Directory up to `/`) freezes the UI. Enumerating jail root touches virtual filesystems (`/proc`, `/sys`, …) and stalls the main thread.

## Solution (hang only)

1. **Do not offer `/` as a start location** on webOS.
2. If the browser path becomes `/`, **re-show the platform drive list** instead of `readdir` on root.
3. If root is listed anyway, **skip** `proc` / `sys` / `dev` / `run`.
4. Keep a **safe drive list** (app package, storage, USB, temp) so users still have places to browse.

## Out of scope (separate PR)

- Extension filter defaults  
- Default content / browser directory  
- Core Downloader / buildbot config  
- Packaging or setup scripts  

## Files

| File | Change |
|------|--------|
| `frontend/drivers/platform_unix.c` | Safe WEBOS drives; never append `/` |
| `menu/menu_displaylist.c` | Path `/` → drive list |
| `libretro-common/lists/dir_list.c` | Skip virtual nodes under `/` |

## Commit message

```
webOS: fix file browser hang on filesystem root

Under jailer, readdir/stat on / can stall the UI via /proc and /sys.
Do not offer "/" as a drive, redirect root back to the safe drive list,
and skip virtual FS nodes if root is enumerated.
```

## Test plan

- [ ] Load Content does not hang on open  
- [ ] Opening or navigating to `/` does not freeze; safe drives shown  
- [ ] Can still open `/media/internal`, `/media/developer`, app dir  
- [ ] Non-webOS builds unchanged  

## Patch

`webos/patches/0001-webos-file-browser-hang.patch`  
(or generate from commit on branch `fix/webos-file-browser-hang`)
