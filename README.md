# rls-ru-tools

Unofficial tools for **[RLS Career Overhaul](https://github.com/RLS-Modding/rls_career_overhaul)** (BeamNG.drive):

1. **Gamepad navigation for the in-game phone.** Out of the box only *Back* works on a controller: phone icons and cards are
   `<div @click>`, so BeamNG's UI navigation can't see them. After the patch, the D-pad/stick moves focus
   between icons and stays inside the phone, **A** opens, **B** goes app → home → closes the phone, and an orange ring shows focus.
2. **Translation pipeline.** The mod has no localization system; all text is hard-coded in ~260 `.vue`, ~90 `.js`,
   Lua and HTML files. `extract.py` finds the player-facing strings (with exact coordinates and a lot of
   "don't touch logic strings" filtering), `apply.py` puts translations back safely. Used for a full Russian translation.

> **No mod files are included.** RLS is the work of its authors (and 2.7.x is distributed via their Patreon).
> These scripts patch **your own local copy**. The Russian dictionary will be published only with the authors' permission.

Built against **RLS 2.7.2 + BeamNG.drive 0.39.4** (Windows). Phone navigation was verified in-game by driving BeamNG's
`UINavigation` events (exactly what a gamepad sends in menus) and reading the DOM: focus lands on the first icon, the
D-pad moves and can't leave the phone, A opens an app, B → home → closes. Feedback from real-controller play is welcome.

## Requirements
- Python 3.8+ (no extra packages)
- Windows PowerShell 5+ (for packing the zip)
- Optional, for validation: Node.js 18+ (`cd validate && npm install`), `luajit`

## Usage

```bash
# 0. unpack the ORIGINAL mod zip somewhere
unzip rls_career_overhaul_2.7.2.zip -d rls

# A. gamepad patch only
python scripts/patch_phone_nav.py --mod-dir rls --out-dir overlay

# B. translation (+ gamepad on top)
python scripts/extract.py --mod-dir rls --out-dir work          # -> work/uniq.json: strings to translate
#    make translations.json: {"English string": "translated string", ...}
python scripts/apply.py --mod-dir rls --occ work/occ.json --dict translations.json --out-dir overlay-tr
python scripts/patch_phone_nav.py --mod-dir rls --base-overlay overlay-tr --out-dir overlay-nav
#    merge: copy overlay-tr/* then overlay-nav/* into one "overlay" folder

# optional: compile-check everything you changed
node validate/check.js overlay check.json     # 0 errors expected
bash validate/check_lua.sh overlay            # no output expected
```

```powershell
# C. pack (Windows). Close the game first.
powershell -ExecutionPolicy Bypass -File windows\build_zip.ps1 `
  -Source  rls_career_overhaul_2.7.2.zip `
  -Overlay overlay `
  -Output  rls_career_overhaul_2.7.2_patched.zip
```
Put the new zip into `%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\` and **move the original zip out** of `mods`
(two copies = conflicts). To roll back, delete the patched zip and put the original back.

## What exactly the gamepad patch changes
| File | Change |
|---|---|
| phone views + components (~33 files) | clickable non-buttons (`@click`/`@tap`) get `bng-nav-item tabindex="0" v-bng-on-ui-nav:ok.asMouse.focusRequired` — the same pattern RLS already uses for the garage computer. Pointer-only containers (map, page viewport, dock) are **not** tagged: tagging them sends focus into an invisible box. |
| `lua/ge/extensions/overhaul/uiRoutes.lua` | `phone*` routes get `scopeTree = {["rls-phone"] = {}}`. Runtime-registered mod routes can't declare `targetScope`; the scopeTree root becomes it. |
| `PhoneWrapper.vue` | `v-bng-scoped-nav` scope `rls-phone` (no escaping the phone with the D-pad; Back = app → home → close; 300 ms double-press guard), focus on the first icon when opened with a controller, visible focus ring. |
| `PhoneHomescreen.vue` | inactive icon pages and the search page get `bng-no-child-nav`, so focus doesn't jump to invisible icons. |

Every anchor is checked; on a different mod version the script stops with `ANCHOR NOT FOUND` instead of guessing.

**Known limits:** list rows inside some apps that have no `@click` handler may still be unreachable with a controller.

## Two traps worth knowing (if you build your own patches)
- **.NET `ZipArchive` in *Update* mode corrupts empty entries** (`stored, csize=2, usize=0`). RLS ships 16 zero-byte
  "switch-off" files (e.g. `levels/west_coast_usa/dynamicAudioEmitters/ribbonData.audioSFX.json`). BeamNG skips the broken
  entry, loads the vanilla file instead → `core/audioRibbon.lua:596 attempt to compare number with nil` → endless level loading.
  `build_zip.ps1` always writes a *new* archive (Create mode).
- **BeamNG 0.39's runtime Vue compiler caches components by file timestamp.** Repack a changed `.vue` with its old
  `LastWriteTime` and the game keeps showing the old component. `build_zip.ps1` stamps replaced entries with the current time.

## Translation notes
`apply.py` rejects any translation that breaks `%s/%d` (count and order), `${…}`, `{{…}}`, escapes, HTML tags or
edge spaces; rejects go to `rejected.json` and stay in English. Strings that are ever compared in code
(`== "…"`, `case`, `includes(…)`, table keys) are never extracted, so game logic doesn't break.
For RLS 2.7.2: 6 772 unique strings (~36k words), 8 956 occurrences in 434 files, 8 400 applied, 18 rejected.
`GLOSSARY.ru.md` is the Russian glossary we used.

## License
MIT for the code in this repository. RLS Career Overhaul and BeamNG.drive belong to their respective authors.

---

## По-русски коротко
Неофициальные инструменты для RLS Career Overhaul: **управление телефоном с геймпада** и **конвейер перевода**
(извлечь строки → перевести → безопасно вставить → собрать zip). Файлов мода в репозитории нет — скрипты правят
вашу локальную копию. Русский словарь (6 772 строки) выложим, когда авторы мода разрешат.
