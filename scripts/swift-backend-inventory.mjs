import { readdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const declared = {
  'src/main/store.ts': ['macos/TerminalDeckNative/Sources/TerminalDeckNativeCore/NativeStateStore.swift'],
  'src/main/platform/paths.ts': ['macos/TerminalDeckNative/Sources/TerminalDeckNativeCore/NativePlatformPaths.swift'],
  'src/main/chat-transcript.ts': ['macos/TerminalDeckNative/Sources/TerminalDeckNativeCore/NativeChatTranscript.swift', 'macos/TerminalDeckNative/Sources/TerminalDeckNative/NativeTranscriptBackend.swift'],
  'src/main/native-shell/registry.ts': ['macos/TerminalDeckNative/Sources/TerminalDeckNativeCore/NativeChannelRegistry.swift'],
  'src/main/pty-manager.ts': ['macos/TerminalDeckNative/Sources/TerminalDeckBackend/BackendPTYManager.swift'],
  'src/main/account-vault/electron-cipher.ts': ['macos/TerminalDeckNative/Sources/TerminalDeckNativeCore/ChromiumSafeStorageCipher.swift'],
  'src/main/browser-session.ts': ['macos/TerminalDeckNative/Sources/TerminalDeckNative/NativeBrowserDataBridge.swift'],
  'src/main/updates/updater.ts': ['macos/TerminalDeckNative/Sources/TerminalDeckNative/NativeAppUpdater.swift'],
}
// Retired behavior is the explicit Safari/Chrome-extension decision. Other
// modules remain required until their native behavior is actually supplied.
const retired = new Set(['src/main/chrome-import.ts', 'src/main/cookie-import.ts', 'src/main/browser-extensions-ipc.ts'])
function walk(directory) {
  return readdirSync(join(root, directory), { withFileTypes: true }).flatMap((entry) => {
    const path = `${directory}/${entry.name}`
    if (entry.isDirectory()) return entry.name === '__tests__' ? [] : walk(path)
    return /\.tsx?$/.test(path) && !/\.(test|spec)\./.test(path) ? [path] : []
  })
}
const modules = ['src/main', 'src/shared'].flatMap(walk).sort().map((source) => {
  const data = readFileSync(join(root, source))
  const native = (declared[source] ?? []).filter((path) => existsSync(join(root, path)))
  return {
    source, sha256: createHash('sha256').update(data).digest('hex'), lines: data.toString('utf8').split('\n').length,
    status: retired.has(source) ? 'retired-by-safari-decision' : native.length ? 'native-implementation-written-unverified' : 'queued',
    native,
  }
})
const inventory = {
  generatedAt: new Date().toISOString(), scope: 'Mac backend; server backend stays Node',
  evidence: 'Source files and declared equivalents only. No behavioral verification or completion claim.',
  modules: modules.length, lines: modules.reduce((total, row) => total + row.lines, 0),
  nativeDeclared: modules.filter((row) => row.native.length).length,
  retired: modules.filter((row) => row.status.startsWith('retired')).length,
  queued: modules.filter((row) => row.status === 'queued').length,
  files: modules,
}
writeFileSync(join(root, 'macos/backend-inventory.json'), JSON.stringify(inventory, null, 2) + '\n')
console.error(JSON.stringify({ modules: inventory.modules, lines: inventory.lines, nativeDeclared: inventory.nativeDeclared, retired: inventory.retired, queued: inventory.queued }))
