{**
 * local_tests — assertions the golden corpus structurally cannot make.
 *
 * The corpus schema has no field for line terminators other than LF, for a nil RNG,
 * for #include resolution, permutation <config> or plural lenient fallbacks (spec §8).
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

begin
  {$IFDEF FPC}
  DefaultSystemCodePage := CP_UTF8;
  SetTextCodePage(Output, CP_UTF8);
  {$ENDIF}

  TestLineTerminators;
  TestNilRng;

  Writeln(Format('local tests: %d checks, %d failed', [Checks, Failures]));
  if Failures > 0 then ExitCode := 1;
end.
