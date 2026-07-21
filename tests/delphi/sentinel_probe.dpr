{**
 * sentinel_probe — settles ONE question that no FPC run can answer:
 * does the engine's sentinel encoding survive Delphi's UTF-16 `string`?
 *
 * Under FPC in delphi mode with long strings on, `string` is AnsiString and
 * `Char` is one byte,
 * so Sentinel(i) = #$EE#$80 + Chr($80+i) is the UTF-8 encoding of U+E000+i.
 * Under Delphi 2009+ `string` is UnicodeString and `Char` is WideChar, so the
 * same literal is THREE code units (U+00EE, U+0080, U+0080+i) and not U+E000+i.
 *
 * Deliberately depends on nothing but SysUtils and the engine: the corpus runner
 * needs fpjson/jsonparser, which Delphi does not have, and that port is only
 * worth doing if this probe says the engine is viable here at all.
 *
 * Build: open this .dpr in the IDE and press Ctrl+F9 (Delphi Starter has no
 * command-line compiler). Then run the produced .exe — it prints a verdict and
 * exits 0 for "byte semantics" or 1 for "UTF-16 semantics".
 *}
program sentinel_probe;

{$APPTYPE CONSOLE}

uses
  SysUtils,
  Spintax in '..\..\src\Spintax.pas';

var
  ExitVerdict: Integer = 0;

procedure Line(const s: string);
begin
  WriteLn(s);
end;

function Ords(const s: string): string;
var i: Integer;
begin
  Result := '';
  for i := 1 to Length(s) do
  begin
    if i > 1 then Result := Result + ' ';
    Result := Result + 'U+' + IntToHex(Ord(s[i]), 4);
  end;
end;

procedure ReportEnvironment;
begin
  Line('--- environment ---');
  Line('SizeOf(Char)      = ' + IntToStr(SizeOf(Char)) + '  (1 = byte string / FPC, 2 = UTF-16 / Delphi)');
  {$IFDEF UNICODE}
  Line('UNICODE defined   = yes  -> string is UnicodeString');
  {$ELSE}
  Line('UNICODE defined   = no   -> string is a byte string');
  {$ENDIF}
  {$IFDEF FPC}
  Line('compiler          = FPC');
  {$ELSE}
  Line('compiler          = Delphi ' + IntToStr(CompilerVersion));
  {$ENDIF}
  Line('');
end;

procedure ProbeSentinel;
var s: string;
begin
  Line('--- Sentinel(0) ---');
  s := SpNeutralize('{');           // one structural char -> exactly one sentinel
  Line('SpNeutralize(''{'') length = ' + IntToStr(Length(s)));
  Line('  code units: ' + Ords(s));
  {$IFDEF UNICODE}
  { UTF-16: correct means ONE code point, U+E000. Three units means the literal
    #$EE#$80#$80 was read as three wide chars - the divergence this probe exists for. }
  if (Length(s) = 1) and (Ord(s[1]) = $E000) then
    Line('  VERDICT: single code point U+E000 - matches the reference')
  else if Length(s) = 3 then
  begin
    Line('  VERDICT: THREE code units, not the reference''s single U+E000.');
    Line('           The sentinel literal is UTF-8 bytes read as wide chars.');
    ExitVerdict := 1;
  end
  else
    Line('  VERDICT: unexpected shape - investigate.');
  {$ELSE}
  { Byte string: correct means the three UTF-8 bytes EE 80 80. }
  if (Length(s) = 3) and (Ord(s[1]) = $EE) and (Ord(s[2]) = $80) and (Ord(s[3]) = $80) then
    Line('  VERDICT: 3 bytes EE 80 80 = UTF-8 for U+E000 - correct for a byte string')
  else
  begin
    Line('  VERDICT: unexpected byte shape - investigate.');
    ExitVerdict := 1;
  end;
  {$ENDIF}
  Line('');
end;

procedure ProbeRoundTrip;
var neutral, back: string;
begin
  Line('--- engine round-trip (must hold on any compiler) ---');
  neutral := SpNeutralize('{a|b}');
  back := SpSafetyRestore(neutral);
  Line('  neutralize -> restore = ' + back);
  if back = '{a|b}' then
    Line('  OK: the engine is self-consistent')
  else
  begin
    Line('  BROKEN: the engine does not even round-trip its own output');
    ExitVerdict := 2;
  end;
  Line('');
end;

procedure ProbeForeignSentinel;
var foreign, restored: string;
begin
  { The trust-model case. A value neutralized by the HOST or by another engine
    carries a real U+E000. If SpSafetyRestore cannot see it, structural chars
    from untrusted input reach the parser unshielded - and nothing announces it. }
  Line('--- foreign (host-neutralized) sentinel ---');
  {$IFDEF UNICODE}
  foreign := Char($E000) + 'a';
  {$ELSE}
  foreign := #$EE#$80#$80 + 'a';
  {$ENDIF}
  restored := SpSafetyRestore(foreign);
  Line('  input     : ' + Ords(foreign));
  Line('  restored  : ' + restored);
  if restored = '{a' then
    Line('  OK: a genuine U+E000 from outside is restored to ''{''')
  else
  begin
    Line('  FAILS: a genuine U+E000 is NOT restored - the mandatory safety');
    Line('         restore silently does nothing on host-neutralized input.');
    ExitVerdict := 3;
  end;
  Line('');
end;

procedure ProbeRender;
var ctx: TSpContext;
begin
  Line('--- smoke render (does the engine work here at all) ---');
  ctx := Default(TSpContext);
  ctx.Locale := 'en';
  ctx.PostProcess := False;
  ctx.Rng := TFirstRng.Create;
  try
    Line('  {a|b|c}    -> ' + SpRender('{a|b|c}', ctx));
    Line('  cyrillic   -> ' + SpRender('{товар|услуга}', ctx));
  finally
    ctx.Rng.Free;
  end;
  Line('');
end;

begin
  try
    Line('sentinel_probe - spintax-win');
    Line('');
    ReportEnvironment;
    ProbeSentinel;
    ProbeRoundTrip;
    ProbeForeignSentinel;
    ProbeRender;
    Line('exit code = ' + IntToStr(ExitVerdict));
  except
    on E: Exception do
    begin
      Line('EXCEPTION ' + E.ClassName + ': ' + E.Message);
      ExitVerdict := 9;
    end;
  end;
  ExitCode := ExitVerdict;
end.
