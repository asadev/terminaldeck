/**
 * The one method of Electron's `IpcMain` that the core actually uses.
 *
 * Three files had already written this interface out by hand — `wsl.ts` called
 * it `IpcInvokeHandlers`, `remote/machines/ipc.ts` called it `InvokeRegistrar`,
 * and both gave the same reason: narrowing it means the registration can be
 * exercised with an ordinary object instead of `as unknown as IpcMain`, and a
 * cast in a test throws away the very check the test is for. `remote/server.ts`
 * imported the real `IpcMain` type instead, which is what made
 * `registerRemoteIpc` — the largest registration in the app — reachable only
 * from a process that has Electron in it.
 *
 * So the shape moves here and the three of them share it. That is the whole of
 * the "unpick ipcMain" step in `HEADLESS.md`: the headless daemon registers the
 * same handlers, in the same order, against a desk that keeps them in a Map
 * instead of sending them across a process boundary, and the CLI invokes them by
 * the same channel names the preload uses. One implementation, two callers.
 *
 * `src/preload/contract.test.ts` reads the literal `ipcMain.handle('…')` calls
 * out of the sources, so every registrar parameter stays named `ipcMain`.
 */

export interface InvokeRegistrar {
  handle(channel: string, listener: (event: unknown, ...args: unknown[]) => unknown): void
}
