using TerminalDeck.Platform.Windows.Chats;
try { return await ChatPipeWorker.TryRunAsync(args) ? 0 : 64; }
catch { Console.Error.WriteLine("The scratch chat worker could not start."); return 78; }
