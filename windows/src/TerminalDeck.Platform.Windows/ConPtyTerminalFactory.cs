using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Channels;
using Microsoft.Win32.SafeHandles;
using TerminalDeck.Core.Platform;

namespace TerminalDeck.Platform.Windows;

// This factory belongs in a durable per-session worker, never in a window.
// Its HPCON cannot survive the owning process dying. The supervisor/worker
// adoption path must be proved before claiming keeper-restart survival.
public sealed class ConPtyTerminalFactory : ITerminalFactory
{
  public ValueTask<ITerminalProcess> StartAsync(ProcessLaunch launch, TerminalSize size, CancellationToken cancellationToken = default)
  {
    cancellationToken.ThrowIfCancellationRequested(); size.Validate();
    if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException();
    if (!Path.IsPathFullyQualified(launch.Executable) || !launch.Executable.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) || !File.Exists(launch.Executable) || !Directory.Exists(launch.WorkingDirectory))
      throw new ArgumentException("Choose an installed Windows executable and an existing folder.");
    var command = WindowsCommandLine.Compose(launch.Executable, launch.Arguments);
    // cmd.exe parses its switches itself, rather than through the CRT argv
    // rules. Quoting /d and /q changes their meaning on Windows.
    if (Path.GetFileName(launch.Executable).Equals("cmd.exe", StringComparison.OrdinalIgnoreCase))
    {
      if (launch.Arguments.Any(a => a is not ("/d" or "/q"))) throw new ArgumentException("Use terminal input for shell commands.");
      command = WindowsCommandLine.Quote(launch.Executable) + " " + string.Join(' ', launch.Arguments);
    }
    var environment = WindowsCommandLine.EnvironmentBlock(launch.Environment);
    // Any terminal can be running Claude Code (an AI session, or `claude` typed in a
    // shell): its quit waits for a sign-in renewal already under way in that folder.
    var renewalFolder = TerminalDeck.Core.Accounts.SignInRenewal.ConfigFolder("claude", launch.Environment);
    return ValueTask.FromResult<ITerminalProcess>(ConPtyProcess.Start(launch.Executable, command, environment, launch.WorkingDirectory, size, renewalFolder));
  }
}

public sealed class ConPtyProcess : ITerminalProcess
{
  private readonly SafeFileHandle process;
  private readonly SafeFileHandle job;
  private readonly SafeFileHandle completionPort;
  private readonly TaskCompletionSource treeExited = new(TaskCreationOptions.RunContinuationsAsynchronously);
  private readonly FileStream input;
  private readonly FileStream output;
  private readonly SemaphoreSlim inputGate = new(1);
  private readonly SemaphoreSlim consoleGate = new(1);
  private readonly Channel<ReadOnlyMemory<byte>> chunks = Channel.CreateBounded<ReadOnlyMemory<byte>>(256);
  private readonly CancellationTokenSource closing = new();
  private readonly TaskCompletionSource pumpDone = new(TaskCreationOptions.RunContinuationsAsynchronously);
  private readonly Task<int> exit;
  private readonly string? renewalFolder;
  private IntPtr console;
  private int reader;
  private int disposed;
  public int ProcessId { get; }
  public int ActiveProcessCount
  {
    get
    {
      if (!Native.QueryInformationJobObject(job, 1, out var accounting, Marshal.SizeOf<Native.JobAccounting>(), IntPtr.Zero)) throw Failure();
      return checked((int)accounting.ActiveProcesses);
    }
  }
  public bool RootExited => exit.IsCompletedSuccessfully;

