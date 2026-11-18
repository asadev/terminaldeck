using TerminalDeck.Core.Agents;

namespace TerminalDeck.Core.Tests.Agents;

public sealed class AgentSkillLibraryTests : IDisposable
{
  private readonly string root = Path.Combine(Path.GetTempPath(), "td-skill-library-" + Guid.NewGuid().ToString("N"));
  [Fact] public void New_skill_is_a_real_installed_file_and_edit_refuses_a_stale_copy()
  {
    var first = AgentSkillLibrary.Save(root, "release", "---\nname: Release\ndescription: Check the release\n---\nCheck the package.");
    Assert.Equal("Release", first.Name);
    Assert.Equal("Check the release", first.Summary);
    var next = AgentSkillLibrary.Save(root, "release", first.Text + "\nCheck the feed.", first.Text);
    Assert.Contains("Check the feed.", AgentSkillLibrary.Read(root, "release").Text);
    Assert.Throws<IOException>(() => AgentSkillLibrary.Save(root, "release", "Overwrite", first.Text));
    Assert.Equal(next.Text, File.ReadAllText(Path.Combine(root, "release", "SKILL.md")));
  }
  [Theory] [InlineData("../elsewhere")] [InlineData("two/levels")] [InlineData("")] [InlineData("a.b")]
  public void Skill_name_cannot_escape_its_chosen_root(string name) => Assert.Throws<ArgumentException>(() => AgentSkillLibrary.Save(root, name, "Instructions"));
  [Fact] public void Existing_skill_is_never_overwritten_by_create()
  {
    var saved = AgentSkillLibrary.Save(root, "check", "Keep this.");
    Assert.Throws<IOException>(() => AgentSkillLibrary.Save(root, "check", "Replace it."));
    Assert.Equal("Keep this.", AgentSkillLibrary.Read(root, "check").Text);
  }
  public void Dispose() { if (Directory.Exists(root)) Directory.Delete(root, true); }
}
