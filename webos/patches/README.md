# webOS file-browser PRs (upstream)

## PR 1 — hang on `/`
- Description: `../PR1-webos-file-browser-hang.md`
- Files: `platform_unix.c` (no `/`, safe drives), `menu_displaylist.c`, `dir_list.c`
- Branch suggestion: `fix/webos-file-browser-hang`

## PR 2 — Load Content empty / wrong place
- Description: `../PR2-webos-load-content-visibility.md`
- Files: `config.def.h`, `configuration.c`, `platform_unix.c` (WEBOS base_path + menu content + drive entries)
- Branch suggestion: `fix/webos-load-content-visibility` (base on PR 1)

## Order
1. Land PR 1 first (hang).
2. Land PR 2 on top (content visibility).

Local setup scripts (`setup-cores.sh`, `setup-amiga.sh`) stay out of both PRs.