  private ConPtyProcess(IntPtr console, SafeFileHandle process, SafeFileHandle job, SafeFileHandle completionPort, int pid, SafeFileHandle input, SafeFileHandle output, string? renewalFolder)
  {
    this.renewalFolder = renewalFolder; this.console = console; this.process = process; this.job = job; this.completionPort = completionPort; ProcessId = pid;
    this.input = new FileStream(input, FileAccess.Write, 32768, isAsync: false);
    this.output = new FileStream(output, FileAccess.Read, 32768, isAsync: false);
    exit = WaitForProcessAsync(process);
    new Thread(ObserveJob) { IsBackground = true, Name = "Deck terminal job" }.Start();
    new Thread(Pump) { IsBackground = true, Name = "Deck ConPTY output" }.Start();
  }
  internal static ConPtyProcess Start(string executable, string command, string environment, string cwd, TerminalSize size, string? renewalFolder = null)
  {
    SafeFileHandle? inputRead = null; SafeFileHandle? inputWrite = null; SafeFileHandle? outputRead = null; SafeFileHandle? outputWrite = null;
    SafeFileHandle? process = null; SafeFileHandle? thread = null; SafeFileHandle? job = null; SafeFileHandle? completionPort = null;
    var console = IntPtr.Zero; var attributes = IntPtr.Zero; var environmentPointer = IntPtr.Zero; var attributesReady = false;
    try
    {
      if (!Native.CreatePipe(out inputRead, out inputWrite, IntPtr.Zero, 0) || !Native.CreatePipe(out outputRead, out outputWrite, IntPtr.Zero, 0)) throw Failure();
      if (Native.CreatePseudoConsole(new((short)size.Columns, (short)size.Rows), inputRead, outputWrite, 0, out console) < 0) throw Failure();
      nuint bytes = 0; _ = Native.InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref bytes);
      attributes = Marshal.AllocHGlobal(checked((int)bytes));
      if (!Native.InitializeProcThreadAttributeList(attributes, 1, 0, ref bytes)) throw Failure(); attributesReady = true;
      if (!Native.UpdateProcThreadAttribute(attributes, 0, (IntPtr)0x00020016, console, (nuint)IntPtr.Size, IntPtr.Zero, IntPtr.Zero)) throw Failure();
      // Explicit null standard handles prevent Windows from duplicating a
      // redirected launcher's stdout around ConPTY (even with inherit=false).
      var startup = new Native.StartupInfoEx { StartupInfo = new() { Size = Marshal.SizeOf<Native.StartupInfoEx>(), Flags = 0x00000100 }, AttributeList = attributes };
      environmentPointer = Marshal.StringToHGlobalUni(environment);
      // Suspend until job assignment: descendants cannot escape the owned tree.
      if (!Native.CreateProcess(executable, new StringBuilder(command), IntPtr.Zero, IntPtr.Zero, false, 0x00080000 | 0x00000400 | 0x00000004,
        environmentPointer, cwd, ref startup, out var information)) throw Failure();
      process = new(information.Process, true); thread = new(information.Thread, true);
      job = Native.CreateJobObject(IntPtr.Zero, null);
      if (job.IsInvalid) throw Failure();
      completionPort = Native.CreateIoCompletionPort(new IntPtr(-1), IntPtr.Zero, 0, 1);
      if (completionPort.IsInvalid) throw Failure();
      var association = new Native.CompletionAssociation { Key = new IntPtr(1), Port = completionPort.DangerousGetHandle() };
      if (!Native.SetInformationJobObject(job, 7, ref association, Marshal.SizeOf<Native.CompletionAssociation>()) || !Native.AssignProcessToJobObject(job, process)) throw Failure();
      // Only the durable worker owns this non-inherited handle. Supervisor and
      // window crashes leave it open; worker death closes it and contains every child.
      var limits = new Native.ExtendedJobLimits { Basic = new() { LimitFlags = 0x00002000 } };
      if (!Native.SetInformationJobObject(job, 9, ref limits, Marshal.SizeOf<Native.ExtendedJobLimits>())) throw Failure();
      if (Native.ResumeThread(thread) == uint.MaxValue) throw Failure();
      inputRead.Dispose(); outputWrite.Dispose();
      var result = new ConPtyProcess(console, process, job, completionPort, checked((int)information.ProcessId), inputWrite, outputRead, renewalFolder);
      console = IntPtr.Zero; process = null; job = null; completionPort = null; inputWrite = null; outputRead = null; return result;
    }
    catch
    {
      if (process is not null && !process.IsInvalid) _ = Native.TerminateProcess(process, 1);
      throw new IOException("Windows could not start this terminal. Check the executable and folder.");
    }
    finally
    {
      if (environmentPointer != IntPtr.Zero)
      {
        for (var i = 0; i <= environment.Length; i++) Marshal.WriteInt16(environmentPointer, i * 2, 0);
        Marshal.FreeHGlobal(environmentPointer);
      }
      if (attributesReady) Native.DeleteProcThreadAttributeList(attributes);
      if (attributes != IntPtr.Zero) Marshal.FreeHGlobal(attributes);
      if (console != IntPtr.Zero) Native.ClosePseudoConsole(console);
      inputRead?.Dispose(); inputWrite?.Dispose(); outputRead?.Dispose(); outputWrite?.Dispose(); process?.Dispose(); thread?.Dispose(); job?.Dispose(); completionPort?.Dispose();
    }
  }
  private void Pump()
  {
    try
    {
      while (true)
      {
        var buffer = new byte[32768]; var count = output.Read(buffer, 0, buffer.Length); if (count == 0) break;
        if (ConPtyControlCells.Needed) ConPtyControlCells.Blank(buffer.AsSpan(0, count));
        if (closing.IsCancellationRequested)
        {
          // ClosePseudoConsole emits a final frame. Preserve it when the reader
          // has room, while a stalled reader must never deadlock handle cleanup.
          chunks.Writer.TryWrite(buffer.AsMemory(0, count)); continue;
        }
        try { chunks.Writer.WriteAsync(buffer.AsMemory(0, count), closing.Token).AsTask().GetAwaiter().GetResult(); }
        catch (OperationCanceledException) when (closing.IsCancellationRequested) { chunks.Writer.TryWrite(buffer.AsMemory(0, count)); }
      }
      chunks.Writer.TryComplete();
    }
    catch (IOException) { chunks.Writer.TryComplete(new IOException("The terminal output connection ended.")); }
    finally { pumpDone.TrySetResult(); }
  }
  private void ObserveJob()
  {
    while (Native.GetQueuedCompletionStatus(completionPort, out var message, out var key, out _, uint.MaxValue))
    {
      if (key == IntPtr.Zero) return;
      if (message == 4) { treeExited.TrySetResult(); return; } // ACTIVE_PROCESS_ZERO
    }
    treeExited.TrySetException(Failure());
  }
  public Task WaitForTreeExitAsync(CancellationToken ct = default) => treeExited.Task.WaitAsync(ct);
  public async ValueTask FinishAsync(CancellationToken ct = default)
  {
    await WaitForTreeExitAsync(ct);
    await consoleGate.WaitAsync(ct);
    try
    {
      if (console == IntPtr.Zero) return;
      closing.Cancel(); var owned = console; console = IntPtr.Zero;
      await Task.Run(() => Native.ClosePseudoConsole(owned)); await pumpDone.Task;
    }
    finally { consoleGate.Release(); }
  }
  public IAsyncEnumerable<ReadOnlyMemory<byte>> ReadOutputAsync(CancellationToken cancellationToken = default)
  {
    if (Interlocked.Exchange(ref reader, 1) != 0) throw new InvalidOperationException("The terminal output already has an owner.");
    return chunks.Reader.ReadAllAsync(cancellationToken);
  }
  public async ValueTask WriteAsync(ReadOnlyMemory<byte> bytes, CancellationToken cancellationToken = default)
  {
    await inputGate.WaitAsync(cancellationToken);
    try { ObjectDisposedException.ThrowIf(disposed != 0, this); await input.WriteAsync(bytes, cancellationToken); await input.FlushAsync(cancellationToken); }
    finally { inputGate.Release(); }
  }
  public async ValueTask ResizeAsync(TerminalSize size, CancellationToken cancellationToken = default)
  {
    size.Validate(); await consoleGate.WaitAsync(cancellationToken);
    try { if (console == IntPtr.Zero || Native.ResizePseudoConsole(console, new((short)size.Columns, (short)size.Rows)) < 0) throw Failure(); }
    finally { consoleGate.Release(); }
  }
  public Task<int> WaitForExitAsync(CancellationToken cancellationToken = default) => exit.WaitAsync(cancellationToken);
  public async ValueTask QuitAsync(CancellationToken cancellationToken = default)
  {
    // Ending Claude between its sign-in renewal's server call and save blanks the
    // login (saba-pc, 1 Nov): let a renewal already under way finish first.
    if (console != IntPtr.Zero && !exit.IsCompleted)
      await TerminalDeck.Core.Accounts.SignInRenewal.WaitAsync(renewalFolder, TerminalDeck.Core.Accounts.SignInRenewal.Patience, cancellationToken: cancellationToken);
    await consoleGate.WaitAsync(cancellationToken);
    try
    {
      if (console == IntPtr.Zero) return;
      if (!Native.TerminateJobObject(job, 1)) throw Failure();
      closing.Cancel(); var owned = console; console = IntPtr.Zero;
      await Task.Run(() => Native.ClosePseudoConsole(owned));
      await pumpDone.Task;
      await exit; await treeExited.Task;
    }
    finally { consoleGate.Release(); }
  }
  public async ValueTask DisposeAsync()
  {
    if (Interlocked.Exchange(ref disposed, 1) != 0) return;
    try { await QuitAsync(); }
    finally
    {
      closing.Cancel(); await input.DisposeAsync(); await output.DisposeAsync(); process.Dispose(); job.Dispose(); Native.PostQueuedCompletionStatus(completionPort, 0, IntPtr.Zero, IntPtr.Zero); completionPort.Dispose(); closing.Dispose();
    }
  }
  private sealed class ProcessWaitHandle : WaitHandle
  {
    public ProcessWaitHandle(SafeFileHandle process) { SafeWaitHandle = new(process.DangerousGetHandle(), ownsHandle: false); }
  }
  private static Task<int> WaitForProcessAsync(SafeFileHandle process)
  {
    var done = new TaskCompletionSource<int>(TaskCreationOptions.RunContinuationsAsynchronously); var wait = new ProcessWaitHandle(process);
    var registration = ThreadPool.RegisterWaitForSingleObject(wait, (_, _) =>
    {
      if (Native.GetExitCodeProcess(process, out var code)) done.TrySetResult(unchecked((int)code));
      else done.TrySetException(Failure());
    }, null, Timeout.Infinite, executeOnlyOnce: true);
    _ = done.Task.ContinueWith(_ => { registration.Unregister(null); wait.Dispose(); }, CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
    return done.Task;
  }
  private static IOException Failure() => new("Windows could not complete this terminal operation.");

  private static class Native
  {
    [StructLayout(LayoutKind.Sequential)] internal struct Coord(short x, short y) { public short X = x; public short Y = y; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] internal struct StartupInfo
    {
      public int Size; public IntPtr Reserved; public IntPtr Desktop; public IntPtr Title; public uint X; public uint Y; public uint XSize; public uint YSize; public uint XCount; public uint YCount; public uint Fill; public uint Flags; public short ShowWindow; public short ReservedSize; public IntPtr ReservedBytes; public IntPtr Input; public IntPtr Output; public IntPtr Error;
    }
    [StructLayout(LayoutKind.Sequential)] internal struct StartupInfoEx { public StartupInfo StartupInfo; public IntPtr AttributeList; }
    [StructLayout(LayoutKind.Sequential)] internal struct ProcessInfo { public IntPtr Process; public IntPtr Thread; public uint ProcessId; public uint ThreadId; }
    [StructLayout(LayoutKind.Sequential)] internal struct BasicJobLimits
    { public long ProcessTime; public long JobTime; public uint LimitFlags; public nuint MinimumWorkingSet; public nuint MaximumWorkingSet; public uint ActiveProcessLimit; public nuint Affinity; public uint PriorityClass; public uint SchedulingClass; }
    [StructLayout(LayoutKind.Sequential)] internal struct IoCounters { public ulong ReadOperations; public ulong WriteOperations; public ulong OtherOperations; public ulong ReadBytes; public ulong WriteBytes; public ulong OtherBytes; }
    [StructLayout(LayoutKind.Sequential)] internal struct ExtendedJobLimits
    { public BasicJobLimits Basic; public IoCounters Io; public nuint ProcessMemoryLimit; public nuint JobMemoryLimit; public nuint PeakProcessMemory; public nuint PeakJobMemory; }
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool SetInformationJobObject(SafeFileHandle job, int kind, ref ExtendedJobLimits info, int size);
    [StructLayout(LayoutKind.Sequential)] internal struct CompletionAssociation { public IntPtr Key; public IntPtr Port; }
    [DllImport("kernel32.dll", EntryPoint = "CreateIoCompletionPort", SetLastError = true)] internal static extern SafeFileHandle CreateIoCompletionPort(IntPtr file, IntPtr existing, nuint key, uint threads);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool SetInformationJobObject(SafeFileHandle job, int kind, ref CompletionAssociation info, int size);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool GetQueuedCompletionStatus(SafeFileHandle port, out uint bytes, out IntPtr key, out IntPtr overlapped, uint timeout);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool PostQueuedCompletionStatus(SafeFileHandle port, uint bytes, IntPtr key, IntPtr overlapped);
    [StructLayout(LayoutKind.Sequential)] internal struct JobAccounting { public long TotalUser; public long TotalKernel; public long PeriodUser; public long PeriodKernel; public uint PageFaults; public uint TotalProcesses; public uint ActiveProcesses; public uint TotalTerminated; }
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool CreatePipe(out SafeFileHandle read, out SafeFileHandle write, IntPtr attributes, uint size);
    [DllImport("kernel32.dll")] internal static extern int CreatePseudoConsole(Coord size, SafeFileHandle input, SafeFileHandle output, uint flags, out IntPtr console);
    [DllImport("kernel32.dll")] internal static extern int ResizePseudoConsole(IntPtr console, Coord size);
    [DllImport("kernel32.dll")] internal static extern void ClosePseudoConsole(IntPtr console);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, uint flags, ref nuint size);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, nuint size, IntPtr previous, IntPtr returned);
    [DllImport("kernel32.dll")] internal static extern void DeleteProcThreadAttributeList(IntPtr list);
    [DllImport("kernel32.dll", EntryPoint = "CreateProcessW", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool CreateProcess(string executable, StringBuilder command, IntPtr processSecurity, IntPtr threadSecurity, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint flags, IntPtr environment, string directory, ref StartupInfoEx startup, out ProcessInfo information);
    [DllImport("kernel32.dll", SetLastError = true)] internal static extern uint ResumeThread(SafeFileHandle thread);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool TerminateProcess(SafeFileHandle process, uint code);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool GetExitCodeProcess(SafeFileHandle process, out uint code);
    [DllImport("kernel32.dll", EntryPoint = "CreateJobObjectW", CharSet = CharSet.Unicode, SetLastError = true)] internal static extern SafeFileHandle CreateJobObject(IntPtr attributes, string? name);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool AssignProcessToJobObject(SafeFileHandle job, SafeFileHandle process);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool TerminateJobObject(SafeFileHandle job, uint code);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool QueryInformationJobObject(SafeFileHandle job, int informationClass, out JobAccounting information, int size, IntPtr returned);
  }
}
