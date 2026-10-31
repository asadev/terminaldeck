using System.Security.Cryptography;
using System.Text.Json;
using TerminalDeck.Core.Storage;
using TerminalDeck.Keeper;
using TerminalDeck.Platform.Windows;

try
{
  if (await TerminalDeck.Platform.Windows.Chats.ChatPipeWorker.TryRunAsync(args)) return 0;
  var worker = Array.IndexOf(args, "--worker");
  if (worker >= 0 && worker != args.Length - 2) throw new ArgumentException();
  var root = AppDataRoot.FromArguments(worker >= 0 ? args[..worker] : args);
  WindowsPrivateDirectory.Ensure(Path.Combine(root.DirectoryPath, "keeper"));
  using var stop = new CancellationTokenSource();
  Console.CancelKeyPress += (_, e) => { e.Cancel = true; stop.Cancel(); };
  if (worker >= 0)
  {
    var key = WorkerPaths.Key(args[worker + 1]);
    var plain = new CurrentUserDpapi(root).Unprotect(File.ReadAllBytes(WorkerPaths.PathFor(root, key, ".launch")));
    WorkerLaunch launch;
    try { launch = JsonSerializer.Deserialize<WorkerLaunch>(plain) ?? throw new IOException(); }
    finally { CryptographicOperations.ZeroMemory(plain); }
    if (launch.Session.CreationKey != key) throw new IOException();
    await new SessionWorkerServer(root, launch, KeeperCredentials.GetOrCreate(root)).RunAsync(stop.Token);
  }
  else
  {
    var executable = Environment.ProcessPath ?? throw new IOException();
    await new WindowsKeeperRuntime(root, executable, WindowsProviderLaunchPlanner.BundledToolsDirectory).RunAsync(stop.Token);
  }
  return 0;
}
catch (OperationCanceledException) { return 0; }
catch (ArgumentException)
{
  Console.Error.WriteLine("Choose one scratch folder with --user-data-dir."); return 64;
}
catch
{
  Console.Error.WriteLine("The Windows keeper could not start. Existing sessions were left alone."); return 78;
}
