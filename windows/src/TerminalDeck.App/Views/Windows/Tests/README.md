Run the layout tests with outputs outside the WinUI source tree:

    ~/.dotnet/dotnet test src/TerminalDeck.App/Views/Windows/Tests/TerminalDeck.Shell.Tests.csproj --artifacts-path /tmp/td-p-shell-tests

The Windows app uses default recursive C# globs. Do not leave a nested test project's generated `obj/*.cs` under its sources before building the app.
