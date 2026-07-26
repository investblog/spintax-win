(*
 * Spintax — Object Pascal (Delphi-mode) port of the reference @spintax/core.
 *
 * Ported from the reference TypeScript engine (github.com/investblog/spintax-js,
 * packages/core), held to the SAME golden-fixture corpus, which it passes in full:
 * PASS=168 FAIL=0 SKIP=4 on FPC 3.2.2. Scope: parse + render
 * (enumeration / permutation / variable / conditional / plural), hash-set / hash-def
 * directives, neutralize / safety-restore, extract, validate, and the complete cosmetic
 * post-process -- URL / mailto / email / domain / decimal / abbreviation shielding,
 * spacing, Spanish sentence openers, and Unicode-aware capitalization.
 *
 * STRING WIDTH: `string` is UTF-8 BYTES here, and UTF-16 code units on a compiler that
 * defines UNICODE. That portability is kept but not maintained -- see the spec, sec.2 --
 * and the branches must not be deleted to "simplify": a second compiler is what exposed
 * two defects that were present in the byte-string build as well.
 * The structural scan branches only on ASCII, which is safe either way. Everything that
 * reasons about CHARACTERS -- the post-process, the sentinels, the fullwidth braces --
 * goes through SpCodePointAt / SpCodePointToStr and the baked tables in
 * Spintax.Unicode.inc, so no index arithmetic assumes a width. Adding code that indexes
 * text directly is how this port has broken before.
 *
 * HOST DUTY under FPC: declare `DefaultSystemCodePage := CP_UTF8` at start-up, or
 * non-ASCII text is mangled before the engine ever sees it. A library cannot set it for
 * its callers.
 *)
unit Spintax;

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
  SysUtils, Classes, Generics.Collections;

