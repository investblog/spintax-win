{**
 * Conformance runner — loads the shared golden-corpus JSON fixtures and runs each
 * case against the Object Pascal port, asserting the deterministic gate (render,
 * neutralize, extract, validate). kind:rng render cases are reported as SKIP: they
 * assert within-engine reproducibility, not a cross-engine exact output.
 *
 * Builds under BOTH compilers. It used to be FPC-only because it spoke fpjson
 * directly; all JSON access now goes through SpxJson, so Delphi can run the same
 * corpus rather than a second harness that would drift from this one.
 *
 * NOTE: it REPORTS and always exits 0. The gate is tests/check-corpus.sh, which
 * diffs the failing set against tests/known-failures.txt.
 *
 * Usage: corpus_runner [fixtures-dir]      (falls back to $SPINTAX_FIXTURES)
 *}
program corpus_runner;

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}
{$APPTYPE CONSOLE}

uses
  SysUtils, Classes, Generics.Collections,
  { FPC resolves these from the -Fu search paths, which stays portable: CI builds
    on Linux, where a backslash in an `in` clause would not resolve. Delphi needs
    the explicit paths, and only ever builds this on Windows through the IDE. }
  {$IFDEF FPC}
  SpxJson, Spintax;
  {$ELSE}
  SpxJson in 'SpxJson.pas',
  Spintax in '..\src\Spintax.pas';
  {$ENDIF}

var
  TotalPass, TotalFail, TotalSkip: Integer;

function RngFromStrategy(node: TJsonNode): TSpRng;
var seqArr: TJsonNode; i: Integer; seq: array of Integer;
begin
  if node = nil then Exit(TFirstRng.Create);
  if JIsString(node) then
  begin
    if JStr(node) = 'last' then Exit(TLastRng.Create)
    else Exit(TFirstRng.Create); // 'first'
  end;
  if JIsObject(node) then
  begin
    seqArr := JFind(node, 'sequence');
    SetLength(seq, JCount(seqArr));
    for i := 0 to JCount(seqArr) - 1 do seq[i] := JInt(JItem(seqArr, i));
    Exit(TSequenceRng.Create(seq));
  end;
  Result := TFirstRng.Create;
end;

function NormalizeList(sl: TStringList): string;
var tmp: TStringList; i: Integer;
begin
  tmp := TStringList.Create;
  try
    for i := 0 to sl.Count - 1 do tmp.Add(sl[i]);
    tmp.Sort;
    Result := tmp.CommaText;
  finally
    tmp.Free;
  end;
end;

function JsonArrToList(arr: TJsonNode): TStringList;
var i: Integer;
begin
  Result := TStringList.Create;
  if arr <> nil then
    for i := 0 to JCount(arr) - 1 do Result.Add(JStr(JItem(arr, i)));
end;

procedure RunCase(c: TJsonNode; const fname: string);
var
  id, op, kind, tmpl, locale, got, want: string;
  postProc: Boolean;
  ctx: TSpContext;
  vars: TDictionary<string, string>;
  ctxObj: TJsonNode;
  neutralizeCtx: TJsonNode;
  expect: TJsonNode;
  i: Integer;
  pass: Boolean;
  reason, nkey, nval, verdict, wantCode, wantSev: string;
  ex: TExtractResult;
  diags: TSpDiagList;
  knownInc: TStringList;
  expDiags: TJsonNode;
  j: Integer;
  found: Boolean;
