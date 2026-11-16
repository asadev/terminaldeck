using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;
using TerminalDeck.Core.WhatsApp;

namespace TerminalDeck.Core.Tests.WhatsApp;

/// The Mac's WhatsAppTextTests.swift, case for case, plus the golden vectors made by the Swift code itself.
public sealed class WhatsAppTextTests
{
  // ---- format (the Mac's cases) ---------------------------------------------------------------------------

  [Fact]
  public void HeadingsBecomeOneBoldLineWithoutNestedStars()
  {
    Assert.Equal("*Build report for TD*", WhatsAppText.Format("# Build report for **TD**"));
    Assert.Equal("*Next steps*", WhatsAppText.Format("### Next steps ###"));
    Assert.Equal("*Setup*\nText", WhatsAppText.Format("Setup\n-----\nText"));
    Assert.Equal("*Title*", WhatsAppText.Format("Title\n=====\n"));
    Assert.Equal("*Issue #42*", WhatsAppText.Format("# Issue #42"));
  }

  [Fact]
  public void BoldItalicStrikeAndInlineCode()
  {
    Assert.Equal("The build *passed* in _12 minutes_.", WhatsAppText.Format("The build **passed** in *12 minutes*."));
    Assert.Equal("*bold* and _italic_ and ~gone~ and *_both_*", WhatsAppText.Format("__bold__ and _italic_ and ~~gone~~ and ***both***"));
    Assert.Equal("Run `swift test --filter **x**` now", WhatsAppText.Format("Run `swift test --filter **x**` now"));
    Assert.Equal("my_var_name and snake_case_too, 5 * 3 * 2", WhatsAppText.Format("my_var_name and snake_case_too, 5 * 3 * 2"));
    Assert.Equal("Literal *stars* stay", WhatsAppText.Format(@"Literal \*stars\* stay"));
  }

  [Fact]
  public void CodeBlocksKeepTheirTextExactlyAndLoseTheLanguage()
  {
    const string markdown = "Here:\n\n```swift\nlet x = **not bold** // _keep_\n\n    indented()\n```\nDone.";
    Assert.Equal("Here:\n\n```\nlet x = **not bold** // _keep_\n\n    indented()\n```\nDone.", WhatsAppText.Format(markdown));
    Assert.Equal("```\nraw\n```", WhatsAppText.Format("~~~\nraw\n~~~"));
    Assert.Equal("```\nnever closed\n```", WhatsAppText.Format("```\nnever closed"));
  }

  [Fact]
  public void ListsArePlainLines()
  {
    const string markdown = "- one\n  - nested **b**\n* two\n+ three\n1. first\n2) second\n- [x] done\n- [ ] open";
    Assert.Equal("- one\n  - nested *b*\n- two\n- three\n1. first\n2. second\n- ☑ done\n- ☐ open", WhatsAppText.Format(markdown));
  }

  [Fact]
  public void ATableBecomesOneLinePerRow()
  {
    const string markdown = "| Name | Size | Note |\n|:-----|-----:|:----:|\n| a.txt | 3 KB | **new** |\n| b.txt | 4 \\| 5 KB | |\n\nAfter.";
    Assert.Equal("*Name* | *Size* | *Note*\na.txt | 3 KB | *new*\nb.txt | 4 | 5 KB | \n\nAfter.", WhatsAppText.Format(markdown));
  }

  [Fact]
  public void LinksBecomeTextAndUrlOrTheBareUrl()
  {
    Assert.Equal("See the docs (https://example.com/a_b_c).", WhatsAppText.Format("See [the docs](https://example.com/a_b_c \"title\")."));
    Assert.Equal("https://y.com and https://y.com", WhatsAppText.Format("[https://y.com](https://y.com) and [y.com](https://y.com)"));
    Assert.Equal("Open https://x.com/some_path_here_now, then https://z.io/a*b*c.", WhatsAppText.Format("Open https://x.com/some_path_here_now, then <https://z.io/a*b*c>."));
    Assert.Equal("chart (https://e.com/c.png)", WhatsAppText.Format("![chart](https://e.com/c.png)"));
  }