type
  { RNG seam — signature (min,max)=>int inclusive, mirrors the reference `Rng`.
    Subclasses provide the corpus strategies + a seeded PRNG. }
  TSpRng = class
  public
    function Next(min, max: Integer): Integer; virtual; abstract;
  end;

  TFirstRng = class(TSpRng)
  public
    function Next(min, max: Integer): Integer; override; // always min
  end;

  TLastRng = class(TSpRng)
  public
    function Next(min, max: Integer): Integer; override; // always max
  end;

  { sequence: raw returns clamped to [min,max]; last value reused after exhaustion. }
  TSequenceRng = class(TSpRng)
  private
    FSeq: array of Integer;
    FPos: Integer;
  public
    constructor Create(const ASeq: array of Integer);
    function Next(min, max: Integer): Integer; override;
  end;

  { mulberry32 seeded PRNG (for kind:rng within-engine reproducibility). }
  TMulberry32Rng = class(TSpRng)
  private
    FState: LongWord;
    function NextUnit: Double;
  public
    constructor Create(ASeed: LongWord);
    function Next(min, max: Integer): Integer; override;
  end;

  TStrMap = TDictionary<string, string>;

  { The #include seam, shaped like TSpRng: an abstract class the HOST subclasses, caller-
    owned, never freed here. The engine owns the SEMANTICS of an include (child render,
    scope, cycles, depth); the host owns the LOOKUP -- files, a database, a map in memory.

    Resolve returns False for "no such template", which is the reference's `null`: an
    unknown target resolves to an empty string, never to an error. An exception raised out
    of Resolve is the host's own bug and propagates unchanged; the engine itself never
    throws over a template. }
  TSpIncludeResolver = class
  public
    function Resolve(const Ref: string; out Text: string): Boolean; virtual; abstract;
  end;

  TSpContext = record
    Vars: TStrMap;       // runtime context, keys lower-cased (caller owns)
    Locale: string;
    PostProcess: Boolean;
    Rng: TSpRng;         // caller owns
    { nil -- the default -- leaves every #include line in the output verbatim, which is
      also what the reference does when no resolver is supplied. Set it and the engine
      resolves includes the way the family does: see SP_DEFAULT_INCLUDE_DEPTH. }
    IncludeResolver: TSpIncludeResolver;   // caller owns
    { How deep #include may nest before a further one resolves to ''. Counts the include
      stack ONLY -- parse nesting and variable expansion have their own limits.

      0 = the family's default, SP_DEFAULT_INCLUDE_DEPTH, and so is any negative value: a
      zeroed record field cannot be told from a deliberate 0, so this field cannot carry the
      reference's "0 means resolve nothing". To resolve nothing, leave IncludeResolver nil. }
    MaxIncludeDepth: Integer;
  end;

  TExtractResult = record
    Refs, Sets, Defs, Includes: TStringList;
  end;

  { One directive OCCURRENCE, as the renderer sees it. SpExtract answers "which names and
    targets appear" -- deduplicated, unordered, no values, no positions -- which is all a
    validator needs and not enough for an editor: a host that wants to SUBSTITUTE an
    #include, show a macro's value, or render a fragment with the document's #set/#def in
    scope has to know WHERE each directive is and WHAT it says. Rebuilding that host-side
    means a second copy of this unit's comment strip and line model, and the first thing it
    gets wrong is the deduplication: the same target commented out AND live is one entry in
    SpExtract, so a host substituting by name expands the commented copy too -- and comments
    do not nest, so an included fragment carrying `#/` escapes the comment it landed in.

      Kind   'set' | 'def' | 'include'.
      Name   macro name, lower-cased (as directives are keyed), or the include target
             verbatim -- a slug is a host identifier, compared EXACTLY here and against
             KnownIncludes, where every variable name this unit reports is case-folded.
      Value  the right-hand side for set/def, trimmed as the renderer trims it; '' for
             include.
      Text   the directive's line WITHOUT its terminator and with comments already removed
             -- the exact text the renderer consumed, so a host can re-emit it rather than
             re-spell the grammar.
      Line/Column/EndLine/EndColumn  the line's span in the ORIGINAL source, same contract
             as TSpDiag: 1-based, code-point columns, editor EOL, End* exclusive. A comment
             at the HEAD or TAIL of the line shrinks the span to the part that survived it,
             so replacing the span leaves that comment where it was. One INSIDE the
             directive is part of what the renderer consumed, so the span covers it -- and
             if it swallowed the line's terminator the span crosses into the next source
             line. Replacing THAT span removes the comment with it.

    Occurrences come in source order, duplicates kept. A directive inside /# ... #/ is not
    reported, an inline #include is not a directive, and neither is an #include inside a
    #def value (which validate flags as def.include-in-value) -- all three exactly as the
    renderer treats them.

    Two limits on "as the renderer sees it", both shared with SpExtract and SpValidate:

    - #include is never RESOLVED here. The renderer emits the line verbatim and the host
      substitutes it, so for that kind the contract is "the line SpExtract and SpValidate
      call an include", which is the same scan run here.
    - the scan reads the source AS WRITTEN, while SpRender deletes reserved sentinels
      (U+E000..U+E005) before stripping comments. A raw one inside directive syntax
      therefore makes the two disagree in both directions: `#se<U+E000>t %x% = A` is no
      directive here and a #set to the renderer; `/<U+E000>#` opens no comment here and one
      to the renderer, hiding a #set this list still reports. Measured on @spintax/core:
      its extract and validate diverge from its render in exactly the same two ways, so
      this is the family's contract for reserved characters in author markup, not a gap in
      this port -- and a host is better served by three functions that agree with each
      other than by one that agrees with the renderer. Sentinels enter a template through
      SpNeutralize; author markup has no business carrying them. }
  TSpDirective = record
    Kind: string;
    Name: string;
    Value: string;
    Text: string;
    Line: Integer;
    Column: Integer;
    EndLine: Integer;
    EndColumn: Integer;
  end;
  TSpDirectiveList = TList<TSpDirective>;

  { A single validator finding. Severity is 'error' or 'warning'; a template is "invalid"
    iff any diagnostic is 'error'. Code + Severity are the parity contract (the golden
    corpus gates only those). Line/Column/EndLine/EndColumn are BEST-EFFORT source
    positions for editors, NOT parity-gated and never identical across engines:
      - all 1-based; 0 means "position unknown", which is a valid, common answer;
      - Column/EndColumn count CODE POINTS from the line start, so the value is the
        same under FPC (UTF-8) and a UTF-16 compiler and points at a character, not a
        byte -- the corpus is full of Cyrillic where a byte column would be wrong;
      - Line uses editor end-of-line semantics (\n, \r\n, \r each one line), which is
        deliberately not the engine's /gmu render-time line model;
      - End* give a span when one is cheap to compute, else 0. }
  TSpDiag = record
    Code: string;
    Severity: string;
    Line: Integer;
    Column: Integer;
    EndLine: Integer;
    EndColumn: Integer;
  end;
  TSpDiagList = TList<TSpDiag>;

const
  { The family's DEFAULT_MAX_DEPTH: how many #include levels may nest before a further one
    resolves to ''. Exceeding it is lenient, never an error -- the reference deliberately
    has no MaxDepthExceededError, and validate deliberately does not call a circular
    include invalid: it is a render-time guard, not a verdict. }
  SP_DEFAULT_INCLUDE_DEPTH = 20;

{ Public API }
function SpRender(const Template: string; const Ctx: TSpContext): string;
function SpNeutralize(const Value: string): string;
function SpSafetyRestore(const Text: string): string;
function SpStripSentinels(const Text: string): string;
function SpExtract(const Src: string): TExtractResult;
{ Every #set / #def / #include occurrence with its source span, value and text -- the
  editor-side companion to SpExtract, see TSpDirective. Caller frees the list. }
function SpExtractDirectives(const Src: string): TSpDirectiveList;
function SpValidate(const Src, Locale: string; KnownIncludes: TStringList): TSpDiagList; overload;
{ KnownVariables: names the HOST will supply at render time. A reference to one of them is
  not "undefined", so the `variable.undefined` warning is suppressed for it — the same role
  KnownIncludes plays for `#include` targets, and the same thing the reference's
  ValidateOptions.knownVariables does. Pass nil to declare none.

  It only ever silences a WARNING: an unresolved %var% never made a template invalid, and
  must not start to. }
function SpValidate(const Src, Locale: string;
  KnownIncludes, KnownVariables: TStringList): TSpDiagList; overload;

{ Unicode helpers. Public because this port has to do Unicode work that neither compiler's
  RTL offers portably, because a team porting the engine needs the same primitives, and
  because the tests gate them directly rather than through the behaviour built on top.
  Tables are baked from the reference's Unicode version -- see SpUnicodeTableVersion. }
function SpCodePointAt(const s: string; i: Integer; out cpLen: Integer): LongWord;
function SpCodePointToStr(cp: LongWord): string;
function SpIsUniLower(cp: LongWord): Boolean;
function SpIsUniLetter(cp: LongWord): Boolean;
function SpIsUniLowerFolded(cp: LongWord): Boolean;
function SpIsUniLetterFolded(cp: LongWord): Boolean;
function SpIsUniNumber(cp: LongWord): Boolean;
function SpUpperCodePoint(cp: LongWord): string;
function SpUnicodeTableVersion: string;

{ Locale helpers }
function NormalizeBaseLang(const Locale: string): string;
function PluralArity(const BaseLang: string): Integer;

implementation

uses
  StrUtils;

const
  MAX_VARIABLE_DEPTH = 50;
  PHP_WS = [' ', #9, #10, #13, #0, #11];

{ Unicode tables for the post-process stage, generated from the reference's own Unicode
  version. See scripts/gen-unicode-tables.cjs for why they are baked rather than read
  from the host RTL. }
{$I Spintax.Unicode.inc}

{ ─── code points ─────────────────────────────────────────────────────────────
  `string` is UTF-8 bytes under FPC and UTF-16 code units under Delphi, so anything that
  reasons about CHARACTERS rather than bytes has to go through here. Every earlier bug in
  this port that involved non-ASCII text came from code that skipped this step. }

{ The code point starting at s[i]; CpLen is its size in code units. Malformed input yields
  the raw unit with CpLen = 1, so a scan always advances and never loops. }
function SpCodePointAt(const s: string; i: Integer; out cpLen: Integer): LongWord;
{$IFNDEF UNICODE}
var b0, b1, b2, b3: LongWord; n: Integer;
{$ENDIF}
begin
  cpLen := 1;
  Result := 0;
  if (i < 1) or (i > Length(s)) then Exit;
  {$IFDEF UNICODE}
  Result := Ord(s[i]);
  { A surrogate pair is one code point in two units. }
  if (Result >= $D800) and (Result <= $DBFF) and (i < Length(s))
     and (LongWord(Ord(s[i + 1])) >= $DC00) and (LongWord(Ord(s[i + 1])) <= $DFFF) then
  begin
    { Every operand stays LongWord: Ord() is signed, and mixing widths here made Delphi
      warn (W1024) about combining signed and unsigned types. }
    Result := LongWord($10000) + ((Result - LongWord($D800)) shl 10)
              + (LongWord(Ord(s[i + 1])) - LongWord($DC00));
    cpLen := 2;
  end;
  {$ELSE}
  b0 := Ord(s[i]);
  if b0 < $80 then begin Result := b0; Exit; end;
  if      (b0 and $E0) = $C0 then n := 2
  else if (b0 and $F0) = $E0 then n := 3
  else if (b0 and $F8) = $F0 then n := 4
  else begin Result := b0; Exit; end;      { stray continuation byte }
  if i + n - 1 > Length(s) then begin Result := b0; Exit; end;
  b1 := Ord(s[i + 1]);
  if (b1 and $C0) <> $80 then begin Result := b0; Exit; end;
  case n of
    2: Result := ((b0 and $1F) shl 6) or (b1 and $3F);
    3: begin
         b2 := Ord(s[i + 2]);
         if (b2 and $C0) <> $80 then begin Result := b0; Exit; end;
         Result := ((b0 and $0F) shl 12) or ((b1 and $3F) shl 6) or (b2 and $3F);
       end;
  else
    begin
      b2 := Ord(s[i + 2]); b3 := Ord(s[i + 3]);
      if ((b2 and $C0) <> $80) or ((b3 and $C0) <> $80) then begin Result := b0; Exit; end;
      Result := ((b0 and $07) shl 18) or ((b1 and $3F) shl 12)
                or ((b2 and $3F) shl 6) or (b3 and $3F);
    end;
  end;
  { Reject OVERLONG encodings and anything above the Unicode maximum. Without this,
    #$C0#$80 decodes to U+0000 -- and U+0000 is the reference's placeholder delimiter, so
    a shielding scan could be fooled by two arbitrary bytes. Lead bytes F5..F7 likewise
    decode past U+10FFFF, which the UTF-16 encoder cannot represent. }
  if ((n = 2) and (Result < $80)) or ((n = 3) and (Result < $800))
     or ((n = 4) and ((Result < $10000) or (Result > $10FFFF))) then
  begin
    Result := b0;
    cpLen := 1;
    Exit;
  end;
  cpLen := n;
  {$ENDIF}
end;

{ A code point in this compiler's string encoding. }
function SpCodePointToStr(cp: LongWord): string;
begin
  { Above the Unicode maximum there is no encoding. Returning '' beats the UTF-16 branch
    silently emitting two LOW surrogates, which is what the arithmetic would do. }
  if cp > $10FFFF then Exit('');
  {$IFDEF UNICODE}
  if cp < $10000 then
    Result := Chr(cp)
  else
  begin
    cp := cp - $10000;
    Result := Chr($D800 + (cp shr 10)) + Chr($DC00 + (cp and $3FF));
  end;
  {$ELSE}
  if cp < $80 then
    Result := Chr(cp)
  else if cp < $800 then
    Result := Chr($C0 or (cp shr 6)) + Chr($80 or (cp and $3F))
  else if cp < $10000 then
    Result := Chr($E0 or (cp shr 12)) + Chr($80 or ((cp shr 6) and $3F))
              + Chr($80 or (cp and $3F))
  else
    Result := Chr($F0 or (cp shr 18)) + Chr($80 or ((cp shr 12) and $3F))
              + Chr($80 or ((cp shr 6) and $3F)) + Chr($80 or (cp and $3F));
  {$ENDIF}
end;

{ Binary search over a flat (lo, hi) range table. One routine for every table -- the
  generator emits flat arrays so an open-array parameter can take any of them. }
function InRangeTable(cp: LongWord; const tbl: array of LongWord): Boolean;
var lo, hi, mid: Integer;
begin
  Result := False;
  lo := 0;
  hi := (Length(tbl) div 2) - 1;
  while lo <= hi do
  begin
    mid := (lo + hi) div 2;
    if cp < tbl[mid * 2] then hi := mid - 1
    else if cp > tbl[mid * 2 + 1] then lo := mid + 1
    else Exit(True);
  end;
end;

function SpUnicodeTableVersion: string;
begin
  Result := UNICODE_TABLE_VERSION;
end;

function SpIsUniLower(cp: LongWord): Boolean;
begin
  Result := InRangeTable(cp, LL_RANGES);
end;

function SpIsUniLetter(cp: LongWord): Boolean;
begin
  Result := InRangeTable(cp, L_RANGES);
end;

{ The reference does not use one flag set throughout: CAP_AFTER_BLOCK_RE is /giu/ and the
  email / domain / single-abbreviation rules are /giu/ too, where a property escape is
  CASE-FOLDED. Under /iu, Ll also matches titlecase letters and the Greek iota-subscript
  forms -- 1446 extra code points, 32 with a differing uppercase -- and L gains U+0345.
  Steps 8, 9 and 11 are /u/ or /gu/ and must stay strict. Two predicates, because the
  reference has two; using the strict one for the block-tag step would leave a
  titlecase letter after a block tag uncapitalised where the reference capitalises it. }
function SpIsUniLowerFolded(cp: LongWord): Boolean;
begin
  Result := InRangeTable(cp, LL_FOLD_RANGES);
end;

function SpIsUniLetterFolded(cp: LongWord): Boolean;
begin
  Result := InRangeTable(cp, L_FOLD_RANGES);
end;

function SpIsUniNumber(cp: LongWord): Boolean;
begin
  Result := InRangeTable(cp, N_RANGES);
end;

{ Uppercase of one code point, as a STRING: a few expand to more than one character
  (sharp s -> SS), and the reference's toUpperCase() expands them too. }
function SpUpperCodePoint(cp: LongWord): string;
var lo, hi, mid, i: Integer;
begin
  { multi-character expansions first -- they are excluded from the runs }
  lo := 0; hi := UPPER_MULTI_COUNT - 1;
  while lo <= hi do
  begin
    mid := (lo + hi) div 2;
    if cp < UPPER_MULTI_CP[mid] then hi := mid - 1
    else if cp > UPPER_MULTI_CP[mid] then lo := mid + 1
    else
    begin
      Result := '';
      for i := 0 to UPPER_MULTI_MAXLEN - 1 do
        if UPPER_MULTI_TO[mid * UPPER_MULTI_MAXLEN + i] <> 0 then
          Result := Result + SpCodePointToStr(UPPER_MULTI_TO[mid * UPPER_MULTI_MAXLEN + i]);
      Exit;
    end;
  end;
  lo := 0; hi := UPPER_RUNS_COUNT - 1;
  while lo <= hi do
  begin
    mid := (lo + hi) div 2;
    if LongInt(cp) < UPPER_RUNS[mid * 3] then hi := mid - 1
    else if LongInt(cp) > UPPER_RUNS[mid * 3 + 1] then lo := mid + 1
    else Exit(SpCodePointToStr(LongWord(LongInt(cp) + UPPER_RUNS[mid * 3 + 2])));
  end;
  Result := SpCodePointToStr(cp);
end;

{ ─── RNG ─────────────────────────────────────────────────────────────────── }

function TFirstRng.Next(min, max: Integer): Integer;
begin
  Result := min;
end;

function TLastRng.Next(min, max: Integer): Integer;
begin
  Result := max;
end;

constructor TSequenceRng.Create(const ASeq: array of Integer);
var i: Integer;
begin
  inherited Create;
  SetLength(FSeq, Length(ASeq));
  for i := 0 to High(ASeq) do FSeq[i] := ASeq[i];
  FPos := 0;
end;

function TSequenceRng.Next(min, max: Integer): Integer;
var raw: Integer;
begin
  if Length(FSeq) = 0 then Exit(min);
  if FPos < Length(FSeq) then
  begin
    raw := FSeq[FPos];
    Inc(FPos);
  end
  else
    raw := FSeq[High(FSeq)]; // exhausted => reuse last
  if raw < min then raw := min;
  if raw > max then raw := max;
  Result := raw;
end;

constructor TMulberry32Rng.Create(ASeed: LongWord);
begin
  inherited Create;
  FState := ASeed;
end;

{ mulberry32 is 32-bit wraparound arithmetic by definition: the additions and
  multiplications below are MEANT to overflow. Delphi's Debug configuration enables
  overflow and range checks, which turned every one of them into EIntOverflow — the
  corpus never caught it because kind:rng cases are skipped, and it only became
  reachable once a nil Ctx.Rng started defaulting to this generator.

  Checks are disabled only around this arithmetic and restored to whatever the build
  had, via $IFOPT, so a host compiling with checks on keeps them everywhere else. }
{$IFOPT Q+}{$DEFINE SPX_Q_WAS_ON}{$Q-}{$ENDIF}
{$IFOPT R+}{$DEFINE SPX_R_WAS_ON}{$R-}{$ENDIF}

function TMulberry32Rng.NextUnit: Double;
var a, t: LongWord;
begin
  FState := FState + LongWord($6D2B79F5);
  a := FState;
  t := a xor (a shr 15);
  t := LongWord(t * (1 or a));
  t := LongWord(t + LongWord((t xor (t shr 7)) * (61 or t))) xor t;
  Result := ((t xor (t shr 14)) and $FFFFFFFF) / 4294967296.0;
end;

function TMulberry32Rng.Next(min, max: Integer): Integer;
begin
  Result := min + Trunc(NextUnit * (max - min + 1));
end;

{$IFDEF SPX_R_WAS_ON}{$R+}{$UNDEF SPX_R_WAS_ON}{$ENDIF}
{$IFDEF SPX_Q_WAS_ON}{$Q+}{$UNDEF SPX_Q_WAS_ON}{$ENDIF}

{ ─── small helpers ───────────────────────────────────────────────────────── }

function PhpTrimLR(const s: string; left, right: Boolean): string;
var a, b: Integer;
begin
  a := 1; b := Length(s);
  if left then
    while (a <= b) and CharInSet(s[a], PHP_WS) do Inc(a);
  if right then
    while (b >= a) and CharInSet(s[b], PHP_WS) do Dec(b);
  Result := Copy(s, a, b - a + 1);
end;

function PhpTrim(const s: string): string;  begin Result := PhpTrimLR(s, True, True); end;
function PhpLtrim(const s: string): string; begin Result := PhpTrimLR(s, True, False); end;
function PhpRtrim(const s: string): string; begin Result := PhpTrimLR(s, False, True); end;

{ Named ASCII predicates.

  Every character class in this engine is ASCII by design — it does no Unicode
  classification, and the text flowing through is arbitrary UTF-8. `CharInSet` states
  that safely on both compilers: it is defined for values above the set's range, and it
  is what Delphi asks for instead of a bare `c in [...]` (W1050, 30 of them before this).

  Measured, so the reader need not wonder: `CharInSet(Chr($D1), [...])` is False under
  FPC, and `Char($0441) in ['A'..'Z']` is False under Delphi 13 — neither compiler was
  truncating. The change is for clarity and a clean build, not a bug fix. The one real
  encoding defect this project hit was elsewhere entirely: a lossy codepage conversion at
  the host boundary. See tests/delphi/RESULTS.md. }
function IsAsciiSentencePunct(c: Char): Boolean;
begin
  Result := CharInSet(c, [',', ';', ':', '!', '?', '.']);
end;

function IsAsciiLower(c: Char): Boolean;
begin
  Result := CharInSet(c, ['a'..'z']);
end;

function IsAsciiWord(c: Char): Boolean;
begin
  Result := CharInSet(c, ['A'..'Z', 'a'..'z', '0'..'9', '_']);
end;

function LowerAscii(const s: string): string;
var i: Integer;
begin
  Result := s;
  for i := 1 to Length(Result) do
    if CharInSet(Result[i], ['A'..'Z']) then
      Result[i] := Chr(Ord(Result[i]) + 32);
end;

{ Index (1-based) of the close matching the open at OpenPos; 0 if unmatched. }
function FindMatchingClose(const text: string; openPos: Integer; open, close: Char): Integer;
var depth, i: Integer;
begin
  depth := 0;
  for i := openPos to Length(text) do
  begin
    if text[i] = open then Inc(depth)
    else if text[i] = close then
    begin
      Dec(depth);
      if depth = 0 then Exit(i);
    end;
  end;
  Result := 0;
end;

{ Split on top-level '|': brace and bracket depths tracked independently and
  decremented unconditionally (may go negative); split only when BOTH are 0. }
procedure SplitTopLevel(const inner: string; out parts: TStringList);
var brace, bracket, i: Integer; cur: string; ch: Char;
begin
  parts := TStringList.Create;
  brace := 0; bracket := 0; cur := '';
  for i := 1 to Length(inner) do
  begin
    ch := inner[i];
    if ch = '{' then Inc(brace)
    else if ch = '}' then Dec(brace)
    else if ch = '[' then Inc(bracket)
    else if ch = ']' then Dec(bracket);
    if (ch = '|') and (brace = 0) and (bracket = 0) then
    begin
      parts.Add(cur);
      cur := '';
    end
    else
      cur := cur + ch;
  end;
  parts.Add(cur);
end;

{ First top-level '|' in a conditional body (single counter clamped at 0); 0 if none. }
function FirstTopLevelPipe(const body: string): Integer;
var depth, j: Integer; ch: Char;
begin
  depth := 0;
  for j := 1 to Length(body) do
  begin
    ch := body[j];
    if (ch = '{') or (ch = '[') then Inc(depth)
    else if (ch = '}') or (ch = ']') then
    begin
      if depth > 0 then Dec(depth);
    end
    else if (ch = '|') and (depth = 0) then Exit(j);
  end;
  Result := 0;
end;

{ ─── neutralize / sentinels (U+E000..U+E005 = EE 80 80 .. EE 80 85) ─────────── }

const
  STRUCTURAL: array[0..5] of Char = ('{', '}', '[', ']', '%', '#');

{ Sentinels live at U+E000..U+E005. How a code point is spelled in `string`
  depends on the compiler, and it MUST match the reference's spelling, because a
  neutralized value crosses process boundaries: the host, or a sibling engine,
  hands us one and SpSafetyRestore has to recognise it.

  FPC (byte string): the 3-byte UTF-8 encoding.
  Delphi (UTF-16):   one code unit. Writing the UTF-8 bytes here does NOT produce
                     U+E000 — measured, it produced U+043E U+0402, i.e. the bytes
                     decoded through the machine's ANSI codepage, so the result
                     was not even stable across machines. See tests/delphi/RESULTS.md. }
function Sentinel(i: Integer): string; // U+E000+i in this compiler's string encoding
begin
  {$IFDEF UNICODE}
  Result := Chr($E000 + i);
  {$ELSE}
  Result := #$EE#$80 + Chr($80 + i);
  {$ENDIF}
end;

{ True when a sentinel begins at s[i]. k = which structural char it stands for,
  adv = how many code units it occupies. Shared so the two readers below cannot
  drift apart from the writer above. }
function SentinelAt(const s: string; i: Integer; out k, adv: Integer): Boolean;
begin
  Result := False; k := 0; adv := 1;
  {$IFDEF UNICODE}
  if (i <= Length(s)) and (Ord(s[i]) >= $E000) and (Ord(s[i]) <= $E005) then
  begin
    k := Ord(s[i]) - $E000; adv := 1; Result := True;
  end;
  {$ELSE}
  if (i + 2 <= Length(s)) and (s[i] = #$EE) and (s[i+1] = #$80)
     and (Ord(s[i+2]) >= $80) and (Ord(s[i+2]) <= $85) then
  begin
    k := Ord(s[i+2]) - $80; adv := 3; Result := True;
  end;
  {$ENDIF}
end;

function SpNeutralize(const Value: string): string;
var i, k: Integer; ch: Char; found: Boolean;
begin
  Result := '';
  for i := 1 to Length(Value) do
  begin
    ch := Value[i];
    found := False;
    for k := 0 to High(STRUCTURAL) do
      if ch = STRUCTURAL[k] then
      begin
        Result := Result + Sentinel(k);
        found := True;
        Break;
      end;
    if not found then Result := Result + ch;
  end;
end;

function SpSafetyRestore(const Text: string): string;
var i, k, adv: Integer;
begin
  Result := '';
  i := 1;
  while i <= Length(Text) do
  begin
    if SentinelAt(Text, i, k, adv) then
    begin
      Result := Result + STRUCTURAL[k];
      Inc(i, adv);
    end
    else
    begin
      Result := Result + Text[i];
      Inc(i);
    end;
  end;
end;

function SpStripSentinels(const Text: string): string;
var i, k, adv: Integer;
begin
  Result := '';
  i := 1;
  while i <= Length(Text) do
  begin
    if SentinelAt(Text, i, k, adv) then
      Inc(i, adv)
    else
    begin
      Result := Result + Text[i];
      Inc(i);
    end;
  end;
end;

{ ─── plurals ─────────────────────────────────────────────────────────────── }

function NormalizeBaseLang(const Locale: string): string;
var s: string; i: Integer;
begin
  s := LowerAscii(Locale);
  Result := '';
  for i := 1 to Length(s) do
  begin
    if (s[i] = '-') or (s[i] = '_') then Break;
    Result := Result + s[i];
  end;
end;

function PluralArity(const BaseLang: string): Integer;
begin
  if (BaseLang = 'ru') or (BaseLang = 'uk') or (BaseLang = 'be')
     or (BaseLang = 'sr') or (BaseLang = 'hr') or (BaseLang = 'bs') then
    Result := 3
  else
    Result := 2;
end;

function PluralFor(const BaseLang: string; n: Integer; forms: TStringList): string;
var a, mod10, mod100: Integer;
begin
  a := Abs(n);
  mod10 := a mod 10;
  mod100 := a mod 100;
  if PluralArity(BaseLang) = 3 then
  begin
    if (mod10 = 1) and (mod100 <> 11) then Exit(forms[0]);
    if (mod10 >= 2) and (mod10 <= 4) and ((mod100 < 12) or (mod100 > 14)) then Exit(forms[1]);
    Exit(forms[2]);
  end
  else
  begin
    if a = 1 then Exit(forms[0]) else Exit(forms[1]);
  end;
end;

{ ─── comments / directives ───────────────────────────────────────────────── }

{ Remove /# ... #/ block comments (non-greedy, spans newlines). The overload also records,
  for each surviving character, its 1-based offset in the ORIGINAL text, so a diagnostic
  found in the stripped text can be reported at true source coordinates -- comments remove
  characters AND the newlines inside them, so without this map every position after a
  comment is wrong (spintax-js#... editor coordinates). Detection is byte-identical either
  way: the returned string is the same, only a parallel map is filled. Pass map = nil to skip. }
function StripComments(const text: string; map: TList<Integer>): string; overload;
var i, n: Integer;
begin
  Result := '';
  i := 1; n := Length(text);
  while i <= n do
  begin
    if (i + 1 <= n) and (text[i] = '/') and (text[i+1] = '#') then
    begin
      // find closing #/
      Inc(i, 2);
      while (i + 1 <= n) and not ((text[i] = '#') and (text[i+1] = '/')) do Inc(i);
      if (i + 1 <= n) then Inc(i, 2) else i := n + 1;
    end
    else
    begin
      if map <> nil then map.Add(i);
      Result := Result + text[i];
      Inc(i);
    end;
  end;
end;

function StripComments(const text: string): string; overload;
begin
  Result := StripComments(text, nil);
end;

function CollapseNewlines3(const s: string): string;
var i, run: Integer;
begin
  // \n{3,} -> \n\n
  Result := ''; i := 1;
  while i <= Length(s) do
  begin
    if s[i] = #10 then
    begin
      run := 0;
      while (i <= Length(s)) and (s[i] = #10) do begin Inc(run); Inc(i); end;
      if run >= 3 then run := 2;
      Result := Result + StringOfChar(#10, run);
    end
    else
    begin
      Result := Result + s[i];
      Inc(i);
    end;
  end;
end;

{ Parse a single directive line body after leading [ \t] already consumed at LStart.
  Matches ^[ \t]*#(set|def)[ \t]+%(\w+)%[ \t]*=[ \t]*(.*?)[ \t]*\r?$ }
function TryParseDirective(const line: string; out kind, name, value: string): Boolean;
var p, L: Integer; nm: string;
begin
  Result := False;
  L := Length(line);
  p := 1;
  while (p <= L) and ((line[p] = ' ') or (line[p] = #9)) do Inc(p);
  if (p + 3 <= L) and (Copy(line, p, 4) = '#set') then begin kind := 'set'; Inc(p, 4); end
  else if (p + 3 <= L) and (Copy(line, p, 4) = '#def') then begin kind := 'def'; Inc(p, 4); end
  else Exit;
  if (p > L) or not ((line[p] = ' ') or (line[p] = #9)) then Exit;
  while (p <= L) and ((line[p] = ' ') or (line[p] = #9)) do Inc(p);
  if (p > L) or (line[p] <> '%') then Exit;
  Inc(p);
  nm := '';
  while (p <= L) and IsAsciiWord(line[p]) do begin nm := nm + line[p]; Inc(p); end;
  if nm = '' then Exit;
  if (p > L) or (line[p] <> '%') then Exit;
  Inc(p);
  while (p <= L) and ((line[p] = ' ') or (line[p] = #9)) do Inc(p);
  if (p > L) or (line[p] <> '=') then Exit;
  Inc(p);
  while (p <= L) and ((line[p] = ' ') or (line[p] = #9)) do Inc(p);
  value := Copy(line, p, L - p + 1);
  { The reference's tail is `(.*?)[ \t]*\r?$`: from the end, at most ONE CR, then spaces and
    tabs -- and nothing else. PhpRtrim used to do this, and it also strips \n, \0 and \x0B,
    which are part of the value there: `#set %x% = A` + NUL rendered "A\0" in the reference
    and "A" here. Measured. The CR half is unreachable through the scans in this unit (a
    terminator never survives into `line`), but it is what the rule says, and a caller that
    hands over a raw line should get the rule. }
  if (Length(value) > 0) and (value[Length(value)] = #13) then
    SetLength(value, Length(value) - 1);
  while (Length(value) > 0)
        and ((value[Length(value)] = ' ') or (value[Length(value)] = #9)) do
    SetLength(value, Length(value) - 1);
  name := LowerAscii(nm);
  Result := True;
end;

{ Extract global #set/#def, strip their lines, collapse blank runs. }
{ ─── line terminators ────────────────────────────────────────────────────────
  The reference scans directives with /^…$/gmu, and JavaScript's multiline anchors
  break on FOUR terminators: LF, CR, U+2028 and U+2029 — not LF alone. Splitting on
  #10 only made `#set %x% = A` + CR + `%x%` render as nothing and validate as invalid,
  where the reference renders CR + 'A' and calls it valid. Same for U+2028/U+2029.

  Plain CRLF was never affected, which is why it went unnoticed: the CR was stripped
  as trailing whitespace before the directive was matched.

  One helper rather than a fix in each of the eight scanning loops — they were
  identical, and identical loops drift apart when patched one at a time. }

{ Length of the line terminator starting at text[i], or 0 if none starts there. }
function LineBreakLen(const text: string; i: Integer): Integer;
begin
  Result := 0;
  if (i < 1) or (i > Length(text)) then Exit;
  if text[i] = #13 then
  begin
    if (i < Length(text)) and (text[i + 1] = #10) then Result := 2 else Result := 1;
    Exit;
  end;
  if text[i] = #10 then Exit(1);
  {$IFDEF UNICODE}
  if (Ord(text[i]) = $2028) or (Ord(text[i]) = $2029) then Result := 1;
  {$ELSE}
  { U+2028 / U+2029 are E2 80 A8 / E2 80 A9 in UTF-8. }
  if (i + 2 <= Length(text)) and (text[i] = #$E2) and (text[i + 1] = #$80)
     and ((text[i + 2] = #$A8) or (text[i + 2] = #$A9)) then Result := 3;
  {$ENDIF}
end;

{ Index of the next terminator at or after From, or Length(text)+1 when the text ends
  first. TermLen is its size in code units, 0 at end of text. }
function NextLineBreak(const text: string; from: Integer; out termLen: Integer): Integer;
var i, n: Integer;
begin
  n := Length(text);
  i := from;
  while i <= n do
  begin
    termLen := LineBreakLen(text, i);
    if termLen > 0 then Exit(i);
    Inc(i);
  end;
  termLen := 0;
  Result := n + 1;
end;

{ ─── #include recognition ────────────────────────────────────────────────────
  One rule, one implementation, three callers -- SpExtract, SpValidate and
  SpExtractDirectives. It is the reference's

      /^[ \t]*#include[ \t\n\r\f\x0B]+"([^"]+)"[ \t\n\r\f\x0B]*$/gmu

  The PHP core and the plugin write `\s` under /u where the reference spells the class out.
  The reference's own comment says it does that for PHP parity, i.e. it believes PHP's \s is
  this ASCII set; PCRE2 under /u also sets UCP, which would make \s match NBSP, so the two
  may in fact disagree on `#include<NBSP>"x"`. Unmeasured -- no PHP on this machine -- and
  recorded in docs/TODO.md as a question for the family. This port follows @spintax/core,
  which the charter makes the normative reference, so an NBSP is not whitespace here.

  This port used to read it as "#include at a line start, then the first quoted string
  anywhere on the line", which is looser in five ways and stricter in one. Since
  include.unknown-target is an ERROR, the loose half moved validate VERDICTS -- a defect by
  spec §3, not a divergence -- and the corpus could not see it, carrying two plain #include
  cases. Measured against @spintax/core over 86 419 include-shaped inputs, which is also
  what says this matcher now agrees with it everywhere.

  Why a matcher over the text instead of a test on one line: the class holds \n and \r, so
  the run before the target and the run after it may CROSS line terminators, and the target
  is [^"]+, so it may contain them too. `#include` + newline + `"frag"` is one include to
  every other engine in the family. }

{ Include targets are compared EXACTLY -- TStringList.IndexOf ignores case, the reference
  uses a Set and Array.includes, and extract's own docblock says slugs are left "as
  authored" where every other name it collects is lower-cased. They are host identifiers,
  not variable names. Measured: `#include "OK"` against KnownIncludes ['ok'] is invalid in
  the reference and used to be valid here, and `#include "a"` + `#include "A"` is two
  targets there and used to be one here.

  A helper rather than the list's CaseSensitive property: the list belongs to the caller,
  and setting that on a sorted one re-sorts it. }
function HasExact(list: TStringList; const s: string): Boolean;
var i: Integer;
begin
  for i := 0 to list.Count - 1 do
    if list[i] = s then Exit(True);
  Result := False;
end;

{ The whitespace class above, which is NOT the same set as a line terminator: U+2028/9 end a
  line for ^ and $ but are not whitespace, and CR/LF are both. }
function IsIncludeSpace(c: Char): Boolean;
begin
  Result := (c = ' ') or (c = #9) or (c = #10) or (c = #13) or (c = #12) or (c = #11);
end;

{ Does an #include match start at From, which must be a ^ position (start of text, or just
  after a line terminator)? Ref is the target, RefStart/RefEnd its span in text (inclusive /
  exclusive, i.e. the two quote positions +1 and +0), MatchEnd one past the whole match.

  The trailing [ \t\n\r\f\x0B]*$ is greedy and then backtracks to the last $ it can reach,
  so walking the run forward and keeping the LAST $ seen inside it gives the same answer as
  the regex engine gives coming back from the end. }
{ After a match, a line-by-line scan must carry on from the MATCH END, not from the next line
  start: the reference scans with /g, and the whitespace class holds terminators, so a match
  can swallow line starts that are no longer ^ positions. Retrying them invents includes --
  measured, and it moves a verdict:

    #include "a          the reference sees ONE include, `a\n#include `; scanning every line
    #include "           start finds a second, `   \nb`, because the quotes inside the first
    b"                   target line up again from there.

  MatchEnd is a $ position by construction, so it is either past the end or on a terminator;
  E and TermLen are moved onto it, and the caller's `lineStart := e + termLen` then lands on
  the next real ^. }
procedure ResumeAfterInclude(const text: string; matchEnd: Integer;
  var e, termLen: Integer);
begin
  e := matchEnd;
  termLen := LineBreakLen(text, e);
end;

function MatchIncludeAt(const text: string; from: Integer;
  out ref: string; out refStart, refEnd, matchEnd: Integer): Boolean;
var p, n, runStart, q: Integer;
begin
  Result := False; ref := ''; refStart := 0; refEnd := 0; matchEnd := 0;
  n := Length(text);
  p := from;
  while (p <= n) and ((text[p] = ' ') or (text[p] = #9)) do Inc(p);        { ^[ \t]* }
  if Copy(text, p, 8) <> '#include' then Exit;
  Inc(p, 8);
  runStart := p;
  while (p <= n) and IsIncludeSpace(text[p]) do Inc(p);                    { [ \t\n\r\f\x0B]+ }
  if p = runStart then Exit;                                              { the + is not a * }
  if (p > n) or (text[p] <> '"') then Exit;
  refStart := p + 1;
  q := refStart;
  while (q <= n) and (text[q] <> '"') do Inc(q);                           { "([^"]+)" }
  if (q > n) or (q = refStart) then Exit;                    { unterminated, or empty target }
  refEnd := q;
  ref := Copy(text, refStart, q - refStart);
  p := q + 1;
  while True do                                                { [ \t\n\r\f\x0B]*$ }
  begin
    if (p > n) or (LineBreakLen(text, p) > 0) then matchEnd := p;
    if (p > n) or not IsIncludeSpace(text[p]) then Break;
    Inc(p);
  end;
  Result := matchEnd > 0;
end;

procedure ExtractDirectives(const text: string; setDefs, defDefs: TStrMap; out body: string);
var
  kind, nm, val, kept, line: string;
  lineStart, n, e, termLen: Integer;
  isDirective: Boolean;
begin
  // Mirror the reference regex: only the directive TEXT is removed, the newline
  // that separated its line stays. So a directive line becomes an empty segment;
  // segments are re-joined with #10 and then \n{3,} collapses to \n\n.
  kept := '';
  lineStart := 1;
  n := Length(text);
  while lineStart <= n + 1 do
  begin
    e := NextLineBreak(text, lineStart, termLen);
    line := Copy(text, lineStart, e - lineStart);
    isDirective := TryParseDirective(line, kind, nm, val);
    if isDirective then
    begin
      if kind = 'def' then defDefs.AddOrSetValue(nm, val)
      else setDefs.AddOrSetValue(nm, val);
      // emit nothing for the directive's own text
    end
    else
      kept := kept + line;
    { Keep the terminator that was actually there. Emitting #10 for every line would turn a
      bare CR into LF; the reference preserves the character it broke on.

      With one exception, which is the same `[ \t]*\r?$` that trims the value: the reference
      removes the whole MATCH, and the optional \r is greedy, so it takes the CR whenever $
      still holds AFTER it. $ under /m holds at end of input and before ANY line terminator,
      so that is: end of text, another CR, an LF, U+2028 and U+2029 -- everything except an
      ordinary character. Measured on @spintax/core, `#set %x% = A` + CR + <what follows>:

        (end)  ""      CR  "\rZ"     LF  "\nZ"     U+2028  "<LS>Z"     U+2029  "<PS>Z"
        Z      "\rZ"   -- the only shape where the CR survives

      So: drop the CR, keep whatever the terminator has after it (the LF of a CRLF; nothing
      at all for a bare CR). Getting this wrong is what shipped in v0.3.1, which handled the
      CRLF case only and said in this comment that a lone CR is never consumed -- a wrong
      justification, next to code that was right for one shape out of five. }
    if termLen > 0 then
      if isDirective and (text[e] = #13)
         and ((e + 1 > n) or (LineBreakLen(text, e + 1) > 0)) then
        kept := kept + Copy(text, e + 1, termLen - 1)
      else
        kept := kept + Copy(text, e, termLen);
    if e > n then Break;
    lineStart := e + termLen;
  end;
  body := CollapseNewlines3(kept);
end;

{ ─── AST ─────────────────────────────────────────────────────────────────── }

type
  TNodeKind = (nkLiteral, nkVariable, nkEnumeration, nkPermutation, nkConditional, nkPlural);

  TNode = class;
  TNodeList = TObjectList<TNode>;

  TPermOption = class
  public
    Nodes: TNodeList;
    Separator: string;
    HasSeparator: Boolean;
    destructor Destroy; override;
  end;

  TNode = class
  public
    Kind: TNodeKind;
    // literal / variable
    Text: string;
    // enumeration: options = list of TNodeList
    EnumOptions: TObjectList<TNodeList>;
    // permutation
    PermMin, PermMax: Integer;   // -1 = null
    PermSep: string;
    PermLastSep: string; PermHasLastSep: Boolean;
    PermOptions: TObjectList<TPermOption>;
    // conditional
    CondName: string; CondInverted: Boolean;
    CondThen, CondElse: TNodeList;
    // plural
    PluralCountRaw, PluralFormsRaw: string;
    destructor Destroy; override;
  end;

destructor TPermOption.Destroy;
begin
  Nodes.Free;
  inherited;
end;

destructor TNode.Destroy;
begin
  EnumOptions.Free;
  PermOptions.Free;
  CondThen.Free;
  CondElse.Free;
  inherited;
end;

{ forward }
function ParseSequence(const text: string): TNodeList; forward;

function ParsePlural(const afterPrefix: string): TNode;
var colon: Integer;
begin
  colon := Pos(':', afterPrefix);
  Result := TNode.Create;
  Result.Kind := nkPlural;
  Result.PluralCountRaw := Copy(afterPrefix, 1, colon - 1);
  Result.PluralFormsRaw := Copy(afterPrefix, colon + 1, MaxInt);
end;

function TryParseConditional(const content: string): TNode;
var p, sep: Integer; inverted: Boolean; nm, body, thenRaw, elseRaw: string;
begin
  Result := nil;
  p := 2; // past leading '?'
  inverted := False;
  if (p <= Length(content)) and (content[p] = '!') then begin inverted := True; Inc(p); end;
  nm := '';
  if (p <= Length(content)) and (CharInSet(content[p], ['A'..'Z', 'a'..'z', '_'])) then
  begin
    nm := nm + content[p]; Inc(p);
    while (p <= Length(content)) and IsAsciiWord(content[p]) do begin nm := nm + content[p]; Inc(p); end;
  end
  else Exit;
  if (p > Length(content)) or (content[p] <> '?') then Exit;
  Inc(p);
  body := Copy(content, p, MaxInt);
  sep := FirstTopLevelPipe(body);
  if sep < 1 then begin thenRaw := body; elseRaw := ''; end
  else begin thenRaw := Copy(body, 1, sep - 1); elseRaw := Copy(body, sep + 1, MaxInt); end;
  Result := TNode.Create;
  Result.Kind := nkConditional;
  Result.CondName := nm;
  Result.CondInverted := inverted;
  Result.CondThen := ParseSequence(thenRaw);
  Result.CondElse := ParseSequence(elseRaw);
end;

{ Permutation config parse (faithful-enough: key form or single-separator form,
  with the family's HTML-start-tag guard in front). }
procedure ParsePermConfig(const raw: string; node: TNode; out content: string);
var trimmed, configStr, remaining, low, sv: string; endPos, i: Integer; inQuote: Boolean;
  { HTML_TAG_RE ^([a-zA-Z][a-zA-Z0-9-]*)(?:\s+[^>]*)?\/?$ plus the closing-tag probe:
    a leading <li ...>...</li> or <br/> is markup, not config. }
  function LooksLikeHtmlStartTag: Boolean;
  var t, nameLow, remLow: string; k, j, n: Integer;
  begin
    Result := False;
    t := PhpTrim(configStr);
    if (t = '') or not CharInSet(t[1], ['A'..'Z', 'a'..'z']) then Exit;
    n := 1;
    while (n < Length(t)) and CharInSet(t[n + 1], ['A'..'Z', 'a'..'z', '0'..'9', '-']) do Inc(n);
    if n < Length(t) then
    begin
      // after the tag name: a lone trailing '/', or whitespace then attrs without '>'
      // (whitespace = JS \s restricted to ASCII, so VT and FF included)
      if (t[n + 1] = '/') and (n + 1 = Length(t)) then
        { bare self-closing tag }
      else if CharInSet(t[n + 1], [' ', #9, #10, #11, #12, #13]) then
      begin
        for j := n + 2 to Length(t) do
          if t[j] = '>' then Exit;
      end
      else
        Exit;
    end;
    if t[Length(t)] = '/' then Exit(True); // self-closing
    // start tag counts as HTML only when remaining holds </name\s*>
    nameLow := LowerAscii(Copy(t, 1, n));
    remLow := LowerAscii(remaining);
    k := 1;
    repeat
      k := PosEx('</' + nameLow, remLow, k);
      if k = 0 then Exit;
      j := k + 2 + Length(nameLow);
      while (j <= Length(remLow)) and CharInSet(remLow[j], [' ', #9, #10, #11, #12, #13]) do Inc(j);
      if (j <= Length(remLow)) and (remLow[j] = '>') then Exit(True);
      Inc(k);
    until False;
  end;
  { CONFIG_KEY_RE \b(?:minsize|maxsize|sep|lastsep)\s*= -- a bare Pos() also fires on
    "separator" or "xminsize", which the family keeps as a single separator. }
  function HasConfigKey: Boolean;
  const KEYS: array[0..3] of string = ('minsize', 'maxsize', 'sep', 'lastsep');
  var k, j, e: Integer;
  begin
    Result := False;
    for k := 1 to Length(low) do
    begin
      if (k > 1) and CharInSet(low[k - 1], ['a'..'z', '0'..'9', '_']) then Continue;
      for j := 0 to High(KEYS) do
        if Copy(low, k, Length(KEYS[j])) = KEYS[j] then
        begin
          e := k + Length(KEYS[j]);
          while (e <= Length(low)) and CharInSet(low[e], [' ', #9, #10, #11, #12, #13]) do Inc(e);
          if (e <= Length(low)) and (low[e] = '=') then Exit(True);
        end;
    end;
  end;
  function FindInt(const key: string): Integer;
  var k, j: Integer; num: string;
  begin
    Result := -1;
    k := Pos(key, LowerAscii(configStr));
    if k = 0 then Exit;
    j := k + Length(key);
    while (j <= Length(configStr)) and (CharInSet(configStr[j], [' ', #9])) do Inc(j);
    if (j <= Length(configStr)) and (configStr[j] = '=') then Inc(j);
    while (j <= Length(configStr)) and (CharInSet(configStr[j], [' ', #9])) do Inc(j);
    num := '';
    while (j <= Length(configStr)) and (CharInSet(configStr[j], ['0'..'9'])) do begin num := num + configStr[j]; Inc(j); end;
    if num <> '' then Result := StrToInt(num);
  end;
  function FindStr(const key: string; out val: string): Boolean;
  var k, j: Integer; low2: string;
  begin
    Result := False; val := '';
    low2 := LowerAscii(configStr);
    // find key not preceded by 'last' when key='sep'
    k := 1;
    while True do
    begin
      k := PosEx(key, low2, k);
      if k = 0 then Exit;
      if (key = 'sep') and (k >= 5) and (Copy(low2, k - 4, 4) = 'last') then begin Inc(k); Continue; end;
      Break;
    end;
    j := k + Length(key);
    while (j <= Length(configStr)) and (CharInSet(configStr[j], [' ', #9])) do Inc(j);
    if (j <= Length(configStr)) and (configStr[j] = '=') then Inc(j) else Exit;
    while (j <= Length(configStr)) and (CharInSet(configStr[j], [' ', #9])) do Inc(j);
    if (j > Length(configStr)) or (configStr[j] <> '"') then Exit;
    Inc(j);
    while (j <= Length(configStr)) and (configStr[j] <> '"') do begin val := val + configStr[j]; Inc(j); end;
    Result := True;
  end;
begin
  node.PermMin := -1; node.PermMax := -1; node.PermSep := ' ';
  node.PermLastSep := ''; node.PermHasLastSep := False;
  content := raw;
  trimmed := PhpLtrim(raw);
  if (trimmed = '') or (trimmed[1] <> '<') then Exit;
  // find closing '>' respecting quotes
  endPos := 0; inQuote := False;
  for i := 2 to Length(trimmed) do
  begin
    if trimmed[i] = '"' then inQuote := not inQuote;
    if (trimmed[i] = '>') and not inQuote then begin endPos := i; Break; end;
  end;
  if endPos = 0 then Exit;
  configStr := Copy(trimmed, 2, endPos - 2);
  remaining := Copy(trimmed, endPos + 1, MaxInt);
  if LooksLikeHtmlStartTag then Exit; // a leading HTML tag stays in the content
  low := LowerAscii(configStr);
  // key form?
  if HasConfigKey then
  begin
    node.PermMin := FindInt('minsize');
    node.PermMax := FindInt('maxsize');
    if FindStr('sep', sv) then node.PermSep := sv else node.PermSep := ' ';
    if FindStr('lastsep', sv) then begin node.PermLastSep := sv; node.PermHasLastSep := True; end;
    content := remaining;
  end
  else
  begin
    // single-separator form: whole string is sep AND lastsep
    node.PermSep := configStr;
    node.PermLastSep := configStr; node.PermHasLastSep := True;
    content := remaining;
  end;
end;

function ParsePermutation(const rawInner: string): TNode;
var
  content, pendingSep, part, trimmed, sepInner, rt, innerTrim, trailingSep: string;
  parts: TStringList;
  i, k, openPos, q: Integer;
  hasPending, hasTrailing, bail, looksHtml: Boolean;
  opt: TPermOption;
begin
  Result := TNode.Create;
  Result.Kind := nkPermutation;
  Result.PermOptions := TObjectList<TPermOption>.Create(True);
  ParsePermConfig(rawInner, Result, content);
  SplitTopLevel(content, parts);
  try
    pendingSep := ''; hasPending := False;
    for i := 0 to parts.Count - 1 do
    begin
      part := parts[i];
      trailingSep := ''; hasTrailing := False;
      if i < parts.Count - 1 then
      begin
        // extractTrailingSep: trailing < sep > that is not an HTML tag
        rt := PhpRtrim(part);
        if (Length(rt) > 0) and (rt[Length(rt)] = '>') then
        begin
          openPos := 0; bail := False;
          for k := Length(rt) - 1 downto 1 do
          begin
            if rt[k] = '<' then begin openPos := k; Break; end;
            if rt[k] = '>' then begin bail := True; Break; end;
          end;
          if (not bail) and (openPos > 0) then
          begin
            sepInner := Copy(rt, openPos + 1, Length(rt) - 1 - openPos);
            innerTrim := PhpTrim(sepInner);
            looksHtml := (Length(innerTrim) > 0) and
              ((innerTrim[1] = '/') or (innerTrim[Length(innerTrim)] = '/'));
            // per-elem html: ^[A-Za-z][A-Za-z0-9]*\s
            if (not looksHtml) and (Length(innerTrim) >= 2) and (CharInSet(innerTrim[1], ['A'..'Z','a'..'z'])) then
            begin
              q := 2;
              while (q <= Length(innerTrim)) and (CharInSet(innerTrim[q], ['A'..'Z','a'..'z','0'..'9'])) do Inc(q);
              if (q <= Length(innerTrim)) and (CharInSet(innerTrim[q], [' ',#9,#10,#13])) then looksHtml := True;
            end;
            if not looksHtml then
            begin
              part := Copy(rt, 1, openPos - 1);
              trailingSep := sepInner; hasTrailing := True;
            end;
          end;
        end;
      end;
      trimmed := PhpTrim(part);
      if trimmed <> '' then
      begin
        opt := TPermOption.Create;
        opt.Nodes := ParseSequence(trimmed);
        opt.Separator := pendingSep; opt.HasSeparator := hasPending;
        Result.PermOptions.Add(opt);
      end;
      pendingSep := trailingSep; hasPending := hasTrailing;
    end;
  finally
    parts.Free;
  end;
end;

function ParseBraceConstruct(const content: string): TNode;
var parts: TStringList; i: Integer; nl: TNodeList; cond: TNode;
const PLURAL_PREFIX = 'plural ';
begin
  if (Length(content) > 0) and (content[1] = '?') then
  begin
    cond := TryParseConditional(content);
    if cond <> nil then Exit(cond);
    // malformed -> fall through to enumeration
  end
  else if (Copy(content, 1, Length(PLURAL_PREFIX)) = PLURAL_PREFIX)
     and (Pos(':', Copy(content, Length(PLURAL_PREFIX) + 1, MaxInt)) > 0) then
  begin
    Exit(ParsePlural(Copy(content, Length(PLURAL_PREFIX) + 1, MaxInt)));
  end;
  // enumeration
  Result := TNode.Create;
  Result.Kind := nkEnumeration;
  Result.EnumOptions := TObjectList<TNodeList>.Create(True);
  SplitTopLevel(content, parts);
  try
    for i := 0 to parts.Count - 1 do
    begin
      nl := ParseSequence(parts[i]);
      Result.EnumOptions.Add(nl);
    end;
  finally
    parts.Free;
  end;
end;

function ParseSequence(const text: string): TNodeList;
var i, j, endp, namelen: Integer; ch: Char; literal, nm: string; node: TNode;

  procedure FlushLiteral;
  begin
    if literal <> '' then
    begin
      node := TNode.Create; node.Kind := nkLiteral; node.Text := literal;
      Result.Add(node); literal := '';
    end;
  end;

begin
  Result := TNodeList.Create(True);
  literal := ''; i := 1;
  while i <= Length(text) do
  begin
    ch := text[i];
    if ch = '{' then
    begin
      endp := FindMatchingClose(text, i, '{', '}');
      if endp = 0 then begin literal := literal + ch; Inc(i); Continue; end;
      FlushLiteral;
      Result.Add(ParseBraceConstruct(Copy(text, i + 1, endp - i - 1)));
      i := endp + 1; Continue;
    end;
    if ch = '[' then
    begin
      endp := FindMatchingClose(text, i, '[', ']');
      if endp = 0 then begin literal := literal + ch; Inc(i); Continue; end;
      FlushLiteral;
      Result.Add(ParsePermutation(Copy(text, i + 1, endp - i - 1)));
      i := endp + 1; Continue;
    end;
    if ch = '%' then
    begin
      // %(\w+)%
      namelen := 0; nm := '';
      j := i + 1;
      while (j <= Length(text)) and IsAsciiWord(text[j]) do begin nm := nm + text[j]; Inc(j); Inc(namelen); end;
      if (namelen > 0) and (j <= Length(text)) and (text[j] = '%') then
      begin
        FlushLiteral;
        node := TNode.Create; node.Kind := nkVariable; node.Text := nm;
        Result.Add(node);
        i := j + 1; Continue;
      end;
    end;
    literal := literal + ch;
    Inc(i);
  end;
  FlushLiteral;
end;

{ ─── render ──────────────────────────────────────────────────────────────── }

type
  TRenderOpts = record
    Vars: TStrMap;   // lower-cased keys
    Locale: string;
    Depth: Integer;
    Rng: TSpRng;
  end;

function RenderNodes(nodes: TNodeList; const opts: TRenderOpts): string; forward;

function HasConstructChar(const s: string): Boolean;
var i: Integer;
begin
  for i := 1 to Length(s) do
    if (s[i] = '{') or (s[i] = '[') or (s[i] = '%') then Exit(True);
  Result := False;
end;

function ExpandVarsOnly(const text: string; const opts: TRenderOpts): string;
var iter, i, j: Integer; changed: Boolean; outp, nm, val, res: string;
begin
  outp := text;
  for iter := 1 to MAX_VARIABLE_DEPTH do
  begin
    changed := False;
    res := ''; i := 1;
    while i <= Length(outp) do
    begin
      if outp[i] = '%' then
      begin
        j := i + 1; nm := '';
        while (j <= Length(outp)) and IsAsciiWord(outp[j]) do begin nm := nm + outp[j]; Inc(j); end;
        if (nm <> '') and (j <= Length(outp)) and (outp[j] = '%') then
        begin
          if opts.Vars.TryGetValue(LowerAscii(nm), val) then
          begin
            res := res + val; changed := True; i := j + 1; Continue;
          end;
        end;
      end;
      res := res + outp[i]; Inc(i);
    end;
    outp := res;
    if not changed then Break;
  end;
  Result := outp;
end;

function ResolveVariable(const name: string; const opts: TRenderOpts): string;
var val: string; sub: TNodeList; subOpts: TRenderOpts;
begin
  if not opts.Vars.TryGetValue(LowerAscii(name), val) then Exit('%' + name + '%');
  if (opts.Depth >= MAX_VARIABLE_DEPTH) or (not HasConstructChar(val)) then Exit(val);
  sub := ParseSequence(val);
  try
    subOpts := opts; subOpts.Depth := opts.Depth + 1;
    Result := RenderNodes(sub, subOpts);
  finally
    sub.Free;
  end;
end;

function RenderConditional(node: TNode; const opts: TRenderOpts): string;
var val: string; baseTruthy, truthy: Boolean; i: Integer;
begin
  baseTruthy := False;
  if opts.Vars.TryGetValue(LowerAscii(node.CondName), val) then
    for i := 1 to Length(val) do
      if not (CharInSet(val[i], [' ', #9, #10, #13, #12, #11])) then begin baseTruthy := True; Break; end;
  if node.CondInverted then truthy := not baseTruthy else truthy := baseTruthy;
  if truthy then Result := RenderNodes(node.CondThen, opts)
  else Result := RenderNodes(node.CondElse, opts);
end;

function IsIntStr(const s: string): Boolean;
var i, st: Integer;
begin
  if s = '' then Exit(False);
  st := 1;
  if s[1] = '-' then st := 2;
  if st > Length(s) then Exit(False);
  for i := st to Length(s) do if not (CharInSet(s[i], ['0'..'9'])) then Exit(False);
  Result := True;
end;

function FullwidthVerbatim(const countRaw, formsRaw: string): string;
var raw, res: string; i: Integer;
begin
  raw := '{plural ' + countRaw + ':' + formsRaw + '}';
  res := '';
  { Same encoding split as Sentinel(): the reference emits the fullwidth braces
    U+FF5B / U+FF5D, which are 3 UTF-8 bytes on a byte string and 1 code unit
    under UTF-16. }
  for i := 1 to Length(raw) do
    {$IFDEF UNICODE}
    if raw[i] = '{' then res := res + Chr($FF5B)
    else if raw[i] = '}' then res := res + Chr($FF5D)
    {$ELSE}
    if raw[i] = '{' then res := res + #$EF#$BD#$9B
    else if raw[i] = '}' then res := res + #$EF#$BD#$9D
    {$ENDIF}
    else res := res + raw[i];
  Result := res;
end;

function RenderPlural(node: TNode; const opts: TRenderOpts): string;
var countRaw, formsRaw, count, picked, cur: string; base: string;
    forms: TStringList; i: Integer; hasBracket: Boolean; sub: TNodeList;
begin
  countRaw := ExpandVarsOnly(node.PluralCountRaw, opts);
  formsRaw := ExpandVarsOnly(node.PluralFormsRaw, opts);
  base := NormalizeBaseLang(opts.Locale);

  hasBracket := False;
  for i := 1 to Length(formsRaw) do
    if CharInSet(formsRaw[i], ['{', '}', '[', ']']) then begin hasBracket := True; Break; end;
  if hasBracket then Exit(FullwidthVerbatim(countRaw, formsRaw));

  count := PhpTrim(countRaw);
  if not IsIntStr(count) then Exit('');

  forms := TStringList.Create;
  try
    forms.StrictDelimiter := True;
    // split on '|'
    cur := '';
    for i := 1 to Length(formsRaw) do
      if formsRaw[i] = '|' then begin forms.Add(PhpTrim(cur)); cur := ''; end
      else cur := cur + formsRaw[i];
    forms.Add(PhpTrim(cur));
    if forms.Count <> PluralArity(base) then Exit(FullwidthVerbatim(countRaw, formsRaw));
    picked := PluralFor(base, StrToInt(count), forms);
  finally
    forms.Free;
  end;
  sub := ParseSequence(picked);
  try
    Result := RenderNodes(sub, opts);
  finally
    sub.Free;
  end;
end;

function RenderEnumeration(node: TNode; const opts: TRenderOpts): string;
var idx: Integer;
begin
  if node.EnumOptions.Count = 0 then Exit('');
  idx := opts.Rng.Next(0, node.EnumOptions.Count - 1);
  Result := RenderNodes(node.EnumOptions[idx], opts);
end;

function PadSeparator(const sep: string): string;
var t: string; i: Integer; allLetters: Boolean;
begin
  t := PhpTrim(sep);
  if t = '' then Exit(sep);
  // \p{L}+ approximated: all bytes are ASCII letters OR any non-ASCII (UTF-8 letter bytes)
  allLetters := True;
  for i := 1 to Length(t) do
    if not ((CharInSet(t[i], ['A'..'Z','a'..'z'])) or (Ord(t[i]) >= $80)) then begin allLetters := False; Break; end;
  if allLetters then Result := ' ' + t + ' ' else Result := sep;
end;

function RenderPermutation(node: TNode; const opts: TRenderOpts): string;
type TElem = record Text: string; Sep: string; HasSep: Boolean; end;
var elems: array of TElem; total, i, j, min, max, pick: Integer; tmp: TElem;
    globalSep, globalLast, sep: string;
begin
  total := node.PermOptions.Count;
  if total = 0 then Exit('');
  SetLength(elems, total);
  for i := 0 to total - 1 do
  begin
    elems[i].Text := RenderNodes(node.PermOptions[i].Nodes, opts);
    elems[i].Sep := node.PermOptions[i].Separator;
    elems[i].HasSep := node.PermOptions[i].HasSeparator;
  end;

  if (node.PermMin >= 0) and (node.PermMax >= 0) then begin min := node.PermMin; max := node.PermMax; end
  else if node.PermMin >= 0 then begin min := node.PermMin; max := total; end
  else if node.PermMax >= 0 then begin min := 1; max := node.PermMax; end
  else begin min := total; max := total; end;
  if min < 1 then min := 1;
  if min > total then min := total;
  if max < min then max := min;
  if max > total then max := total;

  if min = max then pick := min else pick := opts.Rng.Next(min, max);

  // Fisher-Yates: i = n-1..1, j = rng(0,i), swap
  for i := total - 1 downto 1 do
  begin
    if 0 = i then j := 0 else j := opts.Rng.Next(0, i);
    tmp := elems[i]; elems[i] := elems[j]; elems[j] := tmp;
  end;

  globalSep := node.PermSep;
  if node.PermHasLastSep then globalLast := node.PermLastSep else globalLast := node.PermSep;

  if pick = 0 then Exit('');
  Result := elems[0].Text;
  for i := 1 to pick - 1 do
  begin
    if elems[i].HasSep then sep := elems[i].Sep
    else if i = pick - 1 then sep := globalLast
    else sep := globalSep;
    Result := Result + PadSeparator(sep) + elems[i].Text;
  end;
end;

function RenderNode(node: TNode; const opts: TRenderOpts): string;
begin
  case node.Kind of
    nkLiteral:     Result := node.Text;
    nkVariable:    Result := ResolveVariable(node.Text, opts);
    nkEnumeration: Result := RenderEnumeration(node, opts);
    nkPermutation: Result := RenderPermutation(node, opts);
    nkConditional: Result := RenderConditional(node, opts);
    nkPlural:      Result := RenderPlural(node, opts);
  else
    Result := '';
  end;
end;

function RenderNodes(nodes: TNodeList; const opts: TRenderOpts): string;
var i: Integer;
begin
  Result := '';
  for i := 0 to nodes.Count - 1 do
    Result := Result + RenderNode(nodes[i], opts);
end;

{ ─── #def rolling (dependency order) ─────────────────────────────────────── }

{ Ordered-unique add. TStringList.IndexOf is a linear scan, so k distinct names cost O(k^2):
  6400 distinct %refs% measured 11.4 s in SpExtract, almost all of it here. The LIST keeps
  order -- the corpus compares these order-normalized, but a host sees it -- and the
  dictionary keeps membership.

  Keys compare EXACTLY, where IndexOf ignored case. That is the same answer, not a quiet
  behaviour change: every name reaching here has already been through LowerAscii at its call
  site, and include targets are exact by contract (v0.2.2). Adding a name with mixed case
  would now keep both, so keep folding at the call sites. }
procedure AddUniqueOrdered(list: TStringList; seen: TDictionary<string, Boolean>;
  const s: string);
begin
  if seen.ContainsKey(s) then Exit;
  seen.Add(s, True);
  list.Add(s);
end;

procedure DirectReferences(const text: string; target: TStringList;
  seen: TDictionary<string, Boolean>); overload;
var i, j: Integer; nm: string;
begin
  i := 1;
  while i <= Length(text) do
  begin
    if text[i] = '%' then
    begin
      j := i + 1; nm := '';
      while (j <= Length(text)) and IsAsciiWord(text[j]) do begin nm := nm + text[j]; Inc(j); end;
      if (nm <> '') and (j <= Length(text)) and (text[j] = '%') then
      begin
        AddUniqueOrdered(target, seen, LowerAscii(nm));
        i := j + 1; Continue;
      end;
    end;
    Inc(i);
  end;
end;

{ For the callers that gather a handful of names into a list of their own: the membership
  set is built from what the list already holds, so repeated calls accumulate exactly as
  they did through IndexOf. Only the document-wide scans, where k grows with the input,
  carry a dictionary of their own. }
procedure DirectReferences(const text: string; target: TStringList); overload;
var seen: TDictionary<string, Boolean>; i: Integer;
begin
  seen := TDictionary<string, Boolean>.Create;
  try
    for i := 0 to target.Count - 1 do seen.AddOrSetValue(target[i], True);
    DirectReferences(text, target, seen);
  finally
    seen.Free;
  end;
end;

{ The `{?name?` / `{?!name?` half of a reference scan, split out so it can run per line
  rather than over a rebuilt copy of the document. }
procedure ConditionalReferences(const text: string; target: TStringList;
  seen: TDictionary<string, Boolean>);
var i, j: Integer; nm: string;
begin
  i := 1;
  while i <= Length(text) do
  begin
    if (i + 1 <= Length(text)) and (text[i] = '{') and (text[i+1] = '?') then
    begin
      j := i + 2;
      if (j <= Length(text)) and (text[j] = '!') then Inc(j);
      nm := '';
      if (j <= Length(text)) and (CharInSet(text[j], ['A'..'Z','a'..'z','_'])) then
      begin
        nm := nm + text[j]; Inc(j);
        while (j <= Length(text)) and IsAsciiWord(text[j]) do begin nm := nm + text[j]; Inc(j); end;
        if (j <= Length(text)) and (text[j] = '?') then
          AddUniqueOrdered(target, seen, LowerAscii(nm));
      end;
    end;
    Inc(i);
  end;
end;

{ ─── public render pipeline ──────────────────────────────────────────────── }

{ ─── post-process: shielding ─────────────────────────────────────────────────
  Faithful port of the reference pipeline. URLs, emails, domains, decimals and
  abbreviations are replaced by placeholders BEFORE the spacing and capitalization
  passes, then restored, so those passes cannot corrupt them.

  The regexes are hand-scanned here because neither compiler has Unicode-property
  matching. Each scanner mirrors one regex and is named after it. Whitespace is the
  explicit ASCII set throughout, matching the reference: JS -s- is Unicode, PHP's is not,
  and using either would diverge around NBSP and thin spaces. }

const
  SENTENCE_OPENER_1 = $00BF;   { inverted question mark }
  SENTENCE_OPENER_2 = $00A1;   { inverted exclamation mark }

function IsPpWs(c: Char): Boolean;
begin
  Result := (c = ' ') or (c = #9) or (c = #13) or (c = #10) or (c = #12) or (c = #11);
end;

{ The set that terminates a URL or URI: whitespace, or one of  < > " ' )  ] }
function IsUriStop(c: Char): Boolean;
begin
  { #0 stops a URI body. Nothing is shielded yet when this pass runs, so on ordinary
    input it never bites; it is there for a caller-supplied #0, which would otherwise
    let a URI match run through the delimiters of a placeholder minted after it. }
  Result := IsPpWs(c) or (c = #0) or (c = '<') or (c = '>') or (c = '"') or (c = '''')
            or (c = ')') or (c = ']');
end;

function LowerAsciiCh(c: Char): Char;
begin
  if CharInSet(c, ['A'..'Z']) then Result := Chr(Ord(c) + 32) else Result := c;
end;

{ Case-insensitive ASCII compare of s[i..] against lit. Enough for the URL and URI
  schemes, which are ASCII by definition. }
function MatchesAt(const s: string; i: Integer; const lit: string): Boolean;
var k: Integer;
begin
  Result := False;
  if i + Length(lit) - 1 > Length(s) then Exit;
  for k := 1 to Length(lit) do
    if LowerAsciiCh(s[i + k - 1]) <> LowerAsciiCh(lit[k]) then Exit;
  Result := True;
end;

{ Case-insensitive compare that folds NON-ASCII too, by upper-casing both sides one code
  point at a time. The abbreviation rule is -giu- and its list is largely Cyrillic, so an
  ASCII-only fold missed every capitalised form: an uppercase Russian abbreviation was
  treated as ordinary text and the next word got capitalised after it.
  Returns the matched length in code units, or 0. }
function MatchesFoldedAt(const s: string; i: Integer; const lit: string): Integer;
var p, q, lenS, lenL: Integer; a, b: string;
begin
  Result := 0;
  p := i; q := 1;
  while q <= Length(lit) do
  begin
    if p > Length(s) then Exit;
    SpCodePointAt(s, p, lenS);
    SpCodePointAt(lit, q, lenL);
    a := SpUpperCodePoint(SpCodePointAt(s, p, lenS));
    b := SpUpperCodePoint(SpCodePointAt(lit, q, lenL));
    if a <> b then Exit;
    Inc(p, lenS);
    Inc(q, lenL);
  end;
  Result := p - i;
end;

{ JS -b- is ASCII: word chars are A-Za-z0-9 and underscore. }
function IsBoundaryWordCh(const s: string; i: Integer): Boolean;
begin
  Result := (i >= 1) and (i <= Length(s)) and IsAsciiWord(s[i]);
end;

{ A word boundary sits at index i when exactly one side of it is an ASCII word char.
  Modelling it as merely "the char before is not a word char" is wrong in BOTH directions,
  because -w- is ASCII even under -iu-: a Cyrillic domain like an all-Cyrillic label has
  no boundary before it and the reference does NOT shield it, while an abbreviation
  preceded by an underscore DOES have one and the reference does shield it. }
function IsWordBoundaryAt(const s: string; i: Integer): Boolean;
begin
  Result := IsBoundaryWordCh(s, i - 1) <> IsBoundaryWordCh(s, i);
end;

{ Start index of the code point that ENDS at i-1, i.e. the one before position i.
  UTF-8 continuation bytes and UTF-16 low surrogates are not code-point starts, so a
  lookbehind that just does i-1 reads the middle of a character. }
function PrevCodePointStart(const s: string; i: Integer): Integer;
begin
  Result := i - 1;
  if Result < 1 then Exit(1);
  {$IFDEF UNICODE}
  if (Result > 1) and (Ord(s[Result]) >= $DC00) and (Ord(s[Result]) <= $DFFF)
     and (Ord(s[Result - 1]) >= $D800) and (Ord(s[Result - 1]) <= $DBFF) then
    Dec(Result);
  {$ELSE}
  while (Result > 1) and ((Ord(s[Result]) and $C0) = $80) do Dec(Result);
  {$ENDIF}
end;

{ Letter or digit at i, using the CASE-FOLDED tables. The email, domain and
  single-abbreviation rules are all -giu- in the reference, and under -iu- a property
  escape is folded, so the folded predicate is the faithful one there. }
function IsLetterOrNumFoldedAt(const s: string; i: Integer; out cpLen: Integer): Boolean;
var cp: LongWord;
begin
  cpLen := 1;
  Result := False;
  if (i < 1) or (i > Length(s)) then Exit;
  cp := SpCodePointAt(s, i, cpLen);
  Result := SpIsUniLetterFolded(cp) or SpIsUniNumber(cp);
end;

function IsLetterFoldedAt(const s: string; i: Integer; out cpLen: Integer): Boolean;
var cp: LongWord;
begin
  cpLen := 1;
  Result := False;
  if (i < 1) or (i > Length(s)) then Exit;
  cp := SpCodePointAt(s, i, cpLen);
  Result := SpIsUniLetterFolded(cp);
end;

{ Strict letter, for the multi-abbreviation rule, which is -gu- and not folded. }
function IsLetterStrictAt(const s: string; i: Integer; out cpLen: Integer): Boolean;
var cp: LongWord;
begin
  cpLen := 1;
  Result := False;
  if (i < 1) or (i > Length(s)) then Exit;
  cp := SpCodePointAt(s, i, cpLen);
  Result := SpIsUniLetter(cp);
end;

{ One DOMAIN_PART: one or more dot-terminated labels followed by a TLD.
    label = optional xn-- prefix, then letters/digits, then any number of
            hyphen-joined letter/digit groups
    tld   = xn-- plus 2..59 of a-z 0-9 hyphen, OR a letter followed by 1..62
            letter / digit / hyphen
  Greedy on the labels, with backtracking, because the last label can double as the TLD:
  in example.com the regex takes example. as the label and com as the TLD. }
{ requireEndBoundary: the callers all place a -b- after the domain, and the regex
  BACKTRACKS the TLD length to satisfy it. Taking the greedy length and testing the
  boundary once is not the same thing: in an email followed by a Cyrillic letter the
  greedy TLD swallows the letter -- it is a Unicode letter too -- the boundary then fails,
  and the whole match is lost where the reference simply stops at the shorter TLD. }
function ScanDomainPart(const s: string; i: Integer; requireEndBoundary: Boolean): Integer;
var
  p, cpLen, labelEnd, tldLen, k, n, m: Integer;
  dotEnds: array of Integer;
  ends: array of Integer;
  cnt: Integer;
begin
  Result := 0;
  SetLength(dotEnds, 0);
  cnt := 0;
  p := i;
  { collect as many dot-terminated labels as possible }
  while True do
  begin
    labelEnd := p;
    if MatchesAt(s, labelEnd, 'xn--') then Inc(labelEnd, 4);
    n := 0;
    while IsLetterOrNumFoldedAt(s, labelEnd, cpLen) do begin Inc(labelEnd, cpLen); Inc(n); end;
    if n = 0 then Break;
    { hyphen-joined groups }
    while (labelEnd <= Length(s)) and (s[labelEnd] = '-') do
    begin
      k := labelEnd + 1;
      n := 0;
      while IsLetterOrNumFoldedAt(s, k, cpLen) do begin Inc(k, cpLen); Inc(n); end;
      if n = 0 then Break;
      labelEnd := k;
    end;
    if (labelEnd > Length(s)) or (s[labelEnd] <> '.') then Break;
    Inc(labelEnd);                       { consume the dot }
    SetLength(dotEnds, cnt + 1);
    dotEnds[cnt] := labelEnd;
    Inc(cnt);
    p := labelEnd;
  end;
  if cnt = 0 then Exit;

  { try the TLD after the longest run of labels, backtracking one label at a time }
  for k := cnt - 1 downto 0 do
  begin
    p := dotEnds[k];
    tldLen := 0;
    if MatchesAt(s, p, 'xn--') then
    begin
      n := 0;
      labelEnd := p + 4;
      while (labelEnd <= Length(s))
            and (CharInSet(s[labelEnd], ['a'..'z', 'A'..'Z', '0'..'9', '-'])) do
      begin Inc(labelEnd); Inc(n); end;
      while (n > 59) do begin Dec(labelEnd); Dec(n); end;
      while (n >= 2) and requireEndBoundary and not IsWordBoundaryAt(s, labelEnd) do
      begin Dec(labelEnd); Dec(n); end;
      if (n >= 2) and (n <= 59) then tldLen := labelEnd - p;
    end;
    if tldLen = 0 then
    begin
      if IsLetterFoldedAt(s, p, cpLen) then
      begin
        { Record every acceptable end position, longest first, so the boundary check can
          walk back through them exactly as the regex backtracks the quantifier. }
        SetLength(ends, 0);
        labelEnd := p + cpLen;
        n := 0;
        while (n < 62) and (labelEnd <= Length(s)) do
        begin
          if n >= 1 then
          begin
            SetLength(ends, Length(ends) + 1);
            ends[Length(ends) - 1] := labelEnd;
          end;
          if s[labelEnd] = '-' then begin Inc(labelEnd); Inc(n); end
          else if IsLetterOrNumFoldedAt(s, labelEnd, cpLen) then
            begin Inc(labelEnd, cpLen); Inc(n); end
          else Break;
        end;
        if n >= 1 then
        begin
          SetLength(ends, Length(ends) + 1);
          ends[Length(ends) - 1] := labelEnd;
        end;
        for m := Length(ends) - 1 downto 0 do
          if (not requireEndBoundary) or IsWordBoundaryAt(s, ends[m]) then
          begin
            tldLen := ends[m] - p;
            Break;
          end;
      end;
    end;
    if tldLen > 0 then Exit(p + tldLen - i);
  end;
end;

{ https:// http:// ftp:// then everything up to whitespace or one of the stop chars. }
{ URIs -- https/http/ftp (with a // authority) and mailto:/tel: (without one) -- are
  shielded in ONE pass, deliberately.

  They used to be two passes, URLs then mailto:/tel:. A URI body runs to the first stop
  character, so the two match sets overlap whenever one URI contains the other's scheme,
  and with two passes the second one ran into a placeholder the first had already minted:
  mailto:sales@x.com?body=see%20https://shop.x.com/cart shielded the URL first, then
  stored a mailto: value with URL_0's key inside it. Restore was past that key by the time
  the value landed, so the engine emitted a raw #0 -- illegal in XML, U+FFFD to an HTML
  parser, rejected by Postgres text, and a live key again as soon as an edit detaches it
  from the prefix that was shielding it (spintax-js#53).

  Neither pass order fixes it, because whichever runs second is the one that gets split:
  shielding mailto:/tel: first only moves the damage onto a URL whose path carries a
  mailto:, where the leading half then loses its trailing dot to the punctuation pass.
  A single alternation has no second pass to damage -- the leftmost match wins and takes
  the whole token, whichever scheme it is.

  Without this shield at all, the email and domain passes swallow the address, the bare
  prefix is left behind, and the space-after-colon rule splits it into a malformed href. }
function ScanUri(const s: string; i: Integer): Integer;
var p, k: Integer;
begin
  Result := 0;
  if MatchesAt(s, i, 'https://') then p := i + 8
  else if MatchesAt(s, i, 'http://') then p := i + 7
  else if MatchesAt(s, i, 'ftp://') then p := i + 6
  else if MatchesAt(s, i, 'mailto:') then p := i + 7
  else if MatchesAt(s, i, 'tel:') then p := i + 4
  else Exit;
  { The reference's [^...]+ needs at least one character after the scheme, so a bare
    "https://" is not a URL. The old guard compared against a fixed length and let the
    empty ones through. }
  k := p;
  while (p <= Length(s)) and not IsUriStop(s[p]) do Inc(p);
  if p > k then Result := p - i;
end;

{ Which placeholder prefix a match gets. Kept distinct (URL vs URI) even though one pass
  mints both: the prefixes are what the other engines' fixtures speak. }
function UriPrefix(const matched: string): string;
begin
  if MatchesAt(matched, 1, 'mailto:') or MatchesAt(matched, 1, 'tel:') then
    Result := 'URI'
  else
    Result := 'URL';
end;

function ScanEmail(const s: string; i: Integer): Integer;
var p, dom: Integer;
begin
  Result := 0;
  p := i;
  while (p <= Length(s))
        and CharInSet(s[p], ['a'..'z', 'A'..'Z', '0'..'9', '.', '_', '%', '+', '-']) do
    Inc(p);
  if (p = i) or (p > Length(s)) or (s[p] <> '@') then Exit;
  Inc(p);
  dom := ScanDomainPart(s, p, True);
  if dom = 0 then Exit;
  Inc(p, dom);
  if not IsWordBoundaryAt(s, p) then Exit;
  Result := p - i;
end;

function ScanDomain(const s: string; i: Integer): Integer;
var dom: Integer;
begin
  Result := 0;
  if not IsWordBoundaryAt(s, i) then Exit;
  dom := ScanDomainPart(s, i, True);
  if dom = 0 then Exit;
  if not IsWordBoundaryAt(s, i + dom) then Exit;
  Result := dom;
end;

function ScanDecimal(const s: string; i: Integer): Integer;
var p, a, b: Integer;
begin
  Result := 0;
  if not IsWordBoundaryAt(s, i) then Exit;
  p := i; a := 0;
  while (p <= Length(s)) and CharInSet(s[p], ['0'..'9']) do begin Inc(p); Inc(a); end;
  if (a = 0) or (p > Length(s)) or (s[p] <> '.') then Exit;
  Inc(p); b := 0;
  while (p <= Length(s)) and CharInSet(s[p], ['0'..'9']) do begin Inc(p); Inc(b); end;
  if b = 0 then Exit;
  if not IsWordBoundaryAt(s, p) then Exit;
  Result := p - i;
end;

{ Two or more groups of one-or-two letters each followed by a dot and optional
  whitespace. This is the -gu- rule, so letters are strict, not folded. }
function ScanMultiAbbr(const s: string; i: Integer): Integer;
var p, cpLen, groups, letters, lastEnd: Integer;
begin
  Result := 0;
  if not IsWordBoundaryAt(s, i) then Exit;
  p := i; groups := 0; lastEnd := i;
  while True do
  begin
    letters := 0;
    while (letters < 2) and IsLetterStrictAt(s, p, cpLen) do
    begin Inc(p, cpLen); Inc(letters); end;
    if (letters = 0) or (p > Length(s)) or (s[p] <> '.') then Break;
    Inc(p);
    while (p <= Length(s)) and IsPpWs(s[p]) do Inc(p);
    Inc(groups);
    lastEnd := p;
  end;
  if groups >= 2 then Result := lastEnd - i;
end;

{ Rebuilt once from the generated code-point table, in whatever width this compiler uses. }
{ Built once, on first use, and freed in finalization. Not thread-safe to initialise
  concurrently -- the engine has no other global state and no threading contract, so this
  is documented rather than locked. }
var
  GAbbrevs: TStringList = nil;

procedure EnsureAbbrevs;
var i, k, n, len: Integer; a: string;
begin
  if GAbbrevs <> nil then Exit;
  GAbbrevs := TStringList.Create;
  i := 0;
  for k := 1 to ABBREV_COUNT do
  begin
    len := ABBREV_DATA[i]; Inc(i);
    a := '';
    for n := 1 to len do begin a := a + SpCodePointToStr(ABBREV_DATA[i]); Inc(i); end;
    GAbbrevs.Add(a);
  end;
end;

{ One of the known abbreviations, then a dot, with no letter or digit before it and
  whitespace, end of text, or a tag right after. Case-insensitive, hence the folded
  predicate for the preceding character. }
function ScanSingleAbbr(const s: string; i: Integer): Integer;
var k, p, cpLen, prev: Integer; a: string;
begin
  Result := 0;
  EnsureAbbrevs;
  { negative lookbehind: no letter or digit immediately before }
  if i > 1 then
  begin
    prev := PrevCodePointStart(s, i);
    if IsLetterOrNumFoldedAt(s, prev, cpLen) then Exit;
  end;
  for k := 0 to GAbbrevs.Count - 1 do
  begin
    a := GAbbrevs[k];
    cpLen := MatchesFoldedAt(s, i, a);
    if cpLen = 0 then Continue;
    p := i + cpLen;
    if (p > Length(s)) or (s[p] <> '.') then Continue;
    Inc(p);
    if (p > Length(s)) or IsPpWs(s[p]) or (s[p] = '<') then Exit(p - i);
  end;
end;

type
  TScanFn = function(const s: string; i: Integer): Integer;

{ Replace every match of one scanner with a placeholder, left to right. The key is
  NUL prefix underscore counter NUL, exactly the reference's shape: NUL cannot occur in
  rendered output, so nothing else can collide with it. }
{ ─── a growable buffer ───────────────────────────────────────────────────────
  The post-process runs sixteen passes over the whole text, and each one used to
  accumulate its result with  res := res + one character , which reallocates and copies
  on every append. That made the stage quadratic: measured 0.11 s at 14 KB but 45 s at
  950 KB, where four times the input cost seven to ten times the work.

  Used ONLY inside the post-process. Concatenation elsewhere is not on a hot path and is
  left alone. }
type
  TStrBuf = record
    Data: string;
    Len: Integer;
    procedure Init(capacity: Integer);
    procedure Grow(needed: Integer);
    procedure AppendChar(c: Char);
    procedure AppendSlice(const s: string; start, count: Integer);
    procedure AppendStr(const s: string);
    function Finish: string;
  end;

procedure TStrBuf.Init(capacity: Integer);
begin
  if capacity < 16 then capacity := 16;
  SetLength(Data, capacity);
  Len := 0;
end;

procedure TStrBuf.Grow(needed: Integer);
var cap: Integer;
begin
  cap := Length(Data);
  if Len + needed <= cap then Exit;
  while cap < Len + needed do cap := cap * 2;
  SetLength(Data, cap);
end;

procedure TStrBuf.AppendChar(c: Char);
begin
  Grow(1);
  Inc(Len);
  Data[Len] := c;
end;

procedure TStrBuf.AppendSlice(const s: string; start, count: Integer);
var i: Integer;
begin
  if count <= 0 then Exit;
  Grow(count);
  for i := 0 to count - 1 do Data[Len + 1 + i] := s[start + i];
  Inc(Len, count);
end;

procedure TStrBuf.AppendStr(const s: string);
begin
  AppendSlice(s, 1, Length(s));
end;

function TStrBuf.Finish: string;
begin
  SetLength(Data, Len);
  Result := Data;
end;

{ perMatchPrefix: the URI pass mints two prefixes from one alternation, so it derives the
  prefix from the match instead of taking the fixed one. Every other pass passes False. }
procedure ShieldPass(var text: string; scan: TScanFn; const prefix: string;
  keys, vals: TStringList; var counter: Integer; stripTrailingPunct: Boolean;
  perMatchPrefix: Boolean);
var
  buf: TStrBuf;
  matched, key, suffix: string;
  i, len, cut: Integer;
begin
  buf.Init(Length(text) + 16);
  i := 1;
  while i <= Length(text) do
  begin
    len := scan(text, i);
    if len > 0 then
    begin
      matched := Copy(text, i, len);
      suffix := '';
      if stripTrailingPunct then
      begin
        { A URL at the end of a sentence must give the sentence its full stop back, or
          the sentence never ends. Only a trailing run of  . , ; : !  is returned. }
        cut := Length(matched);
        while (cut > 0) and CharInSet(matched[cut], ['.', ',', ';', ':', '!']) do Dec(cut);
        if cut < Length(matched) then
        begin
          suffix := Copy(matched, cut + 1, Length(matched) - cut);
          matched := Copy(matched, 1, cut);
        end;
      end;
      if matched = '' then
        buf.AppendStr(suffix)
      else
      begin
        if perMatchPrefix then
          key := #0 + UriPrefix(matched) + '_' + IntToStr(counter) + #0
        else
          key := #0 + prefix + '_' + IntToStr(counter) + #0;
        Inc(counter);
        keys.Add(key);
        vals.Add(matched);
        buf.AppendStr(key);
        buf.AppendStr(suffix);
      end;
      Inc(i, len);
    end
    else
    begin
      buf.AppendChar(text[i]);
      Inc(i);
    end;
  end;
  text := buf.Finish;
end;

{ Steps 6 and 7: collapse space runs, then punctuation spacing. }
function SpacingPasses(const input: string): string;
var s: string; buf: TStrBuf; i, runEnd, cpLen: Integer; cp: LongWord;
begin
  s := input;

  { 6: collapse runs of space and tab to one space }
  buf.Init(Length(s) + 16); i := 1;
  while i <= Length(s) do
  begin
    if (s[i] = ' ') or (s[i] = #9) then
    begin
      runEnd := i;
      while (runEnd <= Length(s)) and ((s[runEnd] = ' ') or (s[runEnd] = #9)) do Inc(runEnd);
      { The reference collapses runs of TWO OR MORE only: a lone tab stays a tab.
        Rewriting a single space-or-tab to a space turned a tab into a space. }
      if runEnd - i >= 2 then buf.AppendChar(' ')
      else buf.AppendSlice(s, i, runEnd - i);
      i := runEnd;
    end
    else begin buf.AppendChar(s[i]); Inc(i); end;
  end;
  s := buf.Finish;

  { 7: remove whitespace before  , ; : ! ? .  }
  buf.Init(Length(s) + 16); i := 1;
  while i <= Length(s) do
  begin
    if IsPpWs(s[i]) then
    begin
      runEnd := i;
      while (runEnd <= Length(s)) and IsPpWs(s[runEnd]) do Inc(runEnd);
      if (runEnd <= Length(s)) and CharInSet(s[runEnd], [',', ';', ':', '!', '?', '.']) then
      begin
        i := runEnd;                 { drop the whitespace run entirely }
        Continue;
      end;
      buf.AppendSlice(s, i, runEnd - i);
      i := runEnd;
      Continue;
    end;
    buf.AppendChar(s[i]);
    Inc(i);
  end;
  s := buf.Finish;

  { 7: a space after  , ; :  unless a digit, whitespace, end of text or a tag follows }
  buf.Init(Length(s) + 16); i := 1;
  while i <= Length(s) do
  begin
    buf.AppendChar(s[i]);
    if CharInSet(s[i], [',', ';', ':']) and (i < Length(s))
       and not CharInSet(s[i + 1], ['0'..'9']) and not IsPpWs(s[i + 1])
       and (s[i + 1] <> '<') then
      buf.AppendChar(' ');
    Inc(i);
  end;
  s := buf.Finish;

  { 7: a space after a RUN of  . ! ?  -- a run is ONE sentence end, so the space goes
    after the whole run or "Wow!!!" becomes "Wow!! !". }
  buf.Init(Length(s) + 16); i := 1;
  while i <= Length(s) do
  begin
    if CharInSet(s[i], ['.', '!', '?']) then
    begin
      runEnd := i;
      while (runEnd <= Length(s)) and CharInSet(s[runEnd], ['.', '!', '?']) do Inc(runEnd);
      buf.AppendSlice(s, i, runEnd - i);
      if (runEnd <= Length(s)) and not CharInSet(s[runEnd], ['0'..'9'])
         and not IsPpWs(s[runEnd]) and (s[runEnd] <> '<') then
        buf.AppendChar(' ');
      i := runEnd;
      Continue;
    end;
    buf.AppendChar(s[i]);
    Inc(i);
  end;
  s := buf.Finish;

  { 7a: a Spanish opener binds to the word it opens. BEFORE capitalization, so the
    capitalizer sees the real first letter instead of a space. }
  buf.Init(Length(s) + 16); i := 1;
  while i <= Length(s) do
  begin
    { Advance by whole CODE POINTS. Stepping one unit at a time landed inside multi-byte
      characters, where a stray UTF-8 continuation byte decodes to itself: $BF is the
      second byte of Cyrillic -p- and equals the code point of the inverted question mark,
      so "cyp goryachiy" lost the space after every such letter. Silent corruption of
      ordinary Russian prose, and FPC-only -- under UTF-16 there are no continuation
      units, so the two backends disagreed on the same input. }
    cp := SpCodePointAt(s, i, cpLen);
    buf.AppendSlice(s, i, cpLen);
    Inc(i, cpLen);
    if (cp = SENTENCE_OPENER_1) or (cp = SENTENCE_OPENER_2) then
      while (i <= Length(s)) and IsPpWs(s[i]) do Inc(i);
  end;
  Result := buf.Finish;
end;

{ The LEAD: everything that can sit between a sentence boundary and the first letter --
  HTML tags, Spanish sentence openers and whitespace, in any order and any number.
  A single optional opener is not enough: the RAE form for a sentence that is both a
  question and an exclamation opens with TWO marks, and the opened word is routinely
  wrapped in markup, which puts a tag AFTER the opener. }
function ScanLead(const s: string; i: Integer): Integer;
var p, cpLen, k: Integer; cp: LongWord;
begin
  p := i;
  while p <= Length(s) do
  begin
    if s[p] = '<' then
    begin
      k := p + 1;
      while (k <= Length(s)) and (s[k] <> '>') do Inc(k);
      { <[^>]+> requires at least one character inside, so <> is literal text. }
      if (k > Length(s)) or (k = p + 1) then Break;
      p := k + 1;
      Continue;
    end;
    if IsPpWs(s[p]) then begin Inc(p); Continue; end;
    cp := SpCodePointAt(s, p, cpLen);
    if (cp = SENTENCE_OPENER_1) or (cp = SENTENCE_OPENER_2) then
    begin Inc(p, cpLen); Continue; end;
    Break;
  end;
  Result := p - i;
end;

{ Uppercase the code point at i, if it is a lowercase letter. Folded chooses which
  predicate applies: the block-tag step is -giu- in the reference and the others are not.
  Returns the replacement text and its source length, or 0 when nothing applies. }
function CapAt(const s: string; i: Integer; folded: Boolean; out repl: string): Integer;
var cp: LongWord; cpLen: Integer; isLow: Boolean;
begin
  Result := 0;
  repl := '';
  if (i < 1) or (i > Length(s)) then Exit;
  cp := SpCodePointAt(s, i, cpLen);
  if folded then isLow := SpIsUniLowerFolded(cp) else isLow := SpIsUniLower(cp);
  if not isLow then Exit;
  repl := SpUpperCodePoint(cp);
  Result := cpLen;
end;

{ Steps 8-11. Each finds a boundary, skips the LEAD, and upper-cases the first lowercase
  letter after it. }
function HasPrefix(const s, prefix: string): Boolean;
begin
  Result := (Length(s) >= Length(prefix)) and (Copy(s, 1, Length(prefix)) = prefix);
end;

function CapitalizePasses(const input: string): string;
var
  s, repl: string;
  buf: TStrBuf;
  i, leadLen, capLen, k: Integer;
  cp: LongWord; cpLen: Integer;

  function IsBlockTagAt(const t: string; at: Integer; out tagLen: Integer): Boolean;
  var q, nameStart: Integer; name: string;
  begin
    Result := False; tagLen := 0;
    if (at > Length(t)) or (t[at] <> '<') then Exit;
    q := at + 1;
    if (q <= Length(t)) and (t[q] = '/') then Inc(q);
    nameStart := q;
    while (q <= Length(t)) and CharInSet(t[q], ['a'..'z', 'A'..'Z', '0'..'9']) do Inc(q);
    name := LowerAscii(Copy(t, nameStart, q - nameStart));
    while (q <= Length(t)) and (t[q] <> '>') do Inc(q);
    if q > Length(t) then Exit;
    { The reference alternation is followed by [^>]*, so the name only has to START with
      one of the alternatives: <pre> matches via "p", <thead> via "th", <link> via "li".
      Comparing the whole name for equality missed every one of those. }
    if HasPrefix(name, 'p') or HasPrefix(name, 'li') or HasPrefix(name, 'blockquote')
       or HasPrefix(name, 'div') or HasPrefix(name, 'td') or HasPrefix(name, 'th')
       or ((Length(name) >= 2) and (name[1] = 'h') and CharInSet(name[2], ['1'..'6'])) then
    begin
      Result := True;
      tagLen := q + 1 - at;
    end;
  end;

begin
  s := input;

  { 8: the first letter, skipping the lead }
  leadLen := ScanLead(s, 1);
  capLen := CapAt(s, 1 + leadLen, False, repl);
  if capLen > 0 then
    s := Copy(s, 1, leadLen) + repl + Copy(s, 1 + leadLen + capLen, MaxInt);

  { 9: after sentence punctuation, through the lead }
  buf.Init(Length(s) + 16); i := 1;
  while i <= Length(s) do
  begin
    cp := SpCodePointAt(s, i, cpLen);
    if (cpLen = 1) and CharInSet(s[i], ['.', '!', '?']) or (cp = $2026) then
    begin
      buf.AppendSlice(s, i, cpLen);
      Inc(i, cpLen);
      leadLen := ScanLead(s, i);
      buf.AppendSlice(s, i, leadLen);
      Inc(i, leadLen);
      capLen := CapAt(s, i, False, repl);
      if capLen > 0 then begin buf.AppendStr(repl); Inc(i, capLen); end;
      Continue;
    end;
    buf.AppendSlice(s, i, cpLen);
    Inc(i, cpLen);
  end;
  s := buf.Finish;

  { 10: after a block-level tag. This one is -giu- in the reference, so the CASE-FOLDED
    predicate applies -- 1446 extra code points, 32 with a differing uppercase. }
  buf.Init(Length(s) + 16); i := 1;
  while i <= Length(s) do
  begin
    if IsBlockTagAt(s, i, k) then
    begin
      buf.AppendSlice(s, i, k);
      Inc(i, k);
      leadLen := ScanLead(s, i);
      buf.AppendSlice(s, i, leadLen);
      Inc(i, leadLen);
      capLen := CapAt(s, i, True, repl);
      if capLen > 0 then begin buf.AppendStr(repl); Inc(i, capLen); end;
      Continue;
    end;
    buf.AppendChar(s[i]);
    Inc(i);
  end;
  s := buf.Finish;

  { 11: after a line break }
  buf.Init(Length(s) + 16); i := 1;
  while i <= Length(s) do
  begin
    if s[i] = #10 then
    begin
      buf.AppendChar(s[i]);
      Inc(i);
      leadLen := ScanLead(s, i);
      buf.AppendSlice(s, i, leadLen);
      Inc(i, leadLen);
      capLen := CapAt(s, i, False, repl);
      if capLen > 0 then begin buf.AppendStr(repl); Inc(i, capLen); end;
      Continue;
    end;
    buf.AppendChar(s[i]);
    Inc(i);
  end;
  Result := buf.Finish;
end;

{ The full pipeline, in the reference's order. Phase 1 covers shielding and spacing;
  the capitalization steps land next and must come AFTER shielding, or the engine starts
  capitalising inside example.com and after an abbreviation. }
{ JS String#trim strips Unicode whitespace -- and NOT the C0 controls or NUL that Pascal's
  Trim removes. Measured from Node; both differences were observable: Pascal's Trim ate a
  leading NUL the reference keeps, and left a non-breaking space the reference strips. }
function IsJsTrimCp(cp: LongWord): Boolean;
begin
  Result := (cp = $0009) or (cp = $000A) or (cp = $000B) or (cp = $000C) or (cp = $000D)
         or (cp = $0020) or (cp = $00A0) or (cp = $1680)
         or ((cp >= $2000) and (cp <= $200A))
         or (cp = $2028) or (cp = $2029) or (cp = $202F) or (cp = $205F) or (cp = $3000)
         or (cp = $FEFF);
end;

function JsTrim(const s: string): string;
var first, past, prevStart, cpLen: Integer;
begin
  first := 1;
  while (first <= Length(s)) and IsJsTrimCp(SpCodePointAt(s, first, cpLen)) do
    Inc(first, cpLen);
  past := Length(s) + 1;
  while past > first do
  begin
    prevStart := PrevCodePointStart(s, past);
    if not IsJsTrimCp(SpCodePointAt(s, prevStart, cpLen)) then Break;
    past := prevStart;
  end;
  Result := Copy(s, first, past - first);
end;

{ Step 12: put the shielded text back.

  One left-to-right pass, not one StringReplace per key: the old form walked the whole
  text once for every shielded match, which is the second half of why the stage was
  quadratic. A dictionary does the lookup, because keys.IndexOf per placeholder would
  just move the quadratic cost somewhere else.

  A token is NUL, a key body, NUL. Anything that is not a known key -- an unclosed NUL, or
  a NUL pair the input itself contained -- is copied through verbatim, which is what the
  per-key replace did too.

  Values are NOT rescanned. That is deliberate and it matches the reference: it restores
  in insertion order, so a key that leaks into a later value is inserted after its own
  pass has run and stays literal. }
procedure RestorePlaceholders(const text: string; keys, vals: TStringList;
  var buf: TStrBuf);
var
  map: TDictionary<string, string>;
  i, j, k: Integer;
  token, value: string;
begin
  map := TDictionary<string, string>.Create;
  try
    for k := 0 to keys.Count - 1 do map.AddOrSetValue(keys[k], vals[k]);
    i := 1;
    while i <= Length(text) do
    begin
      if text[i] = #0 then
      begin
        j := i + 1;
        while (j <= Length(text)) and (text[j] <> #0) do Inc(j);
        if j <= Length(text) then
        begin
          token := Copy(text, i, j - i + 1);
          if map.TryGetValue(token, value) then
          begin
            buf.AppendStr(value);
            i := j + 1;
            Continue;
          end;
        end;
      end;
      buf.AppendChar(text[i]);
      Inc(i);
    end;
  finally
    map.Free;
  end;
end;

function FullPostProcess(const input: string): string;
var
  keys, vals: TStringList;
  text: string;
  restored: TStrBuf;
  counter: Integer;
begin
  keys := TStringList.Create;
  vals := TStringList.Create;
  try
    text := input;
    counter := 0;
    { 1-5: shield. Every URI scheme in ONE pass, so neither can run into a placeholder the
      other minted (spintax-js#53), and always before email and domain, so the whole
      mailto: survives instead of the address being carved out from under its prefix. }
    ShieldPass(text, @ScanUri,        'URL',   keys, vals, counter, True,  True);
    ShieldPass(text, @ScanEmail,      'EMAIL', keys, vals, counter, False, False);
    ShieldPass(text, @ScanDomain,     'DOM',   keys, vals, counter, False, False);
    ShieldPass(text, @ScanDecimal,    'NUM',   keys, vals, counter, False, False);
    ShieldPass(text, @ScanMultiAbbr,  'ABBR',  keys, vals, counter, False, False);
    ShieldPass(text, @ScanSingleAbbr, 'ABBR',  keys, vals, counter, False, False);

    { 6, 7, 7a }
    text := SpacingPasses(text);

    { 8-11: capitalization, only now that URLs and abbreviations are out of the way }
    text := CapitalizePasses(text);

    { 12: restore, then trim.

      Two restores, and the choice is not an optimization detail -- it is the
      contract. The reference replaces each key across the whole text, one key at
      a time, in insertion order. That is O(text x keys), which is what made this
      stage quadratic, but it is also observable: a replacement can rewrite text
      an earlier replacement produced, and an unpaired #0 the CALLER supplied can
      pair with the opening #0 of a real placeholder to form a key that was never
      minted. A single left-to-right pass cannot reproduce either effect.

      The guard removes the #0-borne disagreements, and that is ALL it does. Two
      earlier drafts of this comment claimed it made the two restores identical on
      #0-free input. That is false, and the false version propagated to the other
      engines before it was caught (spintax-js#52), so it is worth stating plainly
      what survives the guard:

        #0 ABBR_2 #0 URL_0 #0 URI_1 #0

      Two placeholders landing flush around caller text that spells a bare key
      name. The closing delimiter of one and the opening delimiter of the next
      spell a THIRD occurrence of the URL_0 key. The loop substitutes it and
      destroys both real tokens; the fast pass consumes ABBR_2 whole and never
      sees the forgery. It needs no #0 in the input -- only prose containing
      URL_0, which any document about this engine has.

      We keep the fast pass's answer there deliberately: the loop returns wreckage
      with raw sentinels in it, so this is not a contract worth preserving. It is
      pinned by nul-free/forged-key-between-two-shields.

      What the guard IS for: with no #0 in the input, every #0 in the working text
      is one the shield placed, so a caller cannot forge or split a delimiter, and
      passes 6-11 touch only whitespace, punctuation and lowercase letters, so
      none of them can break a key open. The reference-shaped loop still runs on
      the inputs that do carry a #0, where the delimiters no longer pair as the
      shield placed them. }
    if Pos(#0, input) = 0 then
    begin
      restored.Init(Length(text) + 16);
      RestorePlaceholders(text, keys, vals, restored);
      Result := JsTrim(restored.Finish);
    end
    else
    begin
      for counter := 0 to keys.Count - 1 do
        text := StringReplace(text, keys[counter], vals[counter], [rfReplaceAll]);
      Result := JsTrim(text);
    end;
  finally
    keys.Free;
    vals.Free;
  end;
end;


{ ─── #def ordering ───────────────────────────────────────────────────────────
  Definitions must be rolled dependencies-first. Iterating the TDictionary instead
  made the order depend on the hash layout: it happened to work under FPC and
  failed under Delphi (def/dependency-through-a-set-alias — the dependent froze
  with its dependency unexpanded and the plural block vanished). Ported from the
  reference's orderDefinitions/referencedNames.

  The order must follow ALIASES: a #def can reach another #def through a #set,
  which is expanded at reference time and so is invisible in the first
  definition's own text. }

{ Every name a value reaches, hopping through alias values to a fixpoint.
  Uses the DirectReferences helper already defined above — it de-duplicates on
  insert, which is exactly the queue behaviour this BFS wants. }
function ReferencedNames(const value: string; aliases: TStrMap): TStringList;
var queue: TStringList; nm, alias: string; head: Integer;
begin
  Result := TStringList.Create;
  Result.Sorted := False;
  queue := TStringList.Create;
  try
    DirectReferences(value, queue);
    head := 0;
    while head < queue.Count do
    begin
      nm := queue[head]; Inc(head);
      if Result.IndexOf(nm) >= 0 then Continue;
      Result.Add(nm);
      if aliases.TryGetValue(nm, alias) then DirectReferences(alias, queue);
    end;
  finally
    queue.Free;
  end;
end;

{ Definition names, dependencies first. A cycle cannot be ordered, so its members
  come last — in whatever order remains, exactly as the reference does. }
function OrderDefinitions(defDefs, aliases: TStrMap): TStringList;
var
  names, pending, ordered, ready, reached: TStringList;
  pair: TPair<string, string>;
  i, j: Integer;
  blocked: TObjectDictionary<string, TStringList>;
  deps: TStringList;
  isReady: Boolean;
begin
  names := TStringList.Create;
  ordered := TStringList.Create;
  pending := TStringList.Create;
  blocked := TObjectDictionary<string, TStringList>.Create([doOwnsValues]);
  try
    for pair in defDefs do names.Add(pair.Key);

    // deps(name) = the definition names this value can reach, through aliases
    for i := 0 to names.Count - 1 do
    begin
      reached := ReferencedNames(defDefs[names[i]], aliases);
      try
        deps := TStringList.Create;
        for j := 0 to names.Count - 1 do
          if reached.IndexOf(names[j]) >= 0 then deps.Add(names[j]);
        blocked.AddOrSetValue(names[i], deps);
      finally
        reached.Free;
      end;
    end;

    pending.Assign(names);
    while pending.Count > 0 do
    begin
      ready := TStringList.Create;
      try
        for i := 0 to pending.Count - 1 do
        begin
          isReady := True;
          if blocked.TryGetValue(pending[i], deps) then
            for j := 0 to deps.Count - 1 do
              if (deps[j] <> pending[i]) and (pending.IndexOf(deps[j]) >= 0) then
                begin isReady := False; Break; end;
          if isReady then ready.Add(pending[i]);
        end;

        // no progress => a cycle; emit the rest as-is rather than looping forever
        if ready.Count = 0 then
        begin
          for i := 0 to pending.Count - 1 do ordered.Add(pending[i]);
          Break;
        end;

        for i := 0 to ready.Count - 1 do
        begin
          ordered.Add(ready[i]);
          j := pending.IndexOf(ready[i]);
          if j >= 0 then pending.Delete(j);
        end;
      finally
        ready.Free;
      end;
    end;

    Result := TStringList.Create;
    Result.Assign(ordered);
  finally
    names.Free; ordered.Free; pending.Free; blocked.Free;
  end;
end;

{ A caller who leaves Ctx.Rng nil is the exact analogue of calling the reference's
  render with no seed, which builds an rng from Math.random rather than failing.
  Matching that beats an EAccessViolation from deep inside the walk, which is what a
  nil Rng used to produce.

  Seeded from the clock plus a counter, so two renders in the same millisecond still
  differ, and without calling Randomize — a library has no business resetting the host's
  global RandSeed. Determinism remains available the way the corpus uses it: inject an
  explicit TSpRng. }
var
  GRngCounter: LongWord = 0;

{ The multiply is a hash mixer and wraps on purpose, like the generator itself. }
{$IFOPT Q+}{$DEFINE SPX_Q_WAS_ON}{$Q-}{$ENDIF}
{$IFOPT R+}{$DEFINE SPX_R_WAS_ON}{$R-}{$ENDIF}

function MakeDefaultRng: TSpRng;
begin
  Inc(GRngCounter);
  Result := TMulberry32Rng.Create(
    LongWord(Round(Frac(Now) * 86400000)) xor LongWord(GRngCounter * 2654435761));
end;

{$IFDEF SPX_R_WAS_ON}{$R+}{$UNDEF SPX_R_WAS_ON}{$ENDIF}
{$IFDEF SPX_Q_WAS_ON}{$Q+}{$UNDEF SPX_Q_WAS_ON}{$ENDIF}

{ ─── one document ───────────────────────────────────────────────────────────
  Everything the reference's renderAst does: directives out, vars built, #def rolled, the
  tree walked, and then -- because renderAst ends with resolveIncludes -- each #include line
  in the RESULT replaced by the child, rendered the same way. What it deliberately does NOT
  do is post-process or restore sentinels: those run ONCE, at the top, over the assembled
  document, which is the reference's order (pipeline.ts) and the reason a child must never
  go through the public entry point.

  RuntimeVars is the host's context, inherited by every child unchanged; the parent's
  #set/#def are NOT, because a child builds its own from its own source. Rng is shared, so
  the sequence continues across the seam. Stack carries the refs currently being expanded,
  for the cycle and depth guards. }
function RenderDocument(const Template: string; RuntimeVars: TStrMap; const Locale: string;
  Rng: TSpRng; Resolver: TSpIncludeResolver; MaxDepth: Integer;
  Stack: TStringList): string; forward;

{ The reference's resolveIncludes, run over RENDERED text: every #include line becomes the
  child's OUTPUT, so a `{`, `|` or `%` the child produced is never re-parsed by the parent
  -- it is already output. Cycles are keyed on the ref STRING (this engine has no template
  identity beyond it), so two aliases of one template are not a cycle and unwind until the
  depth cap; cycle, cap and unknown target all resolve to '' the same lenient way.

  Scanning continues AFTER a match, like String.replace with /g -- never into what was just
  inserted, since the child resolved its own includes. Matches can end past their own line
  (spec §5.1), which is why the walk advances by match end rather than by line. }
function ResolveIncludes(const text: string; RuntimeVars: TStrMap; const Locale: string;
  Rng: TSpRng; Resolver: TSpIncludeResolver; MaxDepth: Integer; Stack: TStringList): string;
var n, pos_, lineStart, termLen, matchEnd, refStart, refEnd: Integer;
    ref, childSrc, child: string;
begin
  Result := '';
  n := Length(text);
  pos_ := 1;
  lineStart := 1;
  while lineStart <= n do
  begin
    if MatchIncludeAt(text, lineStart, ref, refStart, refEnd, matchEnd) then
    begin
      if HasExact(Stack, ref) or (Stack.Count >= MaxDepth) then
        child := ''
      else if not Resolver.Resolve(ref, childSrc) then
        child := ''
      else
      begin
        Stack.Add(ref);
        try
          child := RenderDocument(childSrc, RuntimeVars, Locale, Rng, Resolver, MaxDepth, Stack);
        finally
          Stack.Delete(Stack.Count - 1);
        end;
      end;
      Result := Result + Copy(text, pos_, lineStart - pos_) + child;
      pos_ := matchEnd;
      lineStart := matchEnd;
    end
    else
      lineStart := NextLineBreak(text, lineStart, termLen);
    { lineStart now sits on a terminator or one past the end -- the match end is a $ by
      construction, and so is a line break. Step over it to reach the next ^. }
    termLen := LineBreakLen(text, lineStart);
    if termLen = 0 then Break;
    Inc(lineStart, termLen);
  end;
  Result := Result + Copy(text, pos_, n - pos_ + 1);
end;

function RenderDocument(const Template: string; RuntimeVars: TStrMap; const Locale: string;
  Rng: TSpRng; Resolver: TSpIncludeResolver; MaxDepth: Integer; Stack: TStringList): string;
var setDefs, defDefs, vars, aliases: TStrMap;
    body: string;
    nodes, dn: TNodeList;
    opts: TRenderOpts;
    pair: TPair<string, string>;
    outranked, defOrder: TStringList;
    oi: Integer;
begin
  setDefs := TStrMap.Create;
  defDefs := TStrMap.Create;
  vars := TStrMap.Create;
  outranked := TStringList.Create;
  try
    ExtractDirectives(StripComments(SpStripSentinels(Template)), setDefs, defDefs, body);

    // buildVars: setDefs raw, then runtime context overlays (lower-cased)
    for pair in setDefs do vars.AddOrSetValue(pair.Key, pair.Value);
    if Assigned(RuntimeVars) then
      for pair in RuntimeVars do
      begin
        vars.AddOrSetValue(LowerAscii(pair.Key), pair.Value);
        outranked.Add(LowerAscii(pair.Key));
      end;

    opts.Vars := vars;
    opts.Locale := Locale;
    opts.Depth := 0;
    opts.Rng := Rng;

    // Roll each #def once, DEPENDENCIES FIRST; a runtime var of the same name
    // outranks it (never rolled). The order must not come from hash enumeration —
    // see OrderDefinitions above.
    if defDefs.Count > 0 then
    begin
      // Aliases = every macro value a definition can see, minus the definitions
      // that will actually be rolled: a #def shadows a same-named #set, and hopping
      // through the shadowed value computes the wrong graph. One the runtime
      // outranks stays, because it is never rolled and its value is what really
      // gets substituted.
      aliases := TStrMap.Create;
      try
        for pair in vars do
          if not (defDefs.ContainsKey(pair.Key) and (outranked.IndexOf(pair.Key) < 0)) then
            aliases.AddOrSetValue(pair.Key, pair.Value);

        defOrder := OrderDefinitions(defDefs, aliases);
        try
          for oi := 0 to defOrder.Count - 1 do
          begin
            if outranked.IndexOf(defOrder[oi]) >= 0 then Continue;
            dn := ParseSequence(defDefs[defOrder[oi]]);
            try
              vars.AddOrSetValue(defOrder[oi], RenderNodes(dn, opts));
            finally
              dn.Free;
            end;
          end;
        finally
          defOrder.Free;
        end;
      finally
        aliases.Free;
      end;
    end;

    nodes := ParseSequence(body);
    try
      Result := RenderNodes(nodes, opts);
    finally
      nodes.Free;
    end;

    if Resolver <> nil then
      Result := ResolveIncludes(Result, RuntimeVars, Locale, Rng, Resolver, MaxDepth, Stack);
  finally
    setDefs.Free; defDefs.Free; vars.Free; outranked.Free;
  end;
end;

function SpRender(const Template: string; const Ctx: TSpContext): string;
var ownedRng: TSpRng; rng: TSpRng; stack: TStringList; depth: Integer; outp: string;
begin
  { Owned only when the caller supplied none; the caller's own Rng is never freed here. }
  if Ctx.Rng = nil then ownedRng := MakeDefaultRng else ownedRng := nil;
  stack := TStringList.Create;
  try
    if ownedRng <> nil then rng := ownedRng else rng := Ctx.Rng;
    depth := Ctx.MaxIncludeDepth;
    if depth <= 0 then depth := SP_DEFAULT_INCLUDE_DEPTH;

    outp := RenderDocument(Template, Ctx.Vars, Ctx.Locale, rng,
                           Ctx.IncludeResolver, depth, stack);

    { Once, over the whole assembled document -- parent and every child it pulled in. The
      cosmetic pipeline therefore sees across the seam, and a sentinel a child emitted is
      restored here rather than inside it. }
    if Ctx.PostProcess then outp := FullPostProcess(outp);
    Result := SpSafetyRestore(outp);
  finally
    stack.Free; ownedRng.Free;
  end;
end;

{ ─── extract ─────────────────────────────────────────────────────────────── }

function SpExtract(const Src: string): TExtractResult;
var text, line, kind, nm, val, ref: string;
    i, p, q, r, lineStart, e, n, termLen: Integer;
    seenSets, seenDefs, seenRefs, seenCond, seenIncs: TDictionary<string, Boolean>;
    condRefs: TStringList;
begin
  text := StripComments(Src);
  Result.Refs := TStringList.Create;
  Result.Sets := TStringList.Create;
  Result.Defs := TStringList.Create;
  Result.Includes := TStringList.Create;

  seenSets := TDictionary<string, Boolean>.Create;
  seenDefs := TDictionary<string, Boolean>.Create;
  seenRefs := TDictionary<string, Boolean>.Create;
  seenCond := TDictionary<string, Boolean>.Create;
  seenIncs := TDictionary<string, Boolean>.Create;
  { Conditional refs are collected apart, deduplicated among THEMSELVES, and filtered
    against the direct refs only at the end. That is what two passes over the whole document
    produced: every %var% in source order, then the {?name? names that were not already
    there. Sharing one membership set between the two scans looks equivalent and is not -- a
    name written `{?x?` early and `%x%` later would be claimed by the conditional scan and
    move to the tail. Caught by a before/after dump over 4 000 templates. }
  condRefs := TStringList.Create;
  try
    { Includes keep their own scan. It has to resume at the match end (a match may swallow
      line starts), and the reference removes only the #set/#def LHS before collecting refs
      -- never an include line -- so the ref scan below must still see every line. }
    n := Length(text); lineStart := 1;
    while lineStart <= n + 1 do
    begin
      e := NextLineBreak(text, lineStart, termLen);
      if MatchIncludeAt(text, lineStart, ref, p, q, r) then
      begin
        AddUniqueOrdered(Result.Includes, seenIncs, ref);
        ResumeAfterInclude(text, r, e, termLen);
      end;
      if e > n then Break;
      lineStart := e + termLen;
    end;

    { Directive names and references in one pass. The refs used to be scanned over a body
      rebuilt line by line with `body := body + …`, which copies the accumulator every time
      -- O(document^2), and a whole extra copy of the text. Scanning each line where it
      lies is the same answer: neither `%name%` nor `{?name?` can span the #10 that joined
      those lines (a terminator is not a word character, and `{` and `?` had one between
      them), and the `=` the old code prefixed to a directive value was inert for both. }
    lineStart := 1;
    while lineStart <= n + 1 do
    begin
      e := NextLineBreak(text, lineStart, termLen);
      line := Copy(text, lineStart, e - lineStart);
      if TryParseDirective(line, kind, nm, val) then
      begin
        if kind = 'set' then AddUniqueOrdered(Result.Sets, seenSets, nm)
        else AddUniqueOrdered(Result.Defs, seenDefs, nm);
        { the VALUE is body, the LHS is not -- a definition's own name is not a reference }
        DirectReferences(val, Result.Refs, seenRefs);
        ConditionalReferences(val, condRefs, seenCond);
      end
      else
      begin
        DirectReferences(line, Result.Refs, seenRefs);
        ConditionalReferences(line, condRefs, seenCond);
      end;
      if e > n then Break;
      lineStart := e + termLen;
    end;
    for i := 0 to condRefs.Count - 1 do
      AddUniqueOrdered(Result.Refs, seenRefs, condRefs[i]);
  finally
    seenSets.Free; seenDefs.Free; seenRefs.Free; seenCond.Free; seenIncs.Free;
    condRefs.Free;
  end;
end;

{ Kept for the validator, which collects one kind at a time. }
procedure CollectDirectiveNames(const text, directive: string; target: TStringList);
var lineStart, e, n, termLen: Integer; line, kind, nm, val: string;
    seen: TDictionary<string, Boolean>;
begin
  seen := TDictionary<string, Boolean>.Create;
  try
    n := Length(text); lineStart := 1;
    while lineStart <= n + 1 do
    begin
      e := NextLineBreak(text, lineStart, termLen);
      line := Copy(text, lineStart, e - lineStart);
      if TryParseDirective(line, kind, nm, val) and (kind = directive) then
        AddUniqueOrdered(target, seen, nm);
      if e > n then Break;
      lineStart := e + termLen;
    end;
  finally
    seen.Free;
  end;
end;

{ ─── validate ───────────────────────────────────────────────────────────── }

function SpStartsWith(const s, p: string): Boolean;
begin
  Result := (Length(s) >= Length(p)) and (Copy(s, 1, Length(p)) = p);
end;

{ Editor coordinates for a 1-based source offset: line by \n / \r\n / \r, column in
  CODE POINTS from the line start (SpCodePointAt steps one code point whatever the string
  width, so the column matches under FPC and a UTF-16 compiler). offset <= 0 -> 0/0.

  The walk itself lives in CursorLineCol below, because a scan that reports MANY positions
  must not start over at offset 1 for each one: this one is O(offset), so N of them over a
  document cost O(N x length) -- measured at 628 ms for 400 directives sitting at the END of
  a 124 KB document against 32 ms for the same 400 at its start, the same document either
  way, and 7.8 ms either way once the walk resumes. One loop with two entry points rather
  than a resumable copy of it: two line models that can drift apart is exactly the bug this
  file already paid for once with its five line terminators. }
type
  { Where a source walk stopped: a 1-based offset and the coordinates AT that offset. }
  TSourceCursor = record
    Off, Line, Col: Integer;
  end;

procedure InitSourceCursor(out cur: TSourceCursor);
begin
  cur.Off := 1; cur.Line := 1; cur.Col := 1;
end;

{ Coordinates for offset, resumed from cur and leaving cur there, so a forward scan pays for
  one pass over the source in total. Offsets normally arrive NON-DECREASING -- line starts
  and the surviving characters they map to do not move backwards -- and then this costs one
  walk for the whole document. A smaller offset restarts the walk rather than answering from
  a state already past it: SpExtractDirectives can ask for one, because an #include whose
  whitespace class swallowed a terminator ends BEYOND its own line and the next line start
  then sits behind it. Correct either way; only that document pays for the extra pass. }
procedure CursorLineCol(const text: string; var cur: TSourceCursor; offset: Integer;
  out line, col: Integer);
var n, cpLen: Integer;
begin
  if offset <= 0 then begin line := 0; col := 0; Exit; end;
  if offset < cur.Off then InitSourceCursor(cur);
  n := Length(text);
  while (cur.Off < offset) and (cur.Off <= n) do
  begin
    if text[cur.Off] = #13 then
    begin
      if (cur.Off < n) and (text[cur.Off + 1] = #10) then Inc(cur.Off, 2) else Inc(cur.Off);
      Inc(cur.Line); cur.Col := 1;
    end
    else if text[cur.Off] = #10 then
    begin
      Inc(cur.Off); Inc(cur.Line); cur.Col := 1;
    end
    else
    begin
      SpCodePointAt(text, cur.Off, cpLen);
      Inc(cur.Off, cpLen); Inc(cur.Col);
    end;
  end;
  line := cur.Line; col := cur.Col;
end;

procedure SourceLineCol(const text: string; offset: Integer; out line, col: Integer);
var cur: TSourceCursor;
begin
  InitSourceCursor(cur);
  CursorLineCol(text, cur, offset, line, col);
end;

{ Map an INCLUSIVE 1-based stripped offset (a span start) to its source offset. off past the
  end maps to one past the source; off <= 0 stays 0 (unknown). }
function MapStart(map: TList<Integer>; off, srcLen: Integer): Integer;
begin
  if off <= 0 then Exit(0);
  if off <= map.Count then Exit(map[off - 1]);
  Exit(srcLen + 1);
end;

{ Map an EXCLUSIVE 1-based stripped offset (a span end -- one past the last included char) to
  the source position just AFTER the last included character. Mapping it like a start would
  return the next SURVIVING char, which after a comment sits beyond it -- so `%x%/# c #/` would
  stretch the span across the comment. Instead take the last included char's source offset and
  step one code point (not one code unit -- the token may end on a multi-byte char). }
function MapEnd(const src: string; map: TList<Integer>; off, srcLen: Integer): Integer;
var last, srcOff, cpLen: Integer;
begin
  if off <= 1 then Exit(MapStart(map, off, srcLen));
  last := off - 1;                    // stripped position of the last included char
  if last > map.Count then last := map.Count;
  if last < 1 then Exit(MapStart(map, off, srcLen));
  srcOff := map[last - 1];
  cpLen := 1;
  if (srcOff >= 1) and (srcOff <= srcLen) then SpCodePointAt(src, srcOff, cpLen);
  Exit(srcOff + cpLen);
end;

{ Add a diagnostic, located at a STRIPPED-text offset (1-based) that is mapped back to the
  original src through map. startOff = 0 means the position is unknown and yields
  Line/Column = 0, the honest answer for a finding that cannot be cheaply and safely located.
  endOff = 0 leaves the span empty; endOff > 0 fills End* from it. Every finding goes through
  here -- Code and Severity are the contract, the positions are best-effort on top, and
  because detection still runs on the stripped text nothing about the verdict changes. }
{ The same call, for a pass that emits diagnostics in SOURCE ORDER: the walk that turns an
  offset into line/column resumes from the previous one instead of starting over. One
  diagnostic costs O(offset) otherwise, so a document that raises one per reference costs
  O(document x diagnostics) -- 6400 undefined variables measured 6.4 s, nearly all of it
  here. Offsets must be non-decreasing; CursorLineCol restarts the walk if they are not, so
  a caller that gets it wrong is slow rather than wrong. }
procedure AddDiagAtOrdered(list: TSpDiagList; const code, sev: string; const src: string;
  map: TList<Integer>; startOff, endOff: Integer; var cur: TSourceCursor);
var d: TSpDiag; sl: Integer;
begin
  d.Code := code; d.Severity := sev; sl := Length(src);
  CursorLineCol(src, cur, MapStart(map, startOff, sl), d.Line, d.Column);
  if endOff > 0 then
    CursorLineCol(src, cur, MapEnd(src, map, endOff, sl), d.EndLine, d.EndColumn)
  else begin d.EndLine := 0; d.EndColumn := 0; end;
  list.Add(d);
end;

procedure AddDiagAt(list: TSpDiagList; const code, sev: string; const src: string;
  map: TList<Integer>; startOff, endOff: Integer);
var d: TSpDiag; sl: Integer;
begin
  d.Code := code; d.Severity := sev; sl := Length(src);
  SourceLineCol(src, MapStart(map, startOff, sl), d.Line, d.Column);
  if endOff > 0 then SourceLineCol(src, MapEnd(src, map, endOff, sl), d.EndLine, d.EndColumn)
  else begin d.EndLine := 0; d.EndColumn := 0; end;
  list.Add(d);
end;

{ Public. It sits down here, away from SpExtract, because it reports ORIGINAL-source
  coordinates: that needs the strip map and the two mappers just above. The scan itself is
  the renderer's own -- TryParseDirective for #set/#def, and for #include MatchIncludeAt, the
  one copy of the family's line anchor that SpExtract and SpValidate also call -- run over
  the comment-stripped text, so what is reported is exactly what the renderer consumes.
  Deliberately NOT deduplicated: telling two occurrences of one target apart is the whole
  reason a host cannot work from SpExtract's list. }
function SpExtractDirectives(const Src: string): TSpDirectiveList;
var map: TList<Integer>;
    text, line, kind, nm, val: string;
    n, srcLen, lineStart, e, termLen, p, q, r, spanEnd: Integer;
    found: Boolean;
    d: TSpDirective;
    cur: TSourceCursor;
begin
  Result := TSpDirectiveList.Create;
  map := TList<Integer>.Create;
  try
    text := StripComments(Src, map);
    srcLen := Length(Src);
    n := Length(text);
    { One cursor for the whole document: the spans come out in source order, so the walk
      that turns offsets into line/column never has to go back. }
    InitSourceCursor(cur);
    lineStart := 1;
    while lineStart <= n + 1 do
    begin
      e := NextLineBreak(text, lineStart, termLen);
      line := Copy(text, lineStart, e - lineStart);
      found := TryParseDirective(line, kind, nm, val);
      { An #include match starts at the line start (its own ^[ \t]* is part of it) and, for a
        one-line include, ends where the line does -- so the span stays the line's. It can
        also run PAST the line, because the rule's whitespace class holds terminators; then
        the span is the match, which is what a host has to replace. }
      spanEnd := e;
      if not found then
        if MatchIncludeAt(text, lineStart, nm, p, q, r) then
        begin
          kind := 'include';
          val := '';
          spanEnd := r;
          { The trailing whitespace class holds CR, so a CRLF-terminated include line ends
            its match BETWEEN the CR and the LF -- a position the editor line model has no
            coordinate for, and one that puts the line's own terminator inside the span.
            Both Text and the span exclude terminators (see TSpDirective), and a host
            replacing the span must not swallow the line break, so give the CR back. }
          if (spanEnd > lineStart) and (text[spanEnd - 1] = #13) then Dec(spanEnd);
          found := True;
          { ...but the SCAN carries on from the real match end. }
          ResumeAfterInclude(text, r, e, termLen);
        end;
      if found then
      begin
        d.Kind := kind;
        d.Name := nm;
        d.Value := val;
        d.Text := Copy(text, lineStart, spanEnd - lineStart);
        CursorLineCol(Src, cur, MapStart(map, lineStart, srcLen), d.Line, d.Column);
        CursorLineCol(Src, cur, MapEnd(Src, map, spanEnd, srcLen), d.EndLine, d.EndColumn);
        Result.Add(d);
      end;
      if e > n then Break;
      lineStart := e + termLen;
    end;
  finally
    map.Free;
  end;
end;

{ '[' anywhere, or '{' not followed by '?' — spintax still unresolved when plurals run. }
function UnresolvedAtPluralTime(const v: string): Boolean;
var i: Integer;
begin
  for i := 1 to Length(v) do
  begin
    if v[i] = '[' then Exit(True);
    if v[i] = '{' then
      if (i = Length(v)) or (v[i+1] <> '?') then Exit(True);
  end;
  Result := False;
end;

{ Collect well-formed #set/#def occurrences in source order (parallel lists). The overload
  also records, per occurrence, the source offset of the line's '#' -- the anchor for the
  diagnostics that reference these occurrences. Pass poss = nil when positions are not wanted. }
procedure CollectOccurrences(const text: string; kinds, names, values: TStringList;
  poss: TList<Integer>); overload;
var lineStart, e, n, termLen: Integer; line, kind, nm, val: string;
begin
  n := Length(text); lineStart := 1;
  while lineStart <= n + 1 do
  begin
    e := NextLineBreak(text, lineStart, termLen);
    line := Copy(text, lineStart, e - lineStart);
    if TryParseDirective(line, kind, nm, val) then
    begin
      kinds.Add(kind); names.Add(nm); values.Add(val);
      if poss <> nil then
        poss.Add(lineStart + (Length(line) - Length(PhpLtrim(line))));
    end;
    if e > n then Break;
    lineStart := e + termLen;
  end;
end;

procedure CollectOccurrences(const text: string; kinds, names, values: TStringList); overload;
begin
  CollectOccurrences(text, kinds, names, values, nil);
end;

{ Brace-aware scan for plural blocks (finds them inside permutations too). The overload
  also records, per block, the source offset of its '{plural ' start -- the anchor for the
  plural diagnostics. Pass starts = nil when positions are not wanted. }
procedure FindPluralBlocks(const text: string; counts, forms: TStringList;
  starts: TList<Integer>); overload;
const PREFIX = '{plural ';
var i, start, j, depth, colon: Integer; inner: string;
begin
  i := 1;
  while i <= Length(text) do
  begin
    start := PosEx(PREFIX, text, i);
    if start = 0 then Break;
    depth := 1; j := start + Length(PREFIX);
    while j <= Length(text) do
    begin
      if text[j] = '{' then Inc(depth)
      else if text[j] = '}' then begin Dec(depth); if depth = 0 then Break; end;
      Inc(j);
    end;
    if depth <> 0 then begin i := start + Length(PREFIX); Continue; end;
    inner := Copy(text, start + Length(PREFIX), j - (start + Length(PREFIX)));
    colon := Pos(':', inner);
    if colon = 0 then begin i := j + 1; Continue; end;
    counts.Add(Copy(inner, 1, colon - 1));
    forms.Add(Copy(inner, colon + 1, MaxInt));
    if starts <> nil then starts.Add(start);
    i := j + 1;
  end;
end;

procedure FindPluralBlocks(const text: string; counts, forms: TStringList); overload;
begin
  FindPluralBlocks(text, counts, forms, nil);
end;

{ Set-macro names whose value is unresolved-at-plural-time, propagated through %refs%. }
procedure BuildMacroTaint(kinds, names, values: TStringList; tainted: TStringList);
var i, k: Integer; grew: Boolean; refs: TStringList;
begin
  // seed: #set macros with a bracket/enum in the value
  for i := 0 to names.Count - 1 do
    if (kinds[i] = 'set') and UnresolvedAtPluralTime(values[i]) then
      if tainted.IndexOf(names[i]) < 0 then tainted.Add(names[i]);
  // propagate: a #set whose value references a tainted name becomes tainted
  grew := True;
  while grew do
  begin
    grew := False;
    for i := 0 to names.Count - 1 do
    begin
      if kinds[i] <> 'set' then Continue;
      if tainted.IndexOf(names[i]) >= 0 then Continue;
      refs := TStringList.Create;
      try
        DirectReferences(values[i], refs);
        for k := 0 to refs.Count - 1 do
          if tainted.IndexOf(refs[k]) >= 0 then
          begin
            tainted.Add(names[i]); grew := True; Break;
          end;
      finally
        refs.Free;
      end;
    end;
  end;
end;

procedure CheckBrackets(const text, src: string; map: TList<Integer>; res: TSpDiagList);
var stack: array of Char; spos: array of Integer; top, i: Integer; ch, opener: Char;
begin
  SetLength(stack, 0); SetLength(spos, 0); top := 0;
  for i := 1 to Length(text) do
  begin
    ch := text[i];
    if (ch = '{') or (ch = '[') then
    begin
      SetLength(stack, top + 1); SetLength(spos, top + 1);
      stack[top] := ch; spos[top] := i; Inc(top);
    end
    else if (ch = '}') or (ch = ']') then
    begin
      { brackets are ASCII, so one code unit -- the span is [i, i+1) }
      if top = 0 then AddDiagAt(res, 'bracket.unexpected-closing', 'error', src, map, i, i + 1)
      else
      begin
        opener := stack[top - 1]; Dec(top);
        if ((opener = '{') and (ch <> '}')) or ((opener = '[') and (ch <> ']')) then
          AddDiagAt(res, 'bracket.mismatched', 'error', src, map, i, i + 1);
      end;
    end;
  end;
  { each still-open bracket, at the position of the opener that was never closed }
  for i := 0 to top - 1 do
    AddDiagAt(res, 'bracket.unclosed', 'error', src, map, spos[i], spos[i] + 1);
end;

procedure CheckDirectivesV(const text, src: string; map: TList<Integer>; res: TSpDiagList);
var lineStart, e, n, i, p, termLen: Integer;
    line, t, kind, nm, val: string;
    isSet, isDef: Boolean;
    kinds, names, values: TStringList;
    seen: TDictionary<string, Boolean>;
    poss: TList<Integer>;
begin
  // malformed lines
  n := Length(text); lineStart := 1;
  while lineStart <= n + 1 do
  begin
    e := NextLineBreak(text, lineStart, termLen);
    line := Copy(text, lineStart, e - lineStart);
    t := PhpLtrim(line);
    isSet := SpStartsWith(t, '#set ') or SpStartsWith(t, '#set'#9);
    isDef := SpStartsWith(t, '#def ') or SpStartsWith(t, '#def'#9);
    if (isSet or isDef) and (not TryParseDirective(line, kind, nm, val)) then
    begin
      { point at the '#' (first non-space on the line); span = the 4-char keyword }
      p := lineStart + (Length(line) - Length(t));
      if isDef then AddDiagAt(res, 'def.malformed', 'error', src, map, p, p + 4)
      else AddDiagAt(res, 'set.malformed', 'error', src, map, p, p + 4);
    end;
    if e > n then Break;
    lineStart := e + termLen;
  end;

  // duplicate names + #include in a #def value
  kinds := TStringList.Create; names := TStringList.Create; values := TStringList.Create;
  { membership only -- the index this used to take from TStringList.IndexOf was never read,
    and the linear scan behind it cost O(names^2) on a directive-heavy document }
  seen := TDictionary<string, Boolean>.Create;
  poss := TList<Integer>.Create;
  try
    CollectOccurrences(text, kinds, names, values, poss);
    for i := 0 to names.Count - 1 do
    begin
      { duplicate is reported at the LATER occurrence -- poss[i] is that line's '#' }
      if seen.ContainsKey(names[i]) then
        AddDiagAt(res, 'definition.duplicate-name', 'error', src, map, poss[i], poss[i] + 4)
      else seen.Add(names[i], True);
      if kinds[i] = 'def' then
      begin
        p := Pos('#include', values[i]);
        if (p > 0) and ((p + 8 > Length(values[i])) or (not IsAsciiWord(values[i][p + 8]))) then
          AddDiagAt(res, 'def.include-in-value', 'error', src, map, poss[i], poss[i] + 4);
      end;
    end;
  finally
    kinds.Free; names.Free; values.Free; seen.Free; poss.Free;
  end;
end;

procedure CheckPermConfigsV(const text, src: string; map: TList<Integer>; res: TSpDiagList);
var i, p, q, k, b, b2: Integer; configStr, low, key, numv: string;
  function HasKeyEq(const s: string): Boolean;
  var a, b: Integer;
  begin
    Result := False; a := 1;
    while a <= Length(s) do
    begin
      if IsAsciiWord(s[a]) then
      begin
        b := a;
        while (b <= Length(s)) and IsAsciiWord(s[b]) do Inc(b);
        while (b <= Length(s)) and (CharInSet(s[b], [' ', #9])) do Inc(b);
        if (b <= Length(s)) and (s[b] = '=') then Exit(True);
        a := b;
      end
      else Inc(a);
    end;
  end;
  function DigitsOnly(const s: string): Boolean;
  var z: Integer;
  begin
    Result := s <> '';
    for z := 1 to Length(s) do if not (CharInSet(s[z], ['0'..'9'])) then Exit(False);
  end;
  function ExtractNum(const cfg, keyname: string): string;
  var kp, z: Integer; lc: string;
  begin
    Result := #1; // sentinel: key absent
    lc := LowerAscii(cfg);
    kp := Pos(keyname, lc);
    if kp = 0 then Exit;
    z := kp + Length(keyname);
    while (z <= Length(cfg)) and (CharInSet(cfg[z], [' ', #9])) do Inc(z);
    if (z <= Length(cfg)) and (cfg[z] = '=') then Inc(z) else Exit;
    while (z <= Length(cfg)) and (CharInSet(cfg[z], [' ', #9])) do Inc(z);
    Result := '';
    while (z <= Length(cfg)) and not (CharInSet(cfg[z], [';', '>', ' ', #9, #10, #13])) do
    begin Result := Result + cfg[z]; Inc(z); end;
  end;
begin
  i := 1;
  while True do
  begin
    p := PosEx('[<', text, i);
    if p = 0 then Break;
    q := PosEx('>', text, p + 2);
    if q = 0 then begin i := p + 2; Continue; end;
    configStr := Copy(text, p + 2, q - (p + 2));
    i := q + 1;
    if not HasKeyEq(configStr) then Continue;

    // unknown keys
    k := 1;
    while k <= Length(configStr) do
    begin
      if IsAsciiWord(configStr[k]) then
      begin
        b := k;
        while (b <= Length(configStr)) and IsAsciiWord(configStr[b]) do Inc(b);
        key := Copy(configStr, k, b - k);
        b2 := b;
        while (b2 <= Length(configStr)) and (CharInSet(configStr[b2], [' ', #9])) do Inc(b2);
        if (b2 <= Length(configStr)) and (configStr[b2] = '=') then
        begin
          low := LowerAscii(key);
          { key at configStr[k..b) maps to source text[p+1+k .. p+1+b) }
          if (low <> 'minsize') and (low <> 'maxsize') and (low <> 'sep') and (low <> 'lastsep') then
            AddDiagAt(res, 'permutation.unknown-key', 'error', src, map, p + 1 + k, p + 1 + b);
        end;
        k := b;
      end
      else Inc(k);
    end;

    { the offending value sits inside the config; anchor at the config open [<...> }
    numv := ExtractNum(configStr, 'minsize');
    if (numv <> #1) and (not DigitsOnly(numv)) then
      AddDiagAt(res, 'permutation.minsize-not-integer', 'error', src, map, p, q + 1);
    numv := ExtractNum(configStr, 'maxsize');
    if (numv <> #1) and (not DigitsOnly(numv)) then
      AddDiagAt(res, 'permutation.maxsize-not-integer', 'error', src, map, p, q + 1);
  end;
end;

procedure CheckPluralsV(const text, src, locale: string; map: TList<Integer>; res: TSpDiagList);
var base: string; arity, i, k, cnt, m: Integer;
    counts, forms, tainted, kinds, names, values, refs: TStringList;
    starts: TList<Integer>;
    hasBracket: Boolean;
begin
  base := '';
  if locale <> '' then base := NormalizeBaseLang(locale);
  if base <> '' then arity := PluralArity(base) else arity := 0;

  kinds := TStringList.Create; names := TStringList.Create; values := TStringList.Create;
  tainted := TStringList.Create;
  counts := TStringList.Create; forms := TStringList.Create;
  starts := TList<Integer>.Create;
  try
    CollectOccurrences(text, kinds, names, values);
    BuildMacroTaint(kinds, names, values, tainted);
    FindPluralBlocks(text, counts, forms, starts);

    for i := 0 to counts.Count - 1 do
    begin
      { every plural diagnostic anchors at the block's '{plural ' (8-char prefix span) }
      // count-macro: a tainted #set name referenced in the count slot
      refs := TStringList.Create;
      try
        DirectReferences(counts[i], refs);
        for k := 0 to refs.Count - 1 do
          if tainted.IndexOf(refs[k]) >= 0 then
          begin
            AddDiagAt(res, 'plural.count-macro', 'error', src, map, starts[i], starts[i] + 8); Break;
          end;
      finally
        refs.Free;
      end;

      hasBracket := False;
      for m := 1 to Length(forms[i]) do
        if CharInSet(forms[i][m], ['{', '}', '[', ']']) then begin hasBracket := True; Break; end;
      if hasBracket then
      begin
        AddDiagAt(res, 'plural.nested-brackets', 'error', src, map, starts[i], starts[i] + 8);
        Continue;
      end;

      if arity > 0 then
      begin
        cnt := 1;
        for m := 1 to Length(forms[i]) do if forms[i][m] = '|' then Inc(cnt);
        if cnt <> arity then
          AddDiagAt(res, 'plural.arity', 'error', src, map, starts[i], starts[i] + 8);
      end;
    end;
  finally
    kinds.Free; names.Free; values.Free; tainted.Free; counts.Free; forms.Free; starts.Free;
  end;
end;

procedure DetectCycleV(const current: string; defNames, defValues: TStringList;
  visited: TStringList; res: TSpDiagList; var reported: Boolean;
  const src: string; map: TList<Integer>; anchor: Integer);
var idx, k: Integer; refs: TStringList; ref: string;
begin
  if reported then Exit;
  idx := defNames.IndexOf(current);
  if idx < 0 then Exit;
  refs := TStringList.Create;
  try
    DirectReferences(defValues[idx], refs);
    for k := 0 to refs.Count - 1 do
    begin
      ref := refs[k];
      if ref = current then Continue;
      if visited.IndexOf(ref) >= 0 then
      begin
        AddDiagAt(res, 'variable.circular-reference', 'error', src, map, anchor, anchor + 4);
        reported := True; Exit;
      end;
      if defNames.IndexOf(ref) >= 0 then
      begin
        visited.Add(ref);
        DetectCycleV(ref, defNames, defValues, visited, res, reported, src, map, anchor);
        visited.Delete(visited.Count - 1);
        if reported then Exit;
      end;
    end;
  finally
    refs.Free;
  end;
end;

procedure CheckVariableRefsV(const text, src: string; map: TList<Integer>;
  KnownIncludes: TStringList; res: TSpDiagList);
var kinds, defNames, defValues, visited: TStringList; i: Integer; reported: Boolean;
    poss: TList<Integer>;
begin
  kinds := TStringList.Create; defNames := TStringList.Create; defValues := TStringList.Create;
  poss := TList<Integer>.Create;
  try
    CollectOccurrences(text, kinds, defNames, defValues, poss);
    // self-reference -- at the offending #set/#def line
    for i := 0 to defNames.Count - 1 do
      if Pos('%' + defNames[i] + '%', LowerAscii(defValues[i])) > 0 then
        AddDiagAt(res, 'variable.self-reference', 'error', src, map, poss[i], poss[i] + 4);
    // circular -- anchored at the definition that starts the detected cycle
    for i := 0 to defNames.Count - 1 do
    begin
      reported := False;
      visited := TStringList.Create;
      try
        visited.Add(defNames[i]);
        DetectCycleV(defNames[i], defNames, defValues, visited, res, reported,
                     src, map, poss[i]);
      finally
        visited.Free;
      end;
    end;
    // (undefined-variable warnings are emitted in SpValidate against the body scan)
  finally
    kinds.Free; defNames.Free; defValues.Free; poss.Free;
  end;
end;

function SpValidate(const Src, Locale: string; KnownIncludes: TStringList): TSpDiagList;
begin
  Result := SpValidate(Src, Locale, KnownIncludes, nil);
end;

function SpValidate(const Src, Locale: string;
  KnownIncludes, KnownVariables: TStringList): TSpDiagList;
var text, line, kind, nm, val, ref: string;
    lineStart, e, n, p, q, r, i, j, termLen: Integer;
    kinds, defNames, defValues: TStringList;
    defSet, undefSet: TDictionary<string, Boolean>;
    smap: TList<Integer>;
    cur: TSourceCursor;
begin
  Result := TSpDiagList.Create;
  { smap[k] = source offset of stripped char k+1, so every diagnostic found in the stripped
    text is reported at true source coordinates -- comments drop characters AND the newlines
    inside them. Detection runs on the same stripped text as before, so verdicts are unchanged. }
  smap := TList<Integer>.Create;
  text := StripComments(Src, smap);

  CheckBrackets(text, Src, smap, Result);
  CheckDirectivesV(text, Src, smap, Result);
  CheckPermConfigsV(text, Src, smap, Result);
  CheckPluralsV(text, Src, Locale, smap, Result);
  CheckVariableRefsV(text, Src, smap, KnownIncludes, Result);

  // include.unknown-target (only when a slug list is supplied)
  if (KnownIncludes <> nil) and (KnownIncludes.Count > 0) then
  begin
    n := Length(text); lineStart := 1;
    while lineStart <= n + 1 do
    begin
      e := NextLineBreak(text, lineStart, termLen);
      { the diagnostic points at the slug between the quotes, not at the whole line }
      if MatchIncludeAt(text, lineStart, ref, p, q, r) then
      begin
        if not HasExact(KnownIncludes, ref) then
          AddDiagAt(Result, 'include.unknown-target', 'error', Src, smap, p, q);
        ResumeAfterInclude(text, r, e, termLen);
      end;
      if e > n then Break;
      lineStart := e + termLen;
    end;
  end;

  // undefined-variable warnings: scan body (directive lines dropped), skip defined names
  kinds := TStringList.Create; defNames := TStringList.Create; defValues := TStringList.Create;
  defSet := TDictionary<string, Boolean>.Create;
  undefSet := TDictionary<string, Boolean>.Create;
  try
    CollectOccurrences(text, kinds, defNames, defValues);
    for i := 0 to defNames.Count - 1 do defSet.AddOrSetValue(defNames[i], True);
    // A host-declared variable counts as defined for this check, so seeding it suppresses
    // the warning at both reference sites below without duplicating the test. Names are
    // compared lower-cased, like every other variable name in the engine.
    if KnownVariables <> nil then
      for i := 0 to KnownVariables.Count - 1 do
        defSet.AddOrSetValue(LowerAscii(KnownVariables[i]), True);
    { No body is rebuilt for this. It used to be assembled line by line with
      `body := body + line` -- O(document^2), measured 20 s on 6400 references -- alongside a
      per-character map back to the source. Both existed only to turn a body offset into a
      source offset, and a line already knows where it starts: the ref at line offset j sits
      at lineStart + j - 1. A directive line contributes nothing, exactly as before, which is
      the difference from SpExtract (there the VALUE is body; here the line is dropped whole).

      Still two passes over the lines, not one: the %var% sweep used to run over the whole
      body before the {?name? sweep, and a name seen by both is reported once, at the FIRST
      site. Interleaving them per line would move that report to the other syntax and reorder
      the diagnostics. Two linear passes cost what one does, asymptotically. }
    n := Length(text);
    lineStart := 1;
    InitSourceCursor(cur);
    while lineStart <= n + 1 do
    begin
      e := NextLineBreak(text, lineStart, termLen);
      line := Copy(text, lineStart, e - lineStart);
      if not TryParseDirective(line, kind, nm, val) then
      begin
        i := 1;
        while i <= Length(line) do
        begin
          if line[i] = '%' then
          begin
            j := i + 1; nm := '';
            while (j <= Length(line)) and IsAsciiWord(line[j]) do
            begin nm := nm + line[j]; Inc(j); end;
            if (nm <> '') and (j <= Length(line)) and (line[j] = '%') then
            begin
              nm := LowerAscii(nm);
              if not defSet.ContainsKey(nm) and not undefSet.ContainsKey(nm) then
              begin
                undefSet.Add(nm, True);
                AddDiagAtOrdered(Result, 'variable.undefined', 'warning', Src, smap,
                                 lineStart + i - 1, lineStart + j - 1 + 1, cur);
              end;
              i := j + 1; Continue;
            end;
          end;
          Inc(i);
        end;
      end;
      if e > n then Break;
      lineStart := e + termLen;
    end;
    { {?name? / {?!name? refs -- span the conditional head {?..name..? }
    lineStart := 1;
    InitSourceCursor(cur);
    while lineStart <= n + 1 do
    begin
      e := NextLineBreak(text, lineStart, termLen);
      line := Copy(text, lineStart, e - lineStart);
      if not TryParseDirective(line, kind, nm, val) then
      begin
        i := 1;
        while i <= Length(line) do
        begin
          if (i + 1 <= Length(line)) and (line[i] = '{') and (line[i+1] = '?') then
          begin
            j := i + 2;
            if (j <= Length(line)) and (line[j] = '!') then Inc(j);
            nm := '';
            if (j <= Length(line)) and (CharInSet(line[j], ['A'..'Z','a'..'z','_'])) then
            begin
              nm := nm + line[j]; Inc(j);
              while (j <= Length(line)) and IsAsciiWord(line[j]) do
              begin nm := nm + line[j]; Inc(j); end;
              if (j <= Length(line)) and (line[j] = '?') then
              begin
                nm := LowerAscii(nm);
                if not defSet.ContainsKey(nm) and not undefSet.ContainsKey(nm) then
                begin
                  undefSet.Add(nm, True);
                  AddDiagAtOrdered(Result, 'variable.undefined', 'warning', Src, smap,
                                   lineStart + i - 1, lineStart + j - 1 + 1, cur);
                end;
              end;
            end;
          end;
          Inc(i);
        end;
      end;
      if e > n then Break;
      lineStart := e + termLen;
    end;
  finally
    kinds.Free; defNames.Free; defValues.Free; defSet.Free; undefSet.Free;
  end;
  smap.Free;
end;

initialization
  { Delphi requires an initialization section before a finalization one; FPC does not.
    The abbreviation list is still built lazily -- this exists only to make the pair legal. }

finalization
  GAbbrevs.Free;

end.
