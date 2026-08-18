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
{ A template parsed once and rendered many times.

  SpRender parses on every call, and parsing is where the time goes: phase timing puts
  rendering at 3% of a render and building plus destroying the node tree at 84% of an
  article. A host that renders one template repeatedly -- a content tool spinning the same
  message thousands of times -- pays that on every one.

  The state is opaque on purpose: the node tree is the engine's own, and exposing it would
  make an internal representation part of the contract. Compile once, render as often as
  you like, free when done; every choice is still made per render, and a compiled template
  produces exactly what SpRender produces from the same source. }
type
  { Raised only on programmer error -- a handle that was never produced by SpCompile --
    never on template content. That is the reference's rule for its own error type: a
    template, however malformed, is a diagnostic and not an exception. }
  ESpintax = class(Exception);

  TSpTemplate = class
  private
    FImpl: TObject;
  public
    { Takes the template, and hides TObject's argument-less constructor deliberately: a
      bare `TSpTemplate.Create` would leave the state nil, and a render through that handle
      returned an empty string with no complaint. Now it does not compile. SpCompile is the
      same thing spelled as a function. }
    constructor Create(const Template: string); reintroduce;
    destructor Destroy; override;
  end;

function SpCompile(const Template: string): TSpTemplate;
function SpRenderCompiled(Tmpl: TSpTemplate; const Ctx: TSpContext): string;

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

  { How many code units variable expansion may INSERT over one SpRender call.

    Without it a 62-character template kills the process, and it always has --
    `#set %a% = %b% %b%` over `#set %b% = %a% %a%` doubles the text at every expansion, so
    the depth cap of 50 permits 2^50. Measured here: a plural naming %a% in its forms aborts with
    EOutOfMemory (an exception escaping SpRender, which spec sec.9.2 says never happens on
    content) and a bare reference to that pair runs past a minute. The cycle guard never fires, because an
    acyclic chain of doubling definitions does the same thing. Live in every engine of the
    family, filed as spintax-js#69 -- the render-side twin of the counting bomb.

    A budget on what expansion ADDS, not on template size: 62 bytes is the bomb and a 65 KB
    template is ordinary. Charged per substitution and checked BEFORE it happens, because
    one substitution can be the whole explosion. When it is gone a reference is left
    LITERAL, which is already this engine's answer for a name it does not know, so no new
    output shape enters the language: a plural whose count did not resolve erases exactly as
    it always has, and the host gets text rather than a crash.

    The exact truncated output is DELIBERATELY not parity-gated and no fixture carries it:
    the engines expand by different mechanisms -- a per-reference tree walk here and in the
    reference, a whole-text fixpoint in both PHP engines -- so they stop in different places
    on the same bomb, and making them agree would mean rewriting one engine's traversal for
    input nobody writes. The conformance README says so; each engine pins its own bound in
    its own suite instead. What IS the contract: render terminates, stays lenient, and
    leaves what it could not afford as a literal %name%. }
  SP_RENDER_EXPANSION_BUDGET = 1024 * 1024;
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

{ The FIRST code point of SpUpperCodePoint(cp), without building the string. Same two
  tables, same order, so it is that function's first character by construction.

  It exists for pre-filters: two code points can only fold-match if their uppercase
  strings are equal, which requires their first code points to be equal. Comparing
  these is therefore a necessary condition -- never rejects a real match, and the
  survivors still go through the full string comparison. }
function SpUpperFirstCp(cp: LongWord): LongWord;
var lo, hi, mid, i: Integer;
begin
  lo := 0; hi := UPPER_MULTI_COUNT - 1;
  while lo <= hi do
  begin
    mid := (lo + hi) div 2;
    if cp < UPPER_MULTI_CP[mid] then hi := mid - 1
    else if cp > UPPER_MULTI_CP[mid] then lo := mid + 1
    else
    begin
      { SpUpperCodePoint skips zero slots when it builds the string, so the first
        character is the first NON-zero entry, not necessarily slot 0. }
      for i := 0 to UPPER_MULTI_MAXLEN - 1 do
        if UPPER_MULTI_TO[mid * UPPER_MULTI_MAXLEN + i] <> 0 then
          Exit(UPPER_MULTI_TO[mid * UPPER_MULTI_MAXLEN + i]);
      Exit(cp);
    end;
  end;
  lo := 0; hi := UPPER_RUNS_COUNT - 1;
  while lo <= hi do
  begin
    mid := (lo + hi) div 2;
    if LongInt(cp) < UPPER_RUNS[mid * 3] then hi := mid - 1
    else if LongInt(cp) > UPPER_RUNS[mid * 3 + 1] then lo := mid + 1
    else Exit(LongWord(LongInt(cp) + UPPER_RUNS[mid * 3 + 2]));
  end;
  Result := cp;
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
var brace, bracket, i, start: Integer; ch: Char;
begin
  parts := TStringList.Create;
  brace := 0; bracket := 0; start := 1;
  for i := 1 to Length(inner) do
  begin
    ch := inner[i];
    if ch = '{' then Inc(brace)
    else if ch = '}' then Dec(brace)
    else if ch = '[' then Inc(bracket)
    else if ch = ']' then Dec(bracket);
    { Cut the option out in one Copy at the separator rather than growing it a
      character at a time -- the options of a real template are whole sentences, and
      appending to a string reallocates it on every character. }
    if (ch = '|') and (brace = 0) and (bracket = 0) then
    begin
      parts.Add(Copy(inner, start, i - start));
      start := i + 1;
    end;
  end;
  parts.Add(Copy(inner, start, Length(inner) - start + 1));
end;