  [Fact]
  public void NoHtmlIsLeft()
  {
    Assert.Equal("*Bold* & _it_\nnext <tag> plain", WhatsAppText.Format("<b>Bold</b> &amp; <i>it</i><br>next &lt;tag&gt; <span class=\"x\">plain</span>"));
    Assert.Equal("MoreBody", WhatsAppText.Format("<details><summary>More</summary>Body</details>"));
    Assert.Equal("if a < b and c > d", WhatsAppText.Format("if a < b and c > d"));
  }

  [Fact]
  public void QuotesRulesAndBlankLines()
  {
    Assert.Equal("> quoted _it_\n\nEnd", WhatsAppText.Format("> quoted *it*\n\n---\n\n\n\nEnd"));
    Assert.Equal("Start\n\nEnd", WhatsAppText.Format("\n\nStart\n\n\n\nEnd\n\n"));
  }

  [Fact]
  public void NonEnglishAndEmojiAreUntouched() =>
    Assert.Equal("اردو میں *جواب* 😀 中文 _斜体_ 👨‍👩‍👧‍👦", WhatsAppText.Format("اردو میں **جواب** 😀 中文 *斜体* 👨‍👩‍👧‍👦"));

  [Fact]
  public void ARealLookingAnswer()
  {
    const string answer = """
      ## Done

      I fixed the **login** bug. Changes:

      1. `AuthView.swift`: the button waits for the *token*.
      2. Tests in [AuthTests](https://github.com/a/b/blob/main/AuthTests.swift).

      | Check | Result |
      |---|---|
      | unit | ✅ 42 passed |

      ```bash
      swift test --filter AuthTests
      ```
      """;
    const string expected = """
      *Done*

      I fixed the *login* bug. Changes:

      1. `AuthView.swift`: the button waits for the _token_.
      2. Tests in AuthTests (https://github.com/a/b/blob/main/AuthTests.swift).

      *Check* | *Result*
      unit | ✅ 42 passed

      ```
      swift test --filter AuthTests
      ```
      """;
    Assert.Equal(expected, WhatsAppText.Format(answer));
  }

  // ---- split (the Mac's cases) ----------------------------------------------------------------------------

  private static string[] Words(string text) => Regex.Split(text, @"\s+").Where(w => w.Length > 0).ToArray();
  private static int Fences(string part) => part.Split("```").Length;

  [Fact]
  public void ShortTextIsOnePartAndBlankIsNone()
  {
    Assert.Equal(new[] { "Hello" }, WhatsAppText.Split("Hello"));
    Assert.Equal(new[] { "  Hello" }, WhatsAppText.Split("\n\n  Hello  \n"));
    Assert.Empty(WhatsAppText.Split(""));
    Assert.Empty(WhatsAppText.Split(" \n\n "));
    var exact = new string('a', 4096);
    Assert.Equal(new[] { exact }, WhatsAppText.Split(exact));
  }

  [Fact]
  public void ATwelveThousandCharacterAnswerSplitsAtParagraphEnds()
  {
    var paragraphs = Enumerable.Range(0, 40).Select(i => $"Paragraph {i}: " + string.Concat(Enumerable.Repeat("The build ran again and اردو text 👍🏽 stays whole. ", 6)).Trim());
    var answer = string.Join("\n\n", paragraphs);
    Assert.True(new StringInfo(answer).LengthInTextElements > 12_000);
    var parts = WhatsAppText.Split(answer);
    Assert.True(parts.Count >= 3);
    Assert.All(parts, part =>
    {
      Assert.True(part.Length <= 4096);
      Assert.StartsWith("Paragraph ", part, StringComparison.Ordinal);
      Assert.EndsWith("stays whole.", part, StringComparison.Ordinal);
    });
    Assert.Equal(answer, string.Join("\n\n", parts));
  }

