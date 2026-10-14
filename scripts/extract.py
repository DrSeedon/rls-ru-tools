#!/usr/bin/env python3
"""Extract user-facing English strings from an unpacked RLS Career Overhaul mod.

Usage: python extract.py --mod-dir <unpacked mod> --out-dir <work dir>
Writes:
  occ.json  - every occurrence with exact file/offset coordinates (used by apply.py)
  uniq.json - sorted list of unique strings (the thing you translate)
"""
import argparse, glob, json, os, re
from collections import Counter

ap = argparse.ArgumentParser()
ap.add_argument('--mod-dir', required=True, help='unpacked mod root (contains ui/ and lua/)')
ap.add_argument('--out-dir', required=True)
args = ap.parse_args()
ROOT = os.path.abspath(args.mod_dir)
OUTD = os.path.abspath(args.out_dir)
os.makedirs(OUTD, exist_ok=True)
os.chdir(ROOT)

occ = []  # dicts: file, start, end, text, kind, quote


def human(s):
    """Heuristic: does this literal look like text a player reads (not an id/path/class)?"""
    t = s.strip()
    if not re.search(r'[A-Za-z]{2}', t): return False
    if re.fullmatch(r'[\w\-./:#%@$]+', t) and not re.search(r'[A-Z][a-z]', t): return False  # ids/paths/classes
    if re.fullmatch(r'[a-z]+[A-Z]\w*', t): return False   # camelCase
    if re.fullmatch(r'[a-z0-9_]+', t): return False       # snake/lower id
    if re.search(r'^(https?:|/|\.\.?/|#|mdi-|fa-|bng-|var\(|rgba?\(|calc\()', t): return False
    if re.search(r'\.(png|jpg|svg|lua|js|vue|json|mp3|af|css|html|dae|jbeam)\b', t): return False
    if re.fullmatch(r'[A-Z_0-9]+', t): return False       # CONSTANT
    if re.fullmatch(r'[a-zA-Z_]+(\.[\w\-]+){2,}', t): return False  # i18n keys
    if re.search(r'(px|em|rem|vh|vw|%)$', t) and re.fullmatch(r'[\d.\s\w%-]+', t) and ' ' not in t: return False
    if t.startswith(('.', '#')) or re.fullmatch(r'[\w-]+(\s+[\w-]+)*', t) and re.search(r'(^|\s)[a-z][\w]*-[\w-]+', t): return False  # css class lists
    return True


# Literals that are ever compared / used as keys anywhere must NOT be translated (logic depends on them)
cmp = set()
for f in glob.glob('ui/**/*.*', recursive=True) + glob.glob('lua/**/*.lua', recursive=True):
    if not f.endswith(('.vue', '.js', '.lua', '.html')): continue
    s = open(f, encoding='utf8', errors='ignore').read()
    for m in re.finditer(r'(?:===?|!==?|~=|case)\s*([\'"])((?:\\.|(?!\1).)*)\1', s): cmp.add(m.group(2))
    for m in re.finditer(r'([\'"])((?:\\.|(?!\1).)*)\1\s*(?:===?|!==?|~=)', s): cmp.add(m.group(2))
    for m in re.finditer(r'(?:includes|indexOf|startsWith|endsWith|find|match|gsub|test)\(\s*([\'"])((?:\\.|(?!\1).)*)\1', s): cmp.add(m.group(2))
    for m in re.finditer(r'\[\s*([\'"])((?:\\.|(?!\1).)*)\1\s*\]', s): cmp.add(m.group(2))

STR = re.compile(r"""(['"`])((?:\\.|(?!\1)[^\\\n])*)\1""")


def add(f, st, en, text, kind, q=''):
    occ.append(dict(file=f, start=st, end=en, text=text, kind=kind, quote=q))


def scan_literals(f, s, a, b, kind, strict):
    seg = s[a:b]
    for m in STR.finditer(seg):
        q, val = m.group(1), m.group(2)
        if q == '`' and '${' in val and not re.search(r'[A-Za-z]{2,}\s+[A-Za-z]', re.sub(r'\$\{[^}]*\}', '', val)): continue
        if not human(val) or val in cmp: continue
        if strict:
            core = re.sub(r'\$\{[^}]*\}', '', val)
            if not (' ' in core.strip() or re.search(r'[.!?:]$', core.strip()) or re.fullmatch(r'[A-Z][a-z]+', core.strip())): continue
            pre = seg[max(0, m.start() - 40):m.start()]
            if re.search(r'(import|from|require|emit|\$emit|getComponent|lua\.|bngApi|engineLua|trigger|on|addEventListener|route|name:\s*|path:\s*|id:\s*|key:\s*|icon\w*:\s*|class\w*:\s*|type:\s*|category:\s*|value:\s*|event:\s*|appId:\s*|relatedAppId:\s*)\s*\(?\s*$', pre): continue
        pre2 = seg[max(0, m.start() - 60):m.start()]
        if re.search(r'(console\.\w+|log|warn|error|print|dump)\s*\([^)]*$', pre2): continue
        add(f, a + m.start(2), a + m.end(2), val, kind, q)


