#!/usr/bin/env python3
"""Gamepad/controller navigation for the RLS Career Overhaul phone (tested on RLS 2.7.2, BeamNG 0.39.4).

Why: phone icons/cards are <div @click>, not <button>, so BeamNG's UI navigation never sees them and only
"Back" works. The phone routes also have no controller scope. This script patches YOUR local copy of the mod:

  1. every clickable non-button element in phone views (@click / v-on:click / @tap) gets
     `bng-nav-item tabindex="0" v-bng-on-ui-nav:ok.asMouse.focusRequired` (same pattern the mod already uses
     for the garage computer). Pointer-only containers (map, page viewport, dock) are left alone - tagging
     them steals focus into an invisible box.
  2. overhaul/uiRoutes.lua: phone* routes get `scopeTree = {["rls-phone"] = {}}` (runtime mod routes may
     only declare scopeTree; its root becomes the target scope).
  3. PhoneWrapper.vue: v-bng-scoped-nav "rls-phone" (no escaping the phone with the D-pad, Back closes
     app -> home -> phone, 300 ms double-back guard), focus on the first icon when opened with a controller,
     visible focus ring, and stick scrolling: left/right stick scroll lists like a mouse wheel (when there is
     nothing to scroll the left stick moves focus as before); the D-pad also reaches buttons scrolled out of view
     (the game only focuses elements whose centre is visible, so long lists were cut off).
  4. PhoneHomescreen.vue: hidden icon pages / search page get bng-no-child-nav while not shown.

Usage: python patch_phone_nav.py --mod-dir <unpacked mod> --out-dir <overlay> [--base-overlay <overlay>]
--base-overlay: read files from another overlay first (e.g. the translated one) so both patches stack.
Every anchor is checked; if the mod version differs the script stops instead of guessing.
"""
import argparse, glob, os, re, sys

ap = argparse.ArgumentParser()
ap.add_argument('--mod-dir', required=True)
ap.add_argument('--out-dir', required=True)
ap.add_argument('--base-overlay')
args = ap.parse_args()
SRC = os.path.abspath(args.mod_dir); OUT = os.path.abspath(args.out_dir)
BASE = os.path.abspath(args.base_overlay) if args.base_overlay else None
CAREER = 'ui/ui-vue/src/modules/career'
results = {}


def cur(f):
    if f in results: return results[f]
    p = os.path.join(BASE, f) if BASE else None
    return open(p if p and os.path.exists(p) else os.path.join(SRC, f), encoding='utf8').read()


def die(msg):
    sys.exit(f'ANCHOR NOT FOUND - different mod version? {msg}')


def replace_once(s, old, new, where):
    if s.count(old) != 1: die(f'{where}: {old[:70]!r} found {s.count(old)} times')
    return s.replace(old, new)


# ---------- 1. nav items on clickable non-buttons ----------
targets = set(glob.glob(f'{SRC}/{CAREER}/views/Phone*.vue') + glob.glob(f'{SRC}/{CAREER}/components/phone/**/*.vue', recursive=True))
targets = {os.path.relpath(t, SRC) for t in targets}
for _ in range(2):  # plus components they import, two levels deep
    extra = set()
    for f in list(targets):
        for m in re.finditer(r'import\s+\w+\s+from\s+[\'"]([^\'"]+\.vue)[\'"]', cur(f)):
            p = os.path.normpath(os.path.join(os.path.dirname(f), m.group(1)))
            if p.startswith(CAREER) and os.path.exists(os.path.join(SRC, p)): extra.add(p)
    targets |= extra

SKIP_TAGS = {'template', 'slot', 'transition', 'transition-group', 'router-view', 'keep-alive', 'teleport',
             'component', 'button', 'input', 'select', 'textarea', 'option'}
NAV = ' bng-nav-item{tab} v-bng-on-ui-nav:ok.asMouse.focusRequired'


def tags(t):
    i, n = 0, len(t)
    while i < n:
        if t[i] == '<' and i + 1 < n and t[i + 1].isalpha():
            j, q = i + 1, None
            while j < n:
                c = t[j]
                if q:
                    if c == q: q = None
                elif c in '"\'': q = c
                elif c == '>': break
                j += 1
            yield i, j
            i = j + 1
        else:
            i += 1


