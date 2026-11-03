using System.Text.Json;
using TerminalDeck.Core.Settings;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Tests.Settings;

public sealed class TerminalAppearanceTests
{
  [Fact] public void BuiltInPalettesHaveAllColoursAndFollowAppOrPinIndependently()
  {
    var service = new TerminalAppearanceService(new State()); Assert.Equal(13, service.Palettes().Length);
    Assert.All(service.Palettes(), palette => Assert.All(TerminalAppearanceService.Slots, slot => Assert.True(palette.Colors.ContainsKey(slot))));
    Assert.Equal("#e8e8e8", service.Read(false).Theme["background"]); Assert.Equal("#191919", service.Read(true).Theme["background"]);
    service.Set("dracula"); Assert.Equal(service.Read(false).Theme["background"], service.Read(true).Theme["background"]); service.Reset(); Assert.Equal("follow-app", service.Preferences().Scheme);
  }
  [Fact] public void ImportedAliasesFillOptionalColoursAndCannotOverwriteBuiltIns()
  {
    var service = new TerminalAppearanceService(new State()); var colors = service.Palettes()[0].Colors.ToDictionary(p => p.Key, p => p.Value); colors.Remove("cursorAccent"); colors.Remove("selectionBackground"); colors["cursorColor"] = colors["cursor"]; colors.Remove("cursor"); colors["purple"] = colors["magenta"]; colors.Remove("magenta"); colors["brightPurple"] = colors["brightMagenta"]; colors.Remove("brightMagenta"); colors["name"] = "Imported colours"; colors["id"] = "deck-dark";
    var imported = service.Import(JsonSerializer.Serialize(new { schemes = new[] { colors } })); Assert.StartsWith("custom-", imported.Id); Assert.Equal(imported.Colors["background"], imported.Colors["cursorAccent"]); Assert.Equal("deck-dark", service.Palettes()[0].Id);
    Assert.Throws<ArgumentException>(() => service.Edit("deck-dark", "Changed", imported.Colors)); service.Remove(imported.Id); Assert.Equal("follow-app", service.Preferences().Scheme);
  }
  [Fact] public void FontAndCustomChangesPersistAndInvalidColoursNeverCommit()
  {
    var state = new State(); var service = new TerminalAppearanceService(state); service.Set(fontFamily: "Consolas", fontSize: 18); var custom = service.Copy("deck-light");
    Assert.Equal(18, new TerminalAppearanceService(state).Read(true).FontSize); Assert.Equal("Consolas", new TerminalAppearanceService(state).Read(false).FontFamily); Assert.Equal(custom.Id, new TerminalAppearanceService(state).Preferences().Scheme);
    var colors = new Dictionary<string, string>(custom.Colors) { ["red"] = "url(javascript:bad)" }; Assert.Throws<ArgumentException>(() => service.Edit(custom.Id, "Bad", colors)); Assert.NotEqual("url(javascript:bad)", service.Resolved(false).Colors["red"]);
    Assert.Throws<ArgumentException>(() => service.Set(fontSize: 25)); Assert.Equal("#aabbccdd", TerminalAppearanceService.Color("#abcd"));
  }
  private sealed class State : IStateStore<TerminalAppearanceState>
  { private TerminalAppearanceState? state; public TerminalAppearanceState? Load() => state; public void Save(TerminalAppearanceState value) => state = value; }
}
