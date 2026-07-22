#!/usr/bin/env node
/**
 * Generates src/Spintax.Unicode.inc — the Unicode tables the post-process stage needs.
 *
 * WHY GENERATED, AND WHY FROM NODE:
 *   The reference engine matches \p{Ll}, \p{L} and \p{N} and calls String#toUpperCase().
 *   Neither Free Pascal nor Delphi offers Unicode-property matching, and this project has
 *   zero runtime dependencies, so the data is baked in.
 *
 *   It is generated from NODE on purpose: that is the same Unicode version the reference
 *   itself runs on. Reading the host's tables at runtime would make two machines with
 *   different RTL versions disagree about what a letter is — and the corpus would not
 *   catch it, because both would be internally consistent. The version is stamped into
 *   the output so a future mismatch is visible rather than silent.
 *
 *   Same choice, same reasoning as spintax-py, whose charter pins its baked tables to the
 *   reference's Unicode version rather than the running interpreter's.
 *
 * Run:  node scripts/gen-unicode-tables.cjs > src/Spintax.Unicode.inc
 * The output is committed; regenerate only deliberately, and say so in REGISTRY.
 */

'use strict';

function ranges(test) {
  const out = [];
  let lo = -1, prev = -2;
  for (let cp = 0; cp <= 0x10ffff; cp++) {
    if (test(cp)) {
      if (cp !== prev + 1) {
        if (lo >= 0) out.push([lo, prev]);
        lo = cp;
      }
      prev = cp;
    }
  }
  if (lo >= 0) out.push([lo, prev]);
  return out;
}

const isLl = (cp) => /\p{Ll}/u.test(String.fromCodePoint(cp));
const isL = (cp) => /\p{L}/u.test(String.fromCodePoint(cp));
const isN = (cp) => /\p{N}/u.test(String.fromCodePoint(cp));

// The reference does NOT use one flag set throughout. CAP_AFTER_BLOCK_RE (step 10) is
// 'giu', and under /iu a property escape is case-folded: \p{Ll} then also matches
// titlecase letters and the Greek iota-subscript forms -- 1446 extra code points, 32 of
// which have a differing uppercase. EMAIL/DOMAIN/SINGLE_ABBR are 'giu' too, where \p{L}
// gains exactly one: U+0345. Steps 8, 9 and 11 are 'u'/'gu' and stay strict.
// Two predicates, because the reference has two.
const isLlFold = (cp) => /\p{Ll}/iu.test(String.fromCodePoint(cp));
const isLFold = (cp) => /\p{L}/iu.test(String.fromCodePoint(cp));

// Uppercase, split into the two shapes Pascal needs: arithmetic runs, and the handful of
// code points whose uppercase is more than one character (sharp s -> SS, ligatures, ...).
const upRuns = [];
const upMulti = [];
{
  let run = null;
  for (let cp = 0; cp <= 0x10ffff; cp++) {
    const ch = String.fromCodePoint(cp);
    if (!/\p{Ll}/iu.test(ch)) continue;
    const u = ch.toUpperCase();
    if (u === ch) continue;
    const chars = [...u];
    if (chars.length > 1) {
      upMulti.push([cp, u]);
      run = null;
      continue;
    }
    const delta = u.codePointAt(0) - cp;
    if (run && cp === run[1] + 1 && delta === run[2]) run[1] = cp;
    else {
      run = [cp, cp, delta];
      upRuns.push(run);
    }
  }
}

const hex = (n) => '$' + n.toString(16).toUpperCase().padStart(4, '0');

function emitRanges(name, rs, comment) {
  const lines = [];
  lines.push(`  { ${comment} }`);
  lines.push(`  ${name}_COUNT = ${rs.length};`);
  // Flat (lo, hi) pairs, not a 2-D array: an open-array parameter accepts a flat typed
  // constant, so ONE lookup routine serves every table instead of one copy per table.
  lines.push(`  ${name}: array[0..${name}_COUNT * 2 - 1] of LongWord = (`);
  const body = rs.map(([a, b]) => `${hex(a)}, ${hex(b)}`);
  for (let i = 0; i < body.length; i += 4) {
    const chunk = body.slice(i, i + 4).join(', ');
    lines.push('    ' + chunk + (i + 4 < body.length ? ',' : ''));
  }
  lines.push('  );');
  return lines.join('\n');
}

function emitRuns(name, rs) {
  const lines = [];
  lines.push(`  { uppercase mapping as (lo, hi, delta) runs; delta added to the code point.`);
  lines.push(`    Built over the FOLDED Ll set, which is a superset of the strict one, so a`);
  lines.push(`    single table serves both predicates. }`);
  lines.push(`  ${name}_COUNT = ${rs.length};`);
  lines.push(`  ${name}: array[0..${name}_COUNT * 3 - 1] of LongInt = (`);
  const body = rs.map(([a, b, d]) => `${hex(a)}, ${hex(b)}, ${d}`);
  for (let i = 0; i < body.length; i += 3) {
    const chunk = body.slice(i, i + 3).join(', ');
    lines.push('    ' + chunk + (i + 3 < body.length ? ',' : ''));
  }
  lines.push('  );');
  return lines.join('\n');
}

