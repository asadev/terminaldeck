using System.Text.Json;
using TerminalDeck.Core.Receiver;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Tests.Receiver;

public sealed class W12ReceiverConditionsTests
{
  private static ReceiverDraft Draft(string text = "Outside message") => new("source", "Build", text)
    { Payload = JsonSerializer.SerializeToElement(new { build = new { state = "Failed", jobs = new[] { new { seconds = 12.5m } }, empty = (string?)null } }) };
  [Theory]
  [InlineData(ReceiverConditionOperation.Is, "failed", true)]
  [InlineData(ReceiverConditionOperation.IsNot, "passed", true)]
  [InlineData(ReceiverConditionOperation.Contains, "AIL", true)]
  [InlineData(ReceiverConditionOperation.DoesNotContain, "pass", true)]
  [InlineData(ReceiverConditionOperation.StartsWith, "fail", true)]
  [InlineData(ReceiverConditionOperation.MatchesPattern, "^Fail.*$", true)]
  [InlineData(ReceiverConditionOperation.IsPresent, "", true)]
  [InlineData(ReceiverConditionOperation.IsMissing, "", false)]
  [InlineData(ReceiverConditionOperation.IsOneOf, "passed, failed", true)]
  [InlineData(ReceiverConditionOperation.Is, "passed", false)]
  public void StringConditionsUseParsedPaths(ReceiverConditionOperation operation, string value, bool matches) =>
    Assert.Equal(matches, ReceiverConditions.Matches(Draft(), [new("$.build.state", operation, value)]));
  [Theory]
  [InlineData(ReceiverConditionOperation.IsAbove, "12.4", true)]
  [InlineData(ReceiverConditionOperation.IsBelow, "12.6", true)]
  [InlineData(ReceiverConditionOperation.IsAtLeast, "12.5", true)]
  [InlineData(ReceiverConditionOperation.IsAbove, "12.5", false)]
  [InlineData(ReceiverConditionOperation.IsBelow, "garbage", false)]
  public void NumericConditionsSupportArrayIndexesAndInvariantNumbers(ReceiverConditionOperation operation, string value, bool expected) =>
    Assert.Equal(expected, ReceiverConditions.Matches(Draft(), [new("build.jobs[0].seconds", operation, value)]));
  [Fact] public void MissingAndNullStayDistinctAndInvalidPayloadCannotMatchTextNegation()
  {
    Assert.True(ReceiverConditions.Matches(Draft(), [new("build.empty", ReceiverConditionOperation.IsPresent), new("build.absent", ReceiverConditionOperation.IsMissing)]));
    Assert.False(ReceiverConditions.Matches(Draft(), [new("build.absent", ReceiverConditionOperation.IsNot, "failed")]));
    Assert.False(ReceiverConditions.Matches(new("source", "Build", "not JSON"), [new("state", ReceiverConditionOperation.DoesNotContain, "failed")]));
    Assert.Contains("build.jobs[0].seconds", ReceiverConditions.Paths(Draft()));
    Assert.Throws<ArgumentException>(() => ReceiverConditions.Validate(new("build.state", ReceiverConditionOperation.MatchesPattern, "[")));
  }
  [Fact] public void PersistedRuleMatchesInLiveAndDryRunPathsWithoutSending()
  {
    var f = new Fixture(); var rule = new ReceiverRule("rule", "Slow failure", "source", "", new(RouteKind.Session, "session"))
      { Conditions = [new("build.state", ReceiverConditionOperation.Is, "Failed"), new("build.jobs[0].seconds", ReceiverConditionOperation.IsAtLeast, "12.5")] };
    f.Store.SaveRule(rule); var item = f.Store.Receive(Draft()); Assert.Equal(rule.Id, item.RuleId); Assert.Empty(f.Delivery.Keys);
    var restored = new ReceiverStore(f.State, f.Delivery); Assert.Equal(rule.Id, restored.Test(Draft()).RuleId);
    Assert.Null(restored.Test(Draft() with { Payload = JsonSerializer.SerializeToElement(new { build = new { state = "Passed" } }) }).RuleId);
    var replay = ((IReceiver)restored).Replay(item.Id); Assert.NotEqual(item.Id, replay.Id); Assert.Equal(item.Id, replay.ReplayedFrom); Assert.Equal(rule.Id, replay.RuleId);
    Assert.Equal(item.Payload?.GetRawText(), replay.Payload?.GetRawText()); Assert.Equal(2, restored.Items().Count); Assert.Empty(f.Delivery.Keys);
  }
  [Fact] public void JsonTextFallbackIsAvailableToExistingIntakesAndMcpSamples() =>
    Assert.True(ReceiverConditions.Matches(new("source", "Build", "{\"state\":\"failed\"}"), [new("state", ReceiverConditionOperation.Is, "failed")]));
}
