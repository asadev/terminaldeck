using System.IO.Pipes;
using System.Security.Cryptography;

// OpenSSH invokes this small helper. The secret travels only from a one-use,
// current-user pipe to ssh's private stdout pipe; never through argv or env.
var name = Environment.GetEnvironmentVariable("TD_SERVER_ASKPASS_PIPE");
if (name is null || !name.StartsWith("td-server-", StringComparison.Ordinal) || name.Length != 42) return 1;
using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
var bytes = new byte[2561];
try
{
  await using var pipe = new NamedPipeClientStream(".", name, PipeDirection.In, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
  await pipe.ConnectAsync(timeout.Token); var length = 0;
  while (length < bytes.Length)
  {
    var n = await pipe.ReadAsync(bytes.AsMemory(length), timeout.Token); if (n == 0) break; length += n;
  }
  if (length is < 1 or > 2560 || bytes.AsSpan(0, length).Contains((byte)'\n') || bytes.AsSpan(0, length).Contains((byte)'\r')) return 1;
  using var output = Console.OpenStandardOutput(); await output.WriteAsync(bytes.AsMemory(0, length), timeout.Token); await output.WriteAsync(new byte[] { 10 }, timeout.Token); return 0;
}
catch (Exception ex) when (ex is IOException or OperationCanceledException or UnauthorizedAccessException) { return 1; }
finally { CryptographicOperations.ZeroMemory(bytes); }