{ First top-level '|' in text[from .. upto), a single counter clamped at 0; 0 if none.

  Ranged rather than taking the body as a string of its own, because the count-slot pass
  below walks SPANS of the template: copying the branch out at every level of nesting is
  what makes a deeply nested template quadratic, and that template arrives from a public
  Worker in the family's reference deployment. }
function FirstTopLevelPipe(const text: string; from, upto: Integer): Integer; overload;
var depth, j: Integer; ch: Char;
begin
  depth := 0;
  for j := from to upto - 1 do
  begin
    ch := text[j];
    if (ch = '{') or (ch = '[') then Inc(depth)
    else if (ch = '}') or (ch = ']') then
    begin
      if depth > 0 then Dec(depth);
    end
    else if (ch = '|') and (depth = 0) then Exit(j);
  end;
  Result := 0;
end;

function FirstTopLevelPipe(const body: string): Integer; overload;
begin
  Result := FirstTopLevelPipe(body, 1, Length(body) + 1);
end;

{ A recognized conditional -- `{?name?then|else` -- as OFFSETS into the string it was found
  in; no branch text is copied out. BodyStart is the first character past `?name?`, and
  SepIndex the top-level '|', or 0 when the branch stands alone. }
type
  TCondHead = record
    Name: string;
    Inverted: Boolean;
    BodyStart: Integer;
    SepIndex: Integer;
  end;

{ Recognize `?VAR?then|else` / `?!VAR?then` in text[contentStart .. contentEnd) -- the span
  between the braces, contentStart pointing at the leading '?' -- or False if malformed.

  THE one place the conditional grammar lives. The renderer needs the branches unparsed as
  well as parsed: the plural count slot resolves conditionals textually, without resolving
  the enumerations a branch may carry. A second copy of these rules is exactly how the
  family's #55-#57 syntax divergences happened, so TryParseConditional reads this too. }
function RecognizeConditional(const text: string; contentStart, contentEnd: Integer;
  out head: TCondHead): Boolean;
var p, s: Integer;
begin
  Result := False;
  head.Name := ''; head.Inverted := False; head.BodyStart := 0; head.SepIndex := 0;
  p := contentStart + 1; // past the leading '?'
  if (p <= Length(text)) and (text[p] = '!') then begin head.Inverted := True; Inc(p); end;

  if (p > Length(text)) or (not CharInSet(text[p], ['A'..'Z', 'a'..'z', '_'])) then Exit;
  s := p; Inc(p);
  while (p <= Length(text)) and IsAsciiWord(text[p]) do Inc(p);
  { the name may not run past the content: `{?ab` inside a span ending at 'a' is not a
    conditional, however the text continues outside the span }
  if p > contentEnd then Exit;
  head.Name := Copy(text, s, p - s);

  if (p > Length(text)) or (text[p] <> '?') then Exit; // required '?' after the name
  Inc(p);
  head.BodyStart := p;
  head.SepIndex := FirstTopLevelPipe(text, p, contentEnd);
  Result := True;
end;

{ ─── a growable buffer ───────────────────────────────────────────────────────
  `res := res + one character` reallocates and copies the whole accumulator on every
  append, which makes a single linear pass quadratic. It was first hit in the
  post-process, whose sixteen passes measured 0.11 s at 14 KB but 45 s at 950 KB.

  The fix was scoped to the post-process then, under a comment asserting that
  "concatenation elsewhere is not on a hot path". That was never measured, and it was
  wrong: SpStripSentinels, StripComments, ParseSequence's literal accumulator and
  SpSafetyRestore each walk the WHOLE document on EVERY render, character by character.
  They cost 15 ms on 64 KB carrying no spintax at all -- the price of doing nothing.
  Hence this buffer sits here, above every one of its users, rather than in the
  post-process. Verify before scoping a fix by where the bug was found. }
type
  TStrBuf = record
    Data: string;
    Len: Integer;
    procedure Init(capacity: Integer);
    procedure Reset;
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
  { Reset leaves the buffer with no storage at all, so the doubling has to start from
    something -- from zero it would never reach the requested size. }
  if cap < 16 then cap := 16;
  while cap < Len + needed do cap := cap * 2;
  SetLength(Data, cap);
end;

{ Drop what was accumulated WITHOUT reserving anything. The point is the buffer that is
  never written to again: a re-Init would allocate for a literal that may not come. }
procedure TStrBuf.Reset;
begin
  Data := '';
  Len := 0;
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

{ Index of the first sentinel, or 0 when the text carries none. Both readers below run
  on every render over the whole document, and a document with no sentinel in it -- the
  overwhelmingly common case -- then needs no buffer and no copy at all: the argument is
  returned as-is and only its reference count moves. }
function FirstSentinelIn(const s: string): Integer;
var i, k, adv: Integer;
begin
  for i := 1 to Length(s) do
    if SentinelAt(s, i, k, adv) then Exit(i);
  Result := 0;
end;

function SpNeutralize(const Value: string): string;
var buf: TStrBuf; i, k: Integer; ch: Char; found: Boolean;
begin
  buf.Init(Length(Value) + 16);
  for i := 1 to Length(Value) do
  begin
    ch := Value[i];
    found := False;
    for k := 0 to High(STRUCTURAL) do
      if ch = STRUCTURAL[k] then
      begin
        buf.AppendStr(Sentinel(k));
        found := True;
        Break;
      end;
    if not found then buf.AppendChar(ch);
  end;
  Result := buf.Finish;
end;

function SpSafetyRestore(const Text: string): string;
var buf: TStrBuf; i, k, adv, first: Integer;
begin
  first := FirstSentinelIn(Text);
  if first = 0 then Exit(Text);
  buf.Init(Length(Text) + 16);
  buf.AppendSlice(Text, 1, first - 1);
  i := first;
  while i <= Length(Text) do
  begin
    if SentinelAt(Text, i, k, adv) then
    begin
      buf.AppendChar(STRUCTURAL[k]);
      Inc(i, adv);
    end
    else
    begin
      buf.AppendChar(Text[i]);
      Inc(i);
    end;
  end;
  Result := buf.Finish;
end;

function SpStripSentinels(const Text: string): string;
var buf: TStrBuf; i, k, adv, first: Integer;
begin
  first := FirstSentinelIn(Text);
  if first = 0 then Exit(Text);
  buf.Init(Length(Text) + 16);
  buf.AppendSlice(Text, 1, first - 1);
  i := first;
  while i <= Length(Text) do
  begin
    if SentinelAt(Text, i, k, adv) then
      Inc(i, adv)
    else
    begin
      buf.AppendChar(Text[i]);
      Inc(i);
    end;
  end;
  Result := buf.Finish;
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
var buf: TStrBuf; i, j, n: Integer; hasComment: Boolean;
begin
  n := Length(text);
  { No `/#` anywhere means nothing is stripped, and the caller that wants no position
    map wants the text back unchanged -- skip the copy. A map caller still needs every
    index recorded, so it takes the walk. }
  if map = nil then
  begin
    hasComment := False;
    for i := 1 to n - 1 do
      if (text[i] = '/') and (text[i+1] = '#') then begin hasComment := True; Break; end;
    if not hasComment then Exit(text);
  end;

  buf.Init(n + 16);
  i := 1;
  while i <= n do
  begin
    if (i + 1 <= n) and (text[i] = '/') and (text[i+1] = '#') then
    begin
      { A comment needs its CLOSING `#/`. The reference strips with
        /\/#[\s\S]*?#\//g, and an opener with no closer is simply not a match, so the
        text stays -- where this port used to drop from the `/#` to the end of the
        document. That was not a cosmetic difference: it took whole templates out of the
        render and hid their diagnostics, so `/#` + LF + `{a` was `bracket.unclosed` in
        the reference and clean here. It also ate any ordinary URL carrying a fragment,
        `http://example.com/#top` being the everyday shape.

        So: look for the closer BEFORE consuming anything, and when there is none, fall
        through and treat the `/` as the ordinary character it is. Scanning then resumes
        inside the failed opener, exactly as a regex engine retries at the next position,
        which is what lets a later well-formed comment still match. }
      j := i + 2;
      while (j + 1 <= n) and not ((text[j] = '#') and (text[j+1] = '/')) do Inc(j);
      if j + 1 <= n then
      begin
        i := j + 2;
        Continue;
      end;
    end;
    if map <> nil then map.Add(i);
    buf.AppendChar(text[i]);
    Inc(i);
  end;
  Result := buf.Finish;
end;

function StripComments(const text: string): string; overload;
begin
  Result := StripComments(text, nil);
end;

function CollapseNewlines3(const s: string): string;
var buf: TStrBuf; i, run, j: Integer;
begin
  // \n{3,} -> \n\n
  buf.Init(Length(s) + 16); i := 1;
  while i <= Length(s) do
  begin
    if s[i] = #10 then
    begin
      run := 0;
      while (i <= Length(s)) and (s[i] = #10) do begin Inc(run); Inc(i); end;
      if run >= 3 then run := 2;
      for j := 1 to run do buf.AppendChar(#10);
    end
    else
    begin
      buf.AppendChar(s[i]);
      Inc(i);
    end;
  end;
  Result := buf.Finish;
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
  kind, nm, val, line: string;
  kept: TStrBuf;
  lineStart, n, e, termLen: Integer;
  isDirective: Boolean;
begin
  // Mirror the reference regex: only the directive TEXT is removed, the newline
  // that separated its line stays. So a directive line becomes an empty segment;
  // segments are re-joined with #10 and then \n{3,} collapses to \n\n.
  kept.Init(Length(text) + 16);
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
      kept.AppendStr(line);
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
        kept.AppendSlice(text, e + 1, termLen - 1)
      else
        kept.AppendSlice(text, e, termLen);
    if e > n then Break;
    lineStart := e + termLen;
  end;
  body := CollapseNewlines3(kept.Finish);
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
var sep: Integer; head: TCondHead; body, thenRaw, elseRaw: string;
begin
  Result := nil;
  if not RecognizeConditional(content, 1, Length(content) + 1, head) then Exit;
  body := Copy(content, head.BodyStart, MaxInt);
  if head.SepIndex = 0 then sep := 0 else sep := head.SepIndex - head.BodyStart + 1;
  if sep < 1 then begin thenRaw := body; elseRaw := ''; end
  else begin thenRaw := Copy(body, 1, sep - 1); elseRaw := Copy(body, sep + 1, MaxInt); end;
  Result := TNode.Create;
  Result.Kind := nkConditional;
  Result.CondName := head.Name;
  Result.CondInverted := head.Inverted;
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
  { True for what JS `\s` matches within ASCII. The deliberate narrowing to ASCII is the
    family's convention (the reference spells the class out "for PHP parity"); VT and FF
    are IN it, and leaving them out is simply a wrong port. }
  function IsCfgWs(c: Char): Boolean;
  begin
    Result := CharInSet(c, [' ', #9, #10, #11, #12, #13]);
  end;

  { MINSIZE_RE / MAXSIZE_RE = /(min|max)size\s*=\s*(\d+)/i -- three things this used to
    get wrong, all measured against @spintax/core on 2026-08-06:

      the `=` was OPTIONAL here. `[<sep="-" maxsize 2>a|b|c]` parsed maxsize=2 and rendered
      a random SUBSET; the reference finds no match, leaves maxsize null and renders all
      three. A key word standing in prose silently became a config.

      the whitespace around `=` was [' ', #9]. `[<minsize` LF `=2>a|b|c]` was no config at
      all here and is one to the reference; same for VT, FF and CR, and same after the `=`.

      a failed candidate ENDED the search. A regex retries at the next position, so
      `[<minsize foo minsize=1>…]` matches the second one; this stopped at the first and
      reported nothing. }
  function FindInt(const key: string): Integer;
  var k, j: Integer; num, low2: string;
  begin
    Result := -1;
    low2 := LowerAscii(configStr);
    k := 1;
    while True do
    begin
      k := PosEx(key, low2, k);
      if k = 0 then Exit;
      j := k + Length(key);
      while (j <= Length(configStr)) and IsCfgWs(configStr[j]) do Inc(j);
      if (j <= Length(configStr)) and (configStr[j] = '=') then
      begin
        Inc(j);
        while (j <= Length(configStr)) and IsCfgWs(configStr[j]) do Inc(j);
        num := '';
        while (j <= Length(configStr)) and CharInSet(configStr[j], ['0'..'9']) do
        begin num := num + configStr[j]; Inc(j); end;
        if num <> '' then Exit(StrToInt(num));
      end;
      Inc(k);
    end;
  end;
  { SEP_RE = /(?<!last)sep\s*=\s*"([^"]*)"/i, LASTSEP_RE the same without the lookbehind.
    Same three corrections as FindInt, plus one of its own: `([^"]*)"` needs the CLOSING
    quote, so an unterminated `sep="X` is not a match and the separator stays the default. }
  function FindStr(const key: string; out val: string): Boolean;
  var k, j, q: Integer; low2: string;
  begin
    Result := False; val := '';
    low2 := LowerAscii(configStr);
    k := 1;
    while True do
    begin
      k := PosEx(key, low2, k);
      if k = 0 then Exit;
      { the reference's negative lookbehind: a `sep` that is the tail of `lastsep` is not
        this key }
      if (key = 'sep') and (k >= 5) and (Copy(low2, k - 4, 4) = 'last') then
      begin
        Inc(k); Continue;
      end;
      j := k + Length(key);
      while (j <= Length(configStr)) and IsCfgWs(configStr[j]) do Inc(j);
      if (j <= Length(configStr)) and (configStr[j] = '=') then
      begin
        Inc(j);
        while (j <= Length(configStr)) and IsCfgWs(configStr[j]) do Inc(j);
        if (j <= Length(configStr)) and (configStr[j] = '"') then
        begin
          q := j + 1;
          while (q <= Length(configStr)) and (configStr[q] <> '"') do Inc(q);
          if q <= Length(configStr) then
          begin
            val := Copy(configStr, j + 1, q - j - 1);
            Exit(True);
          end;
        end;
      end;
      Inc(k);
    end;
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
              { PER_ELEM_HTML_RE = /^[a-zA-Z][a-zA-Z0-9]*\s/ -- the ASCII \s set, VT and FF
                included; this had the same four-character gap the config keys had }
              if (q <= Length(innerTrim)) and
                 (CharInSet(innerTrim[q], [' ', #9, #10, #11, #12, #13])) then looksHtml := True;
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
var i, j, endp, namelen: Integer; ch: Char; nm: string; node: TNode; literal: TStrBuf;

  procedure FlushLiteral;
  begin
    if literal.Len > 0 then
    begin
      node := TNode.Create; node.Kind := nkLiteral; node.Text := literal.Finish;
      Result.Add(node);
      { Finish handed Data out as the node's text, so the buffer must let go of it rather
        than keep writing into a string it no longer owns. Reset, not Init: a flush is
        usually the LAST thing this parse does -- every option of an enumeration ends with
        one -- and reserving for a literal that never comes was an allocation per option. }
      literal.Reset;
    end;
  end;

begin
  Result := TNodeList.Create(True);
  literal.Init(Length(text) + 16); i := 1;
  while i <= Length(text) do
  begin
    ch := text[i];
    if ch = '{' then
    begin
      endp := FindMatchingClose(text, i, '{', '}');
      if endp = 0 then begin literal.AppendChar(ch); Inc(i); Continue; end;
      FlushLiteral;
      Result.Add(ParseBraceConstruct(Copy(text, i + 1, endp - i - 1)));
      i := endp + 1; Continue;
    end;
    if ch = '[' then
    begin
      endp := FindMatchingClose(text, i, '[', ']');
      if endp = 0 then begin literal.AppendChar(ch); Inc(i); Continue; end;
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
    literal.AppendChar(ch);
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
    { What variable expansion may still INSERT, for the whole render call including any
      #include children -- see SP_RENDER_EXPANSION_BUDGET. A pointer because TRenderOpts is
      copied at every nesting step and the count has to be shared, not forked. }
    Budget: PInteger;
  end;

function RenderNodes(nodes: TNodeList; const opts: TRenderOpts): string; forward;

function HasConstructChar(const s: string): Boolean;
var i: Integer;
begin
  for i := 1 to Length(s) do
    if (s[i] = '{') or (s[i] = '[') or (s[i] = '%') then Exit(True);
  Result := False;
end;

{ Take `cost` code units out of the render's expansion budget, or refuse.

  Refusing is not an error: the caller leaves the reference LITERAL, which is what this
  engine already emits for a name it does not know. `opts` is const and the counter is
  behind a pointer, because every nesting step copies the record and the count is shared.
  A nil budget means no accounting at all, so a caller that predates this cannot change
  behaviour by not knowing about it. }
function TakeBudget(const opts: TRenderOpts; cost: Integer): Boolean;
begin
  if opts.Budget = nil then Exit(True);
  { Refuse when the purse is EMPTY, not when the next substitution would overdraw it: the
    reference charges after allowing the substitution and stops before the following one, so
    the last one through may take the count negative. Matching it costs nothing and keeps
    the two engines stopping in the same place, even though the conformance README says the
    truncated output is deliberately not asserted. }
  if opts.Budget^ <= 0 then Exit(False);
  Dec(opts.Budget^, cost);
  Result := True;
end;

function ExpandVarsOnly(const text: string; const opts: TRenderOpts): string;
var iter, i, j: Integer; changed, hasPct: Boolean; outp, nm, val: string; res: TStrBuf;
begin
  outp := text;
  for iter := 1 to MAX_VARIABLE_DEPTH do
  begin
    { No '%' left means no reference left to expand -- stop before rebuilding the string. }
    hasPct := False;
    for i := 1 to Length(outp) do
      if outp[i] = '%' then begin hasPct := True; Break; end;
    if not hasPct then Break;

    changed := False;
    res.Init(Length(outp) + 16); i := 1;
    while i <= Length(outp) do
    begin
      if outp[i] = '%' then
      begin
        j := i + 1; nm := '';
        while (j <= Length(outp)) and IsAsciiWord(outp[j]) do begin nm := nm + outp[j]; Inc(j); end;
        if (nm <> '') and (j <= Length(outp)) and (outp[j] = '%') then
        begin
          { Budget first: this loop is the one that doubles. Refused, the reference falls
            through to the literal path below and the pass stops changing anything. Nested
            rather than `and`-ed, because TakeBudget has a side effect and this must not
            depend on which operands a compiler evaluates. }
          if opts.Vars.TryGetValue(LowerAscii(nm), val) then
            if TakeBudget(opts, Length(val)) then
            begin
              res.AppendStr(val); changed := True; i := j + 1; Continue;
            end;
        end;
      end;
      res.AppendChar(outp[i]); Inc(i);
    end;
    outp := res.Finish;
    if not changed then Break;
  end;
  Result := outp;
end;

function ResolveVariable(const name: string; const opts: TRenderOpts): string;
var val: string; sub: TNodeList; subOpts: TRenderOpts;
begin
  if not opts.Vars.TryGetValue(LowerAscii(name), val) then Exit('%' + name + '%');
  { The plain paths first, and they are NOT charged -- a value carrying no construct, or one
    at the depth cap, is substituted and never expanded again, so it cannot be part of an
    explosion. Charging it made ten chained #def hops over one 100 KB literal cost ten times
    its length and then refuse the reference that was the actual output. The reference
    orders these the same way; Codex review, 2026-08-18. }
  if (opts.Depth >= MAX_VARIABLE_DEPTH) or (not HasConstructChar(val)) then Exit(val);
  { Charged before the recursive expansion, because one substitution can be the whole
    explosion: each level of `#set %a% = %b% %b%` doubles, and the depth cap alone permits
    2^50. Out of budget, the reference stays as written -- the answer an unknown name gets. }
  if not TakeBudget(opts, Length(val)) then Exit('%' + name + '%');
  sub := ParseSequence(val);
  try
    subOpts := opts; subOpts.Depth := opts.Depth + 1;
    Result := RenderNodes(sub, subOpts);
  finally
    sub.Free;
  end;
end;

{ JavaScript's `\s`, written out.

  Every other engine in the family decides conditional truthiness with `/\S/u` -- the two
  PHP ones, the Python port and the reference alike -- so a variable holding only U+00A0 is
  FALSY to all of them. This port tested six ASCII characters, BYTE by byte, and called it
  truthy: the other branch rendered. Spec sec.3 names conditional truthiness as
  parity-REQUIRED, and no fixture carries a Unicode space, so nothing caught it until a
  Codex review of the count-slot work pointed at the predicate the new pass had started
  calling too.

  Enumerated rather than taken from the RTL, for the same reason the Unicode tables are
  baked: the answer must not depend on which Unicode version the host was built against.
  U+200B, U+0085 and U+3164 are deliberately NOT here -- measured against the reference,
  all three are non-space and make a variable truthy. }
function IsJsSpaceCp(cp: LongWord): Boolean;
begin
  Result := (cp = $09) or (cp = $0A) or (cp = $0B) or (cp = $0C) or (cp = $0D) or (cp = $20)
         or (cp = $A0) or (cp = $1680) or ((cp >= $2000) and (cp <= $200A))
         or (cp = $2028) or (cp = $2029) or (cp = $202F) or (cp = $205F) or (cp = $3000)
         or (cp = $FEFF);
end;

{ Truthy = the raw var value is set and holds a non-whitespace char (plugin is_truthy).
  Split out from RenderConditional because the plural count slot decides the same branch
  without rendering it.

  Walked as CODE POINTS, not units: a byte scan sees NBSP as $C2 $A0, neither of which is
  an ASCII space, and answers the opposite of the family. }
function ConditionalTakesThen(const name: string; inverted: Boolean;
  const opts: TRenderOpts): Boolean;
var val: string; baseTruthy: Boolean; i, cpLen: Integer;
begin
  baseTruthy := False;
  if opts.Vars.TryGetValue(LowerAscii(name), val) then
  begin
    i := 1;
    while i <= Length(val) do
    begin
      if not IsJsSpaceCp(SpCodePointAt(val, i, cpLen)) then
      begin
        baseTruthy := True; Break;
      end;
      Inc(i, cpLen);
    end;
  end;
  if inverted then Result := not baseTruthy else Result := baseTruthy;
end;

function RenderConditional(node: TNode; const opts: TRenderOpts): string;
begin
  if ConditionalTakesThen(node.CondName, node.CondInverted, opts) then
    Result := RenderNodes(node.CondThen, opts)
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

{ Match every opening brace to its closing brace in ONE pass: for each of them the offset
  of the brace that closes it, or 0.

  Equivalent to searching for the matching close per '{', and that is the point -- the
  per-brace search rescans to the end of the string every time it fails to match, and an
  UNBALANCED count slot is legal input: only the whole `{plural ...` block has to balance,
  and the slot is cut at the first ':'. The reference measured 3 seconds on a 78 KB slot
  that way, against 42 ms for this. }
function MatchBraces(const text: string): TArray<Integer>;
var opens: TArray<Integer>; top, i: Integer;
begin
  Result := nil; // SetLength reads the result variable; -Sew rejects it uninitialised
  SetLength(Result, Length(text) + 1); // zero-filled: 0 means "no matching close"
  SetLength(opens, Length(text) + 1);
  top := 0;
  for i := 1 to Length(text) do
  begin
    if text[i] = '{' then begin opens[top] := i; Inc(top); end
    else if text[i] = '}' then
    begin
      if top > 0 then begin Dec(top); Result[opens[top]] := i; end;
    end;
  end;
end;

{ Resolve conditionals in the plural COUNT slot, TEXTUALLY -- the taken branch is
  substituted, never rendered (spintax-js#67).

  Why it exists: the PHP plugin runs its conditional stage over the whole document before
  plurals, so a `#set` holding `?flag?1|2` in braces reaches the count slot as a plain
  number and the block renders. This engine expanded VARIABLES only into the raw slot, so
  the conditional survived, failed the numeric test, and the block was ERASED -- while
  SpValidate reported nothing at all, and plural.count-macro exempts conditionals precisely
  BECAUSE they resolve before plurals. Valid input, silently deleted output.

  Textual, and only the taken branch's TEXT, because the stage order still holds around it:
  enumerations and permutations resolve AFTER plurals, so a branch yielding an enumeration
  must reach the numeric test intact and erase the block, exactly as the plugin does.
  Rendering the branch would spin it to one option and invent a count no engine has. The
  FORM slot is deliberately untouched -- there the engines genuinely disagree and picking a
  side is not a bug fix.

  Iterative over SPANS of the source, for the two reasons the family's review paid for:
  recursing into the taken branch overflows the stack on deep nesting, which SpRender must
  survive because it never fails on content; and copying the branch out per level, or
  re-scanning for the matching brace per '{?', is quadratic on input a host may accept from
  a stranger. No branch is ever copied out.

  It is NOT linear in the depth of nesting. RecognizeConditional finds the separator by
  scanning the body, so N nested conditionals whose branch is TAKEN scan N + (N-1) + ...
  characters: 2000 levels 54 ms, 4000 210 ms, 8000 913 ms. The reference is quadratic here
  too and slower, and upstream calls bounding such input a host job. An earlier version of
  this comment claimed every character was visited at most once, on a measurement taken with
  the flag EMPTY -- where the else branch is three characters and the nested chain is never
  walked at all. Spec sec.5.6 carries the numbers and both branches are in the suite. }
function ResolveCountConditionals(const text: string; const opts: TRenderOpts): string;
var close: TArray<Integer>; res: TStrBuf; pend: TArray<Integer>;
    top, i, segEnd, open, shut, cut, branchFrom, branchTo: Integer;
    head: TCondHead;
begin
  if Pos('{?', text) = 0 then Exit(text);

  close := MatchBraces(text);
  res.Init(Length(text) + 16);
  { spans of `text` still to emit, in order; a taken branch is a SPAN of the same string,
    never a copy, and the untaken one is skipped }
  SetLength(pend, 64);
  pend[0] := 1; pend[1] := Length(text) + 1; top := 2;

  while top > 0 do
  begin
    Dec(top, 2);
    i := pend[top]; segEnd := pend[top + 1];
    while i < segEnd do
    begin
      open := PosEx('{?', text, i);
      { a '{?' found past this span belongs to the text around it, not to this span }
      if (open = 0) or (open + 1 >= segEnd) then
      begin
        res.AppendSlice(text, i, segEnd - i);
        Break;
      end;

      shut := close[open];
      { a close outside the span is no close at all: the branch it would reach into is not
        ours to read }
      if (shut = 0) or (shut >= segEnd) or
         (not RecognizeConditional(text, open + 1, shut, head)) then
      begin
        { unclosed, or a '{?' that is not a conditional -- to the parser a malformed one is
          an enumeration, and enumerations are not this pass's business }
        cut := open + 2; if cut > segEnd then cut := segEnd;
        res.AppendSlice(text, i, cut - i);
        i := open + 2;
        Continue;
      end;

      res.AppendSlice(text, i, open - i);
      if ConditionalTakesThen(head.Name, head.Inverted, opts) then
      begin
        branchFrom := head.BodyStart;
        if head.SepIndex = 0 then branchTo := shut else branchTo := head.SepIndex;
      end
      else
      begin
        if head.SepIndex = 0 then branchFrom := shut else branchFrom := head.SepIndex + 1;
        branchTo := shut;
      end;

      { continuation first, branch second: the stack pops the branch back out ahead of it,
        which is what keeps the output in source order }
      if top + 4 > Length(pend) then SetLength(pend, Length(pend) * 2);
      pend[top] := shut + 1; pend[top + 1] := segEnd; Inc(top, 2);
      pend[top] := branchFrom; pend[top + 1] := branchTo; Inc(top, 2);
      Break;
    end;
  end;

  Result := res.Finish;
end;

function RenderPlural(node: TNode; const opts: TRenderOpts): string;
var countRaw, formsRaw, count, picked, cur: string; base: string;
    forms: TStringList; i: Integer; hasBracket: Boolean; sub: TNodeList;
begin
  countRaw := ResolveCountConditionals(ExpandVarsOnly(node.PluralCountRaw, opts), opts);
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
    globalSep, globalLast, sep: string; buf: TStrBuf;
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
  if pick = 1 then Exit(elems[0].Text);
  buf.Init(256);
  buf.AppendStr(elems[0].Text);
  for i := 1 to pick - 1 do
  begin
    if elems[i].HasSep then sep := elems[i].Sep
    else if i = pick - 1 then sep := globalLast
    else sep := globalSep;
    buf.AppendStr(PadSeparator(sep));
    buf.AppendStr(elems[i].Text);
  end;
  Result := buf.Finish;
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
var i: Integer; buf: TStrBuf;
begin
  { One node is the common case (a template with no spintax parses to a single literal);
    hand its text straight back rather than copying it through a buffer. }
  if nodes.Count = 0 then Exit('');
  if nodes.Count = 1 then Exit(RenderNode(nodes[0], opts));
  buf.Init(256);
  for i := 0 to nodes.Count - 1 do
    buf.AppendStr(RenderNode(nodes[i], opts));
  Result := buf.Finish;
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
{ Every %name% in order, WITH multiplicity -- DirectReferences deduplicates, and the
  reference's cycle walk iterates `value.matchAll(/%(\w+)%/gu)`, which does not. A value
  naming the same variable twice therefore drives that walk twice, and the count of
  diagnostics depends on it. }
procedure RawReferences(const text: string; target: TStringList);
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
        target.Add(LowerAscii(nm));
        i := j + 1; Continue;
      end;
    end;
    Inc(i);
  end;
end;

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
var p, q, lenS, lenL: Integer; a, b: string; cs, cl: LongWord;
begin
  Result := 0;
  p := i; q := 1;
  while q <= Length(lit) do
  begin
    if p > Length(s) then Exit;
    cs := SpCodePointAt(s, p, lenS);
    cl := SpCodePointAt(lit, q, lenL);
    { SpUpperCodePoint returns a STRING, so the table path allocates twice per code
      point -- and ScanSingleAbbr calls this for all 46 abbreviations at EVERY position
      of the text, which made those allocations the post-process's largest single cost.
      When both code points are ASCII the mapping is exactly 'a'..'z' -> -32 (verified
      against the table over all 128), so take it without allocating.

      Only when BOTH are ASCII. A non-ASCII code point can uppercase INTO ASCII --
      U+017F LATIN SMALL LETTER LONG S -> 'S' -- so a mixed pair must still go through
      the table or a real match would be missed. }
    if (cs < 128) and (cl < 128) then
    begin
      if (cs >= Ord('a')) and (cs <= Ord('z')) then Dec(cs, 32);
      if (cl >= Ord('a')) and (cl <= Ord('z')) then Dec(cl, 32);
      if cs <> cl then Exit;
    end
    else
    begin
      a := SpUpperCodePoint(cs);
      b := SpUpperCodePoint(cl);
      if a <> b then Exit;
    end;
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

{ Rebuilt once from the generated code-point table, in whatever width this compiler uses.
  Built on first use. Not thread-safe to initialise concurrently -- the engine has no other
  global state and no threading contract, so this is documented rather than locked. }
var
  { The 46 abbreviations, plus the folded first code point of each.

    ScanSingleAbbr runs at every word start of the document, and comparing all 46 there
    in full was 86% of the entire post-process -- measured at 1383 ms of 1606 on a 1 MB
    render. An abbreviation can only match when its first code point folds equal to the
    text's, so one integer comparison rejects almost every candidate before the string
    walk starts. The list is still traversed in order, so first-match-wins is unchanged.

    Keyed on the folded code point rather than the raw one, because the match folds, and
    ASCII-only bucketing would have been useless anyway: 28 of the 46 are Cyrillic. }
  GAbbrevArr: array of string;
  GAbbrevFirstUp: array of LongWord;

procedure EnsureAbbrevs;
var i, k, n, len, cpLen: Integer; a: string;
begin
  if Length(GAbbrevArr) > 0 then Exit;
  SetLength(GAbbrevArr, ABBREV_COUNT);
  SetLength(GAbbrevFirstUp, ABBREV_COUNT);
  i := 0;
  for k := 1 to ABBREV_COUNT do
  begin
    len := ABBREV_DATA[i]; Inc(i);
    a := '';
    for n := 1 to len do begin a := a + SpCodePointToStr(ABBREV_DATA[i]); Inc(i); end;
    GAbbrevArr[k - 1] := a;
    GAbbrevFirstUp[k - 1] := SpUpperFirstCp(SpCodePointAt(a, 1, cpLen));
  end;
end;

{ One of the known abbreviations, then a dot, with no letter or digit before it and
  whitespace, end of text, or a tag right after. Case-insensitive, hence the folded
  predicate for the preceding character. }
function ScanSingleAbbr(const s: string; i: Integer): Integer;
var k, p, cpLen, prev: Integer; upHere: LongWord;
begin
  Result := 0;
  EnsureAbbrevs;
  if i > Length(s) then Exit;
  { negative lookbehind: no letter or digit immediately before }
  if i > 1 then
  begin
    prev := PrevCodePointStart(s, i);
    if IsLetterOrNumFoldedAt(s, prev, cpLen) then Exit;
  end;
  upHere := SpUpperFirstCp(SpCodePointAt(s, i, cpLen));
  for k := 0 to High(GAbbrevArr) do
  begin
    { Necessary condition for a fold-match, one integer compare -- see GAbbrevFirstUp. }
    if GAbbrevFirstUp[k] <> upHere then Continue;
    cpLen := MatchesFoldedAt(s, i, GAbbrevArr[k]);
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
{ Everything about a template that does not depend on the render: the directive maps, the
  body's node tree, and the node tree of each #def value.

  What is NOT cached, and cannot be: a #def is rolled once per RENDER and its rolling ORDER
  depends on the host's variables, since a runtime variable of the same name outranks a
  definition and changes which aliases the dependency graph can see. So the trees are
  reused and the ordering is recomputed -- it costs O(definitions), not O(document). }
type
  TTemplateImpl = class
  public
    SetDefs, DefDefs: TStrMap;
    Body: TNodeList;
    DefIdx: TDictionary<string, Integer>;
    DefTrees: TObjectList<TNodeList>;
    constructor Create(const Template: string);
    destructor Destroy; override;
  end;

constructor TTemplateImpl.Create(const Template: string);
var bodyText: string; pair: TPair<string, string>;
begin
  inherited Create;
  SetDefs := TStrMap.Create;
  DefDefs := TStrMap.Create;
  DefIdx := TDictionary<string, Integer>.Create;
  DefTrees := TObjectList<TNodeList>.Create(True);
  ExtractDirectives(StripComments(SpStripSentinels(Template)), SetDefs, DefDefs, bodyText);
  Body := ParseSequence(bodyText);
  for pair in DefDefs do
  begin
    DefIdx.Add(pair.Key, DefTrees.Count);
    DefTrees.Add(ParseSequence(pair.Value));
  end;
end;

destructor TTemplateImpl.Destroy;
begin
  SetDefs.Free; DefDefs.Free; Body.Free; DefIdx.Free; DefTrees.Free;
  inherited Destroy;
end;

function RenderDocument(const Template: string; RuntimeVars: TStrMap; const Locale: string;
  Rng: TSpRng; Resolver: TSpIncludeResolver; MaxDepth: Integer;
  Stack: TStringList; Budget: PInteger): string; forward;

{ The reference's resolveIncludes, run over RENDERED text: every #include line becomes the
  child's OUTPUT, so a `{`, `|` or `%` the child produced is never re-parsed by the parent
  -- it is already output. Cycles are keyed on the ref STRING (this engine has no template
  identity beyond it), so two aliases of one template are not a cycle and unwind until the
  depth cap; cycle, cap and unknown target all resolve to '' the same lenient way.

  Scanning continues AFTER a match, like String.replace with /g -- never into what was just
  inserted, since the child resolved its own includes. Matches can end past their own line
  (spec §5.1), which is why the walk advances by match end rather than by line. }
function ResolveIncludes(const text: string; RuntimeVars: TStrMap; const Locale: string;
  Rng: TSpRng; Resolver: TSpIncludeResolver; MaxDepth: Integer; Stack: TStringList;
  Budget: PInteger): string;
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
          child := RenderDocument(childSrc, RuntimeVars, Locale, Rng, Resolver, MaxDepth,
                                  Stack, Budget);
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

{ The half of a render that depends on the host: variables, the #def roll, the tree walk
  and the includes. Everything it reads from the template was prepared by TTemplateImpl. }
function RenderCompiled(impl: TTemplateImpl; RuntimeVars: TStrMap; const Locale: string;
  Rng: TSpRng; Resolver: TSpIncludeResolver; MaxDepth: Integer; Stack: TStringList;
  Budget: PInteger): string;
var vars, aliases: TStrMap;
    opts: TRenderOpts;
    pair: TPair<string, string>;
    outranked, defOrder: TStringList;
    oi, di: Integer;
begin
  vars := TStrMap.Create;
  outranked := TStringList.Create;
  try
    // buildVars: setDefs raw, then runtime context overlays (lower-cased)
    for pair in impl.SetDefs do vars.AddOrSetValue(pair.Key, pair.Value);
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
    opts.Budget := Budget;

    // Roll each #def once, DEPENDENCIES FIRST; a runtime var of the same name
    // outranks it (never rolled). The order must not come from hash enumeration —
    // see OrderDefinitions above.
    if impl.DefDefs.Count > 0 then
    begin
      // Aliases = every macro value a definition can see, minus the definitions
      // that will actually be rolled: a #def shadows a same-named #set, and hopping
      // through the shadowed value computes the wrong graph. One the runtime
      // outranks stays, because it is never rolled and its value is what really
      // gets substituted.
      aliases := TStrMap.Create;
      try
        for pair in vars do
          if not (impl.DefDefs.ContainsKey(pair.Key) and (outranked.IndexOf(pair.Key) < 0)) then
            aliases.AddOrSetValue(pair.Key, pair.Value);

        defOrder := OrderDefinitions(impl.DefDefs, aliases);
        try
          for oi := 0 to defOrder.Count - 1 do
          begin
            if outranked.IndexOf(defOrder[oi]) >= 0 then Continue;
            { the value's tree was parsed at compile time; rolling it is a render }
            if impl.DefIdx.TryGetValue(defOrder[oi], di) then
              vars.AddOrSetValue(defOrder[oi], RenderNodes(impl.DefTrees[di], opts));
          end;
        finally
          defOrder.Free;
        end;
      finally
        aliases.Free;
      end;
    end;

    Result := RenderNodes(impl.Body, opts);

    if Resolver <> nil then
      Result := ResolveIncludes(Result, RuntimeVars, Locale, Rng, Resolver, MaxDepth,
                                Stack, Budget);
  finally
    vars.Free; outranked.Free;
  end;
end;

{ One-shot: compile, render, discard. This is what an #include child takes, and what
  SpRender takes, so the two paths cannot drift apart. }
function RenderDocument(const Template: string; RuntimeVars: TStrMap; const Locale: string;
  Rng: TSpRng; Resolver: TSpIncludeResolver; MaxDepth: Integer; Stack: TStringList;
  Budget: PInteger): string;
var impl: TTemplateImpl;
begin
  impl := TTemplateImpl.Create(Template);
  try
    Result := RenderCompiled(impl, RuntimeVars, Locale, Rng, Resolver, MaxDepth, Stack, Budget);
  finally
    impl.Free;
  end;
end;

{ The wrapper both public entry points share: the RNG the caller did or did not supply,
  the include stack and depth, then the cosmetic stage and the mandatory restore. `impl`
  nil means "compile Template first", which is what SpRender does. }
function RenderTop(impl: TTemplateImpl; const Template: string;
  const Ctx: TSpContext): string;
var ownedRng: TSpRng; rng: TSpRng; stack: TStringList; depth: Integer; outp: string;
    budget: Integer;
begin
  { Owned only when the caller supplied none; the caller's own Rng is never freed here. }
  if Ctx.Rng = nil then ownedRng := MakeDefaultRng else ownedRng := nil;
  { ONE budget for the whole call, children included: an #include is part of this render,
    not a fresh one, and a per-document budget would multiply by the include depth. }
  budget := SP_RENDER_EXPANSION_BUDGET;
  stack := TStringList.Create;
  try
    if ownedRng <> nil then rng := ownedRng else rng := Ctx.Rng;
    depth := Ctx.MaxIncludeDepth;
    if depth <= 0 then depth := SP_DEFAULT_INCLUDE_DEPTH;

    if impl <> nil then
      outp := RenderCompiled(impl, Ctx.Vars, Ctx.Locale, rng,
                             Ctx.IncludeResolver, depth, stack, @budget)
    else
      outp := RenderDocument(Template, Ctx.Vars, Ctx.Locale, rng,
                             Ctx.IncludeResolver, depth, stack, @budget);

    { Once, over the whole assembled document -- parent and every child it pulled in. The
      cosmetic pipeline therefore sees across the seam, and a sentinel a child emitted is
      restored here rather than inside it. }
    if Ctx.PostProcess then outp := FullPostProcess(outp);
    Result := SpSafetyRestore(outp);
  finally
    stack.Free; ownedRng.Free;
  end;
end;

function SpRender(const Template: string; const Ctx: TSpContext): string;
begin
  Result := RenderTop(nil, Template, Ctx);
end;

constructor TSpTemplate.Create(const Template: string);
begin
  inherited Create;
  FImpl := TTemplateImpl.Create(Template);
end;

destructor TSpTemplate.Destroy;
begin
  FImpl.Free;
  inherited Destroy;
end;

function SpCompile(const Template: string): TSpTemplate;
begin
  Result := TSpTemplate.Create(Template);
end;

function SpRenderCompiled(Tmpl: TSpTemplate; const Ctx: TSpContext): string;
begin
  if (Tmpl = nil) or (Tmpl.FImpl = nil) then
    raise ESpintax.Create('SpRenderCompiled: template handle is nil (use SpCompile)');
  Result := RenderTop(TTemplateImpl(Tmpl.FImpl), '', Ctx);
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

{ FPC will not parse a nested generic in an expression, so the reverse-edge buckets get a
  name of their own. }
type
  TIntList = TList<Integer>;
  TIntBucketList = TObjectList<TIntList>;

{ Set-macro names whose value is unresolved-at-plural-time, propagated through %refs%.

  `tainted` is a membership set and nothing else -- its ORDER is never read, here or by its
  caller -- so it is a dictionary. It used to be a TStringList walked with IndexOf, once per
  name per propagation round, and the round re-parsed every value's references from scratch.
  Names are lower-cased by TryParseDirective and DirectReferences alike, so a plain
  case-sensitive dictionary is exactly the lookup the case-folding IndexOf was doing. }
procedure BuildMacroTaint(kinds, names, values: TStringList;
  tainted: TDictionary<string, Boolean>);
var i, k, b, head: Integer; cur: string;
    allRefs: TObjectList<TStringList>; refs, queue, setNames: TStringList;
    setVal: TStrMap;
    revIdx: TDictionary<string, Integer>;
    buckets: TIntBucketList;
    pair: TPair<string, Boolean>;
begin
  { The reference taints over `extractDirectives(text).setDefs`, which is a MAP: one entry
    per name, the LAST `#set` winning, and a `#def` of the same name not removing it. This
    port walked every occurrence, so a name whose middle definition held an enumeration
    stayed tainted even where the surviving value is a literal. Measured against
    @spintax/core: a `#def` with a literal, then a `#set` with an enumeration, then a `#set`
    with a literal reports plural.count-macro here and nothing there. }
  setNames := TStringList.Create;
  setVal := TStrMap.Create;
  try
    for i := 0 to names.Count - 1 do
      if kinds[i] = 'set' then
      begin
        if not setVal.ContainsKey(names[i]) then setNames.Add(names[i]);
        setVal.AddOrSetValue(names[i], values[i]);
      end;

    // seed: #set macros with a bracket/enum in the surviving value
    for i := 0 to setNames.Count - 1 do
      if UnresolvedAtPluralTime(setVal[setNames[i]]) then
        tainted.AddOrSetValue(setNames[i], True);

  { the references of each value, parsed ONCE -- the propagation below may sweep the list
    many times, and re-parsing there was the larger half of the cost }
  allRefs := TObjectList<TStringList>.Create(True);
  try
    for i := 0 to setNames.Count - 1 do
    begin
      refs := TStringList.Create;
      allRefs.Add(refs);
      DirectReferences(setVal[setNames[i]], refs);
    end;

    { Propagate along REVERSE edges from the seeds: a #set whose value references a
      tainted name becomes tainted, and taints its own referrers in turn.

      This used to be a fixpoint sweep -- re-scan every definition until a pass added
      nothing. On a chain of macros each pass taints exactly one more name, so the sweep
      ran once per definition over every definition: 6400 chained `#set`s spent tens of
      seconds here. A worklist over the reverse graph does the same work once per edge. }
    revIdx := TDictionary<string, Integer>.Create;
    buckets := TIntBucketList.Create(True);
    queue := TStringList.Create;
    try
      for i := 0 to setNames.Count - 1 do
      begin
        refs := allRefs[i];
        for k := 0 to refs.Count - 1 do
        begin
          if not revIdx.TryGetValue(refs[k], b) then
          begin
            b := buckets.Count;
            buckets.Add(TList<Integer>.Create);
            revIdx.Add(refs[k], b);
          end;
          buckets[b].Add(i);
        end;
      end;

      for pair in tainted do queue.Add(pair.Key);
      head := 0;
      while head < queue.Count do
      begin
        cur := queue[head]; Inc(head);
        if not revIdx.TryGetValue(cur, b) then Continue;
        for k := 0 to buckets[b].Count - 1 do
        begin
          i := buckets[b][k];
          if tainted.ContainsKey(setNames[i]) then Continue;
          tainted.AddOrSetValue(setNames[i], True);
          queue.Add(setNames[i]);
        end;
      end;
    finally
      revIdx.Free; buckets.Free; queue.Free;
    end;
  finally
    allRefs.Free;
  end;
  finally
    setNames.Free; setVal.Free;
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
var lineStart, e, n, i, p, segStart, segEnd, segLen: Integer;
    ok: Boolean;
    curDup, curInc: TSourceCursor;
    line, t, kind, nm, val: string;
    isSet, isDef: Boolean;
    kinds, names, values: TStringList;
    seen: TDictionary<string, Boolean>;
    poss: TList<Integer>;
begin
  { MALFORMED LINES. This scan is deliberately NOT the one the parser and the occurrence
    walk use, and the difference is the reference's, not an oversight here.

    `checkDirectives` splits on **LF alone** (`text.split('
')`) and left-trims **spaces
    and tabs alone** (`/^[ 	]+/`), where everything else in the family splits on five
    terminators and this port used PHP's trim charlist. Both differences turned valid
    templates invalid, which is a §3 verdict divergence:

      <VT>#set %x% = A      the VT is not [ 	], so the line never starts with `#set ` and
                            is not a directive at all -- the reference reports only
                            `variable.undefined` for the `%x%` left standing in text
      <NUL>#set broken      likewise: NUL is in PHP's charlist and not in the reference's
      x<CR>#set broken      one line to the reference, so nothing starts with `#set `
      x<U+2028>#set broken  likewise

    all four measured against @spintax/core on 2026-08-06. A CRLF still splits, because the
    LF is there; the CR just stays on the previous line. }
  n := Length(text); lineStart := 1;
  while lineStart <= n + 1 do
  begin
    e := lineStart;
    while (e <= n) and (text[e] <> #10) do Inc(e);
    line := Copy(text, lineStart, e - lineStart);
    t := line;
    i := 1;
    while (i <= Length(t)) and ((t[i] = ' ') or (t[i] = #9)) do Inc(i);
    t := Copy(t, i, MaxInt);
    isSet := SpStartsWith(t, '#set ') or SpStartsWith(t, '#set'#9);
    isDef := SpStartsWith(t, '#def ') or SpStartsWith(t, '#def'#9);
    { DIRECTIVE_RE is /gmu, and the reference TESTS it against the trimmed line. Under `m`
      the anchors break on CR and the paragraph separators too, so a well-formed directive
      sitting after a CR inside this LF-delimited line satisfies the test and nothing is
      reported. Only the LF split is the reference's `split('\n')`; the anchors inside are
      the regex's own, and they are the family's five terminators minus the one already
      used to make the line. }
    ok := False;
    segStart := 1;
    while segStart <= Length(t) + 1 do
    begin
      segEnd := NextLineBreak(t, segStart, segLen);
      if TryParseDirective(Copy(t, segStart, segEnd - segStart), kind, nm, val) then
      begin
        ok := True;
        Break;
      end;
      if segEnd > Length(t) then Break;
      segStart := segEnd + segLen;
    end;
    if (isSet or isDef) and (not ok) then
    begin
      { point at the '#' (first non-blank on the line); span = the 4-char keyword }
      p := lineStart + (Length(line) - Length(t));
      if isDef then AddDiagAt(res, 'def.malformed', 'error', src, map, p, p + 4)
      else AddDiagAt(res, 'set.malformed', 'error', src, map, p, p + 4);
    end;
    if e > n then Break;
    lineStart := e + 1;
  end;

  // duplicate names + #include in a #def value
  kinds := TStringList.Create; names := TStringList.Create; values := TStringList.Create;
  { membership only -- the index this used to take from TStringList.IndexOf was never read,
    and the linear scan behind it cost O(names^2) on a directive-heavy document }
  seen := TDictionary<string, Boolean>.Create;
  poss := TList<Integer>.Create;
  try
    CollectOccurrences(text, kinds, names, values, poss);
    { The offsets ascend, so both diagnostics take the resuming cursor. With AddDiagAt each
      one re-walks the document from offset 1, and the same name defined N times reports N
      times: 6400 duplicate definitions measured 5.4 s, all of it here and none of it in the
      detection. Two cursors, because the two diagnostics interleave and each is ascending
      only within itself. This is the fifth place that defect has been found; the pattern to
      look for is AddDiagAt inside a loop over occurrences. }
    InitSourceCursor(curDup);
    InitSourceCursor(curInc);
    for i := 0 to names.Count - 1 do
    begin
      { duplicate is reported at the LATER occurrence -- poss[i] is that line's '#' }
      if seen.ContainsKey(names[i]) then
        AddDiagAtOrdered(res, 'definition.duplicate-name', 'error', src, map,
                         poss[i], poss[i] + 4, curDup)
      else seen.Add(names[i], True);
      if kinds[i] = 'def' then
      begin
        p := Pos('#include', values[i]);
        if (p > 0) and ((p + 8 > Length(values[i])) or (not IsAsciiWord(values[i][p + 8]))) then
          AddDiagAtOrdered(res, 'def.include-in-value', 'error', src, map,
                           poss[i], poss[i] + 4, curInc);
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

{ How many forms the plural stage will actually RECEIVE -- or an admission that it is not
  knowable. Forms = 0 whenever Unresolved is set.

  Why it exists: SpRender expands %variables% and only THEN splits the form list, while
  this validator split the raw source, so any reference inside a form list was judged on
  the wrong number in BOTH directions -- a `#def %tail% = few|many` in `one|%tail%` made a
  correct 3-form Russian template report plural.arity, and a one-pipe list that expands to
  two forms reported nothing. Found here while adopting plural.locale-missing, then
  confirmed and fixed in all five engines (spintax-js#66).

  The rule is deliberately narrow, and the narrowness IS the correction. The reference's
  first version predicted the roll -- counting pipes at bracket depth 0, on the theory that
  a construct always collapses to one form. It does not: the false branch of a conditional
  `?flag?a|b|c` freezes as `b|c`, which is TWO forms, so

      #set %flag% =
      #def %x% = ... that conditional ...
      plural 1: one|%x%

  renders fine under ru while the guess reported plural.arity.

  So a value is counted only when its form count is the same WHATEVER the roll does -- when
  it carries no bracket at all. Anything else, any name the HOST may supply at render time,
  and any reference the template does not define suppress the count-based verdicts.
  Construct-free is a SUFFICIENT condition, deliberately not a necessary one.

  DirectMacroSpintax is the one prediction that survives, because it is not one: a #set
  named DIRECTLY in the form slot is substituted verbatim and is still spintax when the
  plural is decided, so its brackets earn plural.nested-brackets exactly as brackets
  written inline do. Reached through a #def it is rolled first and earns nothing. }
type
  TFormCount = record
    Forms: Integer;
    Unresolved: Boolean;
    DirectMacroSpintax: Boolean;
  end;

const
  { Passes, not occurrences -- each one substitutes EVERY reference, as the renderer's
    expansion does. Counting occurrences instead let a form list of 51 references exhaust
    the budget and go unjudged. Deliberately NOT claimed to match a renderer's own limit
    (they differ across the family): it only has to terminate, and a chain deeper than this
    is suppressed rather than judged, which is the safe direction. }
  FORM_EXPANSION_PASSES = 51;

  { How far the form list may GROW under expansion, in UTF-16 code units.

    Passes alone do NOT bound the work: `#set %a% = %b% %b%` over `#set %b% = %a% %a%`
    DOUBLES the text every pass, so 51 of them is 2^51 -- a 62-character template took the
    validator out with an out-of-memory crash in every engine of the family, this one
    included, and it reaches SpValidate through any endpoint a host exposes.

    GROWTH, not total size, and the difference is a verdict: a form list of 65 KB of
    ordinary text is plainly two forms and must keep earning plural.arity under ru. A
    ceiling on total LENGTH called that unknowable and flipped it to valid -- this port
    shipped that regression for the length of one review round, having ported the ceiling
    from upstream's work-in-progress before upstream's own review caught it. Expansion that
    ADDS this much is a graph exploding; a long form list is just long.

    Counted in UTF-16 code units, which is what the reference's `.length` counts -- not in
    bytes. The budget decides a verdict, and a byte count made it a different one: 40 000
    Cyrillic characters are 80 KB of UTF-8 and 40 000 units, so `plural 1: %x%` under en was
    silent here and invalid there. Codex review, 2026-08-18. }
  FORM_EXPANSION_MAX_GROWTH = 64 * 1024;

{ All four brackets, conditionals included.

  A conditional resolves before plurals, so it is not "unresolved at plural time" -- but
  its branches can differ in top-level pipes, and counting is about INVARIANCE rather than
  stage order. A closing bracket counts too: a #set holding a lone closer balances against
  an opener elsewhere in the template, so CheckBrackets stays quiet, while every renderer's
  plural guard rejects all four. The form test has to mirror that guard, not test for "a
  construct". }
{ JavaScript's `.length`: UTF-16 code units.

  Under a UTF-16 compiler that is what Length already returns. Under FPC the string is UTF-8
  bytes, so count the code points -- every byte that is not a continuation byte starts one --
  and add a second unit for the astral ones, which are a surrogate PAIR in UTF-16. No full
  decode is needed to count. }
{ How many UTF-16 units ONE code unit of this string contributes: under a UTF-16 compiler
  always one (a surrogate pair is two units and two chars alike); under FPC zero for a
  continuation byte, one for a lead, and two for an astral lead. }
function Utf16Units(c: Char): Integer;
begin
  {$IFDEF UNICODE}
  Result := 1;
  {$ELSE}
  if (Byte(c) and $C0) = $80 then Result := 0
  else if Byte(c) >= $F0 then Result := 2
  else Result := 1;
  {$ENDIF}
end;

function Utf16Len(const s: string): Integer;
{$IFDEF UNICODE}
begin
  Result := Length(s);
end;
{$ELSE}
var i: Integer; b: Byte;
begin
  Result := 0;
  for i := 1 to Length(s) do
  begin
    b := Byte(s[i]);
    if (b and $C0) <> $80 then
    begin
      Inc(Result);
      if b >= $F0 then Inc(Result);
    end;
  end;
end;
{$ENDIF}

function HasAnyBracket(const s: string): Boolean;
var i: Integer;
begin
  for i := 1 to Length(s) do
    if CharInSet(s[i], ['{', '}', '[', ']']) then Exit(True);
  Result := False;
end;

function ExpandFormsForCounting(const formsRaw: string; defs, macros: TStrMap;
  host: TDictionary<string, Boolean>): TFormCount;
var frames: TObjectList<TStringList>; idx: TList<Integer>;
    seen: TDictionary<string, Boolean>;
    refs: TStringList;
    verbatim: Integer; // 0 clean, 1 brackets, 2 opaque
    nm, macro, txt, val: string;
    pass, i, j, k, cnt, total, budget: Integer;
    sawRef, bailed, isRef: Boolean;
    buf: TStrBuf;
begin
  Result.Forms := 0; Result.Unresolved := True; Result.DirectMacroSpintax := False;
  j := 0;

  { Which brackets reach the form slot VERBATIM: follow the #set chain out of the raw slot,
    stopping at anything that changes the answer. "Direct" is a property of the PATH, not
    of one hop -- a #set whose value is another #set never crosses a #def, so the macro
    text arrives whole and the block renders as the fallback.

    Iterative, with the recursion's own visiting order: a form list may name a chain of
    macros as deep as the document is long, and a walk that recurses per link dies on input
    the renderer handles. }
  verbatim := 0;
  frames := TObjectList<TStringList>.Create(True);
  idx := TList<Integer>.Create;
  seen := TDictionary<string, Boolean>.Create;
  try
    refs := TStringList.Create; frames.Add(refs); idx.Add(0);
    RawReferences(formsRaw, refs);
    while (frames.Count > 0) and (verbatim = 0) do
    begin
      refs := frames[frames.Count - 1];
      k := idx[idx.Count - 1];
      if k >= refs.Count then
      begin
        frames.Delete(frames.Count - 1); idx.Delete(idx.Count - 1);
        Continue;
      end;
      idx[idx.Count - 1] := k + 1;
      nm := refs[k];
      { a #def rolls it, and a host value replaces it -- either way the macro text does not
        arrive verbatim, so this path says nothing }
      if defs.ContainsKey(nm) or host.ContainsKey(nm) then Continue;
      if not macros.TryGetValue(nm, macro) then Continue;
      if seen.ContainsKey(nm) then Continue;
      seen.Add(nm, True);
      { a conditional is where the ENGINES disagree: both PHP renderers resolve one that
        expansion introduces inside a form list, this port and the reference do not. Until
        that is settled (spintax-js#67), decline to judge rather than pick a side. }
      if Pos('{?', macro) > 0 then begin verbatim := 2; Break; end;
      if HasAnyBracket(macro) then begin verbatim := 1; Break; end;
      refs := TStringList.Create; frames.Add(refs); idx.Add(0);
      RawReferences(macro, refs);
    end;
  finally
    frames.Free; idx.Free; seen.Free;
  end;
  if verbatim = 1 then begin Result.DirectMacroSpintax := True; Exit; end;
  if verbatim = 2 then Exit;

  { The budget is what this pass may ADD to the list it started with, so a long-but-plain
    form list is judged and a graph exploding is not. Enforced DURING the pass, never after
    it: one pass can multiply the text by the size of the value it substitutes, and
    measuring afterwards means measuring an allocation that has already happened. Built by
    hand for the same reason -- 20 000 refs to a value holding 5 000 refs is 300 MB out of a
    75 KB template, acyclic, so the cycle detector never sees it. Measured 3.5 s before this
    check and 49 ms after. }
  budget := Utf16Len(formsRaw) + FORM_EXPANSION_MAX_GROWTH;
  txt := formsRaw;
  for pass := 1 to FORM_EXPANSION_PASSES do
  begin
    sawRef := False; bailed := False; total := 0;
    { EVERY reference per pass, as the renderer's expansion does. Replacing one at a time
      spends the budget on a list that merely repeats a name. }
    buf.Init(Length(txt) + 16);
    i := 1;
    while i <= Length(txt) do
    begin
      isRef := False;
      if txt[i] = '%' then
      begin
        j := i + 1; nm := '';
        while (j <= Length(txt)) and IsAsciiWord(txt[j]) do begin nm := nm + txt[j]; Inc(j); end;
        isRef := (nm <> '') and (j <= Length(txt)) and (txt[j] = '%');
      end;
      if not isRef then
      begin
        buf.AppendChar(txt[i]); Inc(total, Utf16Units(txt[i])); Inc(i);
        Continue;
      end;

      sawRef := True;
      nm := LowerAscii(nm);
      { runtime context outranks a definition of the same name, so a host-declared name
        makes the count unknowable even where the template defines one locally }
      if host.ContainsKey(nm) then bailed := True
      else if defs.TryGetValue(nm, val) then
      begin
        { a construct in the value: what it rolls to may or may not carry a top-level pipe,
          so no single count is true of every render }
        if HasAnyBracket(val) then bailed := True else buf.AppendStr(val);
      end
      else if macros.TryGetValue(nm, val) then
      begin
        if HasAnyBracket(val) then bailed := True else buf.AppendStr(val);
      end
      else bailed := True;
      if bailed then Break;
      Inc(total, Utf16Len(val));
      if total > budget then Exit; // the graph exploding, not a form list
      i := j + 1;
    end;
    if bailed then Exit; // unresolved, and Result already says so
    if total > budget then Exit;
    txt := buf.Finish;
    if not sawRef then
    begin
      { no construct can be left here, so the plain split is what the renderer does too }
      cnt := 1;
      for k := 1 to Length(txt) do if txt[k] = '|' then Inc(cnt);
      Result.Forms := cnt; Result.Unresolved := False;
      Exit;
    end;
  end;
  // a cycle, or a chain deeper than this bothers to follow
end;

procedure CheckPluralsV(const text, src, locale: string; known: TStringList;
  map: TList<Integer>; res: TSpDiagList);
var base: string; arity, defArity, i, k, cnt, m: Integer;
    counts, forms, kinds, names, values, refs: TStringList;
    tainted, host: TDictionary<string, Boolean>;
    defs, macros: TStrMap;
    formCache: TDictionary<string, Integer>;
    expanded: TFormCount; cached: Integer;
    starts: TList<Integer>;
    hasBracket: Boolean;
    curMacro, curForms: TSourceCursor;
begin
  base := '';
  if locale <> '' then base := NormalizeBaseLang(locale);
  if base <> '' then arity := PluralArity(base) else arity := 0;
  { How many forms RENDER resolves against when the host names no locale. Asked of the same
    table the renderer uses rather than written as 2: the whole of spintax-js#65 is the
    validator and the renderer disagreeing about that number, and a literal here is how they
    would drift apart again. }
  defArity := PluralArity('');

  kinds := TStringList.Create; names := TStringList.Create; values := TStringList.Create;
  tainted := TDictionary<string, Boolean>.Create;
  counts := TStringList.Create; forms := TStringList.Create;
  starts := TList<Integer>.Create;
  defs := TStrMap.Create; macros := TStrMap.Create;
  host := TDictionary<string, Boolean>.Create;
  formCache := TDictionary<string, Integer>.Create;
  try
    CollectOccurrences(text, kinds, names, values);
    BuildMacroTaint(kinds, names, values, tainted);
    FindPluralBlocks(text, counts, forms, starts);

    { One entry per name, the LAST definition winning and a #def of the same name not
      removing the #set -- the reference's extractDirectives returns two MAPS, and every
      downstream reader sees only the surviving value. Names arrive lower-cased from
      TryParseDirective. }
    for k := 0 to names.Count - 1 do
      if kinds[k] = 'def' then defs.AddOrSetValue(names[k], values[k])
      else macros.AddOrSetValue(names[k], values[k]);
    { names the HOST will supply: runtime context outranks a definition of the same name,
      so one of these makes a form count unknowable however the template defines it }
    if known <> nil then
      for k := 0 to known.Count - 1 do host.AddOrSetValue(LowerAscii(known[k]), True);

    { The plain AddDiagAt rescans from offset 1 per diagnostic, which is fine for a document
      raising two and O(document x blocks) for one raising thousands: 2000 no-locale 3-form
      blocks in 102 KB measured 1460 ms that way and 10 ms with a resumed cursor, and the
      same document with locale=en -- the plural.arity path, which has had this shape since
      it was written -- went 1705 ms to 10 ms. The no-locale case only became expensive when
      plural.locale-missing gave it a diagnostic to report; before that it raised none and
      cost 10 ms, so the warning would have shipped a 140x regression on the very shape it
      was added for. Sixth site of this defect (see AGENTS.md).

      TWO cursors, not one, because a resumed walk is only cheap while its offsets never go
      backwards. Blocks arrive in source order, but a single block can raise count-macro AND
      one of the others, and both anchor at the same start -- so after the first call left
      the cursor at start+8, the second asks for start again and CursorLineCol restarts from
      offset 1. Correct, and quadratic: 2000 such blocks measured 523 ms through one cursor
      and 11 ms through these two. Each is monotonic on its own, since count-macro fires at
      most once per block and nested-brackets / arity / locale-missing are mutually
      exclusive. Codex review, 2026-08-18, measured before and after. }
    InitSourceCursor(curMacro);
    InitSourceCursor(curForms);
    for i := 0 to counts.Count - 1 do
    begin
      { every plural diagnostic anchors at the block's '{plural ' (8-char prefix span) }
      // count-macro: a tainted #set name referenced in the count slot
      refs := TStringList.Create;
      try
        DirectReferences(counts[i], refs);
        for k := 0 to refs.Count - 1 do
          if tainted.ContainsKey(refs[k]) then
          begin
            AddDiagAtOrdered(res, 'plural.count-macro', 'error', src, map,
              starts[i], starts[i] + 8, curMacro); Break;
          end;
      finally
        refs.Free;
      end;

      hasBracket := False;
      for m := 1 to Length(forms[i]) do
        if CharInSet(forms[i][m], ['{', '}', '[', ']']) then begin hasBracket := True; Break; end;
      if hasBracket then
      begin
        AddDiagAtOrdered(res, 'plural.nested-brackets', 'error', src, map,
          starts[i], starts[i] + 8, curForms);
        Continue;
      end;

      { The form list AS THE RENDERER WILL SEE IT. SpRender expands %variables% and only
        then splits on '|', so counting the raw pipes judged a different string than the
        one that gets rendered -- in both directions (spintax-js#66).

        Memoized on the raw slot, because the answer depends on nothing else: defs, macros
        and host are fixed for the document. The point of a `#def` holding a form list is to
        name it in every block, so the identical slot arrives thousands of times -- 2000
        blocks naming one 20-link macro chain measured 140 ms walking it per block and 5 ms
        through the cache, against 8 ms for the raw count this replaced. Blocks sharing a
        slot is the SHAPE this feature is for, so it is the shape to measure -- where they
        do NOT share one, 2000 DISTINCT slots over the same chain cost 156 ms against the
        old 38 ms, linear in blocks x chain length and measured, not assumed. }
      if not formCache.TryGetValue(forms[i], cached) then
      begin
        expanded := ExpandFormsForCounting(forms[i], defs, macros, host);
        if expanded.DirectMacroSpintax then cached := -2
        else if expanded.Unresolved then cached := -1
        else cached := expanded.Forms;
        formCache.Add(forms[i], cached);
      end;
      expanded.DirectMacroSpintax := cached = -2;
      expanded.Unresolved := cached < 0;
      if cached > 0 then expanded.Forms := cached else expanded.Forms := 0;

      { A #set whose value carries spintax lands in the form list VERBATIM and is still
        unresolved when the plural is decided -- the same fact plural.count-macro states
        for the count slot. }
      if expanded.DirectMacroSpintax then
      begin
        AddDiagAtOrdered(res, 'plural.nested-brackets', 'error', src, map,
          starts[i], starts[i] + 8, curForms);
        Continue;
      end;

      { A reference the template does not define -- a host variable, or a chain past the
        budget -- has no static form count. Judging it would repeat the mistake
        plural.locale-missing was careful not to make: filing a verdict on a fact the
        caller never claimed. }
      if expanded.Unresolved then Continue;

      cnt := expanded.Forms;
      if arity > 0 then
      begin
        if cnt <> arity then
          AddDiagAtOrdered(res, 'plural.arity', 'error', src, map,
            starts[i], starts[i] + 8, curForms);
      end
      { No locale means no arity VERDICT, deliberately: the template may be right for the
        locale the host will render with, and failing a good template for a fact the caller
        never claimed is worse than silence. The RENDERER has no such luxury. It resolves
        against defArity whatever the caller said, so a block of any other form count comes
        out as the fullwidth-brace fallback, and those braces are U+FF5B/U+FF5D -- no
        downstream check scanning for ASCII braces will ever see them, which is how
        spintax-js#65 reached ~1000 live articles. So the seam is a WARNING: it says the one
        true thing, that this resolves only if a matching locale arrives at render time,
        without moving the verdict. A block of exactly defArity forms stays silent, because
        the default resolves it.

        cnt is the count the RENDERER will split, not the pipes as written -- see
        ExpandFormsForCounting. Both verdicts here were once taken on the raw list, which
        judged a different string than the one that gets rendered; spec sec.5.5 has the
        shapes and the tests that pin them. }
      else if cnt <> defArity then
        AddDiagAtOrdered(res, 'plural.locale-missing', 'warning', src, map,
          starts[i], starts[i] + 8, curForms);
    end;
  finally
    kinds.Free; names.Free; values.Free; tainted.Free; counts.Free; forms.Free; starts.Free;
    defs.Free; macros.Free; host.Free; formCache.Free;
  end;
end;

{ Which names reach a cycle, computed ONCE for the whole graph.

  The walk this replaces started afresh at every definition and remembered nothing across
  starts, so a converging graph re-explored its shared subgraphs -- exponentially, measured:
  a 914-byte document of 20 converging levels took 89 ms, and every four more levels cost
  six times as much. A single cycle of N definitions was walked N times.

  The predicate is narrower than "is in a cycle": a name is reported when it can REACH a
  cycle of length two or more. A direct self-loop is excluded -- that is
  `variable.self-reference`, reported separately -- which is why an edge from a name to
  itself is dropped when the graph is built.

  Standard colours: an edge to a grey node is a back edge and means the source reaches a
  cycle; an edge to a finished node inherits its answer; the answer propagates back along
  the path as the walk unwinds. Iterative, because a chain of definitions is as deep as it
  is long and 6400 of them is an ordinary generated document. }
procedure MarkCyclic(names: TStringList; refsOf: TObjectList<TStringList>;
  reaches: TDictionary<string, Boolean>);
var
  nodeOf: TDictionary<string, Integer>;
  adj: TIntBucketList;
  colour, iter, stack: TList<Integer>;
  hits: array of Boolean;
  i, k, u, v, top: Integer;
  refs: TStringList;
begin
  nodeOf := TDictionary<string, Integer>.Create;
  adj := TIntBucketList.Create(True);
  colour := TList<Integer>.Create;
  iter := TList<Integer>.Create;
  stack := TList<Integer>.Create;
  try
    for i := 0 to names.Count - 1 do
    begin
      nodeOf.Add(names[i], i);
      adj.Add(TIntList.Create);
      colour.Add(0);
      iter.Add(0);
    end;
    SetLength(hits, names.Count);

    { edges: the name's references, minus a self-loop, minus anything undefined }
    for u := 0 to names.Count - 1 do
    begin
      refs := refsOf[u];
      for k := 0 to refs.Count - 1 do
        if (refs[k] <> names[u]) and nodeOf.TryGetValue(refs[k], v) then
          adj[u].Add(v);
    end;

    for i := 0 to names.Count - 1 do
    begin
      if colour[i] <> 0 then Continue;
      stack.Clear;
      stack.Add(i); colour[i] := 1; iter[i] := 0;
      while stack.Count > 0 do
      begin
        top := stack.Count - 1;
        u := stack[top];
        if iter[u] < adj[u].Count then
        begin
          v := adj[u][iter[u]];
          iter[u] := iter[u] + 1;
          if colour[v] = 1 then hits[u] := True
          else if colour[v] = 2 then hits[u] := hits[u] or hits[v]
          else
          begin
            colour[v] := 1; iter[v] := 0;
            stack.Add(v);
          end;
        end
        else
        begin
          colour[u] := 2;
          stack.Delete(top);
          if stack.Count > 0 then
          begin
            v := stack[stack.Count - 1];
            hits[v] := hits[v] or hits[u];
          end;
        end;
      end;
    end;

    for i := 0 to names.Count - 1 do
      if hits[i] then reaches.AddOrSetValue(names[i], True);
  finally
    nodeOf.Free; adj.Free; colour.Free; iter.Free; stack.Free;
  end;
end;

{ The reference's cycle walk, reproduced exactly, because its OUTPUT COUNT is part of the
  contract the corpus gates and is not simply "one per name that reaches a cycle".

  Its shape, in prose: for each reference in the current name's value, in order -- skip a
  reference to the name itself, which is variable.self-reference; if the reference is
  already on the path, emit one diagnostic and RETURN; otherwise, if it names a definition,
  recurse with it appended to the path.

  Two details drive the count. References are NOT deduplicated -- the reference iterates the
  raw matches -- so a value naming the same variable twice walks it twice. And the return
  leaves only the CURRENT frame, so an outer frame keeps iterating after an inner one has
  reported; one start can therefore emit several diagnostics, all anchored at the START
  definition.

  It carries no memo, so the cost is the walk's: one start per definition that can reach a
  cycle, each descending until it meets its own path. For a document that is one cycle of N
  that is N diagnostics of N steps each -- quadratic, and quadratic is what the contract
  costs, since every one of those diagnostics is output. The two things that must NOT be
  paid on top of it are hashing and stack frames, so the walk below is over integer node
  indices with an explicit stack: no dictionary lookup per step, and depth bounded by the
  node count rather than by the machine stack. Written recursively over strings first, it
  took 99 SECONDS on a cycle of 6 400 (see the table in the spec).

  The one safe prune is `reaches`: a name that can reach no cycle at all can push nothing
  from any path, so the descent stops there. That keeps an ordinary document linear and
  leaves the counting untouched.

  `refIdx[i]` is node i's raw references in order, each mapped to a node index or -1 for a
  name that is not a definition -- which cannot be on the path and cannot be descended, so
  it is skipped exactly as the reference's two failed lookups skip it. }
procedure DetectCyclesRef(refIdx: TIntBucketList; names: TStringList;
  const reach: array of Boolean; posOf: TDictionary<string, Integer>;
  res: TSpDiagList; const src: string; map: TList<Integer>; var cur: TSourceCursor);
var n, start, top, node, r, anchor: Integer;
    onPath: array of Boolean;
    stkNode, stkPos: array of Integer;
    refs: TIntList;
begin
  n := names.Count;
  SetLength(onPath, n);
  { the path holds distinct nodes, so it can never be deeper than the node count }
  SetLength(stkNode, n + 1);
  SetLength(stkPos, n + 1);
  for start := 0 to n - 1 do
  begin
    if not reach[start] then Continue;
    anchor := posOf[names[start]];
    top := 0;
    stkNode[0] := start; stkPos[0] := 0;
    onPath[start] := True;
    while top >= 0 do
    begin
      node := stkNode[top];
      refs := refIdx[node];
      if stkPos[top] >= refs.Count then
      begin
        onPath[node] := False;                { frame exhausted: pop, unmarking the path }
        Dec(top);
        Continue;
      end;
      r := refs[stkPos[top]];
      Inc(stkPos[top]);
      if (r < 0) or (r = node) then Continue; { undefined name / a self-loop, which is
                                                variable.self-reference instead }
      if onPath[r] then
      begin
        AddDiagAtOrdered(res, 'variable.circular-reference', 'error', src, map,
                         anchor, anchor + 4, cur);
        onPath[node] := False;                { the reference returns from THIS frame only,
                                                so the frame below it keeps iterating }
        Dec(top);
        Continue;
      end;
      if reach[r] then
      begin
        onPath[r] := True;
        Inc(top);
        stkNode[top] := r; stkPos[top] := 0;
      end;
    end;
  end;
end;

procedure CheckVariableRefsV(const text, src: string; map: TList<Integer>;
  KnownIncludes: TStringList; res: TSpDiagList);
var kinds, defNames, defValues, names: TStringList; i, k, at: Integer;
    poss: TList<Integer>;
    valueOf: TStrMap;
    posOf: TDictionary<string, Integer>;
    reaches: TDictionary<string, Boolean>;
    nameIdx: TDictionary<string, Integer>;
    refsOf, rawRefs: TObjectList<TStringList>;
    refIdx: TIntBucketList;
    ints: TIntList;
    reachArr: array of Boolean;
    refs: TStringList;
    curSelf, curCirc: TSourceCursor;
begin
  kinds := TStringList.Create; defNames := TStringList.Create; defValues := TStringList.Create;
  poss := TList<Integer>.Create;
  names := TStringList.Create;
  valueOf := TStrMap.Create;
  posOf := TDictionary<string, Integer>.Create;
  refsOf := TObjectList<TStringList>.Create(True);
  reaches := TDictionary<string, Boolean>.Create;
  try
    CollectOccurrences(text, kinds, defNames, defValues, poss);

    { DEDUPLICATE BY NAME, LAST DEFINITION WINS. The reference builds a Map and sets each
      name in document order, so a repeated name keeps only its LAST value -- and both the
      self-reference test and the cycle walk run over that map, one entry per NAME rather
      than one per occurrence.

      This port used every occurrence and resolved a name to the FIRST of them, which
      diverged in both directions. Measured against @spintax/core on 2026-08-06:

        selfref then plain      we reported self-reference; the reference does not, because
                                the surviving value is the plain one
        cycle then plain        we reported the cycle three times; the reference reports
                                none, because the surviving value breaks it
        plain then cycle        we reported NOTHING; the reference reports the cycle twice,
                                because the surviving value makes it

      A JS Map keeps a key's FIRST insertion position when a later set overwrites it, so
      the iteration order below is first-seen order while the value and the anchor are the
      last one's. }
    for i := 0 to defNames.Count - 1 do
    begin
      if not valueOf.ContainsKey(defNames[i]) then names.Add(defNames[i]);
      valueOf.AddOrSetValue(defNames[i], defValues[i]);
      posOf.AddOrSetValue(defNames[i], poss[i]);
    end;
    for i := 0 to names.Count - 1 do
    begin
      refs := TStringList.Create;
      refsOf.Add(refs);
      DirectReferences(valueOf[names[i]], refs);
    end;

    { Both loops report in first-seen order while anchoring at the LAST definition, so the
      offsets need not ascend; CursorLineCol restarts when they do not, which costs a walk
      and never an answer. }
    InitSourceCursor(curSelf);
    InitSourceCursor(curCirc);
    // self-reference -- at the surviving #set/#def line
    for i := 0 to names.Count - 1 do
      if Pos('%' + names[i] + '%', LowerAscii(valueOf[names[i]])) > 0 then
      begin
        at := posOf[names[i]];
        AddDiagAtOrdered(res, 'variable.self-reference', 'error', src, map,
                         at, at + 4, curSelf);
      end;
    { circular -- the reference's own walk, pruned by the global reachability set and run
      over node indices (see DetectCyclesRef for why the strings had to go) }
    MarkCyclic(names, refsOf, reaches);
    nameIdx := TDictionary<string, Integer>.Create;
    rawRefs := TObjectList<TStringList>.Create(True);
    refIdx := TIntBucketList.Create(True);
    try
      for i := 0 to names.Count - 1 do nameIdx.Add(names[i], i);
      SetLength(reachArr, names.Count);
      for i := 0 to names.Count - 1 do
        reachArr[i] := reaches.ContainsKey(names[i]);
      for i := 0 to names.Count - 1 do
      begin
        refs := TStringList.Create;
        rawRefs.Add(refs);
        RawReferences(valueOf[names[i]], refs);
        ints := TIntList.Create;
        refIdx.Add(ints);
        for k := 0 to refs.Count - 1 do
          if nameIdx.TryGetValue(refs[k], at) then ints.Add(at) else ints.Add(-1);
      end;
      DetectCyclesRef(refIdx, names, reachArr, posOf, res, src, map, curCirc);
    finally
      nameIdx.Free; rawRefs.Free; refIdx.Free;
    end;
    // (undefined-variable warnings are emitted in SpValidate against the body scan)
  finally
    kinds.Free; defNames.Free; defValues.Free; poss.Free;
    names.Free; valueOf.Free; posOf.Free; refsOf.Free; reaches.Free;
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
  CheckPluralsV(text, Src, Locale, KnownVariables, smap, Result);
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

end.
