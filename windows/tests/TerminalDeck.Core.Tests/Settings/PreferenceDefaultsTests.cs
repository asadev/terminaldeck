using System.Text.Json;
using TerminalDeck.Core.Notifications;
using TerminalDeck.Core.Settings;
using TerminalDeck.Core.Storage;
namespace TerminalDeck.Core.Tests.Settings;

public sealed class PreferenceDefaultsTests
{
  private sealed class Store<T> : IStateStore<T> { public T? Value; public T? Load() => Value; public void Save(T state) => Value = state; }
  [Fact] public void RestoreAndDebugAreRealSavedPreferencesAndResetRequiresExplicitConfirmation()
  {
    var store = new Store<GeneralPreferences>(); var owner = new GeneralSettings(store);
    owner.Patch(JsonSerializer.SerializeToElement(new { restoreSessions = false, debugSettings = true, copyOnSelect = true }));
    var reopened = new GeneralSettings(store); Assert.False(reopened.Read().RestoreSessions); Assert.True(reopened.Read().DebugSettings);
    var calls = 0; Assert.Throws<InvalidOperationException>(() => PreferenceReset.Run(false, new PreferenceResetStep("General", () => { calls++; owner.Save(new()); })));
    Assert.Equal(0, calls); Assert.False(owner.Read().RestoreSessions);
    var result = PreferenceReset.Run(true, new("General", () => owner.Save(new())), new("Failing owner", () => throw new IOException("Synthetic failure")));
    Assert.Equal(new[] { "General" }, result.Completed); Assert.Equal(new[] { "Failing owner" }, result.Failed); Assert.True(owner.Read().RestoreSessions); Assert.False(owner.Read().DebugSettings);
  }
  [Fact] public void TerminalDefaultsResetRetainsUserAuthoredPalettes()
  {
    var owner = new TerminalAppearanceService(new Store<TerminalAppearanceState>());
    var imported = owner.Copy(TerminalAppearanceService.BuiltIns[0].Id); owner.Set(imported.Id, "Consolas", 20);
    owner.Reset(); Assert.Equal("follow-app", owner.Preferences().Scheme); Assert.Contains(owner.Palettes(), p => p.Id == imported.Id);
  }
  private sealed class Sink : ISessionNotificationSink
  {
    public int Tests; public int Notices;
    public ValueTask ShowAsync(SessionNotice notice, string sound, CancellationToken ct) { Notices++; return ValueTask.CompletedTask; }
    public ValueTask<NotificationTestResult> TestAsync(string sound, bool soundOnly, CancellationToken ct) { Tests++; return ValueTask.FromResult(new NotificationTestResult(true, "Fake delivery only")); }
  }
  [Fact] public async Task DisabledPreferenceSetupDoesNotEmitAndOnlyExplicitTestUsesTheFakeSink()
  {
    var sink = new Sink(); var owner = new SessionNotifications(new Store<NotificationPreferences>(), sink, () => false);
    owner.Save(new(NeedsYou: false, Finished: false, Hoot: false, TaskMentions: false, Sound: "none"));
    Assert.Equal(0, sink.Tests); Assert.Equal(0, sink.Notices);
    Assert.True((await owner.TestAsync()).Accepted); Assert.Equal(1, sink.Tests); Assert.Equal(0, sink.Notices);
  }
  [Theory] [InlineData("chime")] [InlineData("blip")] [InlineData("knock")]
  public void OriginalSoundDataIsBoundedPcmWithoutOpeningAnAudioDevice(string id)
  {
    var wave = NotificationSounds.Wave(id); Assert.InRange(wave.Length, 44, 44100);
    Assert.Equal("RIFF", System.Text.Encoding.ASCII.GetString(wave, 0, 4)); Assert.Equal("WAVE", System.Text.Encoding.ASCII.GetString(wave, 8, 4));
    Assert.Equal(wave.Length - 44, BitConverter.ToInt32(wave, 40)); Assert.Equal(16, BitConverter.ToInt16(wave, 34));
  }
}
