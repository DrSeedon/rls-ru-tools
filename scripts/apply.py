#!/usr/bin/env python3
"""Apply a translation dictionary {english: translated} to an unpacked mod.

Usage: python apply.py --mod-dir <unpacked mod> --occ <work>/occ.json --dict translations.json --out-dir <overlay>
Only changed files are written to --out-dir (same relative paths) - this is the "overlay" you pack later.
Every replacement is checked: printf placeholders (%s %d ...), ${...}, {{ }}, escapes, HTML tags and
leading/trailing spaces must survive unchanged; otherwise the string is skipped and logged.
"""
import argparse, json, os, re, shutil

ap = argparse.ArgumentParser()
ap.add_argument('--mod-dir', required=True)
ap.add_argument('--occ', required=True)
ap.add_argument('--dict', required=True)
ap.add_argument('--out-dir', required=True)
args = ap.parse_args()
SRC, OUT = os.path.abspath(args.mod_dir), os.path.abspath(args.out_dir)
occ = json.load(open(args.occ, encoding='utf8'))
tr = json.load(open(args.dict, encoding='utf8'))

PH = re.compile(r"%[-+ #0]*\d*(?:\.\d+)?[sdifqxXcgeE%]|\$\{|\{\{|\}\}|\\.|<[^>]*>|&\w+;|\$")
PF = re.compile(r"%[-+ #0]*\d*(?:\.\d+)?[sdifqxXcgeE]")


def ok(src, dst):
    if not dst.strip(): return False
    if sorted(PH.findall(src)) != sorted(PH.findall(dst)): return False
    if PF.findall(src) != PF.findall(dst): return False  # printf order matters in Lua
    if src[:1] == ' ' and dst[:1] != ' ': return False
    if src[-1:] == ' ' and dst[-1:] != ' ': return False
    return True


stats = {'applied': 0, 'no_translation': 0, 'rejected': 0, 'quote': 0}; badlog = []
byfile = {}
for o in occ: byfile.setdefault(o['file'], []).append(o)
if os.path.exists(OUT): shutil.rmtree(OUT)
changed = []
for f, lst in byfile.items():
    s = open(os.path.join(SRC, f), encoding='utf8').read(); orig = s
    for o in sorted(lst, key=lambda x: -x['start']):
        src = o['text']; dst = tr.get(src)
        if dst is None: stats['no_translation'] += 1; continue
        if dst == src: continue
        if not ok(src, dst): stats['rejected'] += 1; badlog.append((src, dst)); continue
        q = o['quote']; k = o['kind']
        if k in ('vue_text', 'html_text'):
            if '<' in dst.replace('<b>', '').replace('</b>', '') and '<' not in src: stats['rejected'] += 1; continue
            if '{{' in dst and '{{' not in src: stats['rejected'] += 1; continue
        if k == 'vue_attr' and '"' in dst and '"' not in src: stats['quote'] += 1; continue
        if k in ('vue_bind', 'vue_expr') and '"' in dst and '"' not in src: stats['quote'] += 1; continue
        if q and q in dst and q not in src:
            dst = re.sub(r'(?<!\\)' + re.escape(q), lambda m: '\\' + q, dst)
        assert s[o['start']:o['end']] == src, f'{f}: occ.json does not match this mod version ({src!r})'
        s = s[:o['start']] + dst + s[o['end']:]; stats['applied'] += 1
    if s != orig:
        p = os.path.join(OUT, f)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, 'w', encoding='utf8', newline='').write(s); changed.append(f)
json.dump(badlog, open(os.path.join(OUT, '..', 'rejected.json'), 'w'), ensure_ascii=False, indent=1)
print(stats, 'files changed', len(changed), 'dictionary size', len(tr))
