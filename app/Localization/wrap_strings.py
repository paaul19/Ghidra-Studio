#!/usr/bin/env python3
"""Wraps Spanish UI string literals in tr(...) when they exist in en.json.

"Importando \\(x)…"  ->  tr("Importando %@…", "\\(x)")
Idempotent: literals already inside tr( are skipped.
"""
import json, sys, os

HERE = os.path.dirname(os.path.abspath(__file__))
KEYS = set(json.load(open(os.path.join(HERE, "en.json"))).keys())


def scan_literal(src, i):
    """src[i] == '"'. Returns (end_index_exclusive, parts) where parts are text / ('expr', code)."""
    assert src[i] == '"'
    if src.startswith('"""', i):
        return None
    j = i + 1
    text = []
    parts = []
    while j < len(src):
        c = src[j]
        if c == '\n':
            return None
        if c == '\\':
            if src[j + 1] == '(':
                # interpolation: find matching paren, honoring nested strings
                depth = 1
                k = j + 2
                start = k
                while depth:
                    ch = src[k]
                    if ch == '"':
                        r = scan_literal(src, k)
                        if r is None:
                            return None
                        k = r[0]
                        continue
                    if ch == '(':
                        depth += 1
                    elif ch == ')':
                        depth -= 1
                    k += 1
                parts.append(''.join(text))
                text = []
                parts.append(('expr', src[start:k - 1]))
                j = k
                continue
            text.append(src[j:j + 2])
            j += 2
            continue
        if c == '"':
            parts.append(''.join(text))
            return j + 1, parts
        text.append(c)
        j += 1
    return None


def unescape(s):
    return s.replace('\\n', '\n').replace('\\"', '"').replace('\\\\', '\\')


def process(path):
    src = open(path, encoding='utf-8').read()
    out = []
    i = 0
    changed = 0
    while i < len(src):
        c = src[i]
        # skip comments
        if src.startswith('//', i):
            k = src.find('\n', i)
            k = len(src) if k < 0 else k
            out.append(src[i:k]); i = k; continue
        if c == '"':
            if src.startswith('"""', i):
                k = src.find('"""', i + 3) + 3
                out.append(src[i:k]); i = k; continue
            r = scan_literal(src, i)
            if r is None:
                out.append(c); i += 1; continue
            end, parts = r
            literal = src[i:end]
            key = ''.join(p if isinstance(p, str) else '%@' for p in parts)
            exprs = [p[1] for p in parts if not isinstance(p, str)]
            already = src[max(0, i - 3):i] == 'tr(' or src[max(0, i - 4):i] == 'tr( '
            if unescape(key) in KEYS and not already and not any('"' in e and ('?' in e and ':' in e) for e in []):
                args = ''.join(', "\\(%s)"' % e for e in exprs)
                out.append('tr("%s"%s)' % (key, args))
                changed += 1
            else:
                out.append(literal)
            i = end
            continue
        out.append(c)
        i += 1
    if changed:
        open(path, 'w', encoding='utf-8').write(''.join(out))
    return changed


if __name__ == '__main__':
    total = 0
    for p in sys.argv[1:]:
        n = process(p)
        total += n
        print(f"{os.path.basename(p)}: {n}")
    print("total", total)
