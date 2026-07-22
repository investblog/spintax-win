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
  Check('terminator/CRLF render',  RenderFirst('#set %x% = A'#13#10'%x%'), #13#10'A');
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
  TestKnownVariables;
  TestUnicodeTables;
  TestEncoding;
  TestDecoderContract;
  TestCaseFolding;
  TestPostProcess;

  Writeln(Format('local tests: %d checks, %d failed', [Checks, Failures]));
  if Failures > 0 then ExitCode := 1;
end.
