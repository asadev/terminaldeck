using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Keeper;

// The OS releases the lease on a keeper crash. Its successor may observe the
// same saved runs, but a second live keeper cannot watch/post their results.
public sealed class TaskCoordinatorLease : IDisposable
{
  private readonly FileStream file;
  public TaskCoordinatorLease(AppDataRoot root)
  {
    var directory = Path.Combine(root.DirectoryPath, "keeper"); Directory.CreateDirectory(directory);
    try { file = new(Path.Combine(directory, "task-coordinator.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
    catch (IOException) { throw new IOException("Another Keeper is already following tasks in this data folder."); }
  }
  public void Dispose() => file.Dispose();
}
