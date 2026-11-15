using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace TerminalDeck.Core.WhatsApp;

/// Text as WhatsApp reads it (DESIGN-WHATSAPP.md section 4): `*bold*`, `_italic_`, triple backticks for code,
/// plain lists, a table as lines, links as plain URLs; and the split to 4096 characters.
/// A line-for-line port of the Mac's WhatsAppTextRules.swift, so both apps answer WhatsApp identically
/// (WhatsAppTextGoldenTests compares against outputs of the Swift code itself).
///
/// Lengths are counted in UTF-16 units: never more than WhatsApp's count, whether it counts characters,
/// code points or UTF-16 units, so a part that passes here is never refused as too long.
public static partial class WhatsAppText
{
  public const int Limit = WhatsAppLimits.TextCharacters;

  // ---- Markdown -> WhatsApp -------------------------------------------------------------------------------

  /// Markdown (what the AIs write) -> WhatsApp's own marks.
  public static string Format(string markdown)
  {
    var lines = (markdown ?? "").Replace("\r\n", "\n").Replace("\r", "\n").Split('\n');
    var output = new List<string>();
    string? fence = null; // the opening fence's run ("```" or "~~~~") while inside a code block
    var index = 0;
    void Emit(string line)
    {
      if (line.Length == 0 && (output.Count == 0 || output[^1].Length == 0)) return; // one blank line at most, none at the start
      output.Add(line);
    }
    while (index < lines.Length)
    {
      var line = lines[index];
      var trimmed = TrimSpaces(line);
      if (fence is { } open)
      {
        if (trimmed.StartsWith(open, StringComparison.Ordinal) && trimmed.All(c => c == open[0])) { output.Add("```"); fence = null; }
        else output.Add(line); // code is copied exactly
        index++;
        continue;
      }
      if (FenceRun(trimmed) is { } run)
      {
        fence = run;
        output.Add("```"); // the language name is dropped: WhatsApp shows it as text
        index++;
        continue;
      }
      if (trimmed.Contains('|') && index + 1 < lines.Length && IsTableSeparator(lines[index + 1]))
      {
        Emit(string.Join(" | ", Cells(trimmed).Select(c => c.Length == 0 ? "" : "*" + Inline(c, dropBold: true) + "*")));
        index += 2;
        while (index < lines.Length)
        {
          var row = TrimSpaces(lines[index]);
          if (row.Length == 0 || !row.Contains('|')) break;
          Emit(string.Join(" | ", Cells(row).Select(c => Inline(c))));
          index++;
        }
        continue;
      }
      if (trimmed.Length > 0 && index + 1 < lines.Length && IsSetextUnderline(lines[index + 1]) && IsPlainParagraph(trimmed))
      {
        Emit(Heading(trimmed));
        index += 2;
        continue;
      }
      Emit(Block(line));
      index++;
    }
    if (fence is not null) output.Add("```");
    while (output.Count > 0 && output[^1].Length == 0) output.RemoveAt(output.Count - 1);
    return string.Join("\n", output);
  }

  /// Swift's trimmingCharacters(in: .whitespaces): spaces and tabs (not line ends).
  private static string TrimSpaces(string s) => s.Trim(SpaceChars);
  private static readonly char[] SpaceChars = [' ', '\t', '\u00A0', '\u1680', '\u2000', '\u2001', '\u2002', '\u2003', '\u2004', '\u2005', '\u2006', '\u2007', '\u2008', '\u2009', '\u200A', '\u202F', '\u205F', '\u3000'];

  private static string? FenceRun(string trimmed)
  {
    foreach (var mark in new[] { '`', '~' })
    {
      var run = 0;
      while (run < trimmed.Length && trimmed[run] == mark) run++;
      if (run >= 3)
      {
        // An info string after ``` may not contain a backtick (CommonMark); after ~~~ anything goes.
        if (mark == '`' && trimmed.AsSpan(run).Contains('`')) return null;
        return new string(mark, run);
      }
    }
    return null;
  }

