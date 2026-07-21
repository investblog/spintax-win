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
  SysUtils, Generics.Collections,
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
  TestPermutationConfig;
  TestPluralFallbacks;

  Writeln(Format('local tests: %d checks, %d failed', [Checks, Failures]));
  if Failures > 0 then ExitCode := 1;
end.
