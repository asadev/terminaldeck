using TerminalDeck.Core.Agents;

namespace TerminalDeck.App.Views.Agents;

public sealed partial class AgentsPage
{
  // Component fixture only. It supplies the directory rows before Loaded, so the
  // proof never enumerates skills in the real person's home folder.
  internal void CProofDirectory(string view, IReadOnlyList<InstalledSkill> skills)
  {
    if (view is not ("All agents" or "At work" or "Skills")) throw new ArgumentException("Unknown proof directory.");
    librarySkills = skills; grouping = view; Model.SelectedId = null; Render();
  }
}