def is_backdrop(tag):
    """Modal backdrops / click-stoppers are NOT buttons. Tagging them makes A (sent as a mouse click to the
    focused element's ancestors too) hit the backdrop and close the dialog - e.g. App Store "Install" never ran."""
    clicks = re.findall(r'(?:@click|v-on:click)((?:\.[\w]+)*)(="[^"]*")?', tag)
    if not clicks: return False
    for mods, val in clicks:
        if '.self' in mods: return True                       # @click.self="close" - backdrop
        if not val: return True                               # bare @click.stop - only stops propagation
    # full-screen backgrounds / pointer-geometry viewports: the real buttons live inside them, and a focused
    # background swallows the D-pad (Taxi "Start ride" was unreachable). Handlers using clientX are pointer-only.
    if any(re.search(r'background|viewport', v, re.I) for _, v in clicks): return True
    cls = ' '.join(re.findall(r'\sclass="([^"]*)"', tag))
    vals = ' '.join(v for _, v in clicks)
    if re.search(r'overlay|backdrop', cls) and re.search(r'close|cancel|dismiss|hide', vals, re.I): return True
    return False


tagged = 0
for f in sorted(targets):
    s = cur(f)
    tm = re.search(r'<template[^>]*>', s); te = s.rfind('</template>')
    if not tm or te < 0: continue
    a, b = tm.end(), te; t = s[a:b]; edits = []
    for st, en in tags(t):
        tag = t[st:en + 1]
        name = re.match(r'<([\w\-.]+)', tag).group(1)
        if name.lower() in SKIP_TAGS or name.endswith('Button') or (name.startswith('Bng') and name != 'BngCard'): continue
        if not re.search(r'(\s@click|\sv-on:click|\s@tap)\b', tag): continue   # real click targets only
        if is_backdrop(tag): continue
        if re.search(r'bng-nav-item|bng-no-nav|v-bng-on-ui-nav', tag): continue
        tab = '' if re.search(r'[\s:]tabindex=', tag) else ' tabindex="0"'
        edits.append((st + 1 + len(name), NAV.format(tab=tab)))
    if not edits: continue
    for pos, ins in sorted(edits, reverse=True): t = t[:pos] + ins + t[pos:]
    s2 = s[:a] + t + s[b:]
    if not re.search(r'\bvBngOnUiNav\b', s2):
        m = re.search(r'<script\s+setup[^>]*>', s2)
        if not m: print('skip (no <script setup>):', f); continue
        s2 = s2[:m.end()] + '\nimport { vBngOnUiNav } from "@/common/directives"' + s2[m.end():]
    results[f] = s2; tagged += len(edits)

# ---------- 2. controller scope for phone routes ----------
f = 'lua/ge/extensions/overhaul/uiRoutes.lua'
results[f] = replace_once(cur(f),
    '  local luaRoute = {backTarget = backTarget, title = routeTitles[name]}\n',
    '  local luaRoute = {backTarget = backTarget, title = routeTitles[name]}\n'
    '  -- gamepad patch: give phone routes a controller scope (vanilla routes declare targetScope;\n'
    '  -- runtime mod routes may only set scopeTree, whose root becomes the target scope). Matches PhoneWrapper.vue.\n'
    '  if string.find(name, "phone", 1, true) then\n'
    '    luaRoute.scopeTree = {["rls-phone"] = {}}\n'
    '  end\n', f)

# ---------- 3. PhoneWrapper: scoped nav, guarded back, entry focus, focus ring ----------
f = f'{CAREER}/views/PhoneWrapper.vue'
s = cur(f)
s = replace_once(s, """<div class="phone-screen" :class="{ 'phone-screen--has-app-header': !!$slots.header }">""",
                 """<div class="phone-screen" :class="{ 'phone-screen--has-app-header': !!$slots.header }" v-bng-scoped-nav="phoneNavScope">""", f)
