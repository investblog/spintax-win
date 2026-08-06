{**
 * local_tests -- assertions the golden corpus structurally cannot make.
 *
 * The corpus schema has no field for line terminators other than LF, for a nil RNG,
 * for #include resolution, permutation <config> or plural lenient fallbacks (spec sec.8).
 * Every real bug in the sibling ports lived on exactly those surfaces, and two of this
 * port's own did too. A fix on an ungated surface is a fix that will silently regress.
 *
 * Expectations here are MEASURED AGAINST THE REFERENCE, never written by reading this
 * port. Where a case came from an outside measurement, the comment says so.
 *
 * Exits 1 on the first failure; the pre-push gate and CI both run it.
 *}
program local_tests;

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}
{$APPTYPE CONSOLE}

uses
  SysUtils, Classes, Generics.Collections,
  {$IFDEF FPC}
  Spintax;
  {$ELSE}
  Spintax in '..\src\Spintax.pas';
  {$ENDIF}

var
  Failures: Integer = 0;
  Checks: Integer = 0;

function Hex(const s: string): string;
var i: Integer;
begin
  Result := '';
  for i := 1 to Length(s) do Result := Result + IntToHex(Ord(s[i]), 2) + ' ';
  Result := TrimRight(Result);
end;

procedure Check(const name, got, want: string);
begin
  Inc(Checks);
  if got = want then Exit;
  Inc(Failures);
  Writeln('FAIL ', name);
  Writeln('     want <', Hex(want), '>');
  Writeln('     got  <', Hex(got), '>');
end;

