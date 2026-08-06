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

{ FPC's fpjson does not decode a code-point escape faithfully, and the two ways it fails
  were both measured here on 2026-08-07, on FPC 3.2.2:

    "a\u0000b"   -> "ab"    the NUL is DROPPED, on every accessor -- AsString,
                              AsUnicodeString and Value alike, because the loss is in the
                              scanner and nothing downstream can recover it
    "a\u00a0b"   -> "a?b"   every escape above ASCII becomes a question mark: the scanner
                              builds a WideString and converts it in the system codepage

  A raw NUL byte instead of the escape does not help either -- the scanner ends the string
  at it ("string exceeds end of line").

  Neither is academic. The corpus carries `validate/directive-check-nul-line-is-text`, which
  pins that a NUL before `#set` is NOT trimmed and so leaves an ordinary line of text: this
  runner was handing the engine `#set broken` instead and reporting the engine's correct
  answer as a failure. The second failure is latent only because the fixtures spell non-ASCII
  characters as raw UTF-8 today; one escaped Cyrillic letter in a future fixture and this
  runner would compare against a row of question marks. A harness that quietly alters its
  input has stopped testing the same thing -- which is the reason this unit exists.

  So the escapes are decoded HERE, before fpjson sees them, and only where fpjson gets them
  wrong:

    < U+0020, and " and \    left as an escape -- JSON requires it, and fpjson is correct
    U+0000                   swapped for U+0001, and swapped back on the way out of JStr
    everything else          replaced by its own UTF-8 bytes, which fpjson passes through

  U+0001 is the placeholder because it is the only kind of character fpjson delivers
  intact -- an ASCII control -- and a file that carries one of its own is refused rather
  than rewritten, so this can never invent a NUL that was not there.

  Delphi's System.JSON is left alone: it is not gated here, and changing what it parses on
  the strength of a measurement made on the other compiler is how a harness starts lying. }
const
  NUL_ESCAPE = '\' + 'u0000';   { the six characters, as they appear in the file }
  NUL_STANDIN = #1;

var
  NulWasSwapped: Boolean = False;

{ True when the backslash at Index opens an escape rather than being an escaped backslash
  that happens to be followed by one: escaped backslashes come in pairs, so the run ending
  here must be of even length. }
function IsRealEscape(const Text: string; Index: Integer): Boolean;
var
  Run, I: Integer;
begin
  Run := 0;
  I := Index - 1;
  while (I >= 1) and (Text[I] = '\') do begin Inc(Run); Dec(I); end;
  Result := (Run mod 2) = 0;
end;

{ The four hex digits after a `\u` at Index, or -1 if they are not four hex digits. }
function EscapeValue(const Text: string; Index: Integer): Integer;
var
  I, V, Digit: Integer;
  C: Char;
begin
  Result := -1;
  if Index + 5 > Length(Text) then Exit;
  V := 0;
  for I := Index + 2 to Index + 5 do
  begin
    C := Text[I];
    case C of
      '0'..'9': Digit := Ord(C) - Ord('0');
      'a'..'f': Digit := Ord(C) - Ord('a') + 10;
      'A'..'F': Digit := Ord(C) - Ord('A') + 10;
    else
      Exit;
    end;
    V := V * 16 + Digit;
  end;
  Result := V;
end;

function Utf8Bytes(CP: Integer): string;
begin
  if CP < $80 then
    Result := Chr(CP)
  else if CP < $800 then
    Result := Chr($C0 or (CP shr 6)) + Chr($80 or (CP and $3F))
  else if CP < $10000 then
    Result := Chr($E0 or (CP shr 12)) + Chr($80 or ((CP shr 6) and $3F)) +
              Chr($80 or (CP and $3F))
  else
    Result := Chr($F0 or (CP shr 18)) + Chr($80 or ((CP shr 12) and $3F)) +
              Chr($80 or ((CP shr 6) and $3F)) + Chr($80 or (CP and $3F));
end;

{ Rewrites the escapes fpjson would mangle. NulSeen reports whether a NUL escape was
  swapped, so JStr only pays for a file that needed it. }
function PreDecodeEscapes(const Text: string; out NulSeen: Boolean): string;
var
  I, CP, Low: Integer;
  Buf: string;
begin
  Buf := '';
  NulSeen := False;
  I := 1;
  while I <= Length(Text) do
  begin
    if (Text[I] = '\') and (I < Length(Text)) and
       ((Text[I + 1] = 'u') or (Text[I + 1] = 'U')) and IsRealEscape(Text, I) then
    begin
      CP := EscapeValue(Text, I);
      if CP >= 0 then
      begin
        { a surrogate pair is one code point, and its halves are meaningless apart }
        if (CP >= $D800) and (CP <= $DBFF) and (I + 11 <= Length(Text)) and
           (Text[I + 6] = '\') and ((Text[I + 7] = 'u') or (Text[I + 7] = 'U')) then
        begin
          Low := EscapeValue(Text, I + 6);
          if (Low >= $DC00) and (Low <= $DFFF) then
          begin
            Buf := Buf + Utf8Bytes($10000 + ((CP - $D800) shl 10) + (Low - $DC00));
            Inc(I, 12);
            Continue;
          end;
        end;
        if CP = 0 then
        begin
          Buf := Buf + NUL_STANDIN;
          NulSeen := True;
          Inc(I, 6);
          Continue;
        end;
        { below U+0020, and the two characters JSON must keep escaped, fpjson is right }
        if (CP >= $20) and (CP <> Ord('"')) and (CP <> $5C) then
        begin
          Buf := Buf + Utf8Bytes(CP);
          Inc(I, 6);
          Continue;
        end;
      end;
    end;
    Buf := Buf + Text[I];
    Inc(I);
  end;
  Result := Buf;
end;

function JParseFile(const Path: string): TJsonNode;
var
  Text: string;
  NulSeen: Boolean;
begin
  Result := nil;
  Text := ReadFileText(Path);
  if Text = '' then Exit;
  {$IFDEF FPC}
  if Pos(NUL_STANDIN, Text) > 0 then
    WriteLn(ErrOutput, 'SpxJson: ', Path, ' carries a U+0001 of its own; a NUL escape in ',
                       'it cannot be told from one and would be dropped by fpjson')
  else
  begin
    Text := PreDecodeEscapes(Text, NulSeen);
    if NulSeen then NulWasSwapped := True;
  end;
  {$ENDIF}
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
  { undo the stand-in, and only for a file that actually needed one }
  if NulWasSwapped and (Pos(NUL_STANDIN, Result) > 0) then
    Result := StringReplace(Result, NUL_STANDIN, #0, [rfReplaceAll]);
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