  [Fact]
  public void OneLongParagraphSplitsAtLinesThenSentencesNeverInsideAWord()
  {
    var lines = string.Join("\n", Enumerable.Range(0, 120).Select(i => $"Line {i} has some words in it and ends here"));
    var byLine = WhatsAppText.Split(lines);
    Assert.True(byLine.Count > 1);
    Assert.All(byLine, p => { Assert.EndsWith("ends here", p, StringComparison.Ordinal); Assert.True(p.Length <= 4096); });
    Assert.Equal(Words(lines), Words(string.Join("\n", byLine)));

    var sentences = string.Concat(Enumerable.Repeat("Another sentence goes here, with commas. ", 300));
    var bySentence = WhatsAppText.Split(sentences);
    Assert.True(bySentence.Count > 1);
    Assert.All(bySentence, p => { Assert.EndsWith("commas.", p, StringComparison.Ordinal); Assert.True(p.Length <= 4096); });
    Assert.Equal(Words(sentences), Words(string.Join(" ", bySentence)));

    var noStops = string.Concat(Enumerable.Repeat("word ", 2000));
    var byWord = WhatsAppText.Split(noStops);
    Assert.All(byWord, p => { Assert.EndsWith("word", p, StringComparison.Ordinal); Assert.True(p.Length <= 4096); });
    Assert.Equal(Words(noStops), Words(string.Join(" ", byWord)));
  }

  [Fact]
  public void EmojiAndSurrogatePairsAreNeverCut()
  {
    var emoji = string.Concat(Enumerable.Repeat("👍🏽", 3000)); // 4 UTF-16 units each, no spaces
    var parts = WhatsAppText.Split(emoji);
    Assert.All(parts, p =>
    {
      Assert.True(p.Length <= 4096);
      Assert.Equal(0, p.Length % 4);
      Assert.Equal(string.Concat(Enumerable.Repeat("👍🏽", p.Length / 4)), p);
    });
    Assert.Equal(emoji, string.Concat(parts));
    var urdu = string.Concat(Enumerable.Repeat("تجربہ ", 1500));
    Assert.Equal(Words(urdu), Words(string.Join(" ", WhatsAppText.Split(urdu))));
  }

  [Fact]
  public void ACodeBlockThatFitsIsNeverCut()
  {
    var before = string.Concat(Enumerable.Repeat("Intro sentence here. ", 150));
    var code = "```\n" + string.Join("\n", Enumerable.Range(0, 60).Select(i => $"let value{i} = compute({i})")) + "\n```";
    var parts = WhatsAppText.Split(before + "\n\n" + code + "\n\nAfter.");
    Assert.Contains(parts, p => p.Contains(code, StringComparison.Ordinal));
    Assert.All(parts, p => { Assert.True(p.Length <= 4096); Assert.Equal(1, Fences(p) % 2); });
  }

  [Fact]
  public void ALongCodeBlockIsClosedAndReopened()
  {
    var lines = Enumerable.Range(0, 400).Select(i => $"line {i} of code here").ToArray();
    var text = "Here is the log:\n\n```\n" + string.Join("\n", lines) + "\n```\n\nThat is all.";
    var parts = WhatsAppText.Split(text);
    var codeParts = parts.Where(p => p.StartsWith("```", StringComparison.Ordinal)).ToArray();
    Assert.True(codeParts.Length > 1);
    Assert.All(codeParts, p => { Assert.EndsWith("\n```", p, StringComparison.Ordinal); Assert.True(p.Length <= 4096); });
    var carried = codeParts.SelectMany(p => p.Split('\n')).Where(l => l != "```");
    Assert.Equal(lines, carried);
    Assert.Equal("Here is the log:", parts[0]);
    Assert.Equal("That is all.", parts[^1]);
  }