  private static string Block(string line)
  {
    var expanded = line.Replace("\t", "    ");
    var trimmed = TrimSpaces(expanded);
    if (trimmed.Length == 0) return "";
    if (Rule().IsMatch(trimmed)) return ""; // a horizontal rule
    var heading = HeadingLine().Match(expanded);
    if (heading.Success) return Heading(heading.Groups[1].Value);
    if (EmptyHeading().IsMatch(expanded)) return "";
    var quote = QuoteLine().Match(expanded);
    if (quote.Success)
    {
      var inner = Block(quote.Groups[1].Value);
      return inner.Length == 0 ? ">" : "> " + inner;
    }
    var task = TaskLine().Match(expanded);
    if (task.Success) return task.Groups[1].Value + "- " + (task.Groups[2].Value == " " ? "☐ " : "☑ ") + Inline(task.Groups[3].Value);
    var bullet = BulletLine().Match(expanded);
    if (bullet.Success) return bullet.Groups[1].Value + "- " + Inline(bullet.Groups[2].Value);
    var numbered = NumberedLine().Match(expanded);
    if (numbered.Success) return numbered.Groups[1].Value + numbered.Groups[2].Value + ". " + Inline(numbered.Groups[3].Value);
    return Inline(trimmed);
  }

  /// A heading is one bold line; bold marks inside it are dropped so WhatsApp does not see nested stars.
  private static string Heading(string text)
  {
    var body = TrimSpaces(Inline(text, dropBold: true));
    return body.Length == 0 ? "" : "*" + body + "*";
  }

  private static bool IsPlainParagraph(string trimmed) =>
    !(ListStart().IsMatch(trimmed) || trimmed.StartsWith('>') || trimmed.StartsWith('#') || FenceRun(trimmed) is not null || Rule().IsMatch(trimmed));

  private static bool IsSetextUnderline(string line) => SetextLine().IsMatch(line);

  private static bool IsTableSeparator(string line) => line.Contains('|') && TableSeparator().IsMatch(line);

  private static IEnumerable<string> Cells(string row)
  {
    var body = row.Replace("\\|", "\uE0FE");
    if (body.StartsWith('|')) body = body[1..];
    if (body.EndsWith('|')) body = body[..^1];
    return body.Split('|').Select(c => TrimSpaces(c.Replace("\uE0FE", "|")));
  }

  // ---- inline marks ---------------------------------------------------------------------------------------

  private const string Bold = "\uE0FF";

  /// One line's inline marks: code spans are kept as they are; the rest is converted.
  internal static string Inline(string text, bool dropBold = false)
  {
    var result = new StringBuilder();
    var plain = new StringBuilder();
    var index = 0;
    while (index < text.Length)
    {
      if (text[index] != '`') { plain.Append(text[index]); index++; continue; }
      var run = 0;
      while (index + run < text.Length && text[index + run] == '`') run++;
      // Find a closing run of exactly the same length.
      int probe = index + run, close = -1;
      while (probe < text.Length)
      {
        if (text[probe] == '`')
        {
          var other = 0;
          while (probe + other < text.Length && text[probe + other] == '`') other++;
          if (other == run) { close = probe; break; }
          probe += other;
        }
        else probe++;
      }
      if (close < 0) { plain.Append(text, index, run); index += run; continue; }
      result.Append(Convert(plain.ToString(), dropBold));
      plain.Clear();
      var code = text[(index + run)..close];
      if (new StringInfo(code).LengthInTextElements > 2 && code.StartsWith(' ') && code.EndsWith(' ')) code = code[1..^1];
      result.Append(code.Contains('`') ? text[index..(close + run)] : "`" + code + "`");
      index = close + run;
    }
    return result.Append(Convert(plain.ToString(), dropBold)).ToString();
  }

