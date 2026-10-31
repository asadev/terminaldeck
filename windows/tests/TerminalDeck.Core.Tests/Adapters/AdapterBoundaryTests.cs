using System.Text;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Sessions;

namespace TerminalDeck.Core.Tests.Adapters;

public sealed class AdapterBoundaryTests
{
  [Theory] [InlineData("", "\"\"")] [InlineData("plain", "\"plain\"")] [InlineData("with spaces", "\"with spaces\"")] [InlineData("a\"b", "\"a\\\"b\"")]
  public void WindowsArgumentsPreserveEmptySpacesAndQuotes(string argument, string expected) => Assert.Equal(expected, WindowsCommandLine.Quote(argument));
  [Fact] public void WindowsArgumentsDoubleTrailingSlashesAndNeverInvokeAShell()
  {
    Assert.Equal('"' + @"C:\work\\" + '"', WindowsCommandLine.Quote(@"C:\work\"));
    var command = WindowsCommandLine.Compose(@"C:\Program Files\provider.exe", ["$(literal)", "a&b", "`literal`"]);
    Assert.Contains("\"$(literal)\"", command); Assert.DoesNotContain("cmd.exe", command);
    Assert.Throws<ArgumentException>(() => WindowsCommandLine.Compose("provider.exe", ["bad\0argument"]));
  }
  [Fact] public void WindowsEnvironmentIsSortedDoubleNullTerminatedAndRejectsAmbiguity()
  {
    Assert.Equal("A=one\0Z=two\0\0", WindowsCommandLine.EnvironmentBlock(new Dictionary<string, string> { ["Z"] = "two", ["A"] = "one" }));
    Assert.Throws<ArgumentException>(() => WindowsCommandLine.EnvironmentBlock(new Dictionary<string, string> { ["Path"] = "a", ["PATH"] = "b" }));
    Assert.Throws<ArgumentException>(() => WindowsCommandLine.EnvironmentBlock(new Dictionary<string, string> { ["A=B"] = "x" }));
  }
  [Fact] public async Task KeeperClientAuthenticatesHelloAndPinsMutationsToThatInstance()
  {
    var instance = Guid.NewGuid(); var connector = new ScriptedConnector(); connector.Queue(await Frames(new KeeperResponse(Hello: new(2, "test", instance)))); connector.Queue(await Frames(new KeeperResponse(Success: true)));
    var client = new KeeperClient(connector, Encoding.UTF8.GetBytes(new string('x', 32)));
    await client.HelloAsync(); await client.WriteAsync("s", new byte[] { 1 });
    using var written = new MemoryStream(connector.Opened[1].Written.ToArray()); var request = await KeeperWire.ReadAsync<KeeperRequest>(written);
    Assert.Equal(instance, request.Instance); Assert.Equal("write", request.Operation); Assert.Equal(2, connector.Opened.Count); Assert.All(connector.Opened, s => Assert.True(s.Closed));
  }
  [Fact] public async Task KeeperClientNeverRetriesAnAmbiguousWriteOrStartsWithoutHello()
  {
    var connector = new ScriptedConnector(); connector.Queue(await Frames(new KeeperResponse(Hello: new(2, "test", Guid.NewGuid())))); connector.Queue([]);
    var client = new KeeperClient(connector, Encoding.UTF8.GetBytes(new string('x', 32)));
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await client.WriteAsync("s", new byte[] { 1 })); Assert.Empty(connector.Opened);
    await client.HelloAsync(); await Assert.ThrowsAsync<EndOfStreamException>(async () => await client.WriteAsync("s", new byte[] { 1 })); Assert.Equal(2, connector.Opened.Count);
  }
  [Fact] public async Task KeeperClientRefusesAnOlderKeeperWithoutReplacingIt()
  {
    var connector = new ScriptedConnector(); connector.Queue(await Frames(new KeeperResponse(Hello: new(1, "old", Guid.NewGuid())))); var client = new KeeperClient(connector, Encoding.UTF8.GetBytes(new string('x', 32)));
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await client.HelloAsync()); Assert.Single(connector.Opened);
  }
  [Fact] public async Task KeeperClientAttachesSnapshotBeforeStrictlyLaterSessionEvents()
  {
    var instance = Guid.NewGuid(); var definition = new SessionDefinition(Guid.NewGuid().ToString(), "shell", "C:\\work", "A"); var row = new SessionRecord(definition, "create-key", SessionState.Running, "opaque-lease");
    var connector = new ScriptedConnector(); connector.Queue(await Frames(new KeeperResponse(Hello: new(2, "test", instance)))); connector.Queue(await Frames(new KeeperResponse(Snapshot: new(5, row, "before")), new KeeperResponse(Event: new(6, definition.Id, "data", "after")), new KeeperResponse(Event: new(6, definition.Id, "data", "duplicate"))));
    var client = new KeeperClient(connector, Encoding.UTF8.GetBytes(new string('x', 32))); await client.HelloAsync(); await using var attachment = await client.AttachAsync(definition.Id);
    Assert.Equal("before", attachment.Snapshot.Replay); await using var events = attachment.Events().GetAsyncEnumerator(); Assert.True(await events.MoveNextAsync()); Assert.Equal("after", events.Current.Text);
    await Assert.ThrowsAsync<IOException>(async () => await events.MoveNextAsync());
  }
  [Fact] public async Task KeeperClientRejectsWrongSnapshotIdentityAndRedactsPeerError()
  {
    var connector = new ScriptedConnector(); connector.Queue(await Frames(new KeeperResponse(Hello: new(2, "test", Guid.NewGuid())))); connector.Queue(await Frames(new KeeperResponse(Error: "synthetic-private-text")));
    var client = new KeeperClient(connector, Encoding.UTF8.GetBytes(new string('x', 32))); await client.HelloAsync(); var error = await Assert.ThrowsAsync<IOException>(async () => await client.AttachAsync("s")); Assert.DoesNotContain("synthetic-private-text", error.Message); Assert.True(connector.Opened[1].Closed);
  }
  private static async Task<byte[]> Frames(params KeeperResponse[] responses)
  {
    using var stream = new MemoryStream(); foreach (var response in responses) await KeeperWire.WriteAsync(stream, response, response: true); return stream.ToArray();
  }
  private sealed class ScriptedConnector : IKeeperConnector
  {
    private readonly Queue<byte[]> responses = [];
    public List<ScriptedStream> Opened { get; } = [];
    public void Queue(byte[] bytes) => responses.Enqueue(bytes);
    public ValueTask<Stream> ConnectAsync(CancellationToken ct = default) { var stream = new ScriptedStream(responses.Dequeue()); Opened.Add(stream); return ValueTask.FromResult<Stream>(stream); }
  }
  private sealed class ScriptedStream(byte[] response) : Stream
  {
    private readonly MemoryStream input = new(response);
    public MemoryStream Written { get; } = new();
    public bool Closed { get; private set; }
    public override bool CanRead => true; public override bool CanWrite => true; public override bool CanSeek => false;
    public override long Length => throw new NotSupportedException(); public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
    public override int Read(byte[] buffer, int offset, int count) => input.Read(buffer, offset, count);
    public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct = default) => input.ReadAsync(buffer, ct);
    public override void Write(byte[] buffer, int offset, int count) => Written.Write(buffer, offset, count);
    public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken ct = default) => Written.WriteAsync(buffer, ct);
    public override void Flush() { } public override Task FlushAsync(CancellationToken ct) => Task.CompletedTask;
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException(); public override void SetLength(long length) => throw new NotSupportedException();
    protected override void Dispose(bool disposing) { Closed = true; input.Dispose(); base.Dispose(disposing); }
  }
}