{ U+FF5B / U+FF5D -- the fullwidth braces the engine emits when a block is too malformed
  to render but must not throw. Spelled per string width, like the engine's own literals. }
function FullwidthBrace(opening: Boolean): string;
begin
  {$IFDEF UNICODE}
  if opening then Result := #$FF5B else Result := #$FF5D;
  {$ELSE}
  if opening then Result := #$EF#$BD#$9B else Result := #$EF#$BD#$9D;
  {$ENDIF}
end;

function RenderFirst(const tmpl: string): string;
var ctx: TSpContext;
begin
  ctx := Default(TSpContext);
  ctx.Locale := 'en';
  ctx.PostProcess := False;
  ctx.Rng := TFirstRng.Create;
  try
    Result := SpRender(tmpl, ctx);
  finally
    ctx.Rng.Free;
  end;
end;

function Verdict(const tmpl: string): string;
var d: TSpDiagList; i: Integer;
begin
  Result := 'valid';
  d := SpValidate(tmpl, 'en', nil);
  try
    for i := 0 to d.Count - 1 do
      if d[i].Severity = 'error' then Exit('invalid');
  finally
    d.Free;
  end;
end;

{ The reference scans directives with /^...$/gmu, and JavaScript's multiline anchors
  break on LF, CR, U+2028 and U+2029. Measured against the reference: the template
  `#set %x% = A` + CR + `%x%` renders CR + 'A' and validates as valid. This port used to
  split on LF alone, rendering nothing and reporting invalid. }
procedure TestLineTerminators;
const
  U2028 = {$IFDEF UNICODE} #$2028 {$ELSE} #$E2#$80#$A8 {$ENDIF};
  U2029 = {$IFDEF UNICODE} #$2029 {$ELSE} #$E2#$80#$A9 {$ENDIF};
begin
  Check('terminator/LF render',    RenderFirst('#set %x% = A'#10'%x%'), #10'A');
  Check('terminator/CR render',    RenderFirst('#set %x% = A'#13'%x%'), #13'A');
  { A directive line does not leave its CR whole. The reference's `[ \t]*\r?$` is greedy, so
    it takes the CR whenever $ still holds AFTER it -- and under /m that is end of input or
    ANY line terminator. So the CR goes for (end), CR, LF, U+2028 and U+2029, and survives
    only in front of an ordinary character, as in `terminator/CR render` above. All six
    measured 2026-07-25; this line first expected the CRLF back on a measurement never
    taken, and then, once corrected, the rule was written as "CRLF only", which is one shape
    out of five. }
  Check('terminator/CRLF render',  RenderFirst('#set %x% = A'#13#10'%x%'), #10'A');
  Check('terminator/CR at end of input', RenderFirst('#set %x% = A'#13), '');
  Check('terminator/CR before CR',  RenderFirst('#set %x% = A'#13#13'%x%'), #13'A');
  Check('terminator/CR before U2028',
        RenderFirst('#set %x% = A'#13 + U2028 + '%x%'), U2028 + 'A');
  Check('terminator/CR before U2029',
        RenderFirst('#set %x% = A'#13 + U2029 + '%x%'), U2029 + 'A');
  Check('terminator/CRLF def render', RenderFirst('#def %x% = A'#13#10'%x%'), #10'A');
  Check('terminator/CRLF two directives',
        RenderFirst('#set %x% = A'#13#10'#set %y% = B'#13#10'%x%%y%'), #10#10'AB');
  { ...and a line that is NOT a directive keeps its CRLF, because nothing matched it. }
  Check('terminator/CRLF plain line',
        RenderFirst('plain'#13#10'%x%'), 'plain'#13#10'%x%');
  Check('terminator/U2028 render', RenderFirst('#set %x% = A' + U2028 + '%x%'), U2028 + 'A');
  Check('terminator/U2029 render', RenderFirst('#set %x% = A' + U2029 + '%x%'), U2029 + 'A');

  Check('terminator/LF validate',    Verdict('#set %x% = A'#10'%x%'), 'valid');
  Check('terminator/CR validate',    Verdict('#set %x% = A'#13'%x%'), 'valid');
  Check('terminator/CRLF validate',  Verdict('#set %x% = A'#13#10'%x%'), 'valid');
  Check('terminator/U2028 validate', Verdict('#set %x% = A' + U2028 + '%x%'), 'valid');
  Check('terminator/U2029 validate', Verdict('#set %x% = A' + U2029 + '%x%'), 'valid');

  { A terminator inside a value must still end the directive, not be swallowed by it. }
  Check('terminator/CR ends the directive value',
        RenderFirst('#set %x% = A'#13'tail%x%'), #13'tailA');

  { What the value's right-trim removes, and what it must NOT. The rule is
    `(.*?)[ \t]*\r?$` -- spaces and tabs only. This port used PHP's rtrim charlist, which
    also eats \0 and \x0B, so a value ending in either came out short. Measured against the
    reference 2026-07-25; 720 cases of it in the commit's differential. }
  Check('trim/space tail',   RenderFirst('#set %x% = A  '#10'[%x%]'), #10'A');
  Check('trim/tab tail',     RenderFirst('#set %x% = A'#9#10'[%x%]'), #10'A');
  Check('trim/formfeed kept',RenderFirst('#set %x% = A'#12#10'[%x%]'), #10'A'#12);
  Check('trim/NUL kept',     RenderFirst('#set %x% = A'#0#10'[%x%]'), #10'A'#0);
  Check('trim/VT kept',      RenderFirst('#set %x% = A'#11#10'[%x%]'), #10'A'#11);
  Check('trim/VT kept in def',RenderFirst('#def %x% = A'#11#10'[%x%]'), #10'A'#11);
  Check('trim/VT-only value', RenderFirst('#set %x% = '#11#10'[%x%]'), #10#11);
  Check('trim/NUL inside',   RenderFirst('#set %x% = A'#0'B'#10'[%x%]'), #10'A'#0'B');

  { Dropping the CR feeds the blank-run collapse -- three or more bare LFs become two --
    which a CRLF run used to be invisible to. Three CRLF directive lines now collapse the
    way three LF ones always did, and a mixed run collapses only the part that became bare
    LFs. Both measured. }
  Check('terminator/CRLF directives collapse',
        RenderFirst('#set %a% = 1'#13#10'#set %b% = 2'#13#10'#set %c% = 3'#13#10'X'),
        #10#10'X');
  Check('terminator/mixed directives collapse',
        RenderFirst('#set %a% = 1'#13#10'#set %b% = 2'#10'#set %c% = 3'#13'#set %d% = 4'#10'X'),
        #10#10#13#10'X');
end;

{ The reference's render() always builds an rng (Math.random when no seed is given), so
  a nil Rng here is the analogue of "no seed" and must render rather than crash. It used
  to raise EAccessViolation from inside the walk. Only the shape is asserted -- the value
  is deliberately random. }
procedure TestNilRng;
var ctx: TSpContext; got: string;
begin
  Inc(Checks);
  ctx := Default(TSpContext);
  ctx.Locale := 'en';
  ctx.PostProcess := False;
  ctx.Rng := nil;
  try
    got := SpRender('{a|b}', ctx);
    if (got <> 'a') and (got <> 'b') then
    begin
      Inc(Failures);
      Writeln('FAIL nil-rng/renders one of the options, got <', got, '>');
    end;
  except
    on E: Exception do
    begin
      Inc(Failures);
      Writeln('FAIL nil-rng/must not raise, got ', E.ClassName, ': ', E.Message);
    end;
  end;
end;

{ TMulberry32Rng is 32-bit wraparound arithmetic, and NOTHING else exercises it: the
  corpus skips every kind:rng case by design, so the generator ran untested until a nil
  Ctx.Rng started defaulting to it. Under Delphi's Debug configuration, which enables
  overflow checks, every mix step raised EIntOverflow.

  Cross-engine RNG parity is a non-goal, so this asserts only what must hold anywhere:
  it must not raise, it must stay inside the requested bounds, and the same seed must
  reproduce within this engine. }
procedure TestSeededRng;
var r1, r2: TSpRng; i, v, a, b: Integer; seq1, seq2: string;
begin
  Inc(Checks);
  try
    r1 := TMulberry32Rng.Create(12345);
    r2 := TMulberry32Rng.Create(12345);
    try
      seq1 := ''; seq2 := ''; a := 0; b := 9;
      for i := 1 to 200 do
      begin
        v := r1.Next(a, b);
        if (v < a) or (v > b) then
        begin
          Inc(Failures);
          Writeln('FAIL seeded-rng/out of bounds: ', v);
          Exit;
        end;
        seq1 := seq1 + IntToStr(v);
        seq2 := seq2 + IntToStr(r2.Next(a, b));
      end;
      if seq1 <> seq2 then
      begin
        Inc(Failures);
        Writeln('FAIL seeded-rng/same seed must reproduce within this engine');
      end;
    finally
      r1.Free; r2.Free;
    end;
  except
    on E: Exception do
    begin
      Inc(Failures);
      Writeln('FAIL seeded-rng/must not raise, got ', E.ClassName, ': ', E.Message);
    end;
  end;
end;

{ Raw code UNITS of a string, decoded by NOTHING of ours. A reviewer showed the previous
  assertions could not detect a broken encoder: CpList decoded with SpCodePointAt, whose
  only caller was SpCodePointToStr, so any mutually-consistent pair of bugs passed --
  demonstrated by making the encoder emit overlong sequences, with all 163 checks still
  green. These pin the bytes/units against values measured from Node. }
function RawUnits(const s: string): string;
var i: Integer;
begin
  Result := '';
  for i := 1 to Length(s) do
  begin
    if i > 1 then Result := Result + ' ';
    {$IFDEF UNICODE}
    Result := Result + '$' + IntToHex(Ord(s[i]), 4);
    {$ELSE}
    Result := Result + '$' + IntToHex(Ord(s[i]), 2);
    {$ENDIF}
  end;
end;

{ Encodings measured from Node, per string width. Independent of our decoder. }
procedure TestEncoding;
  procedure E(cp: LongWord; const utf8, utf16: string);
  begin
    {$IFDEF UNICODE}
    Check('encode ' + IntToHex(cp, 4), RawUnits(SpCodePointToStr(cp)), utf16);
    {$ELSE}
    Check('encode ' + IntToHex(cp, 4), RawUnits(SpCodePointToStr(cp)), utf8);
    {$ENDIF}
  end;
begin
  E($0041, '$41', '$0041');
  E($007F, '$7F', '$007F');
  E($0080, '$C2 $80', '$0080');
  E($00E9, '$C3 $A9', '$00E9');
  E($07FF, '$DF $BF', '$07FF');
  E($0800, '$E0 $A0 $80', '$0800');
  E($0430, '$D0 $B0', '$0430');
  E($FFFF, '$EF $BF $BF', '$FFFF');
  E($10000, '$F0 $90 $80 $80', '$D800 $DC00');
  E($1F600, '$F0 $9F $98 $80', '$D83D $DE00');
  E($10FFFF, '$F4 $8F $BF $BF', '$DBFF $DFFF');
  { Above the Unicode maximum there is no encoding; the UTF-16 arithmetic would otherwise
    emit two LOW surrogates. }
  Check('encode above-max is empty', RawUnits(SpCodePointToStr($110000)), '');
end;

{ The decoder's stated contract, which had no assertions at all. A regression returning
  cpLen = 0 would hang every scan built on it, silently. }
procedure TestDecoderContract;
  procedure D(const s: string; atIndex: Integer; wantCp: LongWord; wantLen: Integer;
              const name: string);
  var cp: LongWord; cpLen: Integer;
  begin
    cp := SpCodePointAt(s, atIndex, cpLen);
    Check('decode/' + name + ' cp', '$' + IntToHex(cp, 4), '$' + IntToHex(wantCp, 4));
    Check('decode/' + name + ' len', IntToStr(cpLen), IntToStr(wantLen));
  end;
begin
  D('', 1, 0, 1, 'empty string');
  D('A', 0, 0, 1, 'index below start');
  D('A', 5, 0, 1, 'index past end');
  {$IFNDEF UNICODE}
  { Malformed UTF-8 must yield the raw byte and advance by one, never stall. }
  D(#$C3, 1, $C3, 1, 'truncated 2-byte tail');
  D(#$E2#$82, 1, $E2, 1, 'truncated 3-byte tail');
  D(#$80'x', 1, $80, 1, 'stray continuation byte');
  D(#$FE'x', 1, $FE, 1, 'invalid lead byte');
  D(#$C3'x', 1, $C3, 1, 'lead byte with a non-continuation follower');
  { OVERLONG forms must be rejected, not decoded. C0 80 would otherwise manufacture
    U+0000 -- and NUL is the reference's placeholder delimiter, so two arbitrary bytes
    could fool a shielding scan. }
  D(#$C0#$80, 1, $C0, 1, 'overlong NUL');
  D(#$E0#$80#$80, 1, $E0, 1, 'overlong 3-byte');
  { F5.. decodes past U+10FFFF, which UTF-16 cannot represent. }
  D(#$F5#$8F#$BF#$BF, 1, $F5, 1, 'above Unicode maximum');
  { Valid sequences still decode. }
  D(#$C3#$A9, 1, $00E9, 2, 'valid 2-byte');
  D(#$F0#$9F#$98#$80, 1, $1F600, 4, 'valid 4-byte astral');
  {$ENDIF}
end;

{ Code points rendered as a space-separated hex list, so a failure shows WHICH code point
  differs instead of a glyph a terminal cannot draw. }
function CpList(const s: string): string;
var i, cpLen: Integer; cp: LongWord;
begin
  Result := '';
  i := 1;
  while i <= Length(s) do
  begin
    cp := SpCodePointAt(s, i, cpLen);
    if Result <> '' then Result := Result + ' ';
    Result := Result + '$' + IntToHex(cp, 4);
    Inc(i, cpLen);
  end;
end;

{ One code point against the reference's answers. Uppercase is asserted ONLY where the
  code point is Ll: the reference applies toUpperCase() to a Unicode-Ll capture and nowhere
  else, so the baked table is Ll-scoped on purpose. U+2170 is the case that makes this
  explicit -- it uppercases to U+2160 in JS but is Unicode N, and the engine never asks. }
procedure CheckCp(cp: LongWord; wantLl, wantL, wantN: Boolean; const wantUpper: string);
var got: string;
begin
  Check('unicode/Ll ' + IntToHex(cp, 4), BoolToStr(SpIsUniLower(cp), True), BoolToStr(wantLl, True));
  Check('unicode/L  ' + IntToHex(cp, 4), BoolToStr(SpIsUniLetter(cp), True), BoolToStr(wantL, True));
  Check('unicode/N  ' + IntToHex(cp, 4), BoolToStr(SpIsUniNumber(cp), True), BoolToStr(wantN, True));
  if wantUpper <> '' then
  begin
    got := CpList(SpUpperCodePoint(cp));
    Check('unicode/upper ' + IntToHex(cp, 4), got, wantUpper);
  end;
  { Round-trip: encoding a code point then decoding it must return the same value on both
    string widths. This is what catches a broken surrogate pair or UTF-8 sequence. }
  Check('unicode/roundtrip ' + IntToHex(cp, 4), CpList(SpCodePointToStr(cp)), '$' + IntToHex(cp, 4));
end;

{ The Unicode foundation the post-process stage is built on. Expectations generated from
  Node -- the same engine and Unicode version the reference runs on and the tables were
  baked from. Astral code points are included because they are two code units under UTF-16
  and four bytes under UTF-8, which is exactly where a naive scan breaks. }
procedure TestUnicodeTables;
begin
  Check('unicode/table version', SpUnicodeTableVersion, '17.0');
  CheckCp($0041, False, True , False, '');
  CheckCp($0061, True , True , False, '$0041');
  CheckCp($007A, True , True , False, '$005A');
  CheckCp($0030, False, False, True , '');
  CheckCp($00DF, True , True , False, '$0053 $0053');
  CheckCp($00E9, True , True , False, '$00C9');
  CheckCp($00FF, True , True , False, '$0178');
  CheckCp($0131, True , True , False, '$0049');
  CheckCp($0130, False, True , False, '');
  CheckCp($03B1, True , True , False, '$0391');
  CheckCp($03C2, True , True , False, '$03A3');
  CheckCp($0430, True , True , False, '$0410');
  CheckCp($044F, True , True , False, '$042F');
  CheckCp($0451, True , True , False, '$0401');
  CheckCp($1E9E, False, True , False, '');
  CheckCp($FB00, True , True , False, '$0046 $0046');
  CheckCp($FB03, True , True , False, '$0046 $0046 $0049');
  CheckCp($2028, False, False, False, '');
  CheckCp($1D41A, True , True , False, '$1D41A');
  CheckCp($10428, True , True , False, '$10400');
  CheckCp($1F600, False, False, False, '');
  CheckCp($0660, False, False, True , '');
  CheckCp($2160, False, False, True , '');
  CheckCp($2170, False, False, True , '');
end;

{ The reference uses TWO flag sets, and a reviewer caught the port assuming one.
  CAP_AFTER_BLOCK_RE is /giu/, where a property escape is CASE-FOLDED: Ll then also matches
  titlecase letters and the Greek iota-subscript forms. Steps 8, 9 and 11 are /u/ or /gu/
  and stay strict. Measured: 1446 extra code points under folding, 32 with a differing
  uppercase; L gains exactly one, U+0345; N gains none.

  Using the strict predicate for the block-tag step would leave those 32 uncapitalised
  after a block tag, where the reference capitalises them. Expectations from Node. }
procedure CheckFold(cp: LongWord; wantLlStrict, wantLlFold, wantLStrict, wantLFold: Boolean;
                    const wantUpper: string);
begin
  Check('fold/Ll-strict ' + IntToHex(cp, 4),
        BoolToStr(SpIsUniLower(cp), True), BoolToStr(wantLlStrict, True));
  Check('fold/Ll-folded ' + IntToHex(cp, 4),
        BoolToStr(SpIsUniLowerFolded(cp), True), BoolToStr(wantLlFold, True));
  Check('fold/L-strict ' + IntToHex(cp, 4),
        BoolToStr(SpIsUniLetter(cp), True), BoolToStr(wantLStrict, True));
  Check('fold/L-folded ' + IntToHex(cp, 4),
        BoolToStr(SpIsUniLetterFolded(cp), True), BoolToStr(wantLFold, True));
  { The uppercase table is built over the FOLDED set precisely so it serves both. }
  if wantUpper <> '' then
    Check('fold/upper ' + IntToHex(cp, 4), CpList(SpUpperCodePoint(cp)), wantUpper);
end;

procedure TestCaseFolding;
begin
  CheckFold($01C5, False, True , True , True , '$01C4');
  CheckFold($01C8, False, True , True , True , '$01C7');
  CheckFold($01CB, False, True , True , True , '$01CA');
  CheckFold($01F2, False, True , True , True , '$01F1');
  CheckFold($0345, False, True , False, True , '$0399');
  CheckFold($1F88, False, True , True , True , '$1F08 $0399');
  CheckFold($1F98, False, True , True , True , '$1F28 $0399');
  CheckFold($1FBC, False, True , True , True , '$0391 $0399');
  CheckFold($1FCC, False, True , True , True , '$0397 $0399');
  CheckFold($1FFC, False, True , True , True , '$03A9 $0399');
  CheckFold($0061, True , True , True , True , '$0041');
  CheckFold($0041, False, True , True , True , '$0041');
  CheckFold($0430, True , True , True , True , '$0410');
  CheckFold($0030, False, False, False, False, '$0030');
end;


{ A string from code points, so this file stays pure ASCII while still asserting on
  Cyrillic, Greek and Spanish text. Delphi reads an unmarked source as ANSI, so a literal
  here would be at the mercy of the machine's codepage. }
function U(const cps: array of LongWord): string;
var i: Integer;
begin
  Result := '';
  for i := Low(cps) to High(cps) do Result := Result + SpCodePointToStr(cps[i]);
end;

function RenderPP(const tmpl: string): string;
var ctx: TSpContext;
begin
  ctx := Default(TSpContext);
  ctx.Locale := 'en';
  ctx.PostProcess := True;
  ctx.Rng := TFirstRng.Create;
  try
    Result := SpRender(tmpl, ctx);
  finally
    ctx.Rng.Free;
  end;
end;

{ Post-process cases from a differential review against the reference. Each one was a
  DEFECT before it was a test: a stray UTF-8 continuation byte read as a Spanish opener
  (which ate the space after most Russian letters), a word boundary modelled as "previous
  char is not a word char" instead of a transition, ASCII-only folding for a mostly
  Cyrillic abbreviation list, bare schemes accepted as URLs, block-tag names compared for
  equality where the reference only needs a prefix, a lone tab rewritten to a space,
  Pascal Trim standing in for JS trim, an empty tag treated as a tag, and a greedy TLD
  that never backtracked to satisfy the trailing boundary.

  Expectations measured from the reference on 2026-07-22. }
procedure TestPostProcess;
begin
  Check('pp/cyrillic-space-kept', RenderPP(U([$0441, $0443, $043F, $0020, $0433, $043E, $0440, $044F, $0447, $0438, $0439])), U([$0421, $0443, $043F, $0020, $0433, $043E, $0440, $044F, $0447, $0438, $0439]));
  Check('pp/cyrillic-comma', RenderPP(U([$0421, $0020, $0443, $0432, $0430, $0436, $0435, $043D, $0438, $0435, $043C, $002C, $0020, $0418, $0432, $0430, $043D])), U([$0421, $0020, $0443, $0432, $0430, $0436, $0435, $043D, $0438, $0435, $043C, $002C, $0020, $0418, $0432, $0430, $043D]));
  Check('pp/greek-first-letter', RenderPP(U([$03BF, $0020, $03BA, $03CC, $03C3, $03BC, $03BF, $03C2])), U([$039F, $0020, $03BA, $03CC, $03C3, $03BC, $03BF, $03C2]));
  Check('pp/cyrillic-label-not-a-domain', RenderPP(U([$0076, $0069, $0073, $0069, $0074, $0020, $043F, $0440, $0438, $043C, $0435, $0440, $002E, $0063, $006F, $006D, $0020, $0074, $006F, $0064, $0061, $0079])), U([$0056, $0069, $0073, $0069, $0074, $0020, $043F, $0440, $0438, $043C, $0435, $0440, $002E, $0020, $0043, $006F, $006D, $0020, $0074, $006F, $0064, $0061, $0079]));
  Check('pp/cyrillic-tld-not-a-domain', RenderPP(U([$0076, $0069, $0073, $0069, $0074, $0020, $0065, $0078, $0061, $006D, $0070, $006C, $0065, $002E, $0440, $0444, $0020, $0074, $006F, $0064, $0061, $0079])), U([$0056, $0069, $0073, $0069, $0074, $0020, $0065, $0078, $0061, $006D, $0070, $006C, $0065, $002E, $0020, $0420, $0444, $0020, $0074, $006F, $0064, $0061, $0079]));
  Check('pp/abbrev-after-underscore', RenderPP(U([$005F, $0442, $002E, $0434, $002E, $0020, $006D, $006F, $0072, $0065])), U([$005F, $0442, $002E, $0434, $002E, $0020, $006D, $006F, $0072, $0065]));
  Check('pp/uppercase-cyrillic-abbrev', RenderPP(U([$0421, $041C, $002E, $0020, $0440, $0438, $0441, $0443, $043D, $043E, $043A])), U([$0421, $041C, $002E, $0020, $0440, $0438, $0441, $0443, $043D, $043E, $043A]));
  Check('pp/single-letter-cyrillic-abbrev', RenderPP(U([$0413, $002E, $0020, $041C, $043E, $0441, $043A, $0432, $0430])), U([$0413, $002E, $0020, $041C, $043E, $0441, $043A, $0432, $0430]));
  Check('pp/bare-scheme-not-a-url', RenderPP(U([$0073, $0065, $0065, $0020, $0068, $0074, $0074, $0070, $0073, $003A, $002F, $002F, $0020, $0068, $0065, $0072, $0065])), U([$0053, $0065, $0065, $0020, $0068, $0074, $0074, $0070, $0073, $003A, $0020, $002F, $002F, $0020, $0068, $0065, $0072, $0065]));
  Check('pp/bare-mailto-not-a-uri', RenderPP(U([$006D, $0061, $0069, $006C, $0074, $006F, $003A, $0020, $0073, $006F, $006D, $0065, $006F, $006E, $0065])), U([$004D, $0061, $0069, $006C, $0074, $006F, $003A, $0020, $0073, $006F, $006D, $0065, $006F, $006E, $0065]));
  Check('pp/bare-tel-not-a-uri', RenderPP(U([$0074, $0065, $006C, $003A, $0020, $0031, $0032, $0033, $0034, $0035])), U([$0054, $0065, $006C, $003A, $0020, $0031, $0032, $0033, $0034, $0035]));
  Check('pp/block-tag-prefix-pre', RenderPP(U([$0077, $006F, $0072, $0064, $0020, $003C, $0070, $0072, $0065, $003E, $0068, $0065, $006C, $006C, $006F])), U([$0057, $006F, $0072, $0064, $0020, $003C, $0070, $0072, $0065, $003E, $0048, $0065, $006C, $006C, $006F]));
  Check('pp/block-tag-prefix-thead', RenderPP(U([$0077, $006F, $0072, $0064, $0020, $003C, $0074, $0068, $0065, $0061, $0064, $003E, $0078])), U([$0057, $006F, $0072, $0064, $0020, $003C, $0074, $0068, $0065, $0061, $0064, $003E, $0058]));
  Check('pp/lone-tab-kept', RenderPP(U([$0061, $0009, $0062])), U([$0041, $0009, $0062]));
  Check('pp/tab-after-newline', RenderPP(U([$0061, $000A, $0009, $0062])), U([$0041, $000A, $0009, $0042]));
  Check('pp/empty-tag-is-literal', RenderPP(U([$0061, $002E, $0020, $003C, $003E, $0062])), U([$0041, $002E, $0020, $003C, $003E, $0062]));
  Check('pp/nbsp-is-trimmed', RenderPP(U([$00A0, $0068, $0065, $006C, $006C, $006F, $00A0])), U([$0068, $0065, $006C, $006C, $006F]));
  Check('pp/email-then-cyrillic', RenderPP(U([$006D, $0065, $0040, $0065, $0078, $0061, $006D, $0070, $006C, $0065, $002E, $0063, $006F, $006D, $043F])), U([$006D, $0065, $0040, $0065, $0078, $0061, $006D, $0070, $006C, $0065, $002E, $0063, $006F, $006D, $043F]));
  Check('pp/domain-then-cyrillic', RenderPP(U([$0065, $0078, $0061, $006D, $0070, $006C, $0065, $002E, $0063, $006F, $006D, $0421])), U([$0065, $0078, $0061, $006D, $0070, $006C, $0065, $002E, $0063, $006F, $006D, $0421]));
  Check('pp/url-keeps-sentence-stop', RenderPP(U([$0053, $0065, $0065, $0020, $0068, $0074, $0074, $0070, $0073, $003A, $002F, $002F, $0065, $0078, $0061, $006D, $0070, $006C, $0065, $002E, $0063, $006F, $006D, $002E])), U([$0053, $0065, $0065, $0020, $0068, $0074, $0074, $0070, $0073, $003A, $002F, $002F, $0065, $0078, $0061, $006D, $0070, $006C, $0065, $002E, $0063, $006F, $006D, $002E]));
  Check('pp/sentence-run-at-end', RenderPP(U([$0057, $006F, $0077, $0021, $0021, $0021])), U([$0057, $006F, $0077, $0021, $0021, $0021]));

  { The two branches of the abbreviation fold, pinned because the 2026-08-06 speed work
    added a fast path and a pre-filter that nothing in this suite could have caught.

    MatchesFoldedAt now folds an ASCII pair without going through the Unicode table, and
    ScanSingleAbbr rejects a candidate whose folded FIRST code point differs. Both were
    proved by exhaustive one-off runs, which the next refactor will not repeat. These are
    the two shapes where a wrong shortcut is observable, and the abbreviation is `st`:

      long s + t   folds to ST, so `st.` MATCHES across a non-ASCII/ASCII pair. An
                   ASCII-only fast path that short-circuited a mixed pair would miss it,
                   capitalize the next sentence, and uppercase the long s.
      sharp s + t  folds to SST. Its first code point is S, exactly like `st`'s, so the
                   pre-filter admits it -- and the full comparison must still reject it.
                   A pre-filter mistaken for a decision would shield this as an
                   abbreviation and leave `hello` lower-case.

    Measured against @spintax/core on 2026-08-06, both ways. }
  Check('pp/abbrev-folds-non-ascii-into-ascii', RenderPP(U([$017F, $0074, $002E, $0020, $0068, $0065, $006C, $006C, $006F])), U([$017F, $0074, $002E, $0020, $0068, $0065, $006C, $006C, $006F]));
  Check('pp/abbrev-prefilter-is-not-the-verdict', RenderPP(U([$00DF, $0074, $002E, $0020, $0068, $0065, $006C, $006C, $006F])), U([$0053, $0053, $0074, $002E, $0020, $0048, $0065, $006C, $006C, $006F]));
  { the control: same shape, no abbreviation, so the sentence DOES break }
  Check('pp/abbrev-control-not-an-abbrev', RenderPP(U([$0078, $0074, $002E, $0020, $0068, $0065, $006C, $006C, $006F])), U([$0058, $0074, $002E, $0020, $0048, $0065, $006C, $006C, $006F]));
end;

{ The placeholder scheme delimits with NUL, so input that already contains NUL meets the
  restore scanner head-on. Step 12 is now a single left-to-right pass rather than one
  StringReplace per key, and these pin that the change did not move behaviour.

  Measured against the reference. Two of them are worth reading twice:

  - a fake key in the input IS substituted when a real match happened to claim that
    number, and is left alone when no such key exists;
  - a mailto: run swallows a NUL and carries the fake key inside its own value, which the
    restore does NOT rescan -- so it survives literally. That is the reference's behaviour
    too, because it restores in insertion order and a leaked key is inserted after its own
    pass has already run. }
procedure TestNulInInput;
begin
  Check('nul/plain',            RenderPP('a'#0'b'), 'A'#0'b');
  Check('nul/lone',             RenderPP(#0), #0);
  Check('nul/pair',             RenderPP(#0#0), #0#0);
  Check('nul/unclosed',         RenderPP('unclosed '#0' tail'), 'Unclosed '#0' tail');
  { a real URL claims URL_0, so the fake key in the input resolves to it }
  Check('nul/fake-key-claimed',
        RenderPP(#0'URL_0'#0' x https://example.com'),
        'https://example.com x https://example.com');
  Check('nul/fake-key-claimed-after',
        RenderPP('https://example.com '#0'URL_0'#0),
        'https://example.com https://example.com');
  { no URL in the input, so no URL_0 key exists and nothing is substituted }
  Check('nul/fake-key-unclaimed',
        RenderPP(#0'FOO'#0' and '#0'URL_0'#0' end'),
        #0'FOO'#0' and '#0'URL_0'#0' end');
  { Before spintax-js#53 a mailto: run swallowed the #0 and carried the fake key inside
    its own value, so it survived to the output literally. The URI body now stops at #0,
    so the caller's token stays a token, names a key that genuinely exists, and the
    restore substitutes it. Re-measured against the reference after #53. }
  Check('nul/key-leaked-into-a-value',
        RenderPP('https://a.example.com then mailto:x@y.com'#0'URL_0'#0' end'),
        'https://a.example.com then mailto:x@y.comhttps://a.example.com end');
  Check('nul/key-leaked-no-such-key',
        RenderPP('see mailto:x@y.com'#0'URL_0'#0' end'),
        'See mailto:x@y.com'#0'URL_0'#0' end');
  { The two below are why step 12 keeps the reference-shaped restore for inputs
    carrying a #0. A caller-supplied token can name a key the shield really did
    mint, and the reference replaces EVERY occurrence of that key -- so the
    caller's own text is substituted too. A single left-to-right pass restores a
    different string here. Both cases were measured against the reference, and
    both fail if step 12 takes the fast path unconditionally. }
  Check('nul/caller-token-names-a-live-key',
        RenderPP('   tel:+1-555-0100'#0'ABBR_1'#0#0'NOPE_1'#0'! e.g.'),
        'tel:+1-555-0100e.g.'#0'NOPE_1'#0'! e.g.');
  Check('nul/caller-token-between-shields',
        RenderPP('http://x.io/p?q=1'#0'ABBR_1'#0#9'  e.g.'#0'DOM_3'#0#9),
        'http://x.io/p?q=1e.g. e.g.'#0'DOM_3'#0);
  { The one shape the guard does NOT cover, and it carries no #0 at all: two placeholders
    landing flush around caller text that spells a bare key name. Here "e.g. " and
    "mailto:x@y.io" both shield, leaving #0 ABBR_2 #0 URL_0 #0 URI_1 #0 -- and the closing
    delimiter of one token plus the opening delimiter of the next spell a THIRD occurrence
    of the URL_0 key, which the reference-shaped loop substitutes, destroying both real
    tokens. The fast pass tokenises left to right, consumes ABBR_2 whole, and never sees
    the forgery. We deliberately keep the fast pass's answer: the loop returns wreckage
    with raw sentinels in it. Measured against the reference (spintax-js#52). }
  Check('nul-free/forged-key-between-two-shields',
        RenderPP('https://a.io e.g. URL_0mailto:x@y.io'),
        'https://a.io e.g. URL_0mailto:x@y.io');
end;

{ Comma-joined #include targets, for comparing against a measured list. }
function Includes(const tmpl: string): string;
var ex: TExtractResult; i: Integer;
begin
  Result := '';
  ex := SpExtract(tmpl);
  try
    for i := 0 to ex.Includes.Count - 1 do
    begin
      if i > 0 then Result := Result + ',';
      Result := Result + ex.Includes[i];
    end;
  finally
    ex.Refs.Free; ex.Sets.Free; ex.Defs.Free; ex.Includes.Free;
  end;
end;

{ #include resolution is a HOST concern in both engines: with no resolver the directive
  survives rendering verbatim. The corpus covers #include under extract and validate, but
  has ZERO render cases for it, so the render-side behaviour is gated only here.

  Measured against the reference on 2026-07-22. The line-anchoring rules are the subtle
  part: an inline #include is not a directive, quotes are required, leading whitespace is
  allowed, and a CR-delimited line counts as a line -- which is why this doubles as a
  guard on the line-terminator rewrite. }
procedure TestIncludes;
begin
  Check('include/line-survives-render',
        RenderFirst('#include "frag"'#10'after'), '#include "frag"'#10'after');
  Check('include/inline-survives-render',
        RenderFirst('before #include "frag" inline'), 'before #include "frag" inline');
  Check('include/indented-survives-render',
        RenderFirst('   #include "frag"'#10'after'), '   #include "frag"'#10'after');
  { #set is stripped, #include is not -- only #set/#def are directives to remove. }
  Check('include/kept-while-set-is-stripped',
        RenderFirst('#set %v% = V'#10'#include "frag"'#10'%v%'), #10'#include "frag"'#10'V');

  Check('include/extract-line',      Includes('#include "frag"'#10'after'), 'frag');
  Check('include/extract-indented',  Includes('   #include "frag"'#10'after'), 'frag');
  { Inline is not line-anchored, so it is not a directive and not extracted. }
  Check('include/extract-inline-none', Includes('before #include "frag" inline'), '');
  { The target must be quoted. }
  Check('include/extract-unquoted-none', Includes('#include frag'#10'after'), '');
  { A CR-delimited line is a line: this also guards the line-terminator rewrite, since
    treating CR as ordinary text would make the whole input one line and lose the anchor. }
  Check('include/extract-after-CR',   Includes('x'#13'#include "frag"'#13'after'), 'frag');
  Check('include/CR-survives-render',
        RenderFirst('x'#13'#include "frag"'#13'after'), 'x'#13'#include "frag"'#13'after');
end;

{ include.unknown-target with a host slug list -- the verdict half of the anchor. A line the
  family does not call an include cannot be an unknown target, and the code is an ERROR, so
  getting the anchor wrong does not just mis-report a name, it calls a valid template
  invalid. }
function IncludeDiags(const tmpl: string): string;
var d: TSpDiagList; i: Integer; known: TStringList;
begin
  Result := '';
  known := TStringList.Create;
  known.Add('ok');
  try
    d := SpValidate(tmpl, 'en', known);
    try
      for i := 0 to d.Count - 1 do
      begin
        if i > 0 then Result := Result + ' ';
        Result := Result + d[i].Code + '/' + d[i].Severity;
      end;
    finally d.Free; end;
  finally known.Free; end;
end;

{ The exact anchor, which is

      /^[ \t]*#include[ \t\n\r\f\x0B]+"([^"]+)"[ \t\n\r\f\x0B]*$/gmu

  in the reference; the PHP core and the plugin apply the same rule spelled `\s` under /u,
  which may not be the same set for NBSP (see the unit's own note). This port used to read it as
  "#include at a line start, then the first quoted string on the line": looser on five
  shapes, stricter on one, and since include.unknown-target is an error the loose half moved
  VERDICTS -- parity-REQUIRED by spec §3, and invisible to a corpus that carries two plain
  #include cases.

  Every expectation below is the reference's answer, measured 2026-07-25, and the whole rule
  is measured over 86 419 include-shaped inputs by the differential in the commit that
  introduced it: 18 487 include-list and 15 758 verdict differences before, zero after.

  The subtle half is that the class holds \n and \r, so the gaps around the target may cross
  line terminators -- while U+2028/9 end a line for ^ and $ but are NOT whitespace, and an
  NBSP is not whitespace either (the reference writes the class out rather than trusting
  JavaScript's Unicode-aware \s, for exactly this parity). }
procedure TestIncludeAnchor;
const
  NBSP = {$IFDEF UNICODE} #$00A0 {$ELSE} #$C2#$A0 {$ENDIF};
  U2028 = {$IFDEF UNICODE} #$2028 {$ELSE} #$E2#$80#$A8 {$ENDIF};
begin
  { Rejected: anything after the closing quote that is not the rule's whitespace, no gap at
    all, an empty target, a longer keyword, a second quoted string, an unterminated quote. }
  Check('anchor/trailing-junk',     Includes('#include "frag" junk'), '');
  Check('anchor/no-gap',            Includes('#include"frag"'), '');
  Check('anchor/empty-target',      Includes('#include ""'), '');
  Check('anchor/longer-keyword',    Includes('#includes "frag"'), '');
  Check('anchor/second-quoted',     Includes('#include "frag" "ok"'), '');
  Check('anchor/unterminated',      Includes('#include "frag'), '');
  { NBSP is not in the class, on either side of the target. }
  Check('anchor/nbsp-gap',          Includes('#include' + NBSP + '"frag"'), '');
  Check('anchor/nbsp-tail',         Includes('#include "frag"' + NBSP), '');

  { Accepted: every member of the class as a gap, including the terminators -- which is the
    one shape the old rule was too STRICT to see, because it cannot be read line by line. }
  Check('anchor/newline-gap',       Includes('#include'#10'"frag"'), 'frag');
  Check('anchor/crlf-gap',          Includes('#include'#13#10'"frag"'), 'frag');
  Check('anchor/tab-gap',           Includes('#include'#9'"frag"'), 'frag');
  Check('anchor/trailing-spaces',   Includes('#include "frag"   '), 'frag');
  Check('anchor/trailing-formfeed', Includes('#include "frag"'#12), 'frag');
  Check('anchor/tail-then-newline', Includes('#include "frag" '#10'after'), 'frag');
  { U+2028 is not whitespace but IS a line end, so $ matches before it. }
  Check('anchor/u2028-tail',        Includes('#include "frag"' + U2028 + 'x'), 'frag');
  { The target is [^"]+, so it may hold spaces. }
  Check('anchor/target-with-space', Includes('#include "my frag"'), 'my frag');

  { A match may swallow the line starts inside it, and those are no longer ^ positions: the
    reference scans with /g and resumes at the match end. Retrying them finds a SECOND
    include here, because the quotes line up again from the swallowed line -- one target in
    the family, two here, and with a slug list that is a verdict. Measured: the reference
    reports exactly `a` + LF + `#include `. }
  Check('anchor/match-swallows-the-next-line-start',
        Includes('#include "a'#10'#include "   '#10'b"'#10), 'a'#10'#include ');

  { The verdict half: the rejected shapes are VALID templates, the accepted ones report an
    unknown target. This is the parity that was broken. }
  Check('anchor/verdict-trailing-junk', IncludeDiags('#include "frag" junk'), '');
  Check('anchor/verdict-longer-keyword', IncludeDiags('#includes "frag"'), '');
  Check('anchor/verdict-no-gap',        IncludeDiags('#include"frag"'), '');
  Check('anchor/verdict-newline-gap',   IncludeDiags('#include'#10'"frag"'),
        'include.unknown-target/error');
  Check('anchor/verdict-known-target',  IncludeDiags('#include "ok"'), '');

  { A slug is a HOST identifier, so it is compared exactly -- unlike every variable name this
    unit reports, which is case-folded. TStringList.IndexOf ignores case, which made
    `#include "OK"` valid against a list holding only `ok`, and collapsed two distinct
    targets into one. Measured against the reference 2026-07-25; the 86 419-case anchor
    corpus could not see it, because every target in it matched the slug list in case. }
  Check('anchor/case-target-differs',   IncludeDiags('#include "OK"'),
        'include.unknown-target/error');
  Check('anchor/case-target-differs-2', IncludeDiags('#include "Ok"'),
        'include.unknown-target/error');
  Check('anchor/case-dedup-keeps-both', Includes('#include "a"'#10'#include "A"'), 'a,A');
  Check('anchor/case-dedup-same-once',  Includes('#include "a"'#10'#include "a"'), 'a');
  { Non-ASCII too: a locale-aware IndexOf folds Cyrillic as happily as ASCII. }
  Check('anchor/case-dedup-cyrillic',
        Includes('#include "путь"'#10'#include "ПУТЬ"'), 'путь,ПУТЬ');
end;

{ ─── #include resolution ─────────────────────────────────────────────────────
  The corpus schema has no include-resolution field at all, so every line below is the only
  gate on it. Expectations are MEASURED against @spintax/core 2026-07-25 with a matching
  resolver, and the whole surface is measured by the differential recorded in the commit
  that added the seam: 52 cases, 48 of them different when the seam is left nil. }

type
  { The host half of the seam. Exact-match lookup, like the family: a slug is an identifier,
    not a variable name. }
  TMapResolver = class(TSpIncludeResolver)
  private
    FRefs, FTexts: TStringList;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Put(const Ref, Text: string);
    function Resolve(const Ref: string; out Text: string): Boolean; override;
  end;

constructor TMapResolver.Create;
begin
  inherited Create;
  FRefs := TStringList.Create;
  FTexts := TStringList.Create;
end;

destructor TMapResolver.Destroy;
begin
  FRefs.Free; FTexts.Free;
  inherited Destroy;
end;

procedure TMapResolver.Put(const Ref, Text: string);
begin
  FRefs.Add(Ref); FTexts.Add(Text);
end;

function TMapResolver.Resolve(const Ref: string; out Text: string): Boolean;
var i: Integer;
begin
  for i := 0 to FRefs.Count - 1 do
    if FRefs[i] = Ref then begin Text := FTexts[i]; Exit(True); end;
  Result := False;
end;

var
  GResolver: TMapResolver;   { built once by TestIncludeResolver }

{ Render with the shared template set. Depth 0 = the engine's default; Resolve = False
  leaves the seam nil, which must reproduce the pre-seam behaviour exactly. }
function RenderInc(const tmpl: string; UseResolver: Boolean; Depth: Integer;
  PostProcess: Boolean): string;
var ctx: TSpContext; vars: TStrMap;
begin
  ctx := Default(TSpContext);
  vars := TStrMap.Create;
  vars.Add('rt', 'RT');
  ctx.Vars := vars;
  ctx.Locale := 'en';
  ctx.PostProcess := PostProcess;
  ctx.Rng := TFirstRng.Create;
  if UseResolver then ctx.IncludeResolver := GResolver;
  ctx.MaxIncludeDepth := Depth;
  try
    Result := SpRender(tmpl, ctx);
  finally
    ctx.Rng.Free; vars.Free;
  end;
end;

function Inc_(const tmpl: string): string;
begin
  Result := RenderInc(tmpl, True, 0, False);
end;

procedure TestIncludeResolver;
begin
  GResolver := TMapResolver.Create;
  try
    GResolver.Put('plain',       'child text');
    GResolver.Put('withset',     '#set %c% = CHILD'#10'[%c%]');
    GResolver.Put('usesparent',  'p is %p%');
    GResolver.Put('usesruntime', 'rt is %rt%');
    GResolver.Put('d1', 'L1'#10'#include "d2"');
    GResolver.Put('d2', 'L2'#10'#include "d3"');
    GResolver.Put('d3', 'L3'#10'#include "d4"');
    GResolver.Put('d4', 'L4'#10'#include "d5"');
    GResolver.Put('d5', 'L5');
    GResolver.Put('self', 'S'#10'#include "self"'#10'E');
    GResolver.Put('a', 'A'#10'#include "b"');
    GResolver.Put('b', 'B'#10'#include "a"');
    GResolver.Put('dupA', 'D'#10'#include "plain"');
    GResolver.Put('dupB', 'D'#10'#include "plain"');
    GResolver.Put('neutral', SpNeutralize('{a|b}'));

    { nil resolver -- the v0.2.2 behaviour, and the reference's with no resolver supplied. }
    Check('inc/no-resolver-leaves-the-line',
          RenderInc('#include "plain"', False, 0, False), '#include "plain"');

    Check('inc/basic', Inc_('#include "plain"'), 'child text');

    { A child is a document of its own: the parent's #set is NOT in its scope, and its own
      #set does not leak back. This is the row a host that splices raw text gets wrong. }
    Check('inc/child-cannot-see-parent-macro',
          Inc_('#set %p% = PARENT'#10'#include "usesparent"'#10'[%p%]'),
          #10'p is %p%'#10'PARENT');
    Check('inc/parent-cannot-see-child-macro',
          Inc_('#include "withset"'#10'[%c%]'), #10'CHILD'#10'%c%');
    { ...but the runtime context IS inherited. }
    Check('inc/child-sees-runtime-context', Inc_('#include "usesruntime"'), 'rt is RT');

    { Unknown target, a cycle, and running past the depth cap are all lenient: empty string,
      never an error. Cycles are keyed on the ref STRING. }
    Check('inc/unknown-target-is-empty', Inc_('#include "nosuch"'), '');
    Check('inc/self-cycle', Inc_('#include "self"'), 'S'#10#10'E');
    Check('inc/mutual-cycle', Inc_('#include "a"'), 'A'#10'B'#10);
    { Two refs to the same TEXT are not a cycle -- the engine has no template identity
      beyond the ref, so both expand. }
    Check('inc/aliases-are-not-a-cycle',
          Inc_('#include "dupA"'#10'#include "dupB"'),
          'D'#10'child text'#10'D'#10'child text');
    Check('inc/depth-cap-3', RenderInc('#include "d1"', True, 3, False), 'L1'#10'L2'#10'L3'#10);
    Check('inc/depth-cap-default', Inc_('#include "d1"'), 'L1'#10'L2'#10'L3'#10'L4'#10'L5');

    { A child is author markup, so the sentinel strip runs on it: a neutralized value
      embedded in a TEMPLATE is removed, not restored. Neutralized data belongs in the
      runtime context, which is the trust model (spec §6) -- pinned because the opposite is
      the intuitive guess. }
    Check('inc/child-markup-is-sanitised', Inc_('#include "neutral"'), 'a|b');

    { Post-process runs ONCE, over the assembled document, so it sees across the seam:
      `hello.` capitalises the child's first word. }
    Check('inc/postprocess-crosses-the-seam',
          RenderInc('hello.'#10'#include "plain"', True, 0, True), 'Hello.'#10'Child text');

    { The anchor and the resolver agree: what is not an include is not substituted. }
    Check('inc/not-an-include-is-not-resolved',
          Inc_('#include "plain" junk'), '#include "plain" junk');
  finally
    GResolver.Free;
  end;
end;

{ Diagnostic codes+severities, space-joined, with a host-declared variable list. }
function Diags(const tmpl: string; const known: array of string): string;
var d: TSpDiagList; i: Integer; kv: TStringList;
begin
  kv := nil;
  if Length(known) > 0 then
  begin
    kv := TStringList.Create;
    for i := 0 to High(known) do kv.Add(known[i]);
  end;
  try
    Result := '';
    d := SpValidate(tmpl, 'en', nil, kv);
    try
      for i := 0 to d.Count - 1 do
      begin
        if i > 0 then Result := Result + ' ';
        Result := Result + d[i].Code + '/' + d[i].Severity;
      end;
    finally
      d.Free;
    end;
  finally
    kv.Free;
  end;
end;

{ KnownVariables: names the host promises to supply at render time. No fixture can carry
  them -- the corpus schema has no such field, and grep confirms the string appears in no
  fixture -- so this is the only gate.

  Measured against the reference on 2026-07-22. The severity matters as much as the code:
  an unresolved %var% is a WARNING and must never become an error, or a host that renders
  with runtime variables would see its templates called invalid. }
procedure TestKnownVariables;
begin
  Check('knownvars/undeclared-warns',   Diags('%foo%', []),        'variable.undefined/warning');
  Check('knownvars/declared-silent',    Diags('%foo%', ['foo']),   '');
  Check('knownvars/other-name-warns',   Diags('%foo%', ['bar']),   'variable.undefined/warning');
  { A definition wins on its own; the list is not needed for it. }
  Check('knownvars/set-defined',        Diags('#set %foo% = 1'#10'%foo%', ['bar']), '');
  Check('knownvars/def-defined',        Diags('#def %foo% = 1'#10'%foo%', ['bar']), '');
  { Conditionals reference variables too, and obey the same list. }
  Check('knownvars/cond-undeclared',    Diags('{?foo?a|b}', ['bar']), 'variable.undefined/warning');
  Check('knownvars/cond-declared',      Diags('{?foo?a|b}', ['foo']), '');
  Check('knownvars/negated-cond',       Diags('{?!foo?a}', ['foo']),  '');
  { Matching is case-insensitive in BOTH directions -- measured, not assumed. }
  Check('knownvars/upper-reference',    Diags('%FOO%', ['foo']), '');
  Check('knownvars/upper-declaration',  Diags('%foo%', ['FOO']), '');
end;

function RenderIn(const tmpl, locale: string): string;
var ctx: TSpContext;
begin
  ctx := Default(TSpContext);
  ctx.Locale := locale;
  ctx.PostProcess := False;
  ctx.Rng := TFirstRng.Create;
  try
    Result := SpRender(tmpl, ctx);
  finally
    ctx.Rng.Free;
  end;
end;

{ Permutation <config> and plural fallbacks. The corpus schema has no field for either,
  so nothing else asserts them.

  Every expectation below was MEASURED against the reference (@spintax/core dist, node)
  on 2026-07-22, not derived from this port -- which currently agrees on all of them. The
  point is to keep it that way.

  Permutation results are made order-independent by using identical elements, so they do
  not depend on RNG selection, which is not comparable across engines anyway. }
procedure TestPermutationConfig;
begin
  Check('perm/default-sep',      RenderIn('[a|a|a]', ''),                             'a a a');
  Check('perm/sep',              RenderIn('[<sep=", ">a|a|a]', ''),                   'a, a, a');
  Check('perm/sep-and-lastsep',  RenderIn('[<sep=", " lastsep=" and ">a|a|a]', ''),   'a, a and a');
  Check('perm/sep-empty',        RenderIn('[<sep="">a|a|a]', ''),                     'aaa');
  Check('perm/minsize-maxsize',  RenderIn('[<minsize=2 maxsize=2>a|a|a]', ''),        'a a');
  Check('perm/maxsize-1',        RenderIn('[<maxsize=1>a|a|a]', ''),                  'a');
  { Clamped to the element count rather than padding or failing. }
  Check('perm/minsize-over',     RenderIn('[<minsize=5>a|a|a]', ''),                  'a a a');
  { Zero is clamped up to one, not down to empty. }
  Check('perm/maxsize-0',        RenderIn('[<maxsize=0>a|a|a]', ''),                  'a');
  { An unrecognised key is NOT config: the whole <...> stays content and is repeated per
    element. Easy to "fix" into silently dropping it -- the reference does not. }
  Check('perm/unknown-key',      RenderIn('[<bogus=1>a|a|a]', ''),                    'abogus=1abogus=1a');
end;

{ Only the LENIENT paths live here. The Slavic bucket rules are already gated by 37 corpus
  cases, so repeating them would add no coverage -- and would put non-ASCII literals in this
  file, whose bytes each compiler's source-encoding rules would then get a vote on. This
  source stays pure ASCII on purpose. }
procedure TestPluralFallbacks;
begin
  Check('plural/en-1',           RenderIn('{plural 1: item|items}', ''),   'item');
  Check('plural/en-2',           RenderIn('{plural 2: item|items}', ''),   'items');
  Check('plural/en-0',           RenderIn('{plural 0: item|items}', ''),   'items');
  { Negative counts take the singular bucket; decimals are not integers, so they fall to
    the empty result -- the same as a non-numeric count. }
  Check('plural/negative',       RenderIn('{plural -1: item|items}', ''),  'item');
  Check('plural/decimal',        RenderIn('{plural 1.5: item|items}', ''), '');
  Check('plural/non-numeric',    RenderIn('{plural x: item|items}', ''),   '');
  Check('plural/empty-forms',    RenderIn('{plural 2: |}', ''),            '');
  { Wrong arity for the locale renders the block verbatim in FULLWIDTH braces, the
    engine's leniency marker -- it must not throw and must not guess a bucket. }
  Check('plural/arity-1-form',   RenderIn('{plural 5: item}', ''),
        FullwidthBrace(True) + 'plural 5: item' + FullwidthBrace(False));
  Check('plural/arity-3-in-en',  RenderIn('{plural 5: a|b|c}', ''),
        FullwidthBrace(True) + 'plural 5: a|b|c' + FullwidthBrace(False));

end;

{ Best-effort source position of the first diagnostic with a given code, as
  "severity @line:col..endline:endcol". No fixture can express positions (the corpus gates
  code+severity only), so this is the only gate. Columns count CODE POINTS. Codes and
  severities are asserted too, to prove locating a finding never changed its verdict. }
function DiagPos(const tmpl, locale, code: string; const knownInc: array of string): string;
var d: TSpDiagList; i: Integer; ki: TStringList;
begin
  ki := nil;
  if Length(knownInc) > 0 then
  begin
    ki := TStringList.Create;
    for i := 0 to High(knownInc) do ki.Add(knownInc[i]);
  end;
  try
    Result := 'not-found';
    d := SpValidate(tmpl, locale, ki, nil);
    try
      for i := 0 to d.Count - 1 do
        if d[i].Code = code then
        begin
          Result := Format('%s @%d:%d..%d:%d',
            [d[i].Severity, d[i].Line, d[i].Column, d[i].EndLine, d[i].EndColumn]);
          Break;
        end;
    finally d.Free; end;
  finally ki.Free; end;
end;

procedure TestDiagPositions;
begin
  { The editor-critical diagnostics get a 1-based line/column and a span. These are the
    exact positions the brief asks Studio to rely on for squiggles and jump-to-error. }
  Check('pos/unexpected-closing',   DiagPos(']', 'en', 'bracket.unexpected-closing', []),
        'error @1:1..1:2');
  Check('pos/unclosed-line-2',      DiagPos('ok'#10'{a|b', 'en', 'bracket.unclosed', []),
        'error @2:1..2:2');
  Check('pos/set-malformed',        DiagPos('#set broken', 'en', 'set.malformed', []),
        'error @1:1..1:5');
  Check('pos/duplicate-later-line', DiagPos('#set %a% = 1'#10'#set %a% = 2', 'en',
        'definition.duplicate-name', []), 'error @2:1..2:5');
  Check('pos/undefined-var-token',  DiagPos('hi %missing%', 'en', 'variable.undefined', []),
        'warning @1:4..1:13');
  Check('pos/include-slug',         DiagPos('#include "missing"', 'en',
        'include.unknown-target', ['other']), 'error @1:11..1:18');
  Check('pos/plural-arity-block',   DiagPos('{plural %n%: a|b|c}', 'en', 'plural.arity', []),
        'error @1:1..1:9');
  { A byte column would land mid-character on non-ASCII; a code-point column does not.
    Cyrillic "нет " is 4 code points, so %x% opens at column 5 whatever the byte width. }
  Check('pos/undefined-after-cyrillic',
        DiagPos('нет %x%', 'en', 'variable.undefined', []), 'warning @1:5..1:8');

  { Comments are stripped before validation, dropping characters AND the newlines inside
    them. Coordinates must still be the SOURCE's, not the stripped text's -- so a diagnostic
    after a block comment lands where an editor sees it, not shifted up/left. }
  { multiline comment before the ref: the block is 2 source lines, so %missing% is line 3 }
  Check('pos/undefined-after-multiline-comment',
        DiagPos('/# comment'#10'   block #/'#10'%missing%', 'en', 'variable.undefined', []),
        'warning @3:1..3:10');
  { inline comment before the diagnostic: the column is the source column, not the stripped one }
  Check('pos/bracket-after-inline-comment',
        DiagPos('x /# c #/]', 'en', 'bracket.unexpected-closing', []), 'error @1:10..1:11');
  { a construct INSIDE a comment yields no diagnostic at all (it was stripped) }
  Check('pos/no-var-diag-inside-comment',
        DiagPos('/# %missing% #/ok', 'en', 'variable.undefined', []), 'not-found');
  Check('pos/no-bracket-diag-inside-comment',
        DiagPos('/# ] #/ok', 'en', 'bracket.unexpected-closing', []), 'not-found');
  { comment IMMEDIATELY AFTER the token: the span's exclusive end must land just past the
    token, not on the next surviving char beyond the comment -- else the squiggle swallows
    the comment. The end-offset is mapped differently from the start for exactly this. }
  Check('pos/span-not-stretched-by-trailing-comment',
        DiagPos('%x%/# c #/ ok', 'en', 'variable.undefined', []), 'warning @1:1..1:4');
  Check('pos/bracket-span-before-trailing-comment',
        DiagPos(']/# c #/', 'en', 'bracket.unexpected-closing', []), 'error @1:1..1:2');
  { permutation.unknown-key uses a unique p+1+k .. p+1+b formula -- pin it so a future
    change to the config scan cannot silently misplace it. Key "foo" is columns 3..5. }
  Check('pos/perm-unknown-key',
        DiagPos('[<foo=1>]', 'en', 'permutation.unknown-key', []), 'error @1:3..1:6');
  { the conditional {?name? path is scanned separately from %var%; span is the {?name? head }
  Check('pos/undefined-conditional-head',
        DiagPos('{?missing?yes}', 'en', 'variable.undefined', []), 'warning @1:1..1:11');
end;

{ The whole directive list as `kind:name=value@L:C..L:C`, joined by ' | ' -- one string per
  document, so a case pins order, duplicates and spans together. }
function Directives(const tmpl: string): string;
var d: TSpDirectiveList; i: Integer;
begin
  Result := '';
  d := SpExtractDirectives(tmpl);
  try
    for i := 0 to d.Count - 1 do
    begin
      if i > 0 then Result := Result + ' | ';
      Result := Result + Format('%s:%s=%s@%d:%d..%d:%d', [d[i].Kind, d[i].Name, d[i].Value,
        d[i].Line, d[i].Column, d[i].EndLine, d[i].EndColumn]);
    end;
    if Result = '' then Result := '<none>';
  finally d.Free; end;
end;

{ Just the Text fields, pipe-joined -- what a host re-emits as a prelude. }
function DirectiveTexts(const tmpl: string): string;
var d: TSpDirectiveList; i: Integer;
begin
  Result := '';
  d := SpExtractDirectives(tmpl);
  try
    for i := 0 to d.Count - 1 do
    begin
      if i > 0 then Result := Result + ' | ';
      Result := Result + d[i].Text;
    end;
    if Result = '' then Result := '<none>';
  finally d.Free; end;
end;

{ SpExtractDirectives is the editor-side companion to SpExtract: same scans, but every
  OCCURRENCE, in order, with its source span, value and text. It has no counterpart in the
  PUBLIC counterpart in the reference (its parser has an internal occurrence list for
  #set/#def only: no includes, no spans, and its line count is over the STRIPPED text), so
  nothing here is measured against it -- the expectations come from the two
  contracts this port already holds: what the renderer treats as a directive (corpus-gated,
  and cross-checked against SpRender/SpExtract below) and the TSpDiag position contract
  (1-based, code-point columns, editor EOL, exclusive End*, source coordinates).

  The reason the API exists is the first case below: SpExtract deduplicates targets, so a
  host that substitutes #include by NAME cannot tell a commented-out occurrence from a live
  one and expands both -- and since comments do not nest, an included fragment carrying its
  own `/# ... #/` then escapes the comment it landed in. }
procedure TestExtractDirectives;
const
  U2028 = {$IFDEF UNICODE} #$2028 {$ELSE} #$E2#$80#$A8 {$ENDIF};
  U2029 = {$IFDEF UNICODE} #$2029 {$ELSE} #$E2#$80#$A9 {$ENDIF};
  { U+E000, the first reserved sentinel, spelled per string width like the engine's own. }
  SENT = {$IFDEF UNICODE} #$E000 {$ELSE} #$EE#$80#$80 {$ENDIF};
begin
  { Source order, all three kinds, spans covering the directive's line. }
  Check('dir/three-kinds',
        Directives('#set %a% = 1'#10'#def %b% = x'#10'#include "frag"'),
        'set:a=1@1:1..1:13 | def:b=x@2:1..2:13 | include:frag=@3:1..3:16');

  { THE case. Same target commented out and live: SpExtract sees one entry, this sees the
    live occurrence only, at its source line. }
  Check('dir/commented-and-live-include',
        Directives('/#'#10'#include "frag"'#10'#/'#10'#include "frag"'),
        'include:frag=@4:1..4:16');
  Check('dir/commented-and-live-include-vs-extract',
        Includes('/#'#10'#include "frag"'#10'#/'#10'#include "frag"'), 'frag');

  { Occurrences are NOT deduplicated -- that is the difference from SpExtract. }
  Check('dir/duplicates-kept',
        Directives('#include "a"'#10'#include "a"'),
        'include:a=@1:1..1:13 | include:a=@2:1..2:13');
  Check('dir/duplicates-deduped-by-extract', Includes('#include "a"'#10'#include "a"'), 'a');

  { A #set inside a block comment is not a directive -- the renderer never sees it, so a
    prelude built from this list cannot smuggle it into scope. }
  Check('dir/set-inside-comment', Directives('/#'#10'#set %x% = A'#10'#/'#10'[%x%]'), '<none>');

  { A comment on the same line shrinks the span to what survived it: replacing the span
    leaves the comment where it was. }
  Check('dir/comment-before-on-line', Directives('/# c #/#set %a% = 1'),
        'set:a=1@1:8..1:20');
  { ...and a trailing comment does not stretch the end across it. }
  Check('dir/comment-after-on-line', Directives('#set %a% = 1 /# c #/'),
        'set:a=1@1:1..1:14');

  { CRLF and a bare CR -- the terminators an editor actually produces -- end a directive
    line AND advance Line, because the engine's line model and the editor's agree on them. }
  Check('dir/crlf-and-cr-lines',
        Directives('#set %a% = 1'#13#10'#include "b"'#13'#set %c% = 3'),
        'set:a=1@1:1..1:13 | include:b=@2:1..2:13 | set:c=3@3:1..3:13');

  { U+2028/9 are where the two models part, and this is the only place that shows it: they
    END a directive (five terminators, TestLineTerminators pins that for render/validate)
    but do NOT advance Line, which follows the editor EOL contract of TSpDiag. So two
    directives, ONE line, the second at the column just past the separator -- which is what
    an editor that does not break on U+2028 will draw. }
  Check('dir/u2028-splits-directives-not-lines',
        Directives('#set %a% = 1' + U2028 + '#set %b% = 2'),
        'set:a=1@1:1..1:13 | set:b=2@1:14..1:26');
  Check('dir/u2029-splits-directives-not-lines',
        Directives('#set %a% = 1' + U2029 + '#set %b% = 2'),
        'set:a=1@1:1..1:13 | set:b=2@1:14..1:26');

  { Columns are code points: "ЖЖЖ" is 3 characters and 6 UTF-8 bytes, so the line ends at
    column 15, not 18. A byte column fails this. }
  Check('dir/cyrillic-value-column', Directives('#set %a% = ЖЖЖ'),
        'set:a=ЖЖЖ@1:1..1:15');

  { Macro names are lower-cased (that is how directives are keyed); an include target is
    verbatim: a slug is a host identifier, compared exactly here and against KnownIncludes
    (v0.2.2), where every variable name this unit reports is case-folded. }
  Check('dir/name-case', Directives('#set %Name% = 1'#10'#include "Frag"'),
        'set:name=1@1:1..1:16 | include:Frag=@2:1..2:16');

  { Line-anchoring, exactly as SpExtract and the renderer apply it. }
  Check('dir/inline-include-is-not-a-directive',
        Directives('before #include "frag" inline'), '<none>');
  Check('dir/indented-include', Directives('   #include "f"'),
        'include:f=@1:1..1:16');
  Check('dir/unquoted-include-ignored', Directives('#include frag'), '<none>');
  { An #include inside a #def value is a def -- validate flags it as def.include-in-value,
    and a host must not expand it. }
  Check('dir/include-in-def-value', Directives('#def %x% = #include "a"'),
        'def:x=#include "a"@1:1..1:24');
  { Malformed directives are body text, not directives (validate flags set.malformed). }
  Check('dir/malformed-set-is-not-a-directive', Directives('#set broken'), '<none>');
  Check('dir/empty-input', Directives(''), '<none>');

  { Text is the line the RENDERER consumed: comments already removed, no terminator. A host
    re-emits these as a prelude instead of re-spelling the grammar. }
  Check('dir/text-is-the-stripped-line', DirectiveTexts('/# c #/#set %a% = 1'),
        '#set %a% = 1');
  Check('dir/text-keeps-both-lines',
        DirectiveTexts('#set %a% = 1'#10'noise'#10'#def %b% = 2'),
        '#set %a% = 1 | #def %b% = 2');

  { A RAW reserved sentinel in author markup is the one input where this list and SpRender
    disagree, in both directions -- SpRender deletes U+E000..U+E005 BEFORE stripping
    comments, this scan (like SpExtract and SpValidate) reads the source as written. Pinned
    rather than fixed: measured on @spintax/core, its extract and validate diverge from its
    render in exactly these two ways, so the divergence is the family's contract for
    reserved characters in author markup, and three editor-side functions that agree with
    each other are worth more to a host than one that agrees with the renderer.

    The render half of each pair is the control: without it these would just assert that
    the scan does nothing surprising, instead of showing what the renderer does instead. }
  Check('dir/raw-sentinel-hides-a-directive',
        Directives('#se' + SENT + 't %x% = A'#10'%x%'), '<none>');
  Check('dir/raw-sentinel-hides-a-directive-render',
        RenderFirst('#se' + SENT + 't %x% = A'#10'%x%'), #10'A');
  Check('dir/raw-sentinel-forges-a-comment',
        Directives('/' + SENT + '# c'#10'#set %x% = A'#10'#/%x%'), 'set:x=A@2:1..2:13');
  Check('dir/raw-sentinel-forges-a-comment-render',
        RenderFirst('/' + SENT + '# c'#10'#set %x% = A'#10'#/%x%'), '%x%');

  { An #include whose gap swallowed the terminator is ONE occurrence spanning two source
    lines, and the span is the match rather than the first line -- a host replacing it by
    span has to remove both halves or it leaves a stray `"frag"` behind. }
  Check('dir/include-across-lines',
        Directives('#include'#10'"frag"'), 'include:frag=@1:1..2:7');

  { ...but the match end is NOT always the span end. The trailing whitespace class holds CR,
    so a CRLF-terminated include line matches through the CR and ends between it and the LF
    -- a position the editor line model cannot name, and one that puts the line's own
    terminator into the span. Span and Text exclude terminators, so the CR goes back: a host
    replacing this span must not swallow the line break. Compare the bare-CR line, which
    never had the problem. }
  Check('dir/include-crlf-span-excludes-the-cr',
        Directives('A'#13#10'#include "f"'#13#10'B'), 'include:f=@2:1..2:13');
  Check('dir/include-crlf-text-excludes-the-cr',
        DirectiveTexts('A'#13#10'#include "f"'#13#10'B'), '#include "f"');
  Check('dir/include-cr-span',
        Directives('A'#13'#include "f"'#13'B'), 'include:f=@2:1..2:13');

  { The occurrence half of anchor/match-swallows-the-next-line-start: the swallowed line
    start is not a second occurrence, and the span runs to the end of the match -- the last
    matched character is the third space on line 2 (column 13), so the exclusive end is
    2:14, not the start of line 3. Hand-derived and then checked against the scan; the first
    expectation written here said 3:1 and was wrong. }
  Check('dir/swallowed-line-start-is-one-occurrence',
        Directives('#include "a'#10'#include "   '#10'b"'#10),
        'include:a'#10'#include =@1:1..2:14');
end;

begin
  {$IFDEF FPC}
  DefaultSystemCodePage := CP_UTF8;
  SetTextCodePage(Output, CP_UTF8);
  {$ENDIF}

  TestLineTerminators;
  TestNilRng;
  TestSeededRng;
  TestPermutationConfig;
  TestPluralFallbacks;
  TestIncludes;
  TestIncludeAnchor;
  TestIncludeResolver;
  TestKnownVariables;
  TestUnicodeTables;
  TestEncoding;
  TestDecoderContract;
  TestCaseFolding;
  TestPostProcess;
  TestNulInInput;
  TestDiagPositions;
  TestExtractDirectives;

  Writeln(Format('local tests: %d checks, %d failed', [Checks, Failures]));
  if Failures > 0 then ExitCode := 1;
end.