begin
  id := JGetStr(c, 'id', '');
  op := JGetStr(c, 'op', 'render');
  kind := JGetStr(c, 'kind', 'deterministic');
  tmpl := JGetStr(c, 'template', '');
  locale := JGetStr(c, 'locale', '');
  expect := JFind(c, 'expect');

  // Within-engine rng invariants are engine-private by design.
  if (op = 'render') and (kind = 'rng') then
  begin
    Inc(TotalSkip);
    Exit;
  end;

  pass := False; reason := '';
  try
    if op = 'validate' then
    begin
      knownInc := nil;
      if JFind(c, 'knownIncludes') <> nil then
        knownInc := JsonArrToList(JFind(c, 'knownIncludes'));
      diags := SpValidate(tmpl, locale, knownInc);
      try
        // verdict = invalid iff any error-severity diagnostic
        verdict := 'valid';
        for i := 0 to diags.Count - 1 do
          if diags[i].Severity = 'error' then begin verdict := 'invalid'; Break; end;
        pass := (verdict = JGetStr(expect, 'verdict', ''));
        if not pass then reason := 'verdict want=' + JGetStr(expect, 'verdict', '') + ' got=' + verdict;
        // each expected diagnostic code (+severity if given) must be present
        if pass and (JFind(expect, 'diagnostics') <> nil) then
        begin
          expDiags := JFind(expect, 'diagnostics');
          for i := 0 to JCount(expDiags) - 1 do
          begin
            wantCode := JGetStr(JItem(expDiags, i), 'code', '');
            wantSev := JGetStr(JItem(expDiags, i), 'severity', '');
            found := False;
            for j := 0 to diags.Count - 1 do
              if (diags[j].Code = wantCode) and ((wantSev = '') or (diags[j].Severity = wantSev)) then
                begin found := True; Break; end;
            if not found then
              begin pass := False; reason := 'missing diag ' + wantCode; Break; end;
          end;
        end;
      finally
        diags.Free;
        if knownInc <> nil then knownInc.Free;
      end;
    end
    else if op = 'neutralize' then
    begin
      got := SpNeutralize(tmpl);
      want := JGetStr(expect, 'output', '');
      pass := (got = want);
      if not pass then reason := 'want=' + want + ' got=' + got;
    end
    else if op = 'extract' then
    begin
      ex := SpExtract(tmpl);
      try
        pass := True;
        if JFind(expect, 'refs') <> nil then
          if NormalizeList(ex.Refs) <> NormalizeList(JsonArrToList(JFind(expect, 'refs'))) then
            begin pass := False; reason := reason + ' refs:[' + NormalizeList(ex.Refs) + ']'; end;
        if JFind(expect, 'sets') <> nil then
          if NormalizeList(ex.Sets) <> NormalizeList(JsonArrToList(JFind(expect, 'sets'))) then
            begin pass := False; reason := reason + ' sets:[' + NormalizeList(ex.Sets) + ']'; end;
        if JFind(expect, 'defs') <> nil then
          if NormalizeList(ex.Defs) <> NormalizeList(JsonArrToList(JFind(expect, 'defs'))) then
            begin pass := False; reason := reason + ' defs:[' + NormalizeList(ex.Defs) + ']'; end;
        if JFind(expect, 'includes') <> nil then
          if NormalizeList(ex.Includes) <> NormalizeList(JsonArrToList(JFind(expect, 'includes'))) then
            begin pass := False; reason := reason + ' includes:[' + NormalizeList(ex.Includes) + ']'; end;
      finally
        ex.Refs.Free; ex.Sets.Free; ex.Defs.Free; ex.Includes.Free;
      end;
    end
    else // render, deterministic
    begin
      vars := TDictionary<string, string>.Create;
      try
        ctxObj := JFind(c, 'context');
        if ctxObj <> nil then
          for i := 0 to JCount(ctxObj) - 1 do
            vars.AddOrSetValue(JName(ctxObj, i), JStr(JItem(ctxObj, i)));

        // neutralizeContext: apply neutralize() to those keys before rendering
        neutralizeCtx := JFind(c, 'neutralizeContext');
        if neutralizeCtx <> nil then
        begin
          for i := 0 to JCount(neutralizeCtx) - 1 do
          begin
            nkey := JStr(JItem(neutralizeCtx, i));
            if vars.TryGetValue(nkey, nval) then vars.AddOrSetValue(nkey, SpNeutralize(nval));
          end;
        end;

        postProc := JGetBool(c, 'postProcess', True);
        ctx.Vars := vars;
        ctx.Locale := locale;
        ctx.PostProcess := postProc;
        ctx.Rng := RngFromStrategy(JFind(c, 'rng'));
        try
          got := SpRender(tmpl, ctx);
        finally
          ctx.Rng.Free;
        end;
        want := JGetStr(expect, 'output', '');
        pass := (got = want);
        if not pass then reason := 'want=[' + want + '] got=[' + got + ']';
      finally
        vars.Free;
      end;
    end;
  except
    on E: Exception do begin pass := False; reason := 'EXC ' + E.Message; end;
  end;

  if pass then Inc(TotalPass)
  else
  begin
    Inc(TotalFail);
    Writeln('  FAIL [', fname, '] ', id, '  ', reason);
  end;
end;

procedure RunFile(const path: string);
var
  data: TJsonNode;
  i: Integer;
begin
  data := JParseFile(path);
  if data = nil then
  begin
    Writeln(Format('%-32s UNREADABLE', [ExtractFileName(path)]));
    Exit;
  end;
  try
    if not JIsArray(data) then Exit;
    for i := 0 to JCount(data) - 1 do
      RunCase(JItem(data, i), ExtractFileName(path));
    Writeln(Format('%-32s cases=%d', [ExtractFileName(path), JCount(data)]));
  finally
    data.Free;
  end;
end;

var
  dir, mask: string;
  info: TSearchRec;
begin
  TotalPass := 0; TotalFail := 0; TotalSkip := 0;
  if ParamCount >= 1 then dir := ParamStr(1)
  else dir := GetEnvironmentVariable('SPINTAX_FIXTURES');

  if dir = '' then
  begin
    Writeln('corpus_runner: no fixtures directory (pass one, or set SPINTAX_FIXTURES)');
    Writeln('  expected the packages/conformance/fixtures dir of a spintax-js checkout');
    Exit;
  end;

  Writeln('Running golden corpus from: ', dir);
  Writeln('----------------------------------------------------------');
  mask := IncludeTrailingPathDelimiter(dir) + '*.json';
  if FindFirst(mask, faAnyFile, info) = 0 then
  begin
    repeat
      RunFile(IncludeTrailingPathDelimiter(dir) + info.Name);
    until FindNext(info) <> 0;
    FindClose(info);
  end;
  Writeln('----------------------------------------------------------');
  Writeln(Format('PASS=%d  FAIL=%d  SKIP=%d  (skip = kind:rng render, within-engine reproducibility only)',
    [TotalPass, TotalFail, TotalSkip]));
end.
