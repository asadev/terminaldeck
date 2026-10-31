using System.Collections.Immutable;

namespace TerminalDeck.Core.Projects;

public sealed record ProjectSetupAgent(string Id, string ProjectId, ImmutableArray<string> Skills, bool Archived = false);
public sealed record ProjectSetupScore(ImmutableArray<string> Done, ImmutableArray<string> Missing, int Percent)
{
  public bool Complete => Missing.IsEmpty;
}
public static class ProjectSetup
{
  public static readonly string[] GuideSteps = ["Name", "Home folder", "Lead", "Team", "Skills", "Project card", "Connections", "Review"];
  public static string StepFor(string missing) => missing switch
  {
    "What it is" or "Logo" => "name", "Lead" => "lead", "Team" => "team",
    "Skills" => "skills", "Project card" => "card", _ => "review"
  };
  public static ProjectSetupScore Score(Project project, IEnumerable<ProjectSetupAgent> agents, string? card = null)
  {
    var settings = project.Preferences;
    var mine = agents.Where(a => a.ProjectId == project.Id && !a.Archived).ToArray();
    var leadId = project.Lead?.StartsWith("agent:", StringComparison.Ordinal) == true ? project.Lead[6..] : null;
    var checks = new (string Title, bool Set)[]
    {
      ("What it is", !string.IsNullOrWhiteSpace(settings.Text("about"))),
      ("Logo", project.Logo.Length > 0),
      ("Lead", project.Lead is not null || settings.Flag("setup.hootLeads")),
      ("Team", mine.Any(a => a.Id != leadId)),
      ("Skills", mine.Any(a => !a.Skills.IsDefaultOrEmpty)),
      ("Project card", CardFilled(card ?? settings.Text("card")))
    };
    var done = checks.Where(c => c.Set).Select(c => c.Title).ToImmutableArray();
    return new(done, checks.Where(c => !c.Set).Select(c => c.Title).ToImmutableArray(), (int)Math.Round(done.Length * 100.0 / checks.Length, MidpointRounding.AwayFromZero));
  }
  public static bool CardFilled(string text) => text.Split('\n').Any(raw =>
  {
    var line = raw.Trim();
    if (line.Length == 0 || line.StartsWith('#')) return false;
    var body = line.TrimStart('-', '*', '•', ' ');
    return body.Length > 0 && (!body.EndsWith(':') || body[..^1].Contains(':'));
  });
}
