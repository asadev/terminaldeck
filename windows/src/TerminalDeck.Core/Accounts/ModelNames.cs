using System.Text.RegularExpressions;

namespace TerminalDeck.Core.Accounts;

// A provider reports the applied model by its full id ("claude-opus-5-5",
// "claude-sonnet-4-5-20250929[1m]"); people see the name ("Opus 5.5").
public static partial class ModelNames
{
  public static string Display(string id, IEnumerable<ProviderModel> models)
  {
    if (id.Length == 0) return id;
    var list = models.ToArray();
    if (list.FirstOrDefault(m => m.Id == id) is { } exact) return exact.Name;
    // CLI aliases ("opus", "sonnet") name the family's current model: show its real name ("Opus 5.5").
    if (id.All(char.IsLetter) && list.FirstOrDefault(m => m.Name.StartsWith(id + " ", StringComparison.OrdinalIgnoreCase)) is { } familyModel) return familyModel.Name;
    var wanted = Core(id);
    if (list.FirstOrDefault(m => Core(m.Id) == wanted) is { } same) return same.Name;
    var match = Claude().Match(wanted);
    if (!match.Success) return id;
    var family = match.Groups["family"].Value;
    return char.ToUpperInvariant(family[0]) + family[1..] + " " + match.Groups["major"].Value + (match.Groups["minor"].Success ? "." + match.Groups["minor"].Value : "");
  }
  private static string Core(string id) => DateSuffix().Replace(id.Replace("[1m]", "", StringComparison.OrdinalIgnoreCase), "").ToLowerInvariant();
  [GeneratedRegex(@"-\d{8}$")] private static partial Regex DateSuffix();
  [GeneratedRegex(@"^claude-(?<family>opus|sonnet|haiku|fable)-(?<major>\d+)(?:-(?<minor>\d{1,2}))?$")] private static partial Regex Claude();
}