for f in sorted(glob.glob('ui/**/*.vue', recursive=True)):
    s = open(f, encoding='utf8').read()
    tm = re.search(r'<template[^>]*>', s); te = s.rfind('</template>')
    if tm and te > 0:
        a, b = tm.end(), te
        t = s[a:b]
        for m in re.finditer(r'>([^<>]+)<', t):  # text nodes, split around {{ mustache }}
            node = m.group(1); base = a + m.start(1); pos = 0
            for mm in re.finditer(r'\{\{.*?\}\}', node, re.S):
                part = node[pos:mm.start()]
                if human(part):
                    lead = len(part) - len(part.lstrip())
                    add(f, base + pos + lead, base + pos + lead + len(part.strip()), part.strip(), 'vue_text')
                scan_literals(f, s, base + mm.start(), base + mm.end(), 'vue_expr', False)
                pos = mm.end()
            part = node[pos:]
            if human(part):
                lead = len(part) - len(part.lstrip())
                add(f, base + pos + lead, base + pos + lead + len(part.strip()), part.strip(), 'vue_text')
        for m in re.finditer(r'\s(title|placeholder|label|aria-label|alt|tooltip|text|header|subtitle|description|hint|message|confirm-text|cancel-text|empty-text|heading|caption)="([^"]*)"', t):
            if human(m.group(2)) and m.group(2) not in cmp: add(f, a + m.start(2), a + m.end(2), m.group(2), 'vue_attr', '"')
        for m in re.finditer(r'\s[:@#]?[\w\-:.]+="([^"]*)"', t):  # bound attributes with literals
            full = m.group(0)
            if not re.match(r'\s[:]', full) and not re.match(r'\sv-(if|else-if|show|html|text)', full): continue
            if re.match(r'\sv-(if|else-if|show)', full): continue
            scan_literals(f, s, a + m.start(1), a + m.end(1), 'vue_bind', False)
    sm = re.search(r'<script[^>]*>', s); se = s.rfind('</script>')
    if sm and se > 0: scan_literals(f, s, sm.end(), se, 'vue_script', True)

for f in sorted(glob.glob('ui/ui-vue/**/*.js', recursive=True)):
    s = open(f, encoding='utf8').read()
    scan_literals(f, s, 0, len(s), 'js', True)
for f in sorted(glob.glob('ui/ui-vue/src/modules/career/apps/manifests/**/*.js', recursive=True)):
    s2 = open(f, encoding='utf8').read()
    for m in re.finditer(r"name:\s*'([^']+)'", s2):
        if human(m.group(1)): add(f, m.start(1), m.end(1), m.group(1), 'manifest_name', "'")

# Lua: only UI-facing fields / message calls
LUA_KEYS = r'(?:title|msg|message|text|description|desc|label|name|subtitle|header|body|tooltip|hint|reason|summary|caption|prompt|confirmText|buttonText|status\w*Text)'
for f in sorted(glob.glob('lua/**/*.lua', recursive=True)):
    s = open(f, encoding='utf8', errors='ignore').read()
    for m in re.finditer(r'(?:ui_message|guihooks\.message|Message|toastrMsg|career_modules_\w+\.notify\w*|showMessage|notify)\s*\(\s*([\'"])((?:\\.|(?!\1).)*)\1', s):
        v = m.group(2)
        if human(v) and v not in cmp: add(f, m.start(2), m.end(2), v, 'lua_call', m.group(1))
    for m in re.finditer(LUA_KEYS + r'\s*=\s*([\'"])((?:\\.|(?!\1).)*)\1', s):
        v = m.group(2)
        if human(v) and v not in cmp and (' ' in v.strip() or re.search(r'[.!?]$', v)): add(f, m.start(2), m.end(2), v, 'lua_field', m.group(1))
    for m in re.finditer(r'(?:ui_message|msg\s*=|message\s*=|text\s*=)\s*\(?\s*(?:string\.format\()?\s*([\'"])((?:\\.|(?!\1).)*)\1', s):
        v = m.group(2)
        if human(v) and v not in cmp: add(f, m.start(2), m.end(2), v, 'lua_fmt', m.group(1))

# Angular html (ui/modModules, ui/modules)
for f in sorted(glob.glob('ui/mod*/**/*.html', recursive=True) + glob.glob('ui/modules/**/*.html', recursive=True)):
    s = open(f, encoding='utf8', errors='ignore').read()
    for m in re.finditer(r'>([^<>]+)<', s):
        node = m.group(1)
        if '{{' in node:
            for part in re.split(r'\{\{.*?\}\}', node):
                if human(part):
                    i = s.find(part.strip(), m.start(1))
                    if i >= 0: add(f, i, i + len(part.strip()), part.strip(), 'html_text')
            continue
        if human(node) and not re.search(r'[{};]', node):
            lead = len(node) - len(node.lstrip()); st = m.start(1) + lead
            add(f, st, st + len(node.strip()), node.strip(), 'html_text')

# drop overlapping spans
occ.sort(key=lambda o: (o['file'], o['start'], -(o['end'] - o['start'])))
out = []; last = {}
for o in occ:
    k = o['file']
    if k in last and o['start'] < last[k]: continue
    out.append(o); last[k] = o['end']
json.dump(out, open(os.path.join(OUTD, 'occ.json'), 'w'), ensure_ascii=False)
uniq = sorted({o['text'] for o in out})
json.dump(uniq, open(os.path.join(OUTD, 'uniq.json'), 'w'), ensure_ascii=False, indent=0)
print('occurrences', len(out), 'unique', len(uniq), 'words', sum(len(u.split()) for u in uniq))
print(dict(Counter(o['kind'] for o in out)))
