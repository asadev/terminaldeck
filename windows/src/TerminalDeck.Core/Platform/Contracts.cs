using System.Text.Json;

namespace TerminalDeck.Core.Platform;

public interface ISecretStore
{
  ValueTask<byte[]?> ReadAsync(string name, CancellationToken cancellationToken = default);
  ValueTask WriteAsync(string name, ReadOnlyMemory<byte> value, CancellationToken cancellationToken = default);
  ValueTask DeleteAsync(string name, CancellationToken cancellationToken = default);
}

public sealed record ProcessLaunch(string Executable, IReadOnlyList<string> Arguments,
  IReadOnlyDictionary<string, string> Environment, string WorkingDirectory);

public readonly record struct TerminalSize(int Columns, int Rows)
{
  public void Validate()
  {
    if (Columns is < 20 or > 500 || Rows is < 5 or > 200)
      throw new ArgumentOutOfRangeException(nameof(Columns), "Choose a terminal size within 20–500 columns and 5–200 rows.");
  }
}

public interface ITerminalProcess : IAsyncDisposable
{
  int ProcessId { get; }
  IAsyncEnumerable<ReadOnlyMemory<byte>> ReadOutputAsync(CancellationToken cancellationToken = default);
  ValueTask WriteAsync(ReadOnlyMemory<byte> input, CancellationToken cancellationToken = default);
  ValueTask ResizeAsync(TerminalSize size, CancellationToken cancellationToken = default);
  Task<int> WaitForExitAsync(CancellationToken cancellationToken = default);
  ValueTask QuitAsync(CancellationToken cancellationToken = default);
}

public interface ITerminalFactory
{
  ValueTask<ITerminalProcess> StartAsync(ProcessLaunch launch, TerminalSize size, CancellationToken cancellationToken = default);
}

public interface IKeeperConnector
{
  ValueTask<Stream> ConnectAsync(CancellationToken cancellationToken = default);
}

public interface IBrowserSurface : IAsyncDisposable
{
  string TabId { get; }
  Task NavigateAsync(Uri address, CancellationToken cancellationToken = default);
  Task<JsonElement> DevToolsAsync(string method, JsonElement arguments, CancellationToken cancellationToken = default);
}
