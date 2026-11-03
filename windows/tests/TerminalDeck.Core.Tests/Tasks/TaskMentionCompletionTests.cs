using TerminalDeck.Core.Tasks;

namespace TerminalDeck.Core.Tests.Tasks;

public sealed class TaskMentionCompletionTests
{
  [Theory]
  [InlineData("Email x@reviewer")]
  [InlineData("Already @[reviewer]")]
  [InlineData("Line @reviewer\n")]
  public void EmailsCompletedTokensAndNewlinesDoNotOpenThePicker(string text) => Assert.Null(TaskMentionCompletion.Find(text, text.Length));
  [Fact] public void ChosenIdentityReplacesTheQueryAndKeepsTextAfterTheCaret()
  {
    var text = "Please @Release re check this"; var caret = "Please @Release re".Length;
    var prefix = TaskMentionCompletion.Find(text, caret)!; Assert.Equal("Release re", prefix.Query);
    var picked = TaskMentionCompletion.Insert(text, prefix, "release-reviewer");
    Assert.Equal("Please @[release-reviewer]  check this", picked.Text); Assert.Equal("Please @[release-reviewer] ".Length, picked.Caret);
  }
  [Fact] public void TheLastMentionWinsAndMalformedIdsCannotBeInserted()
  {
    var text = "@[first] and @sec"; var prefix = TaskMentionCompletion.Find(text, text.Length)!; Assert.Equal("sec", prefix.Query);
    Assert.Throws<ArgumentException>(() => TaskMentionCompletion.Insert(text, prefix, "bad]identity"));
  }
}
