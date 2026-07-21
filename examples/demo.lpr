{**
 * demo — render a spintax template from the command line.
 *   ./demo "template" [locale]
 * Uses the deterministic 'first' RNG so output is stable (good for a diff).
 * Pass a seed instead by editing TFirstRng -> TMulberry32Rng.Create(seed).
 *}
program demo;

{$mode delphi}{$H+}

uses
  SysUtils, Generics.Collections, Spintax;

var
  tmpl, locale, outp: string;
  ctx: TSpContext;
  vars: TDictionary<string, string>;
begin
  { The engine's contract is raw UTF-8 bytes in `string`. FPC converts to
    DefaultSystemCodePage at boundaries, and that default follows the locale — under
    LANG=C it is ASCII, which silently replaces every non-ASCII character with '?'.
    Any FPC host feeding this engine non-ASCII text has to declare UTF-8; a library
    cannot do it for its callers. }
  DefaultSystemCodePage := CP_UTF8;
  { Tell the RTL what the strings it is about to print actually are. Measured on a
    Russian Windows console: without this the output came out as '?????', with it as
    correctly-encoded CP1251. The engine's bytes are UTF-8 either way — this only
    governs how they reach the terminal. }
  SetTextCodePage(Output, CP_UTF8);

  if ParamCount < 1 then
  begin
    Writeln('usage: demo "template" [locale]');
    Halt(1);
  end;
  tmpl := ParamStr(1);
  if ParamCount >= 2 then locale := ParamStr(2) else locale := '';

  vars := TDictionary<string, string>.Create;
  ctx.Rng := TFirstRng.Create;
  try
    ctx.Vars := vars;
    ctx.Locale := locale;
    ctx.PostProcess := True;
    outp := SpRender(tmpl, ctx);
    Writeln(outp);
  finally
    ctx.Rng.Free;
    vars.Free;
  end;
end.