s = replace_once(s, 'v-bng-on-ui-nav:back,menu.asMouse @click="back"', 'v-bng-on-ui-nav:back,menu.asMouse @click="guardedBack"', f)
s = replace_once(s, 'import { vBngOnUiNav } from "@/common/directives"\n',
                 'import { vBngOnUiNav, vBngScopedNav } from "@/common/directives"\n'
                 'import { focusScreenEntry } from "../composables/useScreenEntryFocus"\n'
                 'import { setFocus as navSetFocus } from "@/services/uiNavFocus"\n'
                 'import useControls from "@/services/controls"\n', f)
if 'const phoneRef' not in s and 'phoneRef = ref' not in s: die(f'{f}: phoneRef')
for name in ('isEntered', 'onUnmounted'):
    if not re.search(r'\b' + name + r'\b', s): die(f'{f}: {name}')
SCRIPT = '''
// --- gamepad patch: controller navigation scope for the phone (phone routes declare scopeTree {"rls-phone"}
// in overhaul/uiRoutes.lua). Back: app -> home -> close; double-press guard 300 ms.
let lastBackAt = 0
const guardedBack = () => {
  const now = Date.now()
  if (now - lastBackAt < 300) return
  lastBackAt = now
  back()
}
const phoneNavScope = {
  scopeId: "rls-phone",
  type: "container",
  activated: true,
  activateOnMount: true,
  preferAutoFocus: true,
  preventNavigationEscape: ["top", "bottom", "left", "right"],
  canDeactivate: () => {
    guardedBack()
    return false
  },
}
const navControls = useControls()
const phoneEntryFocus = () => {
  const root = phoneRef.value
  if (!root || !document.contains(root)) return
  const ae = document.activeElement
  if (ae && ae !== document.body && root.contains(ae) && !ae.classList.contains("status-back")) return
  const el = root.querySelector('.phone-content [bng-nav-item]:not([bng-no-nav="true"]), .phone-content button:not([disabled])')
    || root.querySelector(".status-back")
  if (!el) return
  try { navSetFocus(el) } catch (_) { el.focus() }
}
// --- gamepad patch: sticks scroll the phone like a mouse wheel (left stick: focus_ud/focus_lr, right stick:
// rotate_v_cam/rotate_h_cam). We catch the ui_nav event before the phone scope and crossfire see it: if there is
// something to scroll on that axis we scroll it and swallow the event, otherwise it passes through unchanged
// (the left stick then moves focus exactly as before). On release, focus jumps to a visible item.
const STICK_EVENTS = { focus_ud: "v", focus_lr: "h", rotate_v_cam: "v", rotate_h_cam: "h" }
const STICK_DEAD = 0.2
const STICK_PX = 22 // px per frame at full deflection
const stick = { v: 0, h: 0, area: { v: null, h: null }, pass: { v: false, h: false }, raf: 0 }
const stickCanScroll = (el, ax) => {
  const st = getComputedStyle(el)
  const ov = ax === "v" ? st.overflowY : st.overflowX
  if (ov !== "auto" && ov !== "scroll") return false
  return ax === "v" ? el.scrollHeight > el.clientHeight + 1 : el.scrollWidth > el.clientWidth + 1
}
const stickVisible = el => { const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0 }
const findStickArea = ax => {
  const root = phoneRef.value
  if (!root) return null
  for (let n = document.activeElement; n && n !== root && root.contains(n); n = n.parentElement)
    if (stickCanScroll(n, ax)) return n
  let best = null, bestSize = 0
  for (const n of root.querySelectorAll(".phone-content *")) {
    if (!stickCanScroll(n, ax) || !stickVisible(n)) continue
    const size = n.clientWidth * n.clientHeight
    if (size > bestSize) { best = n; bestSize = size }
  }
  return best
}
const refocusVisible = area => {
  if (!area || !area.isConnected) return
  const ar = area.getBoundingClientRect()
  const inView = el => {
    const r = el.getBoundingClientRect()
    return r.bottom > ar.top + 4 && r.top < ar.bottom - 4 && r.right > ar.left + 4 && r.left < ar.right - 4
  }
  const ae = document.activeElement
  if (ae && area.contains(ae) && inView(ae)) return
  const cand = [...area.querySelectorAll('[bng-nav-item]:not([bng-no-nav="true"]), button:not([disabled])')]
    .filter(el => stickVisible(el) && inView(el))
  if (!cand.length) return
  cand.sort((a, b) => Math.abs(a.getBoundingClientRect().top - ar.top) - Math.abs(b.getBoundingClientRect().top - ar.top))
  try { navSetFocus(cand[0]) } catch (_) { cand[0].focus() }
}
const stickLoop = () => {
  stick.raf = 0
  let moving = false
  for (const ax of ["v", "h"]) {
    const val = stick[ax], area = stick.area[ax]
    if (!area || !area.isConnected || Math.abs(val) < STICK_DEAD) continue
    const mag = (Math.abs(val) - STICK_DEAD) / (1 - STICK_DEAD)
    let d = (ax === "v" ? -1 : 1) * Math.sign(val) * Math.pow(mag, 1.6) * STICK_PX
    d = Math.sign(d) * Math.max(1, Math.abs(d))
    if (ax === "v") area.scrollTop += d
    else area.scrollLeft += d
    moving = true
  }
  if (moving) stick.raf = requestAnimationFrame(stickLoop)
}
const onStickNav = e => {
  const d = e.detail
  const ax = d && STICK_EVENTS[d.name]
  if (!ax) return
  const root = phoneRef.value
  if (!root || !document.contains(root) || !isEntered.value) return
  // focus is in something drawn outside the phone (dropdown/popover list teleported to the body): hands off
  const fa = document.activeElement
  if (fa && fa !== document.body && !root.contains(fa)) return
  const val = typeof d.value === "number" ? d.value : 0
  if (Math.abs(val) < STICK_DEAD) { // released
    stick.pass[ax] = false
    if (stick.area[ax]) {
      const area = stick.area[ax]
      stick[ax] = 0
      stick.area[ax] = null
      refocusVisible(area)
      e.stopPropagation()
      e.preventDefault()
    }
    return
  }
  if (stick.pass[ax]) return // this press already went to normal navigation - keep it there until release
  if (!stick.area[ax] || !stick.area[ax].isConnected) stick.area[ax] = findStickArea(ax)
  if (!stick.area[ax]) { stick.pass[ax] = true; return } // nothing to scroll on this axis
  stick[ax] = val
  e.stopPropagation()
  e.preventDefault()
  if (!stick.raf) stick.raf = requestAnimationFrame(stickLoop)
}
// --- gamepad patch: D-pad reaches items below/above the visible part of a list. The game only focuses elements
// whose centre is actually visible (elementFromPoint occlusion test), so a button scrolled out of its list was
// unreachable (Employment "Start shift"). If there is no visible target in that direction but a clipped one exists
// in the same scroll area, we scroll it into view and focus it ourselves.
const DPAD_DIRS = { focus_d: "d", focus_u: "u", focus_r: "r", focus_l: "l" }
const DPAD_SEL = 'button:not([disabled]), [bng-nav-item]:not([bng-no-nav="true"]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), a[href]'
const onDpadNav = e => {
  const d = e.detail
  const dir = d && DPAD_DIRS[d.name]
  if (!dir || d.value !== 1) return
  const root = phoneRef.value
  if (!root || !document.contains(root) || !isEntered.value) return
  const ae = document.activeElement
  if (!ae || !root.contains(ae)) return
  const ax = dir === "d" || dir === "u" ? "v" : "h"
  let area = null
  for (let n = ae.parentElement; n && n !== root; n = n.parentElement) if (stickCanScroll(n, ax)) { area = n; break }
  if (!area) return
  const ar = area.getBoundingClientRect(), cr = ae.getBoundingClientRect()
  const inDir = r => dir === "d" ? r.top >= cr.bottom - 2 : dir === "u" ? r.bottom <= cr.top + 2 : dir === "r" ? r.left >= cr.right - 2 : r.right <= cr.left + 2
  const centreVisible = r => {
    const x = (r.left + r.right) / 2, y = (r.top + r.bottom) / 2
    return x >= ar.left && x <= ar.right && y >= ar.top && y <= ar.bottom
  }
  const cands = [...area.querySelectorAll(DPAD_SEL)]
    .filter(el => el !== ae && !ae.contains(el) && stickVisible(el) && !el.closest('[bng-no-child-nav="true"]'))
    .map(el => ({ el, r: el.getBoundingClientRect() }))
    .filter(c => inDir(c.r))
  if (!cands.length || cands.some(c => centreVisible(c.r))) return // nothing hidden, or the game can handle it
  const cx = (cr.left + cr.right) / 2, cy = (cr.top + cr.bottom) / 2
  const dist = r => ax === "v"
    ? Math.abs((dir === "d" ? r.top - cr.bottom : cr.top - r.bottom)) + Math.abs((r.left + r.right) / 2 - cx) * 0.5
    : Math.abs((dir === "r" ? r.left - cr.right : cr.left - r.right)) + Math.abs((r.top + r.bottom) / 2 - cy) * 0.5
  cands.sort((a, b) => dist(a.r) - dist(b.r))
  const { el, r } = cands[0]
  if (dir === "d") area.scrollTop += r.bottom - ar.bottom + 12
  else if (dir === "u") area.scrollTop -= ar.top - r.top + 12
  else if (dir === "r") area.scrollLeft += r.right - ar.right + 12
  else area.scrollLeft -= ar.left - r.left + 12
  try { navSetFocus(el) } catch (_) { el.focus({ preventScroll: true }) }
  e.stopPropagation()
  e.preventDefault()
}
onUnmounted(() => {
  window.removeEventListener("ui_nav", onDpadNav, true)
  window.removeEventListener("ui_nav", onStickNav, true)
  if (stick.raf) cancelAnimationFrame(stick.raf)
})
onMounted(() => {
  window.addEventListener("ui_nav", onStickNav, true)
  window.addEventListener("ui_nav", onDpadNav, true)
  focusScreenEntry("rls-phone", { force: true })
  if (!navControls.focusIfController) return
  setTimeout(phoneEntryFocus, 250)
  setTimeout(phoneEntryFocus, 700)
})

</script>
'''
i = s.find('</script>')
if i < 0 or s.count('</script>') != 1: die(f'{f}: </script>')
s = s[:i].rstrip('\n') + '\n' + SCRIPT + s[i + len('</script>\n'):]
s = s.rstrip('\n') + '''

<style lang="scss">
/* gamepad patch: visible focus ring for controller navigation inside the phone */
.phone-wrapper [bng-nav-item]:focus,
.phone-wrapper button:focus {
  outline: 3px solid #ff8c1a !important;
  outline-offset: 2px;
  border-radius: 12px;
}
</style>
'''
results[f] = s

# ---------- 4. PhoneHomescreen: hidden pages are not navigable ----------
f = f'{CAREER}/views/PhoneHomescreen.vue'
s = cur(f)
s = replace_once(s, '            class="page apps-page"\n',
                 '            class="page apps-page"\n'
                 '''            :bng-no-child-nav="pageIdx !== currentPageIndex ? 'true' : undefined"\n''', f)
s = replace_once(s, '            class="page search-page"\n',
                 '            class="page search-page"\n'
                 '''            :bng-no-child-nav="!isSearchPageActive ? 'true' : undefined"\n''', f)
for name in ('currentPageIndex', 'isSearchPageActive'):
    if not re.search(r'\b' + name + r'\b\s*=', s): die(f'{f}: {name}')
if not re.search(r'\bvBngOnUiNav\b', s.split('<script', 1)[1]):
    s = re.sub(r'(<script\s+setup[^>]*>)', r'\1\nimport { vBngOnUiNav } from "@/common/directives"', s, count=1)
results[f] = s

for f, s in results.items():
    p = os.path.join(OUT, f)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, 'w', encoding='utf8', newline='').write(s)
print(f'patched {len(results)} files, {tagged} clickable elements tagged -> {OUT}')
