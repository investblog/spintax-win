{**
 * SpxJson — the thinnest possible JSON reader shared by both compilers.
 *
 * The corpus runner needs about a dozen read-only operations. FPC has fpjson,
 * Delphi has System.JSON, and their APIs differ just enough that a runner written
 * against either one will not compile on the other. Rather than keep two runners
 * (which drift, and a drifting harness stops testing the same thing), the runner
 * is written against these functions and the difference lives here alone.
 *
 * Functions, not wrapper objects, on purpose: the native tree keeps ownership, so
 * only the root returned by JParseFile has to be freed and nothing has to track
 * intermediate wrappers.
 *
 * Read-only. Nothing here writes JSON — the corpus is an input.
 *}
unit SpxJson;

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
  SysUtils, Classes,
  { System.Generics.Collections is listed for Delphi only so its inline accessors in
    System.JSON can actually be expanded — without it dcc32 emits H2443 for every one. }
  {$IFDEF FPC} fpjson, jsonparser {$ELSE} System.Generics.Collections, System.JSON {$ENDIF};

type
  {$IFDEF FPC}
  TJsonNode = TJSONData;
  {$ELSE}
  TJsonNode = TJSONValue;
  {$ENDIF}

{ Parse a UTF-8 file. Returns nil if it cannot be read or parsed. Caller frees. }
function JParseFile(const Path: string): TJsonNode;

function JIsArray(N: TJsonNode): Boolean;
function JIsObject(N: TJsonNode): Boolean;
function JIsString(N: TJsonNode): Boolean;

{ Element count of an array or an object. 0 for anything else (and for nil). }
function JCount(N: TJsonNode): Integer;
{ Array element, or object VALUE by position. }
function JItem(N: TJsonNode; I: Integer): TJsonNode;
{ Object KEY by position. }
function JName(N: TJsonNode; I: Integer): string;
{ Object member by key, or nil when absent — the "is it present" test. }
function JFind(N: TJsonNode; const Key: string): TJsonNode;

function JStr(N: TJsonNode): string;
function JInt(N: TJsonNode): Integer;
{ Convenience: JFind + JStr with a default. }
function JGetStr(N: TJsonNode; const Key, Default: string): string;
{ Same for a boolean member (the corpus uses it only for postProcess). }
function JGetBool(N: TJsonNode; const Key: string; Default: Boolean): Boolean;

implementation

{ Reading the corpus is itself encoding-sensitive, which is the whole reason this
  port exists. On a byte string the UTF-8 bytes must arrive untouched; under UTF-16
  they must be decoded from UTF-8 exactly once. Both branches go through raw bytes
  so no RTL text-file heuristic gets a vote. }
function ReadFileText(const Path: string): string;
var
  Stream: TFileStream;
  Bytes: TBytes;
begin
  Result := '';
  if not FileExists(Path) then Exit;
  Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Bytes, Stream.Size);
    if Stream.Size > 0 then Stream.ReadBuffer(Bytes[0], Stream.Size);
  finally
    Stream.Free;
  end;
  if Length(Bytes) = 0 then Exit;
  {$IFDEF FPC}
  SetLength(Result, Length(Bytes));
  Move(Bytes[0], Result[1], Length(Bytes));
  {$ELSE}
  Result := TEncoding.UTF8.GetString(Bytes);
  {$ENDIF}
end;

function JParseFile(const Path: string): TJsonNode;
var
  Text: string;
begin
  Result := nil;
  Text := ReadFileText(Path);
  if Text = '' then Exit;
  try
    {$IFDEF FPC}
    Result := GetJSON(Text);
    {$ELSE}
    Result := TJSONObject.ParseJSONValue(Text);
    {$ENDIF}
  except
    Result := nil;
  end;
end;

function JIsArray(N: TJsonNode): Boolean;
begin
  {$IFDEF FPC}
  Result := (N <> nil) and (N.JSONType = jtArray);
  {$ELSE}
  Result := (N <> nil) and (N is TJSONArray);
  {$ENDIF}
end;

function JIsObject(N: TJsonNode): Boolean;
begin
  {$IFDEF FPC}
  Result := (N <> nil) and (N.JSONType = jtObject);
  {$ELSE}
  Result := (N <> nil) and (N is TJSONObject);
  {$ENDIF}
end;

function JIsString(N: TJsonNode): Boolean;
begin
  {$IFDEF FPC}
  Result := (N <> nil) and (N.JSONType = jtString);
  {$ELSE}
  Result := (N <> nil) and (N is TJSONString);
  {$ENDIF}
end;

function JCount(N: TJsonNode): Integer;
begin
  Result := 0;
  if N = nil then Exit;
  {$IFDEF FPC}
  if (N.JSONType = jtArray) or (N.JSONType = jtObject) then Result := N.Count;
  {$ELSE}
  if N is TJSONArray then Result := TJSONArray(N).Count
  else if N is TJSONObject then Result := TJSONObject(N).Count;
  {$ENDIF}
end;

function JItem(N: TJsonNode; I: Integer): TJsonNode;
begin
  Result := nil;
  if (N = nil) or (I < 0) or (I >= JCount(N)) then Exit;
  {$IFDEF FPC}
  if N.JSONType = jtArray then Result := TJSONArray(N).Items[I]
  else if N.JSONType = jtObject then Result := TJSONObject(N).Items[I];
  {$ELSE}
  if N is TJSONArray then Result := TJSONArray(N).Items[I]
  else if N is TJSONObject then Result := TJSONObject(N).Pairs[I].JsonValue;
  {$ENDIF}
end;

function JName(N: TJsonNode; I: Integer): string;
begin
  Result := '';
  if (N = nil) or (I < 0) or (I >= JCount(N)) then Exit;
  {$IFDEF FPC}
  if N.JSONType = jtObject then Result := TJSONObject(N).Names[I];
  {$ELSE}
  if N is TJSONObject then Result := TJSONObject(N).Pairs[I].JsonString.Value;
  {$ENDIF}
end;

function JFind(N: TJsonNode; const Key: string): TJsonNode;
begin
  Result := nil;
  if not JIsObject(N) then Exit;
  {$IFDEF FPC}
  Result := TJSONObject(N).Find(Key);
  {$ELSE}
  Result := TJSONObject(N).GetValue(Key);
  {$ENDIF}
end;

function JStr(N: TJsonNode): string;
begin
  Result := '';
  if N = nil then Exit;
  {$IFDEF FPC}
  Result := N.AsString;
  {$ELSE}
  if N is TJSONString then Result := TJSONString(N).Value else Result := N.Value;
  {$ENDIF}
end;

function JInt(N: TJsonNode): Integer;
begin
  Result := 0;
  if N = nil then Exit;
  {$IFDEF FPC}
  Result := N.AsInteger;
  {$ELSE}
  if N is TJSONNumber then Result := TJSONNumber(N).AsInt
  else Result := StrToIntDef(JStr(N), 0);
  {$ENDIF}
end;

function JGetStr(N: TJsonNode; const Key, Default: string): string;
var
  Member: TJsonNode;
begin
  Member := JFind(N, Key);
  if Member = nil then Result := Default else Result := JStr(Member);
end;

function JGetBool(N: TJsonNode; const Key: string; Default: Boolean): Boolean;
var
  Member: TJsonNode;
begin
  Result := Default;
  Member := JFind(N, Key);
  if Member = nil then Exit;
  {$IFDEF FPC}
  Result := Member.AsBoolean;
  {$ELSE}
  if Member is TJSONBool then Result := TJSONBool(Member).AsBoolean
  else Result := SameText(JStr(Member), 'true');
  {$ENDIF}
end;

end.
