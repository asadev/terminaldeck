namespace TerminalDeck.App.Views
{
  public sealed partial class ShellWindow
  {
    // "Sign in to start Hoot": the same in-app sign-in sheet as Settings and the
    // chat pickers, for that AI's chosen account (the app keeps one per AI).
    private async Task SignInForHootAsync(string provider)
    {
      var account = Runtime.Accounts.Preferred(provider) ?? Runtime.Accounts.List(provider).FirstOrDefault()
        ?? throw new InvalidOperationException("Add an account in Coding AIs first.");
      await Runtime.Accounts.SignInAsync(account.Id, Runtime.Root.DirectoryPath);
    }
  }
}
