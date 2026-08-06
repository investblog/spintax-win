(*  GSA Search Engine Ranker dialect -> spintax.net syntax.

  An OPTIONAL front end, not part of the engine and not gated by the golden corpus: it
  rewrites a SER template into the syntax `Spintax` renders, so an existing SER project
  runs on this engine unchanged. The engine itself gains no GSA syntax -- the family's
  contract is the corpus, and a dialect belongs beside it, not inside it.

  Source for the dialect: https://docu.gsa-online.de/search_engine_ranker/macro_guide
  Everything here was measured against that page's examples, and where the page and the SER
  author's description of a construct disagreed, against SER itself (see SPINTAGS).

  THE RULE THIS UNIT IS BUILT ON

  A conversion may never leave the engine free to render a GSA construct as something
  else. Text this unit does not understand is not "left alone" -- left alone is exactly
  how `{#.de Hallo|#.com Hello}` becomes a coin flip that prints `#.de Hallo`. Anything
  unconvertible is lifted OUT of the template into a variable, so the default render
  reproduces it verbatim and a host that wants to resolve it can.

  1. BRACKETED MACROS

  `#file[list.txt,1,S]` is not spintax, but `[` opens a PERMUTATION here, so the engine
  renders it as `#filelist.txt,1,S`: the brackets are eaten and the macro is destroyed
  before SER sees it. Worse where the macro holds a `|` -- `#openai[m,write a|b,50]` or
  `%related_url_link[ignore=a.com|b.com]%` -- which the engine reads as options and
  SHUFFLES. The documented bracketed macros are `#file`, `#file_links`, `#grabbed`,
  `#grabbedAll`, `#gennick`, `#random`, `#err`, `#openai` and the `%…[…]%` form, so the
  name is read as a GSA identifier (letter, then letters, digits or underscore) rather
  than from a list this unit would have to chase.

  It cannot be repaired inside the template text: SpRender STRIPS reserved sentinels from
  a template before parsing it, deliberately, so that author markup cannot forge one.
  Sentinels legitimately enter a render only through the host's variables, which is the
  route taken here -- each macro becomes a `%…mN%` reference whose neutralized text is
  handed back in MacroVars for TSpContext.Vars. The mandatory safety restore then puts the
  real characters into the output.

  The `%…%` macros without brackets need no rescue and get none: `%spinfile-f%`,
  `%spinfolder-p%`, `%columnspinfile-f-2%`, `%random-1-9%`, `#file=f` and `#spin…#nospin`
  all pass through the engine unchanged, because a variable here is `%(\w+)%` and none of
  them are that.

  2. THE TILDE FORM

  `~{a|b|c}` -> `[a|b|c]`. The guide: "all variations are used but in a random order".
  That is this family's permutation exactly -- all elements, shuffled, joined with a
  space -- so the rewrite is textual and nothing is approximated. (The feature request
  that prompted this described the tilde form as emitting the options IN ORDER; the
  guide's own worked example shuffles them, and `[...]` reproduces that example.)

  3. SPINTAGS

  The guide tags each OPTION inside a block, and blocks sharing a tag set move together:

      {#TAG1 I love {the|your} site|#TAG2 Hello there}. {#TAG1 Best forum ever.|#TAG2 How are you?}

  never yields "Hello there. Best forum ever.". Confirmed in SER's own Article Manager:
  eight copies of `{#P 1|#Q 2|#R 3}` in one article all returned the same digit, where eight
  untagged copies of `{1|2|3}` did not.

  The feature request described a different form -- the tag naming the BLOCK, with the
  chosen option's INDEX reused across blocks -- and that form is NOT converted, because the
  same measurement refutes it: eight copies of `{#tagA 1|2|3}` returned `2 1 1 1 1 1 1 1`,
  where index correlation predicts eight identical digits with certainty. Such a block is
  refused and handed back to the host (see 4).

  The engine does the choosing, through `#def`: it resolves once per render and holds,
  which is precisely a choice made once and reused.

      #def %__gsa_g1_1% = {x|}
      {?__gsa_g1_1?I love {the|your} site|Hello there}. {?__gsa_g1_1?Best forum ever.|How are you?}

  For n branches a group emits n-1 definitions, the i-th non-empty with probability
  1/(n-i+1), and each block becomes a chain of n-1 nested conditionals, which is uniform
  over the n branches. A group of ONE block needs no correlation and is written as a plain
  enumeration. It is verbose because `{?VAR?a|b}` tests only whether a variable is SET; a
  value-equality conditional would reduce a group to one definition and one test.

  4. WHAT IT LIFTS OUT INSTEAD OF CONVERTING

  Reported in `Unsupported` as `name=original text`, and rendered verbatim unless the host
  overrides the variable:

  - `{#.de Hallo|#.com Hello}` selects on the TARGET URL's domain. That is not a spin; it
    is a conditional on host context, and a converter that turned it into a random choice
    would be changing behaviour, not translating it.
  - a block where only SOME options carry a tag. SER does something real with these -- the
    measurement above shows correlation of a kind -- but not what the feature request said,
    and not something the guide documents, so there is nothing here to translate INTO.
  - a block whose tag repeats across its own options, which the guide does not describe.
  - blocks whose tag SETS overlap without being equal -- one tagged A and B beside one
    tagged A and C. They share a tag, and whether SER pairs them through it is undocumented
    and unmeasured; calling them independent would be answering that question silently.

  NAMESPACE. The generated names carry a prefix chosen so that it does not occur anywhere
  in the source template, case-insensitively, nor among the keys already in MacroVars. A
  fixed `__gsa_` would collide with a template that mentions `%__gsa_m1%` or defines
  `#def %__gsa_g1_1%` -- those are ordinary legal names, and the engine folds variable case,
  so the check has to as well.

  RENDER THE RESULT WITH PostProcess=False.

  The cosmetic post-process is this FAMILY'S typography, and a converted template is meant
  to be rendered and handed straight back to SER, whose typography is its own. With the
  stage on, the engine capitalises sentence starts and respaces punctuation in the author's
  GSA text -- and reaches inside a rescued macro, because the family's pipeline runs the
  cosmetic stage BEFORE the sentinel restore:

      a #file_links[names.dat,2,S] b   ->   A #file_links[names.dat,2, S] b

  `neutralize` protects structural characters from the PARSER, never text from typography.
  The brackets survive as sentinels; the comma is an ordinary character and step 7 puts a
  space after it when a letter follows. This is not a defect and not local: @spintax/core
  returns the same bytes, measured 2026-08-06. It is pinned in tests/gsa_tests.dpr so that
  a change in the family shows up here rather than in what SER receives.

  ONE ARTIFACT WORTH KNOWING. A `#def` owns its line, and the family's rule is that the
  directive's TEXT is removed while its line break stays. So every definition this emits
  leaves a blank line behind. They are appended at the END of the template for that reason
  -- trailing blank lines displace nothing, where the same lines at the top would shift the
  whole document down. Directive position carries no meaning: the renderer collects every
  directive before it renders anything. `PostProcess=True` trims them away entirely.
*)

unit Spintax.Gsa;

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, Spintax;

{ Rewrites a GSA SER template into this engine's syntax. No rendering and no RNG: the
  result is a template, and every choice it describes is still the engine's to make.

  MacroVars must not be nil. It receives one entry per lifted construct -- bracketed
  macros and unconvertible blocks alike -- and the caller MUST merge it into
  TSpContext.Vars before rendering. Ignore it and those constructs render as a visible
  `%…%` placeholder rather than as something plausible and wrong.

  Unsupported must not be nil. It receives `name=original text` for every block this unit
  refused to convert, so a host can resolve them itself by overriding those variables.
  Empty means everything in the template was translated.

  Both are the caller's to own and free; existing entries are left alone. }
function SpGsaToSpintax(const Src: string; MacroVars: TStrMap;
  Unsupported: TStrings): string;

implementation

{ ─── small parsing helpers ───────────────────────────────────────────────────
  Deliberately re-implemented here rather than exported from the engine: this unit is an
  optional dialect front end and must not widen the engine's public surface to exist. }

function IsBlank(c: Char): Boolean;
begin
  Result := (c = ' ') or (c = #9);
end;

function IsAsciiLetter(c: Char): Boolean;
begin
  Result := ((c >= 'a') and (c <= 'z')) or ((c >= 'A') and (c <= 'Z'));
end;

{ A GSA macro name: letter first, then letters, digits or underscore. `#file_links`,
  `#grabbedAll` and `%related_url_link%` are all documented, so none of the three may be
  cut short by a narrower rule. }
function IsNameTail(c: Char): Boolean;
begin
  Result := IsAsciiLetter(c) or ((c >= '0') and (c <= '9')) or (c = '_');
end;

{ Index of the `cl` closing the `op` at openPos, counting that pair only; 0 if unbalanced. }
function FindClose(const s: string; openPos: Integer; op, cl: Char): Integer;
var i, depth: Integer;
begin
  Result := 0;
  depth := 0;
  for i := openPos to Length(s) do
  begin
    if s[i] = op then Inc(depth)
    else if s[i] = cl then
    begin
      Dec(depth);
      if depth = 0 then Exit(i);
    end;
  end;
end;

{ Split on `|` at nesting depth zero, counting both brace and bracket pairs -- the same
  shape the engine splits an enumeration with. }
procedure SplitTop(const inner: string; parts: TStringList);
var i, start, brace, bracket: Integer; ch: Char;
begin
  brace := 0; bracket := 0; start := 1;
  for i := 1 to Length(inner) do
  begin
    ch := inner[i];
    if ch = '{' then Inc(brace)
    else if ch = '}' then Dec(brace)
    else if ch = '[' then Inc(bracket)
    else if ch = ']' then Dec(bracket);
    if (ch = '|') and (brace = 0) and (bracket = 0) then
    begin
      parts.Add(Copy(inner, start, i - start));
      start := i + 1;
    end;
  end;
  parts.Add(Copy(inner, start, Length(inner) - start + 1));
end;

{ A tagged option is `#<tag> <text>`. The tag runs to the first blank; the text is what
  follows it. A `#` with nothing after it, or with no blank and so no text, is not a tag.

  A tag may not contain a line break. Blank here is space and tab only, so without this an
  option written across two lines -- `#T1` then the text on the next line -- swallowed the
  newline INTO the tag name. That name is then a group key, and group keys round-trip
  through TStringList.Text, which re-splits on the newline: the key order stopped matching
  the keys, every branch resolved to nothing, and the block rendered as the empty string
  with no entry in Unsupported. A whole option of the author's text, deleted silently, by
  the one unit whose stated rule is that this must not happen.

  Refusing rather than accepting the newline as a separator is deliberate: whether SER reads
  a tag that way is not documented, and the block is lifted out and reported instead. }
function TagOf(const opt: string; out tag, text: string): Boolean;
var i, n, tagStart: Integer;
begin
  Result := False; tag := ''; text := '';
  i := 1; n := Length(opt);
  while (i <= n) and IsBlank(opt[i]) do Inc(i);
  if (i > n) or (opt[i] <> '#') then Exit;
  Inc(i);
  tagStart := i;
  while (i <= n) and (not IsBlank(opt[i])) do
  begin
    if (opt[i] = #13) or (opt[i] = #10) then Exit;
    Inc(i);
  end;
  if i = tagStart then Exit;          { bare `#` }
  if i > n then Exit;                 { a tag with no text after it }
  tag := Copy(opt, tagStart, i - tagStart);
  while (i <= n) and IsBlank(opt[i]) do Inc(i);
  text := Copy(opt, i, n - i + 1);
  Result := True;
end;

{ ─── the namespace ─────────────────────────────────────────────────────────── }

{ A prefix that occurs nowhere in the template and among no key already in MacroVars,
  compared case-insensitively because the engine folds variable case. Every generated name
  begins with it, so prefix-freedom is collision-freedom for all of them at once. }
function ChoosePrefix(const Src: string; MacroVars: TStrMap): string;
var lowSrc, cand: string; n: Integer; taken: Boolean; key: string;
begin
  lowSrc := LowerCase(Src);
  n := 0;
  repeat
    Inc(n);
    if n = 1 then cand := '__gsa_' else cand := '__gsa' + IntToStr(n) + '_';
    taken := Pos(cand, lowSrc) > 0;
    if not taken then
      for key in MacroVars.Keys do
        if Pos(cand, LowerCase(key)) = 1 then begin taken := True; Break; end;
  until not taken;
  Result := cand;
end;

{ ─── lifting text out of the template ────────────────────────────────────────
  Everything this unit removes from the template goes through here: it returns a `%name%`
  reference and keeps the real text, neutralized, in the caller's variable map, where the
  engine's safety restore will put it back verbatim. Identical text shares one name, so a
  template full of square brackets costs one variable rather than hundreds. }
type
  TLifter = class
  private
    FPrefix: string;
    FVars: TStrMap;
    FKeys: TStringList;    { kind + text }
    FNames: TStringList;   { the variable name, parallel to FKeys }
    FCounts: TStringList;  { per-kind counter, as kind=number }
  public
    constructor Create(const APrefix: string; AVars: TStrMap);
    destructor Destroy; override;
    function Ref(const Kind, Text: string): string;
    property Prefix: string read FPrefix;
    property Vars: TStrMap read FVars;
  end;

constructor TLifter.Create(const APrefix: string; AVars: TStrMap);
begin
  inherited Create;
  FPrefix := APrefix;
  FVars := AVars;
  FKeys := TStringList.Create;
  { TStringList.IndexOf folds case by default, and the keys here are the author's own
    text. Without this, `#file[A.txt,1,S]` and `#file[a.txt,1,S]` share one variable and
    the second renders as the first -- silent corruption of a file name. This is the same
    defect the family fixed in v0.2.2, where IndexOf folded an include target; it is worth
    treating every TStringList lookup over user text as case-folded until told otherwise. }
  FKeys.CaseSensitive := True;
  FNames := TStringList.Create;
  FCounts := TStringList.Create;
end;

destructor TLifter.Destroy;
begin
  FKeys.Free; FNames.Free; FCounts.Free;
  inherited Destroy;
end;

function TLifter.Ref(const Kind, Text: string): string;
var key, nm: string; i, n: Integer;
begin
  key := Kind + #1 + Text;
  i := FKeys.IndexOf(key);
  if i >= 0 then Exit('%' + FNames[i] + '%');
  n := StrToIntDef(FCounts.Values[Kind], 0) + 1;
  FCounts.Values[Kind] := IntToStr(n);
  nm := FPrefix + Kind + IntToStr(n);
  FVars.AddOrSetValue(nm, SpNeutralize(Text));
  FKeys.Add(key);
  FNames.Add(nm);
  Result := '%' + nm + '%';
end;

{ ─── 1. lift the bracketed macros out ──────────────────────────────────────── }

{ `#name[...]` and `%name[...]%` -> a `%<prefix>mN%` reference, with the macro's own text
  neutralized into MacroVars. }
function ExtractMacros(const Src: string; lift: TLifter): string;
var i, n, j, close_: Integer; res: string;

  { The macro starting at i, or 0 if there is none: its last index. }
  function MacroEndAt(start: Integer): Integer;
  var k, brk: Integer;
  begin
    Result := 0;
    k := start + 1;
    if (k > n) or (not IsAsciiLetter(Src[k])) then Exit;
    while (k <= n) and IsNameTail(Src[k]) do Inc(k);
    if (k > n) or (Src[k] <> '[') then Exit;
    brk := FindClose(Src, k, '[', ']');
    if brk = 0 then Exit;
    if Src[start] = '#' then Exit(brk);
    { the %…% form has to close its percent too }
    if (brk < n) and (Src[brk + 1] = '%') then Exit(brk + 1);
  end;

begin
  res := '';
  i := 1; n := Length(Src);
  while i <= n do
  begin
    if (Src[i] = '#') or (Src[i] = '%') then
    begin
      j := i;
      close_ := MacroEndAt(j);
      if close_ > 0 then
      begin
        res := res + lift.Ref('m', Copy(Src, i, close_ - i + 1));
        i := close_ + 1;
        Continue;
      end;
    end;
    res := res + Src[i];
    Inc(i);
  end;
  Result := res;
end;

{ ─── 1a. lift GSA text that this engine would read as its own syntax ─────────
  The rule at the top of this unit is not only about GSA CONSTRUCTS. GSA has no permutation
  and no comment syntax, so `[` and `/#` in a SER template are ordinary characters -- but
  this engine reads them, and the damage is silent:

    Read [b]this[/b] now.          -> Read bthis/b now.      (brackets eaten)
    Price [10|20] USD.             -> Price 10 20 USD.       (SHUFFLED)
    See http://example.com/#top    -> See http://example.com (rest of the DOCUMENT eaten,
                                                              as an unterminated comment)
    #set %x% = 1  on its own line  -> the line disappears    (read as a directive)

  BBCode and fragment URLs are everyday content in a forum or article template, so this is
  not an exotic case. Each of these characters is lifted the same way a macro is; identical
  ones share a variable, so the cost is four entries however many there are. }
function ProtectLiterals(const Src: string; lift: TLifter): string;
var i, n: Integer; res, word_: string;

  { True when a directive this engine acts on starts at s[i] -- the `#` of a `#set`,
    `#def` or `#include` that is first on its line. }
  function DirectiveAt(k: Integer): Boolean;
  var p: Integer;
  begin
    Result := False;
    p := k - 1;
    while (p >= 1) and IsBlank(Src[p]) do Dec(p);
    if (p >= 1) and (Src[p] <> #10) and (Src[p] <> #13) then Exit;   { not first on its line }
    p := k + 1;
    word_ := '';
    while (p <= n) and IsAsciiLetter(Src[p]) and (Length(word_) < 7) do
    begin
      word_ := word_ + LowerCase(Src[p]);
      Inc(p);
    end;
    Result := (word_ = 'set') or (word_ = 'def') or (word_ = 'include');
  end;

begin
  res := '';
  i := 1; n := Length(Src);
  while i <= n do
  begin
    if (Src[i] = '/') and (i < n) and (Src[i + 1] = '#') then
    begin
      res := res + lift.Ref('l', '/#'); Inc(i, 2); Continue;
    end;
    if (Src[i] = '#') and (i < n) and (Src[i + 1] = '/') then
    begin
      res := res + lift.Ref('l', '#/'); Inc(i, 2); Continue;
    end;
    if (Src[i] = '[') or (Src[i] = ']') then
    begin
      res := res + lift.Ref('l', Src[i]); Inc(i); Continue;
    end;
    if (Src[i] = '#') and DirectiveAt(i) then
    begin
      res := res + lift.Ref('l', '#'); Inc(i); Continue;
    end;
    res := res + Src[i];
    Inc(i);
  end;
  Result := res;
end;

{ Puts the macros back, for text that is going to be lifted out whole: an unconvertible
  block must be reported and restored as the AUTHOR wrote it, macros included, not with
  this unit's placeholders frozen into it. }
function ExpandMacroRefs(const s: string; lift: TLifter): string;
var i, n, j: Integer; res, nm, val: string;
begin
  res := '';
  i := 1; n := Length(s);
  while i <= n do
  begin
    if s[i] = '%' then
    begin
      j := i + 1;
      while (j <= n) and (s[j] <> '%') do Inc(j);
      if j <= n then
      begin
        nm := Copy(s, i + 1, j - i - 1);
        if (Pos(lift.Prefix, nm) = 1) and lift.Vars.TryGetValue(nm, val) then
        begin
          res := res + SpSafetyRestore(val);
          i := j + 1;
          Continue;
        end;
      end;
    end;
    res := res + s[i];
    Inc(i);
  end;
  Result := res;
end;

{ ─── 2. the tilde form becomes a permutation ───────────────────────────────── }

function ConvertTilde(const Src: string): string;
var i, n, close_: Integer; res: string;
begin
  res := '';
  i := 1; n := Length(Src);
  while i <= n do
  begin
    if (Src[i] = '~') and (i < n) and (Src[i + 1] = '{') then
    begin
      close_ := FindClose(Src, i + 1, '{', '}');
      if close_ > 0 then
      begin
        { recurse: a tilde form may hold another one }
        res := res + '[' + ConvertTilde(Copy(Src, i + 2, close_ - i - 2)) + ']';
        i := close_ + 1;
        Continue;
      end;
    end;
    res := res + Src[i];
    Inc(i);
  end;
  Result := res;
end;

{ ─── 3. spintags ───────────────────────────────────────────────────────────── }

type
  { How a braced block reads. bkPlain is not a tag block at all. }
  TBlockKind = (bkPlain, bkPerOption, bkUnsupported);

  { The groups of blocks that move together. A group is a list of KEYS in the order its
    first block fixed: tag names for the per-option form, option indices for the block
    form. The two forms are registered under distinct identities so they cannot merge. }
  TTagGroups = class
  private
    FIds: TStringList;       { group identity }
    FOrders: TStringList;    { canonical key order, LF-joined, parallel to FIds }
    FUses: TStringList;      { how many blocks each group has, as text }
    FBad: TStringList;       { '1' when the group's tags overlap another group's }
  public
    constructor Create;
    destructor Destroy; override;
    function GroupOf(const id: string; keys: TStringList): Integer;
    procedure OrderOf(index: Integer; into: TStringList);
    function BlockCount(index: Integer): Integer;
    procedure CountBlock(index: Integer);
    procedure MarkConflicts;
    function Conflicted(index: Integer): Boolean;
    function Count: Integer;
  end;

constructor TTagGroups.Create;
begin
  inherited Create;
  FIds := TStringList.Create;
  FIds.CaseSensitive := True;
  FOrders := TStringList.Create;
  FUses := TStringList.Create;
  FBad := TStringList.Create;
end;

destructor TTagGroups.Destroy;
begin
  FIds.Free; FOrders.Free; FUses.Free; FBad.Free;
  inherited Destroy;
end;

function TTagGroups.Count: Integer;
begin
  Result := FIds.Count;
end;

function TTagGroups.GroupOf(const id: string; keys: TStringList): Integer;
var i: Integer;
begin
  for i := 0 to FIds.Count - 1 do
    if FIds[i] = id then Exit(i);
  FIds.Add(id);
  FOrders.Add(keys.Text);
  FUses.Add('0');
  FBad.Add('0');
  Result := FIds.Count - 1;
end;

procedure TTagGroups.OrderOf(index: Integer; into: TStringList);
begin
  into.Text := FOrders[index];
end;

function TTagGroups.BlockCount(index: Integer): Integer;
begin
  Result := StrToInt(FUses[index]);
end;

procedure TTagGroups.CountBlock(index: Integer);
begin
  FUses[index] := IntToStr(StrToInt(FUses[index]) + 1);
end;

{ Two groups whose tag sets OVERLAP without being equal are a case the guide does not
  describe: a block tagged A and B beside one tagged A and C share a tag, and whether SER
  pairs them through it is not documented and was not measured. Treating them as
  independent is a silent answer to that question, which this unit's rule forbids, so both
  groups are marked and every block in them is lifted out and reported instead. }
procedure TTagGroups.MarkConflicts;
var i, j, k, shared: Integer; a, b: TStringList;
begin
  a := TStringList.Create;
  b := TStringList.Create;
  try
    a.CaseSensitive := True;
    b.CaseSensitive := True;
    for i := 0 to FIds.Count - 1 do
      for j := i + 1 to FIds.Count - 1 do
      begin
        a.Text := FOrders[i];
        b.Text := FOrders[j];
        shared := 0;
        for k := 0 to a.Count - 1 do
          if b.IndexOf(a[k]) >= 0 then Inc(shared);
        if (shared > 0) and ((shared <> a.Count) or (shared <> b.Count)) then
        begin
          FBad[i] := '1';
          FBad[j] := '1';
        end;
      end;
  finally
    a.Free; b.Free;
  end;
end;

function TTagGroups.Conflicted(index: Integer): Boolean;
begin
  Result := FBad[index] = '1';
end;

{ Reads a block's tag layout. `keys` and `texts` come back parallel and in written order,
  keyed by tag name.

  ONLY the guide's form is converted: every option tagged, no tag repeated, no domain tag.
  A block where some options carry a tag and others do not is REFUSED, and that is a
  measurement, not caution. The feature request described such a block as tagging the whole
  block and correlating the chosen option's INDEX across blocks. Run in SER's own Article
  Manager, eight copies of a one-tag three-option block produced  2 1 1 1 1 1 1 1  --
  index correlation predicts eight identical digits with probability 1, so it is not what
  SER does. Seven of the eight returned `1`, the option the tag is actually ON, which
  points at the guide's per-option rule with one option tagged and the rest not; what makes
  the first block differ is not known. Until it is, the block is handed back to the host
  rather than translated into a rule we made up. }
function ReadBlock(const inner: string; keys, texts: TStringList): TBlockKind;
var parts: TStringList; i, j, tagged, shaped: Integer; tag, text: string;
begin
  Result := bkPlain;
  keys.Clear; texts.Clear;
  parts := TStringList.Create;
  try
    SplitTop(inner, parts);
    if parts.Count < 2 then Exit;

    { An option that OPENS with `#` is claiming to be tagged. If TagOf then cannot read a
      tag out of it -- a bare `#`, a tag with no text, a tag carrying a line break -- the
      block is tag-shaped and unreadable, which is a refusal. Letting it fall through to
      "ordinary spin" would hand the engine a block we admit we do not understand. }
    tagged := 0; shaped := 0;
    for i := 0 to parts.Count - 1 do
    begin
      j := 1;
      while (j <= Length(parts[i])) and IsBlank(parts[i][j]) do Inc(j);
      if (j <= Length(parts[i])) and (parts[i][j] = '#') then Inc(shaped);
      if TagOf(parts[i], tag, text) then Inc(tagged);
    end;
    if (tagged = 0) and (shaped = 0) then Exit;    { an ordinary spin }
    if tagged <> parts.Count then Exit(bkUnsupported);

    for i := 0 to parts.Count - 1 do
    begin
      TagOf(parts[i], tag, text);
      { a domain tag selects on the target URL, not at random }
      if tag[1] = '.' then Exit(bkUnsupported);
      if keys.IndexOf(tag) >= 0 then Exit(bkUnsupported);   { repeated tag }
      keys.Add(tag);
      texts.Add(text);
    end;
    Result := bkPerOption;
  finally
    parts.Free;
  end;
end;

function VarName(const prefix: string; group, level: Integer): string;
begin
  Result := prefix + 'g' + IntToStr(group + 1) + '_' + IntToStr(level);
end;

{ The chain for one block: tests the group's keys in canonical order, so every block of
  the group branches the same way on the same definitions. A group of one block needs no
  correlation, so it is written as the plain enumeration it is. }
function ChainFor(const prefix: string; group: Integer; single: Boolean;
  order, keys, texts: TStringList): string;
var i, idx, n: Integer; res: string;

  function TextFor(k: Integer): string;
  var j: Integer;
  begin
    j := keys.IndexOf(order[k]);
    if j >= 0 then Result := texts[j] else Result := '';
  end;

begin
  n := order.Count;
  if single then
  begin
    res := TextFor(0);
    for i := 1 to n - 1 do res := res + '|' + TextFor(i);
    Exit('{' + res + '}');
  end;
  res := TextFor(n - 1);
  for i := n - 2 downto 0 do
  begin
    idx := i + 1;
    res := '{?' + VarName(prefix, group, idx) + '?' + TextFor(i) + '|' + res + '}';
  end;
  Result := res;
end;

{ The definitions a group needs: n-1 of them, the i-th non-empty with probability
  1/(n-i+1), which makes the chain uniform over the n branches. }
function DefsFor(const prefix: string; group, branches: Integer): string;
var i, k: Integer; res, opts: string;
begin
  res := '';
  for i := 1 to branches - 1 do
  begin
    opts := 'x';
    for k := 1 to branches - i do opts := opts + '|';
    res := res + '#def %' + VarName(prefix, group, i) + '% = {' + opts + '}' + sLineBreak;
  end;
  Result := res;
end;

type
  TWalkCtx = record
    Lift: TLifter;
    Groups: TTagGroups;
    Unsupported: TStrings;
  end;

{ Walks the text and rewrites every tag block, at any nesting depth. `collectOnly` runs the
  identical walk without building a result, so that every group is registered -- and its
  key order and block count fixed -- before the first definition is emitted. }
function WalkTags(const Src: string; var ctx: TWalkCtx; collectOnly: Boolean): string;
var
  i, n, close_, k, g: Integer;
  res, inner, id, nm, original: string;
  keys, texts, order: TStringList;
  kind: TBlockKind;
begin
  res := '';
  i := 1; n := Length(Src);
  while i <= n do
  begin
    if Src[i] = '{' then
    begin
      close_ := FindClose(Src, i, '{', '}');
      if close_ > 0 then
      begin
        inner := Copy(Src, i + 1, close_ - i - 1);
        keys := TStringList.Create;
        texts := TStringList.Create;
        order := TStringList.Create;
        try
          kind := ReadBlock(inner, keys, texts);

          if kind = bkPerOption then
          begin
            { blocks carrying the same SET of tags move together }
            order.Assign(keys); order.Sort;
            id := order.Text;
            g := ctx.Groups.GroupOf(id, keys);
            { a set that partly overlaps another group's is undocumented -- refuse it }
            if (not collectOnly) and ctx.Groups.Conflicted(g) then kind := bkUnsupported;
          end;

          if kind = bkPerOption then
          begin

            if collectOnly then
            begin
              ctx.Groups.CountBlock(g);
              for k := 0 to texts.Count - 1 do
                WalkTags(texts[k], ctx, True);
            end
            else
            begin
              for k := 0 to texts.Count - 1 do
                texts[k] := WalkTags(texts[k], ctx, False);
              ctx.Groups.OrderOf(g, order);
              res := res + ChainFor(ctx.Lift.Prefix, g, ctx.Groups.BlockCount(g) = 1,
                                    order, keys, texts);
            end;
          end
          else if kind = bkUnsupported then
          begin
            { lift it out whole: reported, and rendered exactly as the author wrote it }
            if not collectOnly then
            begin
              original := ExpandMacroRefs(Copy(Src, i, close_ - i + 1), ctx.Lift);
              nm := ctx.Lift.Ref('u', original);
              ctx.Unsupported.Add(Copy(nm, 2, Length(nm) - 2) + '=' + original);
              res := res + nm;
            end;
          end
          else
          begin
            { An ordinary spin: keep the braces, convert what is inside. But a block whose
              text opens with `?` or `plural ` is a CONDITIONAL or a PLURAL to this engine
              and an ordinary spin to GSA. Measured: a plural block renders its second
              option every time, and a well-formed conditional block renders its else
              branch every time, where GSA spins both. A MALFORMED conditional -- a block
              opening with a question mark but carrying no second one -- is not affected,
              because the engine already falls through to an enumeration there; the escape
              covers both rather than trying to tell them apart. Lifting the first
              character defeats the prefix test while leaving the block a spin and the
              character in the output. }
            if collectOnly then
              WalkTags(inner, ctx, True)
            else if (inner <> '') and ((inner[1] = '?') or (Copy(inner, 1, 7) = 'plural ')) then
              res := res + '{' + ctx.Lift.Ref('l', inner[1])
                         + WalkTags(Copy(inner, 2, MaxInt), ctx, False) + '}'
            else
              res := res + '{' + WalkTags(inner, ctx, False) + '}';
          end;
        finally
          keys.Free; texts.Free; order.Free;
        end;
        i := close_ + 1;
        Continue;
      end;
    end;
    if not collectOnly then res := res + Src[i];
    Inc(i);
  end;
  Result := res;
end;

function ConvertTags(const Src: string; lift: TLifter; Unsupported: TStrings): string;
var ctx: TWalkCtx; body, defs: string; g: Integer; order: TStringList;
begin
  ctx.Lift := lift;
  ctx.Groups := TTagGroups.Create;
  ctx.Unsupported := Unsupported;
  try
    { Three steps: the first walk fixes every group, its key order and how many blocks it
      has; MarkConflicts then rules on the overlapping sets; only then can the second walk
      know which blocks it may convert. }
    WalkTags(Src, ctx, True);
    ctx.Groups.MarkConflicts;
    body := WalkTags(Src, ctx, False);

    defs := '';
    order := TStringList.Create;
    try
      for g := 0 to ctx.Groups.Count - 1 do
        if (ctx.Groups.BlockCount(g) > 1) and (not ctx.Groups.Conflicted(g)) then
        begin
          ctx.Groups.OrderOf(g, order);
          defs := defs + DefsFor(lift.Prefix, g, order.Count);
        end;
    finally
      order.Free;
    end;
    if defs = '' then Exit(body);
    { appended, not prepended -- see the note on the blank line a directive leaves behind }
    Result := body + sLineBreak + defs;
  finally
    ctx.Groups.Free;
  end;
end;

{ ─── entry point ─────────────────────────────────────────────────────────────
  Order is load-bearing. Macros are lifted out FIRST, so the brackets of `#openai[a|b]`
  cannot be read as a permutation, as a tag, or as a directive by the passes after it --
  and a block that later turns out to be unconvertible puts them back before it is
  reported, so the host is handed the author's text and not this unit's placeholders.
  Tags run before the tilde form so that a tagged block inside a tilde form is seen while
  its braces are still braces. }
function SpGsaToSpintax(const Src: string; MacroVars: TStrMap;
  Unsupported: TStrings): string;
var lift: TLifter; text: string;
begin
  lift := TLifter.Create(ChoosePrefix(Src, MacroVars), MacroVars);
  try
    text := ExtractMacros(Src, lift);
    text := ProtectLiterals(text, lift);
    Result := ConvertTilde(ConvertTags(text, lift, Unsupported));
  finally
    lift.Free;
  end;
end;

end.