function emitMulti(cps) {
  const lines = [];
  lines.push('  { The few code points whose uppercase is more than one character. Kept as');
  lines.push('    parallel arrays: a const array of records with string fields is not');
  lines.push('    portable enough between the two compilers to be worth it. The strings are');
  lines.push('    ASCII-safe here, but are emitted as code-point lists so the .inc stays');
  lines.push('    pure ASCII and no source-encoding rule can alter them. }');
  lines.push(`  UPPER_MULTI_COUNT = ${cps.length};`);
  lines.push(`  UPPER_MULTI_CP: array[0..UPPER_MULTI_COUNT - 1] of LongWord = (`);
  const a = cps.map(([cp]) => hex(cp));
  for (let i = 0; i < a.length; i += 8) {
    lines.push('    ' + a.slice(i, i + 8).join(', ') + (i + 8 < a.length ? ',' : ''));
  }
  lines.push('  );');
  const maxLen = Math.max(...cps.map(([, s]) => [...s].length));
  lines.push(`  UPPER_MULTI_MAXLEN = ${maxLen};`);
  lines.push(`  UPPER_MULTI_TO: array[0..UPPER_MULTI_COUNT * UPPER_MULTI_MAXLEN - 1] of LongWord = (`);
  const b = cps.map(([, s]) => {
    const parts = [...s].map((c) => hex(c.codePointAt(0)));
    while (parts.length < maxLen) parts.push('0');
    return parts.join(', ');
  });
  for (let i = 0; i < b.length; i += 3) {
    lines.push('    ' + b.slice(i, i + 3).join(', ') + (i + 3 < b.length ? ',' : ''));
  }
  lines.push('  );');
  return lines.join('\n');
}

// The single-token abbreviation list, taken verbatim from the reference and emitted as
// code points so the .inc stays pure ASCII: several entries are Cyrillic, and a compiler's
// source-encoding rule must not get a vote on their bytes. Lower-cased because the
// reference matches them case-insensitively.
const SINGLE_ABBREVS = [
  'соц','эл','см','ср','ст','ул','пр','пер','г','р','руб','коп',
  'тыс','млн','млрд','трлн','доп','напр','прим','изд','обл','респ',
  'стр','табл','рис','мин','макс','тел','факс',
  'etc','vs','mr','mrs','ms','dr','prof','sr','jr','inc','ltd','co',
  'corp','no','st','ave','blvd',
];

function emitAbbrevs(list) {
  const lines = [];
  lines.push('  { Single-token abbreviations, lower-cased, as code points. Flat, with each entry');
  lines.push('    preceded by its length, so one loop rebuilds them in either string width. }');
  lines.push(`  ABBREV_COUNT = ${list.length};`);
  const flat = [];
  for (const a of list) {
    const cps = [...a].map((c) => c.codePointAt(0));
    flat.push(cps.length, ...cps);
  }
  lines.push(`  ABBREV_DATA: array[0..${flat.length - 1}] of LongWord = (`);
  const body = flat.map(hex);
  for (let i = 0; i < body.length; i += 10) {
    lines.push('    ' + body.slice(i, i + 10).join(', ') + (i + 10 < body.length ? ',' : ''));
  }
  lines.push('  );');
  return lines.join(String.fromCharCode(10));
}

const ll = ranges(isLl);
const l = ranges(isL);
const n = ranges(isN);
const llFold = ranges(isLlFold);
const lFold = ranges(isLFold);

const out = [];
out.push('{ GENERATED FILE -- DO NOT EDIT BY HAND.');
out.push('');
out.push('  Produced by scripts/gen-unicode-tables.cjs from Node, i.e. from the same Unicode');
out.push('  version the reference engine runs on. Reading the host RTL instead would let two');
out.push('  machines disagree about what a letter is, consistently enough that the corpus');
out.push('  would never notice.');
out.push('');
out.push(`  Unicode version: ${process.versions.unicode}   (Node ${process.versions.node})`);
out.push('  Regenerate deliberately, and record it in .agents/REGISTRY.md. }');
out.push('');
out.push('const');
out.push(`  UNICODE_TABLE_VERSION = '${process.versions.unicode}';`);
out.push('');
out.push(emitRanges('LL_RANGES', ll, 'Unicode Ll: lowercase letters'));
out.push('');
out.push(emitRanges('L_RANGES', l, 'Unicode L: all letters'));
out.push('');
out.push(emitRanges('N_RANGES', n, 'Unicode N: all numbers (identical under /iu)'));
out.push('');
out.push(emitRanges('LL_FOLD_RANGES', llFold,
  'Unicode Ll under case folding (/iu) -- used by the block-tag capitalization step ONLY'));
out.push('');
out.push(emitRanges('L_FOLD_RANGES', lFold,
  'Unicode L under case folding (/iu) -- email / domain / single-abbrev rules'));
out.push('');
out.push(emitRuns('UPPER_RUNS', upRuns));
out.push('');
out.push(emitMulti(upMulti));
out.push('');
out.push(emitAbbrevs(SINGLE_ABBREVS));
out.push('');

process.stdout.write(out.join('\n'));
