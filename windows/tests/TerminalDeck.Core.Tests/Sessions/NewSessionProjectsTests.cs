using TerminalDeck.Core.Projects;

namespace TerminalDeck.Core.Tests.Sessions;

public sealed class NewSessionProjectsTests
{
  [Fact] public void CleanInstallHasIndependentAndAHomeWithoutCreatingAProject()
  {
    var choices = NewSessionProjects.Choices([]); var independent = Assert.Single(choices);
    Assert.Equal(ProjectIdentity.IndependentId, NewSessionProjects.Selection(choices, null));
    Assert.Equal("C:\\Users\\sm", NewSessionProjects.Folder(independent, "C:\\Users\\sm"));
    Assert.Empty(independent.Folders);
  }
  [Fact] public void FilteringNeverRemovesIndependentOrSelectsAnUnavailableProject()
  {
    Project[] projects = [ProjectIdentity.Independent, new("one", "One", ["C:\\one"]), new("closed", "Closed", ["C:\\closed"], IsOpen: false)];
    var choices = NewSessionProjects.Choices(projects, "no match");
    Assert.Equal(ProjectIdentity.IndependentId, Assert.Single(choices).Id);
    Assert.Equal(ProjectIdentity.IndependentId, NewSessionProjects.Selection(choices, "one"));
    Assert.DoesNotContain(NewSessionProjects.Choices(projects), p => p.Id == "closed");
  }
  [Fact] public void CreatedProjectIsSelectedAndUsesItsHome()
  {
    var created = new Project("created", "Created", ["C:\\created"]);
    var choices = NewSessionProjects.Choices([created]);
    Assert.Equal("created", NewSessionProjects.Selection(choices, created.Id));
    Assert.Equal("C:\\created", NewSessionProjects.Folder(created, "C:\\Users\\sm"));
    Assert.False(ProjectIdentity.ValidId(NewSessionProjects.CreateId));
    Assert.Equal(ProjectIdentity.IndependentId, NewSessionProjects.Selection(choices, NewSessionProjects.CreateId));
  }
}
