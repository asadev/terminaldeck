using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Tests.Agents;

public sealed class TeamImportTests : IDisposable
{
  private readonly string temp = Path.Combine(Path.GetTempPath(), "td-team-import-" + Guid.NewGuid().ToString("N"));
  public void Dispose() { try { Directory.Delete(temp, true); } catch (IOException) { } }

  private (ProjectService, AgentService) Open(AppDataRoot root)
  {
    var projects = new ProjectService(new JsonStateStore<ProjectState>(root, "projects"), new LocalProjectFolders(root));
    return (projects, new AgentService(new JsonStateStore<AgentState>(root, "agents"), projects, new AgentInstructions(root)));
  }

  [Fact]
  public void ImportsEachTeamUnderItsOwnProjectAndIsSafeToRepeat()
  {
    var root = AppDataRoot.Explicit(Path.Combine(temp, "data"));
    var iloop = Directory.CreateDirectory(Path.Combine(temp, "Claude-iloop")).FullName;
    var imatch = Directory.CreateDirectory(Path.Combine(temp, "imatchcrm")).FullName;
    var json = $$"""
    { "projects": [
      { "id": "iloop", "name": "iLoop", "folders": [{{System.Text.Json.JsonSerializer.Serialize(iloop)}}], "colour": "teal",
        "lead": { "role": "lead", "name": "Captain", "icon": "emoji:⚓@teal", "instructions": "Run the iLoop team.", "card": "Lead card" },
        "agents": [
          { "role": "access", "name": "Access & Roles", "model": "opus", "icon": "shield@teal", "instructions": "Own access.", "card": "Access card", "notes": "Access notes" },
          { "role": "tester", "name": "Tester", "model": "sonnet", "notes": "{{new string('x', 130_000)}}" } ] },
      { "id": "imatch-crm", "name": "iMatch CRM", "folders": [{{System.Text.Json.JsonSerializer.Serialize(imatch)}}],
        "lead": { "role": "lead", "name": "Orbit" },
        "agents": [ { "role": "access", "name": "Access & Roles", "model": "opus", "card": "iMatch access card" } ] } ] }
    """;
    var (projects, agents) = Open(root);
    TeamImport.Apply(projects, agents, TeamImport.Read(json));

    (projects, agents) = Open(root);   // read back from disk, as the app would
    Assert.Equal("agent:iloop-lead", projects.Get("iloop").Lead);
    Assert.Equal("agent:imatch-crm-lead", projects.Get("imatch-crm").Lead);
    var access = agents.Get("iloop-access");
    Assert.Equal(("iloop", "iloop-lead", "opus", "shield@teal"), (access.ProjectId, access.ReportsTo, access.Model, access.Icon));
    Assert.Equal("Own access.", agents.ReadInstructions("iloop-access"));
    Assert.Equal("imatch-crm", agents.Get("imatch-crm-access").ProjectId);
    Assert.Equal("Access card", agents.Seats().Single(s => s.SeatKey == "role:iloop/access").Card);
    Assert.Equal("Lead card", agents.Seats().Single(s => s.SeatKey == "lead:iloop").Card);
    Assert.Equal("iMatch access card", agents.Seats().Single(s => s.SeatKey == "role:imatch-crm/access").Card);
    Assert.True(agents.Seats().Single(s => s.SeatKey == "role:iloop/tester").Notes.Length <= 128_000);
    Assert.Single(agents.OrgChart().Single(n => n.Agent.Id == "iloop-lead").Reports, r => r.Agent.Id == "iloop-access");

    agents.SaveSeatMemory("role:iloop/access", "Edited by Umer", "");
    var again = TeamImport.Apply(projects, agents, TeamImport.Read(json));
    Assert.Equal(5, agents.List().Count);
    Assert.Equal(3, projects.List().Count);   // two projects plus Independent
    Assert.Equal("Edited by Umer", agents.Seats().Single(s => s.SeatKey == "role:iloop/access").Card);
    Assert.Contains(again, l => l.Contains("agent kept: Access & Roles"));
  }
}
