using TerminalDeck.App.Views.Settings;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.Core.Tests.Cloud;

// Lane U3: the Bin page's rules (DESIGN-WINDOWS-CLOUD.md section 3) without a screen.
public sealed class CloudBinRulesTests
{
  private static CloudBinLine Line(string id, string what, long at, string device = "Mac mini", bool ai = false, int count = 1) =>
    new(id, [CloudContentsKind.Memory], what, at, device, ai, count);

  private sealed class Reader
  {
    public List<CloudBinLine> Bin = [];
    public int Reads;
    public List<IReadOnlyList<CloudBinLine>> PutBacks = [], Deletes = [];
    public CloudContentsResult Answer = new(0);
    public CloudBinRules Rules() => new(_ => { Reads++; return Task.FromResult<IReadOnlyList<CloudBinLine>>(Bin.ToArray()); },
      lines => { PutBacks.Add(lines); Bin.RemoveAll(l => lines.Any(x => x.Id == l.Id)); return Task.FromResult(Answer with { Done = lines.Count }); },
      lines => { Deletes.Add(lines); Bin.RemoveAll(l => lines.Any(x => x.Id == l.Id)); return Task.FromResult(Answer with { Done = lines.Count }); });
  }

  [Fact] public async Task EmptyBinShowsOneCalmLine()
  {
    var rules = new Reader().Rules(); await rules.RefreshAsync();
    Assert.Empty(rules.Shown()); Assert.Equal(CloudBinRules.Empty, rules.EmptyLine());
  }

  [Fact] public async Task LinesNewestFirstAndNamedByDevice()
  {
    var r = new Reader { Bin = [Line("a", "Lead", 1_000), Line("b", "12 notes in Deck Dev", 5_000, "MacBook Pro", ai: true, count: 12)] };
    var rules = r.Rules(); await rules.RefreshAsync();
    Assert.Equal(["b", "a"], rules.Shown().Select(l => l.Id));
    Assert.Equal("Removed by an AI on MacBook Pro", rules.Shown()[0].Title);
    Assert.Equal("Removed on Mac mini", rules.Shown()[1].Title);
    Assert.Null(rules.EmptyLine());
  }

  [Fact] public async Task SearchLooksAtWhatAndDeviceNeverId()
  {
    var r = new Reader { Bin = [Line("lead-id", "Lead", 1), Line("x", "Notes", 2, "MacBook Pro")] };
    var rules = r.Rules(); await rules.RefreshAsync();
    rules.Search = "macbook"; Assert.Equal(["x"], rules.Shown().Select(l => l.Id));
    rules.Search = "lead-id"; Assert.Empty(rules.Shown()); Assert.Equal(CloudBinRules.NoMatch, rules.EmptyLine());
  }

  [Fact] public async Task PutBackAllIsGreyedWithNothingSelectedAndEveryLineGetsBothMenuActions()
  {
    var r = new Reader { Bin = [Line("a", "Lead", 1), Line("b", "Notes", 2)] };
    var rules = r.Rules(); await rules.RefreshAsync();
    Assert.False(rules.CanPutBackAll([])); Assert.Empty(rules.Menu([]));
    foreach (var line in rules.Shown())
    {
      Assert.True(rules.CanPutBackAll([line]));
      Assert.Equal([CloudBinRules.PutBack, CloudBinRules.DeleteForGood], rules.Menu([line]));
    }
    Assert.Equal([CloudBinRules.PutBack, CloudBinRules.DeleteForGood], rules.Menu(rules.Shown().ToArray()));
  }

  [Fact] public async Task PutBackAllCallsTheReaderOncePerSelection()
  {
    var r = new Reader { Bin = [Line("a", "Lead", 1), Line("b", "Notes", 2), Line("c", "Card", 3)] };
    var rules = r.Rules(); await rules.RefreshAsync();
    var selected = rules.Shown().Where(l => l.Id != "b").ToArray();
    await rules.PutBackAsync(selected);
    Assert.Single(r.PutBacks); Assert.Equal(["c", "a"], r.PutBacks[0].Select(l => l.Id));
    Assert.Empty(r.Deletes);
    Assert.Equal(["b"], rules.Shown().Select(l => l.Id));   // read again after the press
    Assert.Equal(2, r.Reads);
  }

  [Fact] public async Task DeleteForGoodIsOneCallAndAsksOneQuestion()
  {
    var r = new Reader { Bin = [Line("a", "Lead", 1), Line("b", "Notes", 2)] };
    var rules = r.Rules(); await rules.RefreshAsync();
    Assert.Equal("Delete “Lead” for good?", CloudBinRules.DeleteForGoodQuestion([r.Bin[0]]).Title);
    Assert.Equal("Delete 2 removals for good?", CloudBinRules.DeleteForGoodQuestion(rules.Shown()).Title);
    await rules.DeleteForGoodAsync(rules.Shown());
    Assert.Single(r.Deletes); Assert.Equal(2, r.Deletes[0].Count); Assert.Empty(r.PutBacks);
    Assert.Equal(CloudBinRules.Empty, rules.EmptyLine());
  }

  [Fact] public async Task APartlyDoneOrFailedPressLeavesOnePlainLine()
  {
    var r = new Reader { Bin = [Line("a", "Lead", 1)], Answer = new(0, "One item could not be put back.") };
    var rules = r.Rules(); await rules.RefreshAsync();
    await rules.PutBackAsync(rules.Shown()); Assert.Equal("One item could not be put back.", rules.Line);
    var failing = new CloudBinRules(_ => Task.FromResult<IReadOnlyList<CloudBinLine>>([Line("a", "Lead", 1)]), _ => throw new IOException("x"), _ => throw new IOException("x"));
    await failing.RefreshAsync(); await failing.PutBackAsync(failing.Shown());
    Assert.Equal(CloudBinRules.Failed, failing.Line); Assert.False(failing.Working);
  }

  [Fact] public void WhenSaysTodayYesterdayOrTheDate()
  {
    var now = new DateTimeOffset(2026, 11, 15, 12, 0, 0, TimeZoneInfo.Local.GetUtcOffset(new DateTime(2026, 11, 15, 12, 0, 0)));
    Assert.StartsWith("Today, ", CloudBinRules.When(now.AddHours(-1).ToUnixTimeMilliseconds(), now));
    Assert.StartsWith("Yesterday, ", CloudBinRules.When(now.AddDays(-1).ToUnixTimeMilliseconds(), now));
    Assert.Equal(now.AddDays(-5).ToString("d MMM yyyy", System.Globalization.CultureInfo.CurrentCulture), CloudBinRules.When(now.AddDays(-5).ToUnixTimeMilliseconds(), now));
  }
}
