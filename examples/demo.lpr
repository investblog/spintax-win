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