  [Fact]
  public void FormatThenSplitKeepsEveryPartWithinTheLimit()
  {
    var markdown = string.Concat(Enumerable.Range(0, 30).Select(i =>
      $"## Section {i}\n\n**Bold** text with [a link](https://example.com/{i}) and `code`.\n\n" +
      $"| A | B |\n|---|---|\n| {i} | ✅ |\n\n- item\n- item two\n\n" +
      "```\n" + string.Concat(Enumerable.Repeat("x = 1\n", 40)) + "```\n\n"));
    var parts = WhatsAppText.Split(WhatsAppText.Format(markdown));
    Assert.True(parts.Count > 1);
    Assert.All(parts, p => { Assert.True(p.Length <= WhatsAppText.Limit); Assert.NotEmpty(p); Assert.Equal(1, Fences(p) % 2); });
  }

  // ---- more of our own ------------------------------------------------------------------------------------

  [Fact]
  public void HardCutsKeepWholeCharacters()
  {
    var text = string.Concat(Enumerable.Repeat("👍🏽" + "👨‍👩‍👧‍👦" + "é", 900)); // a family emoji, a letter with its mark
    var parts = WhatsAppText.Split(text);
    Assert.Equal(text, string.Concat(parts));
    var starts = StringInfo.ParseCombiningCharacters(text).ToHashSet();
    var at = 0;
    foreach (var p in parts)
    {
      Assert.True(p.Length <= 4096);
      Assert.Contains(at, starts);
      at += p.Length;
    }
  }

  [Fact]
  public void UrduSplitsAfterItsFullStopAndChineseBetweenWholeCharacters()
  {
    // Like the Mac: a sentence end needs a space after it, so text without spaces (Chinese) is cut between characters.
    var chinese = string.Concat(Enumerable.Repeat("这是第一句话，内容很长。", 1000));
    var cut = WhatsAppText.Split(chinese);
    Assert.Equal(chinese, string.Concat(cut));
    Assert.All(cut, p => Assert.True(p.Length <= 4096));
    var urdu = string.Concat(Enumerable.Repeat("یہ ایک لمبا جملہ ہے جو ختم ہوتا ہے۔ ", 400));
    var parts = WhatsAppText.Split(urdu);
    Assert.True(parts.Count > 1);
    Assert.All(parts, p => Assert.EndsWith("ہے۔", p, StringComparison.Ordinal));
  }

  // ---- golden vectors: outputs of the Mac's own WhatsAppTextRules.swift -----------------------------------

  public static TheoryData<string> GoldenNames()
  {
    var names = new TheoryData<string>();
    foreach (var name in Golden().Keys) names.Add(name);
    return names;
  }

  private static Dictionary<string, JsonElement> Golden()
  {
    var path = Path.Combine(AppContext.BaseDirectory, "Fixtures", "whatsapp-text-golden.json");
    using var doc = JsonDocument.Parse(File.ReadAllText(path));
    return doc.RootElement.EnumerateArray().ToDictionary(e => e.GetProperty("name").GetString()!, e => e.Clone());
  }

  [Theory, MemberData(nameof(GoldenNames))]
  public void AnswersExactlyLikeTheMac(string name)
  {
    var c = Golden()[name];
    var text = c.GetProperty("text").GetString()!;
    var limit = c.GetProperty("limit").GetInt32();
    if (c.TryGetProperty("format", out var format)) Assert.Equal(format.GetString(), WhatsAppText.Format(text));
    if (c.TryGetProperty("split", out var split)) Assert.Equal(split.EnumerateArray().Select(e => e.GetString()), WhatsAppText.Split(text, limit));
    if (c.TryGetProperty("splitFormatted", out var both)) Assert.Equal(both.EnumerateArray().Select(e => e.GetString()), WhatsAppText.Split(WhatsAppText.Format(text), limit));
  }
}
