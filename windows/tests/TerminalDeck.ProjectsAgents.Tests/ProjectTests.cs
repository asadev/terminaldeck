using System.Collections.Immutable;
using System.Text.Json;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.ProjectsAgents.Tests;

public sealed class ProjectTests
{
  [Theory]
  [InlineData("../escape")]
  [InlineData("CON")]
  [InlineData("LPT1.txt")]
  [InlineData("trailing.")]
  [InlineData("bad:name")]
  public void NewFolderNamesCannotEscapeOrUseReservedWindowsNames(string name)
  {
    using var f = new Fixture(); Assert.Throws<ArgumentException>(() => f.Projects.CreateFolder(f.Home, name));
  }
  [Theory]
  [InlineData("What it is", "name")]
  [InlineData("Logo", "name")]
  [InlineData("Lead", "lead")]
  [InlineData("Team", "team")]
  [InlineData("Skills", "skills")]
  [InlineData("Project card", "card")]
  public void MissingSetupPartOpensItsOwnStep(string missing, string step) => Assert.Equal(step, ProjectSetup.StepFor(missing));

  [Fact] public void FreshInstallHasIndependentOnly()
  {
    using var f = new Fixture(); Assert.Equal(ProjectIdentity.IndependentId, Assert.Single(f.Projects.List()).Id); Assert.Null(f.Projects.ActiveProjectId);
  }
  [Theory] [InlineData("")] [InlineData("   ")]
  public void NameIsRequired(string name)
  {
    using var f = new Fixture(); Assert.Throws<ArgumentException>(() => f.Projects.Save(new("sample", name, [f.Home]))); Assert.Single(f.Projects.List());
  }
  [Fact] public void HomeFolderIsRequiredAndMustExist()
  {
    using var f = new Fixture(); Assert.Throws<ArgumentException>(() => f.Projects.Save(new("sample", "Sample", [])));
    Assert.Throws<ArgumentException>(() => f.Projects.Save(new("sample", "Sample", [Path.Combine(f.Directory, "missing")])));
  }
  [Fact] public void AppStorageAndItsSymlinkCannotBeAHomeFolder()
  {
    using var f = new Fixture(); Directory.CreateDirectory(f.Root.DirectoryPath);
    Assert.Throws<ArgumentException>(() => f.Projects.Save(new("sample", "Sample", [f.Root.DirectoryPath])));
    var link = Path.Combine(f.Directory, "data-link"); Directory.CreateSymbolicLink(link, f.Root.DirectoryPath);
    Assert.Throws<ArgumentException>(() => f.Projects.Save(new("sample", "Sample", [link])));
  }
  [Fact] public void CreateEditOpenPutAwayAndReloadKeepStableId()
  {
    using var f = new Fixture(); f.Projects.Save(new("sample", "Sample", [f.Home]));
    f.Projects.Select("sample"); f.Projects.SetOpen("sample", false);
    var reopened = f.Projects.OpenFolder(f.Home); Assert.True(reopened.IsOpen);
    var second = Path.Combine(f.Directory, "other"); Directory.CreateDirectory(second);
    f.Projects.Save(new("sample", "Renamed", [second, f.Home]));
    var loaded = f.ReloadProjects(); Assert.Equal("Renamed", loaded.Get("sample").Name); Assert.Equal(second, loaded.Get("sample").HomeFolder); Assert.Equal("sample", loaded.ActiveProjectId);
  }
  [Fact] public void OpeningUnknownFolderDoesNotInventAProject()
  {
    using var f = new Fixture(); Assert.Throws<ArgumentException>(() => f.Projects.OpenFolder(f.Home)); Assert.Single(f.Projects.List());
  }
  [Fact] public void SameFolderCannotCreateDuplicateProjects()
  {
    using var f = new Fixture(); f.Projects.Save(new("sample", "Sample", [f.Home]));
    Assert.Throws<ArgumentException>(() => f.Projects.Save(new("other", "Other", [f.Home + Path.DirectorySeparatorChar])));
    Assert.Equal(2, f.Projects.List().Count);
  }
  [Fact] public void SettingsAndAIAccountChoicesStayInsideTheirProject()
  {
    using var f = new Fixture(); f.Projects.Save(new("sample", "Sample", [f.Home]));
    f.Projects.PatchSettings("sample", new Dictionary<string, JsonElement> { ["about"] = JsonSerializer.SerializeToElement("A sample"), ["whoUsesWhat"] = JsonSerializer.SerializeToElement(new[] { new { use = "chats", provider = "codex", accountId = "opaque-example-id" } }) });
    var loaded = f.ReloadProjects(); Assert.Equal("A sample", loaded.Get("sample").Preferences.Text("about"));
    Assert.Equal("opaque-example-id", Assert.Single(loaded.Get("sample").Preferences.WhoUsesWhat).AccountId); Assert.Empty(loaded.Get("independent").Preferences.Values);
    Assert.False(loaded.Get("sample").Preferences.Values.ContainsKey("whoUsesWhat"));
  }
  [Fact] public void DuplicateAIUsesAreRefusedWithoutPartialSettings()
  {
    using var f = new Fixture(); f.Projects.Save(new("sample", "Sample", [f.Home]));
    Assert.Throws<ArgumentException>(() => f.Projects.SetWhoUsesWhat("sample", [new("chats", "codex", null), new("chats", "claude", null)])); Assert.Empty(f.Projects.Get("sample").Preferences.WhoUsesWhat);
  }
  [Fact] public void PictureIsKeptByMetadataAndCanBeRemoved()
  {
    using var f = new Fixture(); f.Projects.Save(new("sample", "Sample", [f.Home])); f.Projects.SetPicture("sample", "sample.png");
    Assert.Equal("sample-picture.png", f.ReloadProjects().Get("sample").Logo); Assert.NotNull(f.Projects.PicturePath("sample"));
    Assert.Throws<ArgumentException>(() => f.Projects.SetPicture("sample", "bad")); Assert.Equal("sample-picture.png", f.Projects.Get("sample").Logo);
    f.Projects.SetPicture("sample", null); Assert.Null(f.Projects.PicturePath("sample"));
  }
  [Fact] public void SessionGroupsHaveOneRowPerProjectIdAndExplicitChoiceWins()
  {
    using var f = new Fixture(); f.Projects.Save(new("sample", "Sample", [f.Home]));
    var a = Guid.NewGuid().ToString(); var b = Guid.NewGuid().ToString(); var c = Guid.NewGuid().ToString();
    f.Projects.BindSession(c, "independent");
    var rows = new[] { new ProjectSession(a, "One", "codex", f.Home, "Running"), new(b, "Two", "claude", Path.Combine(f.Home, "child"), "Running"), new(c, "Plain", "codex", f.Home, "Running") };
    var groups = f.ReloadProjects().GroupSessions(rows.Concat(rows.Take(1))); Assert.Equal(2, groups.Count);
    Assert.Equal(2, groups.Single(g => g.ProjectId == "sample").Sessions.Length); Assert.Single(groups.Single(g => g.ProjectId == "independent").Sessions);
  }
  [Theory]
  [InlineData("C:\\Work\\App", "c:/work/app/child", true)]
  [InlineData("C:\\Work\\App", "C:/Work/Application", false)]
  [InlineData("\\\\host\\share\\App", "//HOST/share/App/child", true)]
  [InlineData("/work/app", "/work/application", false)]
  public void FolderMatchingHasRealComponentBoundaries(string root, string path, bool expected)
  {
    // "/work/app" is a full path on Mac and Linux only; on Windows the same boundary is checked on a drive.
    if (OperatingSystem.IsWindows() && root.StartsWith('/')) { root = "D:" + root; path = "D:" + path; }
    Assert.Equal(expected, ProjectPaths.Contains(root, path));
  }
  [Fact] public void LongestMatchingFolderWinsAndExplicitOrphanIdsSurvive()
  {
    using var f = new Fixture(); f.Projects.Save(new("sample", "Sample", [f.Home])); var child = Path.Combine(f.Home, "child"); Directory.CreateDirectory(child);
    f.Projects.Save(new("child", "Child", [child])); Assert.Equal("child", f.Projects.Resolve(null, Path.Combine(child, "src")));
    Assert.Equal("gone-project", f.Projects.Resolve("gone-project", child));
  }
  [Fact] public void RemovalKeepsFilesAndIndependentCannotBeRemoved()
  {
    using var f = new Fixture(); f.Projects.Save(new("sample", "Sample", [f.Home])); f.Projects.Select("sample"); f.Projects.Remove("sample");
    Assert.True(Directory.Exists(f.Home)); Assert.Null(f.Projects.ActiveProjectId); Assert.Throws<ArgumentException>(() => f.Projects.Remove("independent"));
  }
  [Fact] public void FailedSaveDoesNotPublishInMemorySuccess()
  {
    using var f = new Fixture(); var store = new MemoryStore<ProjectState> { Fail = true }; var projects = new ProjectService(store, new LocalProjectFolders(f.Root));
    Assert.Throws<IOException>(() => projects.Save(new("sample", "Sample", [f.Home]))); Assert.Single(projects.List());
  }
  [Fact] public void CorruptStateIsRefused()
  {
    using var f = new Fixture(); var store = new MemoryStore<ProjectState>(new(8, [], null, [])); Assert.Throws<IOException>(() => new ProjectService(store, new LocalProjectFolders(f.Root)));
  }
  [Fact] public void SetupNeedsSixPartsAndDisappearsOnlyWhenComplete()
  {
    var p = new Project("sample", "Sample", ["/work"], Logo: "sample.png", Lead: "agent:lead", Settings: new(ImmutableDictionary<string, JsonElement>.Empty.Add("about", JsonSerializer.SerializeToElement("A sample project")), []));
    var agents = new[] { new ProjectSetupAgent("lead", "sample", ["review"]), new ProjectSetupAgent("worker", "sample", []) };
    var incomplete = ProjectSetup.Score(p, agents, "# Goals\n- "); Assert.Equal(83, incomplete.Percent); Assert.False(incomplete.Complete);
    var complete = ProjectSetup.Score(p, agents, "# Goals\n- Make one useful change."); Assert.True(complete.Complete); Assert.Equal(100, complete.Percent); Assert.Empty(complete.Missing);
  }
  [Fact] public void NewIdsAreSafeUniqueAndNeverIndependent()
  {
    Assert.Equal("independent-2", ProjectIdentity.NewId("Independent", [])); Assert.Equal("hello-world-2", ProjectIdentity.NewId("Hello, world!", ["hello-world"])); Assert.Equal("project", ProjectIdentity.NewId("🙂", []));
  }
}
