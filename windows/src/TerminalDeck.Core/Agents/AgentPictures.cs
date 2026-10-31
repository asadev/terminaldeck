using System.Globalization;
using TerminalDeck.Core.Projects;

namespace TerminalDeck.Core.Agents;

public sealed record AgentSymbol(string Id, string Name);
public static class AgentPictures
{
  public static readonly AgentSymbol[] Symbols =
  [
    new("person", "Person"), new("terminal", "Terminal"), new("code", "Code"), new("magnifyingglass", "Search"),
    new("pencil", "Writing"), new("hammer", "Build"), new("lightbulb", "Ideas"), new("briefcase", "Work"),
    new("chart.bar", "Charts"), new("gearshape", "Settings"), new("shield", "Security"), new("star", "Star"), new("bolt", "Lightning")
  ];
  public static (string Picture, string Colour) Parse(string value)
  {
    var at = value.LastIndexOf('@');
    return at <= 0 ? (value, "blue") : (value[..at], value[(at + 1)..]);
  }
  public static string Emoji(string text, string colour)
  {
    text = text.Trim();
    if (text.Length == 0 || text.Any(char.IsControl) || new StringInfo(text).LengthInTextElements != 1 ||
      !text.EnumerateRunes().Any(r => r.Value is >= 0x1F000 and <= 0x1FAFF or >= 0x2190 and <= 0x2BFF or 0xA9 or 0xAE or 0x203C or 0x2049 or 0x2122 or 0x2139 or 0x3030 or 0x303D or 0x3297 or 0x3299 or 0x20E3))
      throw new ArgumentException("Choose one emoji for the picture.");
    if (!ProjectIdentity.Colours.Contains(colour)) throw new ArgumentException("Choose a picture colour.");
    return "emoji:" + text + "@" + colour;
  }
}
