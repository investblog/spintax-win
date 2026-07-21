{**
 * Conformance runner — loads the shared golden-corpus JSON fixtures and runs
 * each case against the Object Pascal port, asserting the deterministic gate
 * (render/deterministic, neutralize, extract). validate and kind:rng cases are
 * reported as SKIP (out of PoC scope; rng cases are within-engine only anyway).
 *}
program corpus_runner;

{$mode delphi}{$H+}

uses
  SysUtils, Classes, fpjson, jsonparser, Generics.Collections, Spintax;

var
  TotalPass, TotalFail, TotalSkip: Integer;

function RngFromStrategy(node: TJSONData): TSpRng;
var seqArr: TJSONArray; i: Integer; seq: array of Integer;
begin
  if node = nil then Exit(TFirstRng.Create);
  if node.JSONType = jtString then
  begin
    if node.AsString = 'last' then Exit(TLastRng.Create)
    else Exit(TFirstRng.Create); // 'first'
  end;
  if node.JSONType = jtObject then
  begin
    seqArr := TJSONObject(node).Arrays['sequence'];
    SetLength(seq, seqArr.Count);
    for i := 0 to seqArr.Count - 1 do seq[i] := seqArr.Integers[i];
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

function JsonArrToList(arr: TJSONArray): TStringList;
var i: Integer;
begin
  Result := TStringList.Create;
  if arr <> nil then
    for i := 0 to arr.Count - 1 do Result.Add(arr.Strings[i]);
end;

procedure RunCase(c: TJSONObject; const fname: string);
var
  id, op, kind, tmpl, locale, got, want: string;
  postProc: Boolean;
  ctx: TSpContext;
  vars: TDictionary<string, string>;
  ctxObj: TJSONObject;
  neutralizeCtx: TJSONArray;
  expect: TJSONObject;
  i: Integer;
  pass: Boolean;
  reason, nkey, nval, verdict, wantCode, wantSev: string;
  ex: TExtractResult;
  diags: TSpDiagList;
  knownInc: TStringList;
  expDiags: TJSONArray;
  j: Integer;
  found: Boolean;
begin
  id := c.Get('id', '');
  op := c.Get('op', 'render');
  kind := c.Get('kind', 'deterministic');
  tmpl := c.Get('template', '');
  locale := c.Get('locale', '');
  expect := c.Objects['expect'];

  // Within-engine rng invariants are out of scope for this PoC.
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
      if c.Find('knownIncludes') <> nil then
        knownInc := JsonArrToList(c.Arrays['knownIncludes']);
      diags := SpValidate(tmpl, locale, knownInc);
      try
        // verdict = invalid iff any error-severity diagnostic
        verdict := 'valid';
        for i := 0 to diags.Count - 1 do
          if diags[i].Severity = 'error' then begin verdict := 'invalid'; Break; end;
        pass := (verdict = expect.Get('verdict', ''));
        if not pass then reason := 'verdict want=' + expect.Get('verdict', '') + ' got=' + verdict;
        // each expected diagnostic code (+severity if given) must be present
        if pass and (expect.Find('diagnostics') <> nil) then
        begin
          expDiags := expect.Arrays['diagnostics'];
          for i := 0 to expDiags.Count - 1 do
          begin
            wantCode := TJSONObject(expDiags.Items[i]).Get('code', '');
            wantSev := TJSONObject(expDiags.Items[i]).Get('severity', '');
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
      want := expect.Get('output', '');
      pass := (got = want);
      if not pass then reason := 'want=' + want + ' got=' + got;
    end
    else if op = 'extract' then
    begin
      ex := SpExtract(tmpl);
      try
        pass := True;
        if expect.Find('refs') <> nil then
          if NormalizeList(ex.Refs) <> NormalizeList(JsonArrToList(expect.Arrays['refs'])) then
            begin pass := False; reason := reason + ' refs:[' + NormalizeList(ex.Refs) + ']'; end;
        if expect.Find('sets') <> nil then
          if NormalizeList(ex.Sets) <> NormalizeList(JsonArrToList(expect.Arrays['sets'])) then
            begin pass := False; reason := reason + ' sets:[' + NormalizeList(ex.Sets) + ']'; end;
        if expect.Find('defs') <> nil then
          if NormalizeList(ex.Defs) <> NormalizeList(JsonArrToList(expect.Arrays['defs'])) then
            begin pass := False; reason := reason + ' defs:[' + NormalizeList(ex.Defs) + ']'; end;
        if expect.Find('includes') <> nil then
          if NormalizeList(ex.Includes) <> NormalizeList(JsonArrToList(expect.Arrays['includes'])) then
            begin pass := False; reason := reason + ' includes:[' + NormalizeList(ex.Includes) + ']'; end;
      finally
        ex.Refs.Free; ex.Sets.Free; ex.Defs.Free; ex.Includes.Free;
      end;
    end
    else // render, deterministic
    begin
      vars := TDictionary<string, string>.Create;
      try
        ctxObj := TJSONObject(c.Find('context'));
        if ctxObj <> nil then
          for i := 0 to ctxObj.Count - 1 do
            vars.AddOrSetValue(ctxObj.Names[i], ctxObj.Items[i].AsString);

        // neutralizeContext: apply neutralize() to those keys before rendering
        if c.Find('neutralizeContext') <> nil then
        begin
          neutralizeCtx := c.Arrays['neutralizeContext'];
          for i := 0 to neutralizeCtx.Count - 1 do
          begin
            nkey := neutralizeCtx.Strings[i];
            if vars.TryGetValue(nkey, nval) then vars.AddOrSetValue(nkey, SpNeutralize(nval));
          end;
        end;

        postProc := c.Get('postProcess', True);
        ctx.Vars := vars;
        ctx.Locale := locale;
        ctx.PostProcess := postProc;
        ctx.Rng := RngFromStrategy(c.Find('rng'));
        try
          got := SpRender(tmpl, ctx);
        finally
          ctx.Rng.Free;
        end;
        want := expect.Get('output', '');
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
  raw: TStringList;
  data: TJSONData;
  arr: TJSONArray;
  i, before: Integer;
begin
  raw := TStringList.Create;
  try
    raw.LoadFromFile(path);
    data := GetJSON(raw.Text);
    try
      if data.JSONType <> jtArray then Exit;
      arr := TJSONArray(data);
      before := TotalPass + TotalFail;
      for i := 0 to arr.Count - 1 do
        RunCase(TJSONObject(arr.Items[i]), ExtractFileName(path));
      Writeln(Format('%-32s cases=%d', [ExtractFileName(path), arr.Count]));
    finally
      data.Free;
    end;
  finally
    raw.Free;
  end;
end;

var
  dir, mask: string;
  info: TSearchRec;
begin
  TotalPass := 0; TotalFail := 0; TotalSkip := 0;
  if ParamCount >= 1 then dir := ParamStr(1)
  else dir := '/home/claude/spintax-js/packages/conformance/fixtures';

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
