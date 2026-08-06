{ Assertions for the optional GSA dialect front end (src/Spintax.Gsa.pas).

  Separate from local_tests.dpr on purpose: that suite gates the ENGINE against surfaces no
  corpus fixture can express, and the dialect is not part of the engine's contract.

  THE LESSON THIS SUITE IS SHAPED BY. Its first version asserted almost entirely on what
  the converter WRITES. Three defects hid in the gap between that and what the engine then
  RENDERS: a macro whose brackets were eaten, and two block forms that were "left exactly
  as written" in the template and came out of SpRender as a random branch with the tag
  still attached. Text-of-conversion checks are the exception here now; the rule is
  convert-then-render, because that is the only thing a host actually sees.

  Every expectation traces to the macro guide:
  https://docu.gsa-online.de/search_engine_ranker/macro_guide }
program gsa_tests;

{$mode delphi}{$H+}

uses
  SysUtils, Classes, Spintax, Spintax.Gsa;

var
  Checks: Integer = 0;
  Failed: Integer = 0;

procedure Check(const What, Got, Want: string);
begin
  Inc(Checks);
  if Got <> Want then
  begin
    Inc(Failed);
    WriteLn('FAIL ', What);
    WriteLn('  got  [', Got, ']');
    WriteLn('  want [', Want, ']');
  end;
end;

procedure CheckTrue(const What: string; Cond: Boolean);
begin
  Inc(Checks);
  if not Cond then
  begin
    Inc(Failed);
    WriteLn('FAIL ', What);
  end;
end;

{ Convert only, for the few checks that are genuinely about the emitted text. }
function Conv(const Src: string): string;
var vars: TStrMap; unsup: TStringList;
begin
  vars := TStrMap.Create;
  unsup := TStringList.Create;
  try
    Result := SpGsaToSpintax(Src, vars, unsup);
  finally
    vars.Free; unsup.Free;
  end;
end;

{ Convert and render, the way a host must: the lifted variables go into the context. }
function ConvRender(const Src: string; PostProc: Boolean): string;
var vars: TStrMap; unsup: TStringList; ctx: TSpContext;
begin
  vars := TStrMap.Create;
  unsup := TStringList.Create;
  try
    ctx := Default(TSpContext);
    ctx.PostProcess := PostProc;
    ctx.Vars := vars;
    Result := SpRender(SpGsaToSpintax(Src, vars, unsup), ctx);
  finally
    vars.Free; unsup.Free;
  end;
end;

{ The text of every block the converter refused, joined for comparison. }
function Refused(const Src: string): string;
var vars: TStrMap; unsup: TStringList; i: Integer;
begin
  vars := TStrMap.Create;
  unsup := TStringList.Create;
  try
    SpGsaToSpintax(Src, vars, unsup);
    Result := '';
    for i := 0 to unsup.Count - 1 do
      Result := Result + unsup.ValueFromIndex[i] + ';';
  finally
    vars.Free; unsup.Free;
  end;
end;

{ Renders many times and collects the DISTINCT outputs, sorted. The only honest assertion
  about a random construct is on the SET of reachable outputs, never on one sample.

  Outputs are trimmed: the converter appends its `#def` lines, and a directive leaves its
  line break behind by the family's rule. That artifact is pinned once, in TestArtifacts. }
procedure Outcomes(const Src: string; Iters: Integer; PostProc: Boolean; into: TStringList);
var vars: TStrMap; unsup: TStringList; ctx: TSpContext; i: Integer; tmpl: string;
begin
  into.Clear;
  into.Sorted := True;
  into.Duplicates := dupIgnore;
  vars := TStrMap.Create;
  unsup := TStringList.Create;
  try
    tmpl := SpGsaToSpintax(Src, vars, unsup);
    ctx := Default(TSpContext);
    ctx.PostProcess := PostProc;
    ctx.Vars := vars;
    for i := 1 to Iters do
      into.Add(Trim(SpRender(tmpl, ctx)));
  finally
    vars.Free; unsup.Free;
  end;
end;

{ Convert, render many times, and assert the output is the input every time -- for
  everything that must come through the engine untouched. }
procedure CheckVerbatim(const What, Src: string);
var outs: TStringList;
begin
  outs := TStringList.Create;
  try
    Outcomes(Src, 300, False, outs);
    Inc(Checks);
    if (outs.Count <> 1) or (outs[0] <> Src) then
    begin
      Inc(Failed);
      WriteLn('FAIL ', What);
      WriteLn('  src  [', Src, ']');
      WriteLn('  outs [', StringReplace(Trim(outs.Text), sLineBreak, ' ~OR~ ',
                                        [rfReplaceAll]), ']');
    end;
  finally
    outs.Free;
  end;
end;

{ Convert, render many times, and assert the set of outputs is exactly the two given --
  for a block that must still be a spin after the conversion. }
procedure CheckSpins(const What, Src, A, B: string);
var outs: TStringList;
begin
  outs := TStringList.Create;
  try
    Outcomes(Src, 600, False, outs);
    Inc(Checks);
    if (outs.Count <> 2) or (outs.IndexOf(A) < 0) or (outs.IndexOf(B) < 0) then
    begin
      Inc(Failed);
      WriteLn('FAIL ', What);
      WriteLn('  src  [', Src, ']');
      WriteLn('  outs [', StringReplace(Trim(outs.Text), sLineBreak, ' ~OR~ ',
                                        [rfReplaceAll]), ']');
    end;
  finally
    outs.Free;
  end;
end;

{ Stronger than CheckVerbatim: asserts the converter did not touch the text AT ALL --
  same string out, nothing lifted into the variable map, nothing reported. CheckVerbatim
  alone cannot tell "left alone" from "lifted", because a lifted construct is designed to
  render verbatim; only the counts distinguish them. }
procedure CheckUntouched(const What, Src: string);
var vars: TStrMap; unsup: TStringList; got: string;
begin
  vars := TStrMap.Create;
  unsup := TStringList.Create;
  try
    got := SpGsaToSpintax(Src, vars, unsup);
    Inc(Checks);
    if (got <> Src) or (vars.Count <> 0) or (unsup.Count <> 0) then
    begin
      Inc(Failed);
      WriteLn('FAIL ', What);
      WriteLn('  got  [', got, ']  lifted=', vars.Count, ' refused=', unsup.Count);
    end;
  finally
    vars.Free; unsup.Free;
  end;
end;

{ ─── 1. bracketed macros survive the render ──────────────────────────────── }

procedure TestMacros;
var ctx: TSpContext; vars: TStrMap; unsup: TStringList; tmpl: string;
begin
  ctx := Default(TSpContext);
  ctx.PostProcess := False;

  { the defect this exists for: unconverted, the engine eats the brackets }
  Check('unconverted #file[] loses its brackets',
        SpRender('Comment: #file[C:\d\c.txt,1,S] end', ctx),
        'Comment: #fileC:\d\c.txt,1,S end');

  { every bracketed macro the guide documents, end to end }
  CheckVerbatim('macro/file',             'x #file[c.txt,1,S] y');
  CheckVerbatim('macro/file_links',       'x #file_links[names.dat,2,S] y');
  CheckVerbatim('macro/file_links-range', 'x #file_links[names.dat,[2..10],S] y');
  CheckVerbatim('macro/grabbedAll',       'x #grabbedAll[1,5] y');
  CheckVerbatim('macro/gennick',          'x #gennick[XYZ,3,9] y');
  CheckVerbatim('macro/random',           'x #random[0..9,A..Z] y');
  CheckVerbatim('macro/err',              'x #err[404] y');

  { the two shapes the engine would not merely truncate but SHUFFLE, because a `|` inside
    the brackets reads to it as a list of options }
  CheckVerbatim('macro/openai-with-pipe', 'x #openai[gpt,write a|b|c,50] y');
  CheckVerbatim('macro/percent-form-with-pipe',
                'x %related_url_link[ignore=domain1.com|url2.com]% y');

  { one entry per macro, value already neutralized, keyed under the chosen prefix }
  vars := TStrMap.Create;
  unsup := TStringList.Create;
  try
    tmpl := SpGsaToSpintax('#file[a,1,S] and #file_links[b,2,L]', vars, unsup);
    Check('two macros become two references', tmpl, '%__gsa_m1% and %__gsa_m2%');
    CheckTrue('both macros are reported', vars.Count = 2);
    CheckTrue('the stored value is neutralized, not raw', Pos('[', vars['__gsa_m1']) = 0);
    Check('the stored value restores to the original',
          SpSafetyRestore(vars['__gsa_m2']), '#file_links[b,2,L]');
    CheckTrue('a macro is not an unsupported block', unsup.Count = 0);
  finally
    vars.Free; unsup.Free;
  end;

  { a host that ignores the map gets a visible placeholder, not a mangled macro }
  Check('an ignored macro map fails visibly',
        SpRender(Conv('x #file[a,1,S] y'), ctx), 'x %__gsa_m1% y');

  { the macros that already pass through must be left exactly alone }
  CheckVerbatim('macro/spinfile',       '%spinfile-C:\n.txt%');
  CheckVerbatim('macro/file-equals',    '#file=C:\n.txt');
  CheckVerbatim('macro/spin-nospin',    'a #spin b #nospin c');
  CheckVerbatim('macro/columnspinfile', '%columnspinfile-C:\a.txt-2%');
  CheckVerbatim('macro/random-dashes',  '%random-1-9%');
  CheckVerbatim('macro/trans-block',    '#trans_en_de hello #notrans');

  { an unbalanced bracket is not a macro; it survives anyway, because the literals pass
    protects a bare bracket whether or not a macro claimed it }
  CheckVerbatim('macro/unbalanced', '#file[oops');
end;

{ ─── 2. the tilde form is our permutation ────────────────────────────────── }

procedure TestTilde;
var outs: TStringList; i, n: Integer;
begin
  Check('tilde becomes a permutation', Conv('~{One.|Two.|Three.}'), '[One.|Two.|Three.]');
  Check('a plain block is not touched', Conv('{One.|Two.}'), '{One.|Two.}');
  Check('nested tilde converts too', Conv('~{a|~{b|c}}'), '[a|[b|c]]');
  CheckVerbatim('tilde/lone-tilde-is-text', 'cost ~ 5 dollars');

  outs := TStringList.Create;
  try
    { the guide: "all variations are used but in a random order" -- so every output is a
      permutation of all three, and all six orders are reachable }
    Outcomes('~{One.|Two.|Three.}', 4000, False, outs);
    CheckTrue('tilde reaches all six orderings of three options', outs.Count = 6);
    n := 0;
    for i := 0 to outs.Count - 1 do
      if (Pos('One.', outs[i]) > 0) and (Pos('Two.', outs[i]) > 0)
         and (Pos('Three.', outs[i]) > 0) then Inc(n);
    CheckTrue('every tilde output uses every option', n = outs.Count);
    { the guide's example joins them with a single space }
    CheckTrue('tilde joins with one space', outs.IndexOf('One. Three. Two.') >= 0);
  finally
    outs.Free;
  end;
end;

{ ─── 3. spintags, the guide's per-option form ────────────────────────────── }

procedure TestPerOptionTags;
var outs: TStringList; made: string;
begin
  made := Conv('{#TAG1 I love {the|your} site|#TAG2 Hello there}. ' +
               '{#TAG1 Best forum ever.|#TAG2 How are you?}');
  CheckTrue('a definition is emitted for the group', Pos('#def %__gsa_g1_1%', made) > 0);
  CheckTrue('no tag survives into the template', Pos('#TAG', made) = 0);

  outs := TStringList.Create;
  try
    Outcomes('{#TAG1 I love {the|your} site|#TAG2 Hello there}. ' +
             '{#TAG1 Best forum ever.|#TAG2 How are you?}', 3000, False, outs);
    { exactly the pairings the guide promises and NOTHING else -- the whole point is that
      "Hello there. Best forum ever." can never appear }
    Check('only the guide''s two pairings are reachable', outs.Text,
          'Hello there. How are you?' + sLineBreak +
          'I love the site. Best forum ever.' + sLineBreak +
          'I love your site. Best forum ever.' + sLineBreak);

    Outcomes('{#A 1a|#B 1b|#C 1c}-{#A 2a|#B 2b|#C 2c}-{#A 3a|#B 3b|#C 3c}',
             4000, False, outs);
    Check('three tags stay aligned across three blocks', outs.Text,
          '1a-2a-3a' + sLineBreak + '1b-2b-3b' + sLineBreak + '1c-2c-3c' + sLineBreak);

    Outcomes('{#A 1a|#B 1b}-{#B 2b|#A 2a}', 2000, False, outs);
    Check('a later block may list its tags in another order', outs.Text,
          '1a-2a' + sLineBreak + '1b-2b' + sLineBreak);

    Outcomes('{#A 1a|#B 1b}{#C 2c|#D 2d}', 4000, False, outs);
    Check('different tag sets are independent groups', outs.Text,
          '1a2c' + sLineBreak + '1a2d' + sLineBreak +
          '1b2c' + sLineBreak + '1b2d' + sLineBreak);

    Outcomes('{#A a|#B b|#C c|#D d}', 6000, False, outs);
    Check('four tags are all reachable', outs.Text,
          'a' + sLineBreak + 'b' + sLineBreak + 'c' + sLineBreak + 'd' + sLineBreak);

    { one block with tags is no correlation at all: it spins, tags removed }
    Outcomes('{#A a|#B b}', 2000, False, outs);
    Check('a single tagged block just spins', outs.Text,
          'a' + sLineBreak + 'b' + sLineBreak);
    CheckTrue('and needs no definition', Pos('#def', Conv('{#A a|#B b}')) = 0);
  finally
    outs.Free;
  end;
end;

{ ─── 4. the block form the request described, measured and refused ───────── }

{ The feature request described a tag on the whole BLOCK, with the chosen option's INDEX
  reused by every later block carrying the same tag. It was implemented that way, and then
  run in SER's own Article Manager: eight copies of a one-tag three-option block returned

      2 1 1 1 1 1 1 1

  where index correlation predicts eight identical digits with probability 1. So SER does
  not do this, and the conversion was removed rather than kept as a plausible guess. Seven
  of the eight gave `1`, the option the tag sits on, which points somewhere -- but not
  anywhere documented, so these blocks are refused and reported. }
procedure TestBlockFormRefused;
var outs: TStringList;
begin
  CheckVerbatim('blockform/two-options', '{#tag1 A|B} then {#tag1 C|D}');
  CheckVerbatim('blockform/three-options', '{#t 1|2|3}-{#t x|y|z}');
  Check('the request''s own example is reported, not translated',
        Refused('{#tag1 variation1|variation2|variation3} something else ' +
                '{#tag1 variation1|variation2|variation3}'),
        '{#tag1 variation1|variation2|variation3};' +
        '{#tag1 variation1|variation2|variation3};');

  { and a single such block is refused too -- there is no "harmless" case of a rule we
    have measured to be wrong }
  CheckVerbatim('blockform/single', '{#tag1 A|B}');

  outs := TStringList.Create;
  try
    { the shape actually run in SER, so the file records what was asked and what came back }
    Outcomes('{#tagA 1|2|3} {#tagA 1|2|3}', 500, False, outs);
    Check('the measured shape comes back verbatim', outs.Text,
          '{#tagA 1|2|3} {#tagA 1|2|3}' + sLineBreak);
  finally
    outs.Free;
  end;
end;

{ ─── 4a. ordinary GSA text that this engine would read as syntax ─────────── }

{ GSA has no permutation and no comment syntax, so a square bracket or a `/#` in a SER
  template is an ordinary character -- to SER. To this engine they are not, and every case
  below was a silent corruption before the literals pass: brackets eaten, bracketed text
  SHUFFLED where it held a pipe, and a fragment URL swallowing the rest of the document as
  an unterminated comment. BBCode and `#top` links are everyday article-template content. }
procedure TestLiteralText;
begin
  CheckVerbatim('literal/bbcode',        'Read [b]this[/b] now.');
  CheckVerbatim('literal/footnote',      'See note [1] and [2].');
  CheckVerbatim('literal/bracket-pipe',  'Price [10|20] USD.');
  CheckVerbatim('literal/fragment-url',  'Go to http://example.com/#top now.');
  CheckVerbatim('literal/comment-close', 'a #/ b');
  CheckVerbatim('literal/hash-bracket',  '#[a,b]');

  { a directive line is this engine's, not GSA's -- the whole line used to vanish }
  CheckVerbatim('literal/set-line',     '#set %x% = 1');
  CheckVerbatim('literal/def-line',     '#def %x% = 1');
  CheckVerbatim('literal/include-line', '#include "other"');
  { but a `#` that opens no directive of ours is left where it is }
  CheckUntouched('literal/non-directive-hash', '#trans hello #notrans');

  { A spin whose first option opens with a character this engine reserves must still spin,
    over the author's own text. Both inputs below genuinely need the escape: unconverted,
    the conditional block renders its else branch every time and the plural block renders
    its second option every time. A block opening with a question mark but carrying no
    second one would NOT belong here -- that is a malformed conditional, which already
    falls through to an enumeration, so it passes with or without the escape and would be
    a test that cannot fail. It was the first thing tried here, and the mutation run is
    what caught that it proved nothing. }
  CheckSpins('literal/conditional-block', '{?a?b|c}', '?a?b', 'c');
  CheckSpins('literal/plural-block', '{plural 2:one|two}', 'plural 2:one', 'two');

  { none of this is a refusal -- the template is fully translated }
  Check('protected literals are not reported as unsupported',
        Refused('[b]x[/b] /# {?a|b}'), '');
end;

{ ─── 5. what it refuses, and what refusing must mean ─────────────────────── }

procedure TestRefusals;
begin
  { THE defect this section exists for. Leaving a block in the template is not leaving it
    alone: the engine reads it as an ordinary spin and prints one branch, tag and all. }
  CheckVerbatim('refuse/domain-tags', '{#.de Hallo Fremder!|#.com Hello Stranger!}');
  Check('domain tags are reported', Refused('{#.de Hallo!|#.com Hello!}'),
        '{#.de Hallo!|#.com Hello!};');

  CheckVerbatim('refuse/repeated-tag', '{#A one|#A two}');
  Check('a repeated tag is reported', Refused('{#A one|#A two}'), '{#A one|#A two};');

  { A tag may not contain a line break. Blank is space and tab only, so an option written
    across two lines used to swallow the newline INTO the tag name -- which is a group key,
    and group keys round-trip through TStringList.Text, which re-split on it. Every branch
    then resolved to nothing: the block rendered as the empty string, and Unsupported was
    empty too. Silent deletion of the author's text, by the unit whose rule forbids it. }
  CheckVerbatim('refuse/tag-with-newline', '{#T1' + sLineBreak + 'A b|#T2' + sLineBreak + 'C d}');
  Check('a tag with a line break is reported',
        Refused('{#T1' + sLineBreak + 'A b|#T2 C}'),
        '{#T1' + sLineBreak + 'A b|#T2 C};');

  { tagged, but neither all options nor the first alone }
  CheckVerbatim('refuse/tag-not-on-first', '{one|#B two}');
  CheckVerbatim('refuse/partial-tags', '{#A one|#B two|three|#D four}');

  { a lifted block keeps the author's macros, not this unit's placeholders }
  CheckVerbatim('refuse/keeps-inner-macro', '{#.de #file[a,1,S]|#.com b}');
  Check('a lifted block is reported with its macro intact',
        Refused('{#.de #file[a,1,S]|#.com b}'), '{#.de #file[a,1,S]|#.com b};');

  { nothing refused means an empty list }
  Check('a fully translated template refuses nothing', Refused('{a|b} ~{c|d}'), '');

  { plain spintax passes through the CONVERTER byte for byte -- it still spins, so the
    render is not the thing to compare; ordinary prose survives both }
  Check('nested plain spin is untouched',
        Conv('{This {was|is} wonderful.|Thank{ you| you all|s}}'),
        '{This {was|is} wonderful.|Thank{ you| you all|s}}');
  CheckUntouched('plain/prose', 'Plain text, no macros.');
  Check('empty input', Conv(''), '');
end;

{ ─── 6. the generated names cannot collide ───────────────────────────────── }

procedure TestNamespace;
var made, out1: string;
begin
  { a template that already mentions the default prefix must push it aside }
  made := Conv('%__gsa_m1% #file[x,1,S]');
  CheckTrue('a colliding reference moves the prefix', Pos('%__gsa2_m1%', made) > 0);
  CheckTrue('the author''s own name is left where it was', Pos('%__gsa_m1%', made) > 0);
  Check('a colliding reference still renders both apart',
        ConvRender('%__gsa_m1% #file[x,1,S]', False), '%__gsa_m1% #file[x,1,S]');

  { the engine folds variable case, so the check has to fold it too }
  Check('a collision in another case also moves the prefix',
        ConvRender('%__GSA_M1% #file[x,1,S]', False), '%__GSA_M1% #file[x,1,S]');

  { A line that looks like one of this engine's directives is ordinary text in a GSA
    template, so it must come out as written rather than being consumed -- and its name
    must not collide with the generated ones either. }
  out1 := Trim(ConvRender('#def %__gsa_g1_1% = zz' + sLineBreak +
                          'x {#A a|#B b}{#A c|#B d}', False));
  CheckTrue('an author directive line stays literal text',
            Pos('#def %__gsa_g1_1% = zz', out1) = 1);
  CheckTrue('and the correlated pair still holds',
            (Pos('x ac', out1) > 0) or (Pos('x bd', out1) > 0));
end;

{ ─── 7. the documented artifact ──────────────────────────────────────────── }

procedure TestArtifacts;
var made: string;
begin
  made := Conv('{#A a|#B b}{#A c|#B d} tail');
  CheckTrue('definitions come after the body', Pos('#def', made) > Pos('tail', made));
  Check('post-process trims the blank lines a definition leaves',
        ConvRender('{#A one|#B one} {#A only|#B only}', True), 'One only');
end;

{ ─── 8. the features together ────────────────────────────────────────────── }

procedure TestCombined;
var outs: TStringList;
begin
  outs := TStringList.Create;
  try
    Outcomes('{#T1 Great|#T2 Poor} service. #file_links[c.txt,2,S] ~{A.|B.} ' +
             '{#T1 Recommended.|#T2 Avoid.}', 4000, False, outs);
    Check('tags, macro and tilde coexist', outs.Text,
          'Great service. #file_links[c.txt,2,S] A. B. Recommended.' + sLineBreak +
          'Great service. #file_links[c.txt,2,S] B. A. Recommended.' + sLineBreak +
          'Poor service. #file_links[c.txt,2,S] A. B. Avoid.' + sLineBreak +
          'Poor service. #file_links[c.txt,2,S] B. A. Avoid.' + sLineBreak);
  finally
    outs.Free;
  end;

  CheckTrue('a tagged block nested in a tilde form converts',
            Pos('#TAG', Conv('~{x|{#TAG1 a|#TAG2 b}}')) = 0);
end;

begin
  DefaultSystemCodePage := CP_UTF8;

  TestMacros;
  TestTilde;
  TestPerOptionTags;
  TestBlockFormRefused;
  TestLiteralText;
  TestRefusals;
  TestNamespace;
  TestArtifacts;
  TestCombined;

  WriteLn(Format('gsa tests: %d checks, %d failed', [Checks, Failed]));
  if Failed > 0 then Halt(1);
end.
