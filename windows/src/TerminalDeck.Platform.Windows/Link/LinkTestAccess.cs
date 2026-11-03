using System.Runtime.CompilerServices;

// The Windows tests call the native engine's entry points directly (stale handles must be harmless — Security W8).
[assembly: InternalsVisibleTo("TerminalDeck.Windows.Tests")]
