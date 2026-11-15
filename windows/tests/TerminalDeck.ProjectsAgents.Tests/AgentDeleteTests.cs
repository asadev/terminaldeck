using TerminalDeck.App.ViewModels.Agents;
using TerminalDeck.Core.Agents;

namespace TerminalDeck.ProjectsAgents.Tests;

// Lane U3: the Agents Delete button deletes with no "archive first" step, as on the Mac. Signed in it goes through the
// Cloud's route (the Bin on every device); signed out the archive-then-remove happens in the same press.
public sealed class AgentDeleteTests
{
  [Fact] public async Task SignedOutDeleteNeedsNoArchiveFirst()
  {
    using var f = await Fixture.ReadyAsync(); var agent = f.Agent("writer");
    using var model = new AgentsViewModel(f.Agents, f.Projects);
    Assert.NotEqual(SavedAgentStatus.Archived, agent.Status);
    Assert.False(model.DeletesToBin);
    model.Delete(agent.Id);
    Assert.DoesNotContain(f.Agents.List(), a => a.Id == agent.Id);
  }

  [Fact] public async Task SignedInDeleteGoesToTheBinRouteOnce()
  {
    using var f = await Fixture.ReadyAsync(); var agent = f.Agent("writer");
    using var model = new AgentsViewModel(f.Agents, f.Projects);
    var routed = new List<string>();
    AgentsViewModel.BinDelete = () => (_, id) => routed.Add(id);
    try
    {
      Assert.True(model.DeletesToBin);
      model.Delete(agent.Id);
      Assert.Equal([agent.Id], routed);
      // The route owns the removal: the page never archives or removes on its own while signed in.
      Assert.Equal(agent.Status, f.Agents.Get(agent.Id).Status);
    }
    finally { AgentsViewModel.BinDelete = null; }
  }

  [Fact] public async Task SignedOutRouteNullKeepsTheLocalDelete()
  {
    using var f = await Fixture.ReadyAsync(); var agent = f.Agent("writer");
    using var model = new AgentsViewModel(f.Agents, f.Projects);
    AgentsViewModel.BinDelete = () => null;
    try { Assert.False(model.DeletesToBin); model.Delete(agent.Id); Assert.DoesNotContain(f.Agents.List(), a => a.Id == agent.Id); }
    finally { AgentsViewModel.BinDelete = null; }
  }
}