  private static string Convert(string text, bool dropBold)
  {
    if (text.Length == 0) return text;
    var kept = new List<string>();
    // Text that later passes must not touch (URLs, escaped marks) waits behind a private-use token.
    string Keep(string value)
    {
      kept.Add(value);
      var digits = (kept.Count - 1).ToString(CultureInfo.InvariantCulture).Select(d => (char)(0xE010 + d - '0'));
      return "\uE000" + string.Concat(digits) + "\uE001";
    }
    var s = text;
    // Backslash escapes: the character itself, never a mark.
    s = Escape().Replace(s, m => Keep(m.Groups[1].Value));
    // HTML that carries meaning, then the rest of the known tags go.
    s = HtmlBreak().Replace(s, "\n");
    s = HtmlBold().Replace(s, "**");
    s = HtmlItalic().Replace(s, "_");
    s = HtmlStrike().Replace(s, "~~");
    // Links and pictures: "text (URL)", or the bare URL when the text is the URL.
    s = Link().Replace(s, m =>
    {
      var label = TrimSpaces(m.Groups[1].Value);
      var url = m.Groups[2].Value;
      var bareUrl = Scheme().Replace(url, "", 1);
      var bareLabel = Scheme().Replace(label, "", 1);
      if (label.Length == 0 || bareLabel == bareUrl || label == url) return Keep(url);
      return label + " (" + Keep(url) + ")";
    });
    s = AutoLink().Replace(s, m => Keep(m.Groups[1].Value));
    s = BareUrl().Replace(s, m => Keep(m.Value));
    s = KnownTag().Replace(s, "");
    // Emphasis: ***x*** -> *_x_*, **x** / __x__ -> *x*, *x* -> _x_, ~~x~~ -> ~x~.
    var b = dropBold ? "" : Bold;
    s = BoldItalic().Replace(s, m => b + "_" + m.Groups[1].Value + "_" + b);
    s = BoldStars().Replace(s, m => b + m.Groups[1].Value + b);
    s = BoldUnderscores().Replace(s, m => b + m.Groups[1].Value + b);
    s = ItalicStar().Replace(s, m => "_" + m.Groups[1].Value + "_");
    s = Strike().Replace(s, m => "~" + m.Groups[1].Value + "~");
    s = s.Replace(Bold, "*");
    // Entities the AIs sometimes write.
    foreach (var (entity, character) in new[] { ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&") })
      s = s.Replace(entity, character);
    // Put the kept text back (a kept URL may itself hold a kept escape).
    for (var round = 0; round < 4 && s.Contains('\uE000'); round++)
      s = KeptToken().Replace(s, m =>
      {
        var number = int.Parse(string.Concat(m.Groups[1].Value.Select(c => (char)(c - 0xE010 + '0'))), CultureInfo.InvariantCulture);
        return number < kept.Count ? kept[number] : "";
      });
    return s;
  }

  // ---- splitting ------------------------------------------------------------------------------------------

  /// Pieces of at most `limit` UTF-16 units, cut at paragraph ends first, then line ends, sentence ends, word ends;
  /// a code block that fits one piece is never cut, a longer one is closed and reopened. In order; [] for blank text.
  public static IReadOnlyList<string> Split(string text, int limit = Limit)
  {
    limit = Math.Max(limit, 1);
    var clean = Tidy(text ?? "");
    if (clean.Length == 0) return [];
    if (clean.Length <= limit) return [clean];
    return Pack(Blocks(clean), limit, Level.Line);
  }

  private sealed record Piece(string Text, bool Code);
  private enum Level { Line, Sentence, Word, Character }

  /// Leading line ends and trailing white space go; leading spaces stay (an indented list line keeps its indent).
  private static string Tidy(string text)
  {
    var end = text.Length;
    while (end > 0 && char.IsWhiteSpace(text[end - 1])) end--;
    var start = 0;
    while (start < end && IsNewline(text[start])) start++;
    return text[start..end];
  }

  private static bool IsNewline(char c) => c is '\n' or '\r' or '\v' or '\f' or '\u0085' or '\u2028' or '\u2029';

  /// Paragraphs (with the blank lines after them) and whole code blocks, in order; joined they are the text again.
  private static List<Piece> Blocks(string text)
  {
    var pieces = new List<Piece>();
    var current = new StringBuilder();
    var inCode = false;
    void Flush(bool code) { if (current.Length > 0) pieces.Add(new(current.ToString(), code)); current.Clear(); }
    var lines = text.Split('\n');
    for (var number = 0; number < lines.Length; number++)
    {
      var raw = lines[number];
      var line = raw + (number < lines.Length - 1 ? "\n" : "");
      var trimmed = TrimSpaces(raw);
      if (inCode)
      {
        current.Append(line);
        if (trimmed.StartsWith("```", StringComparison.Ordinal)) { inCode = false; Flush(true); }
      }
      else if (trimmed.StartsWith("```", StringComparison.Ordinal) && !(trimmed.Length > 3 && trimmed.EndsWith("```", StringComparison.Ordinal)))
      {
        Flush(false);
        current.Append(line);
        inCode = true;
      }
      else if (trimmed.Length == 0)
      {
        // A blank line ends a paragraph and stays with it.
        if (current.Length == 0 && pieces.Count > 0) pieces[^1] = pieces[^1] with { Text = pieces[^1].Text + line };
        else { current.Append(line); Flush(false); }
      }
      else current.Append(line);
    }
    Flush(inCode);
    return pieces;
  }

  /// Fills parts in order with whole pieces; a piece too long for a part on its own is cut finer.
  private static List<string> Pack(IEnumerable<Piece> pieces, int limit, Level? finer)
  {
    var parts = new List<string>();
    var current = "";
    void Flush() { var part = Tidy(current); if (part.Length > 0) parts.Add(part); current = ""; }
    foreach (var piece in pieces)
    {
      if (Tidy(current + piece.Text).Length <= limit) { current += piece.Text; continue; }
      Flush();
      if (Tidy(piece.Text).Length <= limit) { current = piece.Text; continue; }
      if (piece.Code && SplitCode(piece.Text, limit) is { } code) parts.AddRange(code);
      else if (finer is Level level) parts.AddRange(Cut(piece.Text, limit, level));
      else parts.AddRange(HardCut(piece.Text, limit));
    }
    Flush();
    return parts;
  }

  private static List<string> Cut(string text, int limit, Level level)
  {
    Level? next;
    List<string> pieces;
    switch (level)
    {
      case Level.Line: next = Level.Sentence; pieces = Chunks(text, LineChunk()); break;
      case Level.Sentence: next = Level.Word; pieces = Chunks(text, SentenceChunk()); break;
      case Level.Word: next = Level.Character; pieces = Chunks(text, WordChunk()); break;
      default: return HardCut(text, limit);
    }
    if (pieces.Count <= 1) return next is Level n ? Cut(text, limit, n) : HardCut(text, limit);
    return Pack(pieces.Select(p => new Piece(p, false)), limit, next);
  }

  /// Last resort for one word longer than a part: whole characters (never half an emoji or a surrogate pair).
  private static List<string> HardCut(string text, int limit)
  {
    var parts = new List<string>();
    var current = new StringBuilder();
    foreach (var character in Characters(text))
    {
      if (current.Length + character.Length > limit && current.Length > 0) { parts.Add(current.ToString()); current.Clear(); }
      current.Append(character);
    }
    if (Tidy(current.ToString()).Length > 0) parts.Add(current.ToString());
    return parts.Select(Tidy).Where(p => p.Length > 0).ToList();
  }

  /// A code block longer than one part: closed at the end of each part and opened again at the start of the next.
  private static List<string>? SplitCode(string text, int limit)
  {
    var lines = text.Split('\n').ToList();
    while (lines.Count > 0 && lines[^1].Length == 0) lines.RemoveAt(lines.Count - 1);
    if (lines.Count == 0) return null;
    var opener = TrimSpaces(lines[0]);
    lines.RemoveAt(0);
    if (lines.Count > 0 && TrimSpaces(lines[^1]).StartsWith("```", StringComparison.Ordinal)) lines.RemoveAt(lines.Count - 1);
    var room = limit - opener.Length - 1 - "\n```".Length;
    if (room < 8) return null; // too small to be worth fences: cut as plain text
    var groups = new List<string>();
    string? current = null;
    void Flush() { if (current is not null) groups.Add(current); current = null; }
    foreach (var line in lines)
    {
      if (line.Length > room) { Flush(); groups.AddRange(HardCodeLine(line, room)); continue; }
      if (current is not null && current.Length + 1 + line.Length <= room) current = current + "\n" + line;
      else { Flush(); current = line; }
    }
    Flush();
    return groups.Select(g => opener + "\n" + g + "\n```").ToList();
  }

  /// One code line longer than a part: cut after a space where there is one, else between characters.
  private static List<string> HardCodeLine(string line, int room)
  {
    var parts = new List<string>();
    var current = new StringBuilder();
    foreach (var word in Chunks(line, CodeWordChunk()).Where(w => w.Length > 0))
    {
      if (current.Length + word.Length <= room) { current.Append(word); continue; }
      if (current.Length > 0) { parts.Add(current.ToString()); current.Clear(); }
      if (word.Length <= room) { current.Append(word); continue; }
      foreach (var character in Characters(word))
      {
        if (current.Length + character.Length > room && current.Length > 0) { parts.Add(current.ToString()); current.Clear(); }
        current.Append(character);
      }
    }
    if (current.Length > 0) parts.Add(current.ToString());
    return parts;
  }

  /// Whole user-perceived characters (Swift's Character): never half a surrogate pair or a letter without its marks.
  private static IEnumerable<string> Characters(string text)
  {
    for (var i = 0; i < text.Length;)
    {
      var n = StringInfo.GetNextTextElementLength(text, i);
      yield return text.Substring(i, n);
      i += n;
    }
  }

  /// The pieces the pattern matches, in order; joined they are the whole text.
  private static List<string> Chunks(string text, Regex pattern)
  {
    var pieces = new List<string>();
    var consumed = 0;
    foreach (Match match in pattern.Matches(text))
    {
      if (match.Length == 0) continue;
      if (match.Index > consumed) pieces.Add(text[consumed..match.Index]);
      pieces.Add(match.Value);
      consumed = match.Index + match.Length;
    }
    if (consumed < text.Length)
    {
      if (pieces.Count == 0) pieces.Add(text[consumed..]);
      else pieces[^1] += text[consumed..];
    }
    return pieces;
  }

  // ---- patterns (the Swift file's, unchanged) -------------------------------------------------------------

  [GeneratedRegex(@"^([-*_])( *\1){2,} *$")] private static partial Regex Rule();
  [GeneratedRegex(@"^ {0,3}#{1,6}[ \t]+(.*?)[ \t]*#*[ \t]*$")] private static partial Regex HeadingLine();
  [GeneratedRegex(@"^ {0,3}#{1,6}$")] private static partial Regex EmptyHeading();
  [GeneratedRegex(@"^\s*>\s?(.*)$")] private static partial Regex QuoteLine();
  [GeneratedRegex(@"^( *)[-*+][ \t]+\[([ xX])\][ \t]+(.*)$")] private static partial Regex TaskLine();
  [GeneratedRegex(@"^( *)[-*+][ \t]+(.*)$")] private static partial Regex BulletLine();
  [GeneratedRegex(@"^( *)([0-9]{1,9})[.)][ \t]+(.*)$")] private static partial Regex NumberedLine();
  [GeneratedRegex(@"^([-*+]|[0-9]{1,9}[.)])[ \t]")] private static partial Regex ListStart();
  [GeneratedRegex(@"^ {0,3}(=+|-+)[ \t]*$")] private static partial Regex SetextLine();
  [GeneratedRegex(@"^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$")] private static partial Regex TableSeparator();
  [GeneratedRegex(@"\\([!-/:-@\[-`{-~])")] private static partial Regex Escape();
  [GeneratedRegex(@"[ \t]*<br\s*/?>[ \t]*", RegexOptions.IgnoreCase)] private static partial Regex HtmlBreak();
  [GeneratedRegex(@"</?(b|strong)>", RegexOptions.IgnoreCase)] private static partial Regex HtmlBold();
  [GeneratedRegex(@"</?(i|em)>", RegexOptions.IgnoreCase)] private static partial Regex HtmlItalic();
  [GeneratedRegex(@"</?(s|del|strike)>", RegexOptions.IgnoreCase)] private static partial Regex HtmlStrike();
  [GeneratedRegex(@"!?\[([^\]]*)\]\(\s*<?([^\s)>]+)>?(?:\s+""[^""]*"")?\s*\)")] private static partial Regex Link();
  [GeneratedRegex(@"^[a-zA-Z]+://")] private static partial Regex Scheme();
  [GeneratedRegex(@"<((?:https?|mailto):[^>\s]+)>")] private static partial Regex AutoLink();
  [GeneratedRegex(@"https?://[^\s<>]*[^\s<>.,;:!?'"")\]*_~]")] private static partial Regex BareUrl();
  [GeneratedRegex(@"</?(?:a|abbr|b|blockquote|br|code|del|details|div|em|h[1-6]|hr|i|img|ins|kbd|li|mark|ol|p|pre|s|small|span|strike|strong|sub|summary|sup|table|tbody|td|th|thead|tr|u|ul)(?:\s[^>]*)?/?>", RegexOptions.IgnoreCase)] private static partial Regex KnownTag();
  [GeneratedRegex(@"\*\*\*(?=\S)(.+?)(?<=\S)\*\*\*")] private static partial Regex BoldItalic();
  [GeneratedRegex(@"\*\*(?=\S)(.+?)(?<=\S)\*\*")] private static partial Regex BoldStars();
  [GeneratedRegex(@"(?<![\p{L}\p{N}_])__(?=\S)(.+?)(?<=\S)__(?![\p{L}\p{N}_])")] private static partial Regex BoldUnderscores();
  [GeneratedRegex(@"(?<![\p{L}\p{N}*])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?![\p{L}\p{N}*])")] private static partial Regex ItalicStar();
  [GeneratedRegex(@"~~(?=\S)(.+?)(?<=\S)~~")] private static partial Regex Strike();
  [GeneratedRegex("\uE000([\uE010-\uE019]+)\uE001")] private static partial Regex KeptToken();
  [GeneratedRegex(@"[^\n]*\n|[^\n]+$")] private static partial Regex LineChunk();
  [GeneratedRegex(@"[\s\S]*?[.!?…。！？؟۔]+[""')\]»”’]*(\s+|$)|[\s\S]+$")] private static partial Regex SentenceChunk();
  [GeneratedRegex(@"\s*\S+\s*")] private static partial Regex WordChunk();
  [GeneratedRegex(@"\S*\s*")] private static partial Regex CodeWordChunk();
}
