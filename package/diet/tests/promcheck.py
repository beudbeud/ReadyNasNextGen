#!/usr/bin/env python3
"""Checks a Prometheus text exposition (format 0.0.4) written by the DIET collector.

  promcheck.py FILE [PREFIX]

Strict on what the collector promises: every family has HELP and TYPE before
its samples and is contiguous, counters end in _total and are >= 0, no NaN or
infinity, no duplicate series, well-formed names, labels and escapes, every
name starts with PREFIX (default readynas_). Prints the first problem; exit 1.
Used by test-api.sh (promtool check metrics is used as well when installed).
"""
import math
import re
import sys

NAME = re.compile(r'[a-zA-Z_:][a-zA-Z0-9_:]*$')
SAMPLE = re.compile(r'([a-zA-Z_:][a-zA-Z0-9_:]*)(\{(.*)\})? (\S+)( -?\d+)?$')
LABEL = re.compile(r'([a-zA-Z_][a-zA-Z0-9_]*)="((?:[^"\\\n]|\\[\\"n])*)"(,|$)')


def check(text, prefix):
    if not text.endswith('\n'):
        return 'no final newline'
    types, helps, seen, done, cur = {}, set(), set(), set(), None
    for n, line in enumerate(text.splitlines(), 1):
        where = 'line %d: ' % n
        if line.startswith('#'):
            p = line.split(None, 3)
            if len(p) < 3 or p[1] not in ('HELP', 'TYPE'):
                continue                      # plain comment
            name = p[2]
            if not NAME.match(name) or not name.startswith(prefix):
                return where + 'bad metric name ' + name
            if name in done and name != cur:
                return where + name + ' is not contiguous'
            if cur and cur != name:
                done.add(cur)
            cur = name
            if p[1] == 'HELP':
                if name in helps:
                    return where + 'second HELP for ' + name
                helps.add(name)
            else:
                if name in types:
                    return where + 'second TYPE for ' + name
                if len(p) != 4 or p[3] not in ('counter', 'gauge', 'untyped'):
                    return where + 'bad TYPE ' + line
                types[name] = p[3]
            continue
        if not line.strip():
            return where + 'empty line'
        m = SAMPLE.match(line)
        if not m:
            return where + 'not a sample: ' + line
        name, labels, value = m.group(1), m.group(3), m.group(4)
        if name != cur or name not in types or name not in helps:
            return where + name + ' without HELP and TYPE just before'
        if labels:
            pos, keys = 0, []
            while pos < len(labels):
                lm = LABEL.match(labels, pos)
                if not lm:
                    return where + 'bad labels {' + labels + '}'
                keys.append(lm.group(1))
                pos = lm.end()
            if len(set(keys)) != len(keys):
                return where + 'repeated label'
        series = (name, labels or '')
        if series in seen:
            return where + 'duplicate series ' + line
        seen.add(series)
        try:
            v = float(value)
        except ValueError:
            return where + 'bad value ' + value
        if math.isnan(v) or math.isinf(v):
            return where + 'NaN or infinite value'
        if types[name] == 'counter' and (not name.endswith('_total') or v < 0):
            return where + 'counter not named _total or negative: ' + line
    missing = [t for t in types if not any(s[0] == t for s in seen)]
    if missing:
        return 'TYPE without samples: ' + ', '.join(missing)
    return None


if __name__ == '__main__':
    err = check(open(sys.argv[1]).read(), sys.argv[2] if len(sys.argv) > 2 else 'readynas_')
    if err:
        print(err)
        sys.exit(1)
