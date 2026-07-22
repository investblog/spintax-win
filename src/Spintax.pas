(*
 * Spintax — Object Pascal (Delphi-mode) port of the reference @spintax/core.
 *
 * Ported from the reference TypeScript engine (github.com/investblog/spintax-js,
 * packages/core), held to the SAME golden-fixture corpus. Scope of this port:
 * parse + render (enumeration / permutation / variable / conditional / plural),
 * hash-set / hash-def directives, neutralize / safety-restore, extract. The
 * cosmetic post-process stage is minimal (ASCII spacing + first-letter
 * capitalize); full URL/email/Unicode shielding is the documented remainder.
 *
 * UTF-8 note: the structural scan only ever branches on ASCII bytes (the brace,
 * bracket, percent, hash, pipe, colon and angle chars plus ASCII whitespace);
 * UTF-8 continuation bytes never collide with those, so Cyrillic/other text
 * passes through byte-exact without a Unicode layer. FPC 3.2.2, mode delphi.
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

  TSpContext = record
    Vars: TStrMap;       // runtime context, keys lower-cased (caller owns)
    Locale: string;
    PostProcess: Boolean;
    Rng: TSpRng;         // caller owns
  end;

  TExtractResult = record
    Refs, Sets, Defs, Includes: TStringList;
  end;

  { A single validator finding. Severity is 'error' or 'warning'; a template is
    "invalid" iff any diagnostic is 'error' (positions are not modelled — the
    corpus asserts codes + severity only). }
  TSpDiag = record
    Code: string;
    Severity: string;
  end;
  TSpDiagList = TList<TSpDiag>;

{ Public API }
function SpRender(const Template: string; const Ctx: TSpContext): string;
function SpNeutralize(const Value: string): string;
function SpSafetyRestore(const Text: string): string;
function SpStripSentinels(const Text: string): string;
function SpExtract(const Src: string): TExtractResult;
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
     and (Ord(s[i + 1]) >= $DC00) and (Ord(s[i + 1]) <= $DFFF) then
  begin
    Result := $10000 + ((Result - $D800) shl 10) + (Ord(s[i + 1]) - $DC00);
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
  cpLen := n;
  {$ENDIF}
end;

{ A code point in this compiler's string encoding. }
function SpCodePointToStr(cp: LongWord): string;
begin
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

{ Remove /# ... #/ block comments (non-greedy, spans newlines). }
function StripComments(const text: string): string;
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
      Result := Result + text[i];
      Inc(i);
    end;
  end;
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
  // rstrip [ \t] and trailing \r
  value := PhpRtrim(value); // strips \t \n \r \0 \x0B space; fine (single line, no \n)
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

procedure ExtractDirectives(const text: string; setDefs, defDefs: TStrMap; out body: string);
var
  kind, nm, val, kept, line: string;
  lineStart, n, e, termLen: Integer;
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
    if TryParseDirective(line, kind, nm, val) then
    begin
      if kind = 'def' then defDefs.AddOrSetValue(nm, val)
      else setDefs.AddOrSetValue(nm, val);
      // emit nothing for the directive's own text
    end
    else
      kept := kept + line;
    // Keep the terminator that was actually there. Emitting #10 for every line would
    // turn a bare CR into LF; the reference preserves the character it broke on.
    if termLen > 0 then kept := kept + Copy(text, e, termLen);
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

{ Permutation config parse (faithful-enough: key form or single-separator form). }
procedure ParsePermConfig(const raw: string; node: TNode; out content: string);
var trimmed, configStr, remaining, low, sv: string; endPos, i: Integer; inQuote: Boolean;
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
  low := LowerAscii(configStr);
  // key form?
  if (Pos('minsize', low) > 0) or (Pos('maxsize', low) > 0)
     or (Pos('sep', low) > 0) or (Pos('lastsep', low) > 0) then
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

procedure DirectReferences(const text: string; target: TStringList);
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
        if target.IndexOf(LowerAscii(nm)) < 0 then target.Add(LowerAscii(nm));
        i := j + 1; Continue;
      end;
    end;
    Inc(i);
  end;
end;

{ ─── public render pipeline ──────────────────────────────────────────────── }

function MinimalPostProcess(const input: string): string;
var s, res: string; i: Integer;
begin
  s := input;
  // collapse runs of space/tab to single space
  res := ''; i := 1;
  while i <= Length(s) do
  begin
    if (s[i] = ' ') or (s[i] = #9) then
    begin
      res := res + ' ';
      while (i <= Length(s)) and ((s[i] = ' ') or (s[i] = #9)) do Inc(i);
    end
    else begin res := res + s[i]; Inc(i); end;
  end;
  s := res;
  // remove space before , ; : ! ? .
  res := ''; i := 1;
  while i <= Length(s) do
  begin
    if (s[i] = ' ') and (i < Length(s)) and IsAsciiSentencePunct(s[i+1]) then
      // skip the space
    else res := res + s[i];
    Inc(i);
  end;
  s := res;
  // capitalize first ASCII letter (skip leading spaces)
  i := 1;
  while (i <= Length(s)) and (s[i] = ' ') do Inc(i);
  if (i <= Length(s)) and IsAsciiLower(s[i]) then s[i] := Chr(Ord(s[i]) - 32);
  // trim
  Result := Trim(s);
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

function SpRender(const Template: string; const Ctx: TSpContext): string;
var setDefs, defDefs, vars, aliases: TStrMap;
    ownedRng: TSpRng;
    body, outp: string;
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
  { Owned only when the caller supplied none; the caller's own Rng is never freed here. }
  if Ctx.Rng = nil then ownedRng := MakeDefaultRng else ownedRng := nil;
  try
    ExtractDirectives(StripComments(SpStripSentinels(Template)), setDefs, defDefs, body);

    // buildVars: setDefs raw, then runtime context overlays (lower-cased)
    for pair in setDefs do vars.AddOrSetValue(pair.Key, pair.Value);
    if Assigned(Ctx.Vars) then
      for pair in Ctx.Vars do
      begin
        vars.AddOrSetValue(LowerAscii(pair.Key), pair.Value);
        outranked.Add(LowerAscii(pair.Key));
      end;

    opts.Vars := vars;
    opts.Locale := Ctx.Locale;
    opts.Depth := 0;
    if ownedRng <> nil then opts.Rng := ownedRng else opts.Rng := Ctx.Rng;

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
      outp := RenderNodes(nodes, opts);
    finally
      nodes.Free;
    end;

    if Ctx.PostProcess then outp := MinimalPostProcess(outp);
    Result := SpSafetyRestore(outp);
  finally
    setDefs.Free; defDefs.Free; vars.Free; outranked.Free; ownedRng.Free;
  end;
end;

{ ─── extract ─────────────────────────────────────────────────────────────── }

procedure CollectDirectiveNames(const text, directive: string; target: TStringList);
var lineStart, e, n, termLen: Integer; line, kind, nm, val: string;
begin
  n := Length(text); lineStart := 1;
  while lineStart <= n + 1 do
  begin
    e := NextLineBreak(text, lineStart, termLen);
    line := Copy(text, lineStart, e - lineStart);
    if TryParseDirective(line, kind, nm, val) and (kind = directive) then
      if target.IndexOf(nm) < 0 then target.Add(nm);
    if e > n then Break;
    lineStart := e + termLen;
  end;
end;

function SpExtract(const Src: string): TExtractResult;
var text, body, line, kind, nm, val, ref: string;
    i, j, p, q, r, lineStart, e, n, termLen: Integer;
begin
  text := StripComments(Src);
  Result.Refs := TStringList.Create;
  Result.Sets := TStringList.Create;
  Result.Defs := TStringList.Create;
  Result.Includes := TStringList.Create;

  CollectDirectiveNames(text, 'set', Result.Sets);
  CollectDirectiveNames(text, 'def', Result.Defs);

  // includes: ^[ \t]*#include[ \t...]+"ref"
  n := Length(text); lineStart := 1;
  while lineStart <= n + 1 do
  begin
    e := NextLineBreak(text, lineStart, termLen);
    line := Copy(text, lineStart, e - lineStart);
    p := 1;
    while (p <= Length(line)) and (CharInSet(line[p], [' ', #9])) do Inc(p);
    if Copy(line, p, 8) = '#include' then
    begin
      q := Pos('"', line);
      if q > 0 then
      begin
        r := PosEx('"', line, q + 1);
        if r > q then
        begin
          ref := Copy(line, q + 1, r - q - 1);
          if Result.Includes.IndexOf(ref) < 0 then Result.Includes.Add(ref);
        end;
      end;
    end;
    if e > n then Break;
    lineStart := e + termLen;
  end;

  // body: drop #set/#def LHS, then collect %var% and {?name? refs (lower-cased)
  body := '';
  lineStart := 1;
  while lineStart <= n + 1 do
  begin
    e := NextLineBreak(text, lineStart, termLen);
    line := Copy(text, lineStart, e - lineStart);
    if TryParseDirective(line, kind, nm, val) then
      body := body + '=' + val   // keep value, drop LHS (leading '=' harmless for %var% scan)
    else
      body := body + line;
    body := body + #10;
    if e > n then Break;
    lineStart := e + termLen;
  end;

  DirectReferences(body, Result.Refs);
  // conditional refs {?name? / {?!name?
  i := 1;
  while i <= Length(body) do
  begin
    if (i + 1 <= Length(body)) and (body[i] = '{') and (body[i+1] = '?') then
    begin
      j := i + 2;
      if (j <= Length(body)) and (body[j] = '!') then Inc(j);
      nm := '';
      if (j <= Length(body)) and (CharInSet(body[j], ['A'..'Z','a'..'z','_'])) then
      begin
        nm := nm + body[j]; Inc(j);
        while (j <= Length(body)) and IsAsciiWord(body[j]) do begin nm := nm + body[j]; Inc(j); end;
        if (j <= Length(body)) and (body[j] = '?') then
          if Result.Refs.IndexOf(LowerAscii(nm)) < 0 then Result.Refs.Add(LowerAscii(nm));
      end;
    end;
    Inc(i);
  end;
end;

{ ─── validate ───────────────────────────────────────────────────────────── }

function SpStartsWith(const s, p: string): Boolean;
begin
  Result := (Length(s) >= Length(p)) and (Copy(s, 1, Length(p)) = p);
end;

procedure AddDiag(list: TSpDiagList; const code, sev: string);
var d: TSpDiag;
begin
  d.Code := code; d.Severity := sev;
  list.Add(d);
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

{ Collect well-formed #set/#def occurrences in source order (parallel lists). }
procedure CollectOccurrences(const text: string; kinds, names, values: TStringList);
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
    end;
    if e > n then Break;
    lineStart := e + termLen;
  end;
end;

{ Brace-aware scan for plural blocks (finds them inside permutations too). }
procedure FindPluralBlocks(const text: string; counts, forms: TStringList);
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
    i := j + 1;
  end;
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

procedure CheckBrackets(const text: string; res: TSpDiagList);
type TOpen = record ch: Char; end;
var stack: array of Char; top, i: Integer; ch, opener: Char;
begin
  SetLength(stack, 0); top := 0;
  for i := 1 to Length(text) do
  begin
    ch := text[i];
    if (ch = '{') or (ch = '[') then
    begin
      SetLength(stack, top + 1); stack[top] := ch; Inc(top);
    end
    else if (ch = '}') or (ch = ']') then
    begin
      if top = 0 then AddDiag(res, 'bracket.unexpected-closing', 'error')
      else
      begin
        opener := stack[top - 1]; Dec(top);
        if ((opener = '{') and (ch <> '}')) or ((opener = '[') and (ch <> ']')) then
          AddDiag(res, 'bracket.mismatched', 'error');
      end;
    end;
  end;
  for i := 0 to top - 1 do AddDiag(res, 'bracket.unclosed', 'error');
end;

procedure CheckDirectivesV(const text: string; res: TSpDiagList);
var lineStart, e, n, i, seenIdx, p, termLen: Integer;
    line, t, kind, nm, val: string;
    isSet, isDef: Boolean;
    kinds, names, values, seen: TStringList;
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
      if isDef then AddDiag(res, 'def.malformed', 'error')
      else AddDiag(res, 'set.malformed', 'error');
    end;
    if e > n then Break;
    lineStart := e + termLen;
  end;

  // duplicate names + #include in a #def value
  kinds := TStringList.Create; names := TStringList.Create; values := TStringList.Create;
  seen := TStringList.Create;
  try
    CollectOccurrences(text, kinds, names, values);
    for i := 0 to names.Count - 1 do
    begin
      seenIdx := seen.IndexOf(names[i]);
      if seenIdx >= 0 then AddDiag(res, 'definition.duplicate-name', 'error')
      else seen.Add(names[i]);
      if kinds[i] = 'def' then
      begin
        p := Pos('#include', values[i]);
        if (p > 0) and ((p + 8 > Length(values[i])) or (not IsAsciiWord(values[i][p + 8]))) then
          AddDiag(res, 'def.include-in-value', 'error');
      end;
    end;
  finally
    kinds.Free; names.Free; values.Free; seen.Free;
  end;
end;

procedure CheckPermConfigsV(const text: string; res: TSpDiagList);
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
          if (low <> 'minsize') and (low <> 'maxsize') and (low <> 'sep') and (low <> 'lastsep') then
            AddDiag(res, 'permutation.unknown-key', 'error');
        end;
        k := b;
      end
      else Inc(k);
    end;

    numv := ExtractNum(configStr, 'minsize');
    if (numv <> #1) and (not DigitsOnly(numv)) then AddDiag(res, 'permutation.minsize-not-integer', 'error');
    numv := ExtractNum(configStr, 'maxsize');
    if (numv <> #1) and (not DigitsOnly(numv)) then AddDiag(res, 'permutation.maxsize-not-integer', 'error');
  end;
end;

procedure CheckPluralsV(const text, locale: string; res: TSpDiagList);
var base: string; arity, i, k, cnt, m: Integer;
    counts, forms, tainted, kinds, names, values, refs: TStringList;
    hasBracket: Boolean;
begin
  base := '';
  if locale <> '' then base := NormalizeBaseLang(locale);
  if base <> '' then arity := PluralArity(base) else arity := 0;

  kinds := TStringList.Create; names := TStringList.Create; values := TStringList.Create;
  tainted := TStringList.Create;
  counts := TStringList.Create; forms := TStringList.Create;
  try
    CollectOccurrences(text, kinds, names, values);
    BuildMacroTaint(kinds, names, values, tainted);
    FindPluralBlocks(text, counts, forms);

    for i := 0 to counts.Count - 1 do
    begin
      // count-macro: a tainted #set name referenced in the count slot
      refs := TStringList.Create;
      try
        DirectReferences(counts[i], refs);
        for k := 0 to refs.Count - 1 do
          if tainted.IndexOf(refs[k]) >= 0 then
          begin
            AddDiag(res, 'plural.count-macro', 'error'); Break;
          end;
      finally
        refs.Free;
      end;

      hasBracket := False;
      for m := 1 to Length(forms[i]) do
        if CharInSet(forms[i][m], ['{', '}', '[', ']']) then begin hasBracket := True; Break; end;
      if hasBracket then
      begin
        AddDiag(res, 'plural.nested-brackets', 'error');
        Continue;
      end;

      if arity > 0 then
      begin
        cnt := 1;
        for m := 1 to Length(forms[i]) do if forms[i][m] = '|' then Inc(cnt);
        if cnt <> arity then AddDiag(res, 'plural.arity', 'error');
      end;
    end;
  finally
    kinds.Free; names.Free; values.Free; tainted.Free; counts.Free; forms.Free;
  end;
end;

procedure DetectCycleV(const current: string; defNames, defValues: TStringList;
  visited: TStringList; res: TSpDiagList; var reported: Boolean);
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
        AddDiag(res, 'variable.circular-reference', 'error');
        reported := True; Exit;
      end;
      if defNames.IndexOf(ref) >= 0 then
      begin
        visited.Add(ref);
        DetectCycleV(ref, defNames, defValues, visited, res, reported);
        visited.Delete(visited.Count - 1);
        if reported then Exit;
      end;
    end;
  finally
    refs.Free;
  end;
end;

procedure CheckVariableRefsV(const text: string; KnownIncludes: TStringList; res: TSpDiagList);
var kinds, defNames, defValues, visited: TStringList; i: Integer; reported: Boolean;
begin
  kinds := TStringList.Create; defNames := TStringList.Create; defValues := TStringList.Create;
  try
    CollectOccurrences(text, kinds, defNames, defValues);
    // self-reference
    for i := 0 to defNames.Count - 1 do
      if Pos('%' + defNames[i] + '%', LowerAscii(defValues[i])) > 0 then
        AddDiag(res, 'variable.self-reference', 'error');
    // circular
    for i := 0 to defNames.Count - 1 do
    begin
      reported := False;
      visited := TStringList.Create;
      try
        visited.Add(defNames[i]);
        DetectCycleV(defNames[i], defNames, defValues, visited, res, reported);
      finally
        visited.Free;
      end;
    end;
    // (undefined-variable warnings are emitted in SpValidate against the body scan)
  finally
    kinds.Free; defNames.Free; defValues.Free;
  end;
end;

function SpValidate(const Src, Locale: string; KnownIncludes: TStringList): TSpDiagList;
begin
  Result := SpValidate(Src, Locale, KnownIncludes, nil);
end;

function SpValidate(const Src, Locale: string;
  KnownIncludes, KnownVariables: TStringList): TSpDiagList;
var text, body, line, kind, nm, val, ref: string;
    lineStart, e, n, p, q, r, i, j, termLen: Integer;
    kinds, defNames, defValues, seenUndef: TStringList;
begin
  Result := TSpDiagList.Create;
  text := StripComments(Src);

  CheckBrackets(text, Result);
  CheckDirectivesV(text, Result);
  CheckPermConfigsV(text, Result);
  CheckPluralsV(text, Locale, Result);
  CheckVariableRefsV(text, KnownIncludes, Result);

  // include.unknown-target (only when a slug list is supplied)
  if (KnownIncludes <> nil) and (KnownIncludes.Count > 0) then
  begin
    n := Length(text); lineStart := 1;
    while lineStart <= n + 1 do
    begin
      e := NextLineBreak(text, lineStart, termLen);
      line := Copy(text, lineStart, e - lineStart);
      p := 1;
      while (p <= Length(line)) and (CharInSet(line[p], [' ', #9])) do Inc(p);
      if Copy(line, p, 8) = '#include' then
      begin
        q := Pos('"', line);
        if q > 0 then
        begin
          r := PosEx('"', line, q + 1);
          if r > q then
          begin
            ref := Copy(line, q + 1, r - q - 1);
            if KnownIncludes.IndexOf(ref) < 0 then AddDiag(Result, 'include.unknown-target', 'error');
          end;
        end;
      end;
      if e > n then Break;
      lineStart := e + termLen;
    end;
  end;

  // undefined-variable warnings: scan body (directive lines dropped), skip defined names
  kinds := TStringList.Create; defNames := TStringList.Create; defValues := TStringList.Create;
  seenUndef := TStringList.Create;
  try
    CollectOccurrences(text, kinds, defNames, defValues);
    // A host-declared variable counts as defined for this check, so seeding defNames
    // suppresses the warning at both reference sites below without duplicating the test.
    // Names are compared lower-cased, like every other variable name in the engine.
    if KnownVariables <> nil then
      for i := 0 to KnownVariables.Count - 1 do
        if defNames.IndexOf(LowerAscii(KnownVariables[i])) < 0 then
          defNames.Add(LowerAscii(KnownVariables[i]));
    // build body = non-directive lines
    body := '';
    n := Length(text); lineStart := 1;
    while lineStart <= n + 1 do
    begin
      e := NextLineBreak(text, lineStart, termLen);
      line := Copy(text, lineStart, e - lineStart);
      if not TryParseDirective(line, kind, nm, val) then body := body + line;
      body := body + #10;
      if e > n then Break;
      lineStart := e + termLen;
    end;
    // %var% refs
    i := 1;
    while i <= Length(body) do
    begin
      if body[i] = '%' then
      begin
        j := i + 1; nm := '';
        while (j <= Length(body)) and IsAsciiWord(body[j]) do begin nm := nm + body[j]; Inc(j); end;
        if (nm <> '') and (j <= Length(body)) and (body[j] = '%') then
        begin
          nm := LowerAscii(nm);
          if (defNames.IndexOf(nm) < 0) and (seenUndef.IndexOf(nm) < 0) then
          begin
            seenUndef.Add(nm);
            AddDiag(Result, 'variable.undefined', 'warning');
          end;
          i := j + 1; Continue;
        end;
      end;
      Inc(i);
    end;
    // {?name? / {?!name? refs
    i := 1;
    while i <= Length(body) do
    begin
      if (i + 1 <= Length(body)) and (body[i] = '{') and (body[i+1] = '?') then
      begin
        j := i + 2;
        if (j <= Length(body)) and (body[j] = '!') then Inc(j);
        nm := '';
        if (j <= Length(body)) and (CharInSet(body[j], ['A'..'Z','a'..'z','_'])) then
        begin
          nm := nm + body[j]; Inc(j);
          while (j <= Length(body)) and IsAsciiWord(body[j]) do begin nm := nm + body[j]; Inc(j); end;
          if (j <= Length(body)) and (body[j] = '?') then
          begin
            nm := LowerAscii(nm);
            if (defNames.IndexOf(nm) < 0) and (seenUndef.IndexOf(nm) < 0) then
            begin
              seenUndef.Add(nm);
              AddDiag(Result, 'variable.undefined', 'warning');
            end;
          end;
        end;
      end;
      Inc(i);
    end;
  finally
    kinds.Free; defNames.Free; defValues.Free; seenUndef.Free;
  end;
end;

end.
