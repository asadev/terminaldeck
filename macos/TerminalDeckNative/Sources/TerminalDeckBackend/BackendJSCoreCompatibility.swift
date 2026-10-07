import Foundation
import Darwin
@preconcurrency import JavaScriptCore
import TerminalDeckNativeCore

/// The bounded Node subset needed by the repository's real protocol sample.
/// Values/functions stay on the helper VM thread; no domain host is imported.
public enum BackendJSCoreCompatibility {
    public static func install(context: JSContext, configuration: BackendJSCoreRuntimeConfiguration,
                               bridge: BackendJSCoreRuntimeBridge, files: BackendJSCoreCompatibilityFiles) throws {
        precondition(Thread.isMainThread)
        let fs: @convention(block) (String, String) -> String = { files.response($0, json: $1) }
        let encode: @convention(block) (String, String) -> String = { text, encoding in
            do {
                guard text.utf8.count <= BackendJSCoreCompatibilityFiles.maximumBytes else { throw BackendJSCoreCompatibilityFailure("ERR_JSCORE_RESOURCE_LIMIT", "Encoded Buffer exceeds its resource limit") }
                return try bytes(text, encoding: encoding).base64EncodedString()
            }
            catch { setException(context, error); return "" }
        }
        let decode: @convention(block) (String, String) -> String = { base64, encoding in
            do {
                guard base64.utf8.count <= BackendJSCoreCompatibilityFiles.maximumBytes * 2 else { throw BackendJSCoreCompatibilityFailure("ERR_JSCORE_RESOURCE_LIMIT", "Decoded Buffer exceeds its resource limit") }
                guard let data = Data(base64Encoded: base64) else { throw BackendJSCoreCompatibilityFailure("EINVAL", "Invalid encoded bytes") }
                return try string(data, encoding: encoding)
            } catch { setException(context, error); return "" }
        }
        let output: @convention(block) (String, Bool) -> Void = { encoded, stderr in
            guard let bytes = Data(base64Encoded: encoded), bytes.count <= BackendJSCoreCompatibilityFiles.maximumBytes else {
                setException(context, BackendJSCoreCompatibilityFailure("ERR_JSCORE_RESOURCE_LIMIT", "Plugin stream write exceeds its resource limit")); return
            }
            if stderr { bridge.stderr(bytes) } else { bridge.output(bytes) }
        }
        let exit: @convention(block) (Double) -> Void = { code in
            guard code.isFinite, code.rounded(.towardZero) == code, code >= 0, code <= 255 else {
                setException(context, BackendJSCoreCompatibilityFailure("ERR_OUT_OF_RANGE", "process.exit code must be an integer from 0 through 255")); return
            }
            bridge.exit(Int32(code))
        }
        let timer: @convention(block) (JSValue, Double, Bool) -> Int = { callback, delay, repeating in
            let id = bridge.schedule(delayMS: delay, repeatMS: repeating ? delay : nil) { _ = callback.call(withArguments: []) }
            if id == 0 { setException(context, BackendJSCoreCompatibilityFailure("ERR_JSCORE_RESOURCE_LIMIT", "The plugin timer resource limit was reached or the VM is stopping")) }
            return id
        }
        let cancel: @convention(block) (Int) -> Void = { bridge.cancelTimer($0) }
        context.setObject(fs, forKeyedSubscript: "__td_fs" as NSString)
        context.setObject(encode, forKeyedSubscript: "__td_encode" as NSString)
        context.setObject(decode, forKeyedSubscript: "__td_decode" as NSString)
        context.setObject(output, forKeyedSubscript: "__td_output" as NSString)
        context.setObject(exit, forKeyedSubscript: "__td_exit" as NSString)
        context.setObject(timer, forKeyedSubscript: "__td_timer" as NSString)
        context.setObject(cancel, forKeyedSubscript: "__td_cancel" as NSString)
        let config = NativeRPCValue.object([.init("cwd", .string(configuration.folderURL.path)), .init("main", .string(configuration.entryURL.path)),
            .init("home", .string(configuration.dataURL.path)), .init("execPath", .string(CommandLine.arguments.first ?? "TerminalDeckJSCoreHelper")),
            .init("env", .object(configuration.environment.sorted(by: { $0.key < $1.key }).map { .init($0.key, .string($0.value)) })),
            .init("pid", .number(Double(getpid()))), .init("arch", .string(architecture))])
        context.evaluateScript("globalThis.__td_configuration = \(config.compact);\n" + source)
        try check(context)
    }
    public static func check(_ context: JSContext) throws {
        if let exception = context.exception {
            let code = exception.forProperty("code")?.toString() ?? "ERR_JSCORE_PLUGIN"
            let message = exception.toString() ?? "The plugin threw an exception"
            context.exception = nil; throw BackendJSCoreCompatibilityFailure(code, message)
        }
    }
    public static func setException(_ context: JSContext, _ error: Error) {
        let failure = error as? BackendJSCoreCompatibilityFailure
        let value = JSValue(newErrorFromMessage: failure?.message ?? error.localizedDescription, in: context)
        value?.setValue(failure?.code ?? "ERR_JSCORE_PLUGIN", forProperty: "code"); context.exception = value
    }
    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x64"
        #endif
    }
    public static func bytes(_ text: String, encoding: String) throws -> Data {
        switch encoding.lowercased().replacingOccurrences(of: "-", with: "") {
        case "utf8": return Data(text.utf8)
        case "utf16le", "ucs2": return text.utf16.reduce(into: Data()) { $0.append(UInt8($1 & 255)); $0.append(UInt8($1 >> 8)) }
        case "ascii", "latin1", "binary": return Data(text.utf16.map { UInt8($0 & 255) })
        case "base64", "base64url":
            var cleaned = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            cleaned = cleaned.filter { $0.isASCII && ($0.isLetter || $0.isNumber || "+/".contains($0)) }
            if cleaned.count % 4 == 1 { cleaned.removeLast() }
            while cleaned.count % 4 != 0 { cleaned.append("=") }
            return Data(base64Encoded: cleaned) ?? Data()
        case "hex":
            var bytes = Data(), digits: [UInt8] = []
            for scalar in text.unicodeScalars {
                let v = scalar.value, digit: UInt8
                if (48...57).contains(v) { digit = UInt8(v - 48) }
                else if (65...70).contains(v) { digit = UInt8(v - 65 + 10) }
                else if (97...102).contains(v) { digit = UInt8(v - 97 + 10) }
                else { break }
                digits.append(digit)
                if digits.count == 2 { bytes.append(digits[0] << 4 | digits[1]); digits.removeAll(keepingCapacity: true) }
            }
            return bytes
        default: throw BackendJSCoreCompatibilityFailure("ERR_UNKNOWN_ENCODING", "Unknown encoding: \(encoding)")
        }
    }
    public static func string(_ data: Data, encoding: String) throws -> String {
        switch encoding.lowercased().replacingOccurrences(of: "-", with: "") {
        case "utf8": return String(decoding: data, as: UTF8.self)
        case "hex": return data.map { String(format: "%02x", $0) }.joined()
        case "base64": return data.base64EncodedString()
        case "base64url": return data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        case "ascii": return String(String.UnicodeScalarView(data.map { UnicodeScalar(Int($0 & 127))! }))
        case "latin1", "binary": return String(String.UnicodeScalarView(data.map { UnicodeScalar(Int($0))! }))
        case "utf16le", "ucs2":
            let bytes = Array(data), units = stride(from: 0, to: bytes.count - bytes.count % 2, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }
            return String(decoding: units, as: UTF16.self)
        default: throw BackendJSCoreCompatibilityFailure("ERR_UNKNOWN_ENCODING", "Unknown encoding: \(encoding)")
        }
    }

    public static let source = #"""
    (function () {
      'use strict';
      const cfg = __td_configuration, MAX = 67108864, modules = Object.create(null);
      function error(code, message) { const value = new Error(message); value.code = code; return value; }
      function unsupported(what) { throw error('ERR_JSCORE_UNSUPPORTED', what + ' is not supported by the JavaScriptCore plugin runtime'); }
      function size(n) { n = Number(n); if (!Number.isInteger(n) || n < 0 || n > MAX) throw error('ERR_JSCORE_RESOURCE_LIMIT', 'Buffer size must be an integer from 0 through ' + MAX); return n; }
      const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
      function from64(text) { const out = []; let bits = 0, value = 0; for (const ch of text) { const digit = alphabet.indexOf(ch); if (digit < 0) continue; value = (value << 6) | digit; bits += 6; if (bits >= 8) { bits -= 8; out.push((value >> bits) & 255); if (out.length > MAX) throw error('ERR_JSCORE_RESOURCE_LIMIT', 'Buffer exceeds its resource limit'); } } return new Buffer(out); }
      function to64(bytes) { let out = ''; for (let i = 0; i < bytes.length; i += 3) { const a = bytes[i], b = bytes[i + 1], c = bytes[i + 2], n = (a << 16) | ((b || 0) << 8) | (c || 0); out += alphabet[(n >> 18) & 63] + alphabet[(n >> 12) & 63] + (b === undefined ? '=' : alphabet[(n >> 6) & 63]) + (c === undefined ? '=' : alphabet[n & 63]); } return out; }
      class Buffer extends Uint8Array {
        static from(value, encoding, length) {
          if (typeof value === 'string') return from64(__td_encode(value, encoding || 'utf8'));
          if (value instanceof ArrayBuffer) { const offset = encoding === undefined ? 0 : size(encoding); const count = length === undefined ? value.byteLength - offset : size(length); size(count); return new Buffer(value, offset, count); }
          if (typeof value === 'number') throw error('ERR_INVALID_ARG_TYPE', 'Buffer.from does not accept a number');
          if (value && value.type === 'Buffer' && Array.isArray(value.data)) value = value.data;
          if (!value || typeof value.length !== 'number') throw error('ERR_INVALID_ARG_TYPE', 'Buffer.from requires a string, ArrayBuffer or array-like value');
          size(value.length); return new Buffer(value);
        }
        static alloc(n, fill = 0, encoding) { const out = new Buffer(size(n)); if (typeof fill === 'string') { const bytes = Buffer.from(fill, encoding); if (!bytes.length && out.length) throw error('ERR_INVALID_ARG_VALUE', 'Buffer fill is empty'); for (let i = 0; i < out.length; i++) out[i] = bytes[i % bytes.length]; } else out.fill(fill); return out; }
        static allocUnsafe(n) { return new Buffer(size(n)); }
        static isBuffer(v) { return v instanceof Buffer; }
        static byteLength(v, encoding) { return typeof v === 'string' ? Buffer.from(v, encoding).length : v.byteLength === undefined ? v.length : v.byteLength; }
        static concat(list, length) { if (!Array.isArray(list)) throw error('ERR_INVALID_ARG_TYPE', 'Buffer.concat requires an array'); const n = size(length === undefined ? list.reduce((n, v) => n + v.length, 0) : length), out = Buffer.alloc(n); let at = 0; for (const bytes of list) { const take = Math.min(bytes.length, n - at); if (take <= 0) break; out.set(bytes.subarray(0, take), at); at += take; } return out; }
        toString(encoding = 'utf8', start = 0, end = this.length) { return __td_decode(to64(this.subarray(Math.max(0, start), Math.min(this.length, end))), encoding); }
        toJSON() { return { type: 'Buffer', data: Array.from(this) }; }
        slice(start = 0, end = this.length) { return this.subarray(start, end); }
        equals(other) { return this.length === other.length && this.every((v, i) => v === other[i]); }
        indexOf(value, offset = 0) { if (typeof value !== 'number') return unsupported('Buffer.indexOf string/Buffer search'); return Uint8Array.prototype.indexOf.call(this, value, offset); }
        lastIndexOf(value, offset = this.length - 1) { if (typeof value !== 'number') return unsupported('Buffer.lastIndexOf string/Buffer search'); return Uint8Array.prototype.lastIndexOf.call(this, value, offset); }
        includes(value, offset = 0) { return this.indexOf(value, offset) !== -1; }
        copy(target, targetStart = 0, start = 0, end = this.length) { const count = Math.max(0, Math.min(end - start, target.length - targetStart)); target.set(this.subarray(start, start + count), targetStart); return count; }
        write(text, offset = 0, length, encoding = 'utf8') { if (typeof offset === 'string') { encoding = offset; offset = 0; } if (typeof length === 'string') { encoding = length; length = undefined; } if (!Number.isInteger(offset) || offset < 0 || offset > this.length || length !== undefined && (!Number.isInteger(length) || length < 0)) throw error('ERR_OUT_OF_RANGE', 'Buffer.write offset/length are out of range'); const bytes = Buffer.from(text, encoding); let count = Math.min(bytes.length, length === undefined ? this.length - offset : length, this.length - offset), normalized = encoding.toLowerCase().replace(/-/g, ''); if (normalized === 'utf8' && count && count < bytes.length) { let first = count - 1; while (first >= 0 && (bytes[first] & 192) === 128) first--; if (first >= 0) { const lead = bytes[first], needed = lead >= 194 && lead <= 223 ? 2 : lead >= 224 && lead <= 239 ? 3 : lead >= 240 && lead <= 244 ? 4 : 1; if (needed > count - first) count = first; } } else if (normalized === 'utf16le' || normalized === 'ucs2') count -= count % 2; this.set(bytes.subarray(0, count), offset); return count; }
      }
      class EventEmitter {
        constructor() { this._events = new Map(); }
        on(name, listener) { if (typeof listener !== 'function') throw error('ERR_INVALID_ARG_TYPE', 'An event listener must be a function'); const list = this._events.get(name) || []; if (list.length >= 1024) throw error('ERR_JSCORE_RESOURCE_LIMIT', 'At most 1024 listeners may wait on one event'); list.push(listener); this._events.set(name, list); return this; }
        addListener(name, listener) { return this.on(name, listener); }
        once(name, listener) { const once = (...args) => { this.off(name, once); listener.apply(this, args); }; once.listener = listener; return this.on(name, once); }
        off(name, listener) { const list = this._events.get(name) || []; const index = list.map(v => v === listener || v.listener === listener).lastIndexOf(true); if (index >= 0) list.splice(index, 1); if (!list.length) this._events.delete(name); return this; }
        removeListener(name, listener) { return this.off(name, listener); }
        removeAllListeners(name) { if (arguments.length) this._events.delete(name); else this._events.clear(); return this; }
        emit(name, ...args) { const list = this._events.get(name) || []; if (!list.length && name === 'error') throw args[0] instanceof Error ? args[0] : error('ERR_UNHANDLED_ERROR', String(args[0])); for (const listener of list.slice()) listener.apply(this, args); return list.length > 0; }
        listeners(name) { return (this._events.get(name) || []).map(v => v.listener || v); }
        rawListeners(name) { return (this._events.get(name) || []).slice(); }
        listenerCount(name) { return (this._events.get(name) || []).length; }
        eventNames() { return Array.from(this._events.keys()); }
      }
      class StringDecoder {
        constructor(encoding = 'utf8') { Buffer.from('', encoding); this.encoding = encoding.toLowerCase().replace(/-/g, ''); if (this.encoding === 'ucs2') this.encoding = 'utf16le'; this.pending = Buffer.alloc(0); }
        write(input) {
          const bytes = this.pending.length ? Buffer.concat([this.pending, Buffer.from(input)]) : Buffer.from(input); this.pending = Buffer.alloc(0); let end = bytes.length;
          if (this.encoding === 'utf8' && end) { let first = end - 1; while (first >= 0 && (bytes[first] & 192) === 128) first--; if (first >= 0) { const lead = bytes[first], needed = lead >= 194 && lead <= 223 ? 2 : lead >= 224 && lead <= 239 ? 3 : lead >= 240 && lead <= 244 ? 4 : 1; if (needed > end - first) end = first; } }
          else if (this.encoding === 'utf16le') { end -= end % 2; if (end >= 2) { const last = bytes[end - 2] | (bytes[end - 1] << 8); if (last >= 55296 && last <= 56319) end -= 2; } }
          else if (this.encoding === 'base64' || this.encoding === 'base64url') end -= end % 3;
          this.pending = Buffer.from(bytes.subarray(end)); return bytes.subarray(0, end).toString(this.encoding);
        }
        end(input) { const prefix = input === undefined ? '' : this.write(input), rest = this.pending.toString(this.encoding); this.pending = Buffer.alloc(0); return prefix + rest; }
      }
      const stdin = new EventEmitter(); stdin.isTTY = false; stdin.readable = true; stdin.destroyed = false;
      let inputDecoder = null, paused = false, queued = [], queuedBytes = 0;
      function emitInput(chunk) { const value = inputDecoder ? inputDecoder.write(chunk) : chunk; if (!inputDecoder || value.length) stdin.emit('data', value); }
      stdin.setEncoding = function (encoding) { if (inputDecoder && inputDecoder.pending.length) return unsupported('changing stdin encoding with a pending multibyte character'); inputDecoder = new StringDecoder(encoding); return this; };
      stdin.pause = function () { paused = true; return this; };
      stdin.resume = function () { paused = false; const old = queued; queued = []; queuedBytes = 0; old.forEach(emitInput); return this; };
      stdin.destroy = function () { this.destroyed = true; queued = []; queuedBytes = 0; this.removeAllListeners(); };
      function writable(stderr) { const stream = new EventEmitter(); stream.isTTY = false; stream.writable = true; stream.write = function (value, encoding, callback) { if (typeof encoding === 'function') { callback = encoding; encoding = undefined; } const bytes = typeof value === 'string' ? Buffer.from(value, encoding || 'utf8') : Buffer.from(value); __td_output(to64(bytes), stderr); if (callback) Promise.resolve().then(callback); return true; }; return stream; }
      const process = new EventEmitter(); process.stdin = stdin; process.stdout = writable(false); process.stderr = writable(true);
      process.env = Object.assign(Object.create(null), cfg.env); process.argv = [cfg.execPath, cfg.main]; process.execPath = cfg.execPath;
      process.pid = cfg.pid; process.platform = 'darwin'; process.arch = cfg.arch; process.version = undefined; process.versions = Object.freeze({ javascriptcore: 'system' });
      process.cwd = () => cfg.cwd; process.chdir = () => unsupported('process.chdir');
      process.exitCode = 0; process.exit = (code = process.exitCode || 0) => { process.emit('exit', code); __td_exit(Number(code)); };
      process.nextTick = () => unsupported('process.nextTick Node priority queue');
      process.kill = () => unsupported('process.kill'); process.dlopen = () => unsupported('Native Node addons'); process.binding = name => unsupported('process.binding(' + name + ')');
      const timers = new Map();
      function schedule(fn, delay, repeat, args) { if (typeof fn !== 'function') throw error('ERR_INVALID_ARG_TYPE', 'A timer callback must be a function'); if (timers.size >= 1024) throw error('ERR_JSCORE_RESOURCE_LIMIT', 'At most 1024 plugin timers may wait'); let id; id = __td_timer(() => { if (!repeat) timers.delete(id); fn(...args); }, Number(delay || 0), repeat); const handle = Object.freeze({ id, unref() { return unsupported('Timer.unref'); }, ref() { return unsupported('Timer.ref'); }, refresh() { return unsupported('Timer.refresh'); }, [Symbol.toPrimitive]() { return id; } }); timers.set(id, handle); return handle; }
      const setTimeout = (fn, delay, ...args) => schedule(fn, delay, false, args), setInterval = (fn, delay, ...args) => schedule(fn, delay, true, args);
      const clearTimeout = value => { const id = Number(value && value.id !== undefined ? value.id : value); if (Number.isInteger(id)) { timers.delete(id); __td_cancel(id); } };
      const timerModule = { setTimeout, setInterval, clearTimeout, clearInterval: clearTimeout, setImmediate: (fn, ...args) => setTimeout(fn, 1, ...args), clearImmediate: clearTimeout };
      const console = {}; for (const method of ['log', 'info', 'warn', 'error', 'debug']) console[method] = (...args) => (method === 'error' || method === 'warn' ? process.stderr : process.stdout).write(args.map(v => typeof v === 'string' ? v : v instanceof Error ? String(v.stack || v) : JSON.stringify(v)).join(' ') + '\n');
      function fsCall(name, params) { const reply = JSON.parse(__td_fs(name, JSON.stringify(params))); if (!reply.ok) throw error(reply.error.code, reply.error.message); return reply.value; }
      const fs = {};
      fs.readFileSync = (path, options) => { if (options && typeof options === 'object' && (options.signal || options.flag && options.flag !== 'r')) return unsupported('fs.readFile signal/non-read flags'); const bytes = from64(fsCall('readFile', { path: String(path) })), encoding = typeof options === 'string' ? options : options && options.encoding; return encoding ? bytes.toString(encoding) : bytes; };
      function writeFile(name, path, value, options) { options = typeof options === 'string' ? { encoding: options } : options || {}; if (options.signal || options.flush) return unsupported('fs.writeFile signal/flush options'); const bytes = typeof value === 'string' ? Buffer.from(value, options.encoding || 'utf8') : Buffer.from(value); fsCall(name, { path: String(path), data: to64(bytes), flag: options.flag, mode: options.mode }); }
      fs.writeFileSync = (path, value, options) => writeFile('writeFile', path, value, options); fs.appendFileSync = (path, value, options) => writeFile('appendFile', path, value, options);
      fs.existsSync = path => { try { return fsCall('exists', { path: String(path) }); } catch (_) { return false; } };
      fs.realpathSync = path => fsCall('realpath', { path: String(path) });
      function stat(path, name, options) { if (options && options.bigint) return unsupported('fs bigint stats'); const value = fsCall(name, { path: String(path) }); for (const name of ['isFile', 'isDirectory', 'isSymbolicLink', 'isBlockDevice', 'isCharacterDevice', 'isFIFO', 'isSocket']) { const yes = value[name]; value[name] = () => yes; } for (const key of ['atime', 'mtime', 'ctime', 'birthtime']) value[key] = new Date(value[key + 'Ms']); return value; }
      fs.statSync = (path, options) => stat(path, 'stat', options); fs.lstatSync = (path, options) => stat(path, 'lstat', options);
      fs.readdirSync = (path, options) => { if (options && typeof options === 'object' && (options.withFileTypes || options.recursive)) return unsupported('fs.readdir withFileTypes/recursive'); const encoding = typeof options === 'string' ? options : options && options.encoding; if (encoding && !['utf8', 'utf-8', 'buffer'].includes(encoding)) return unsupported('fs.readdir encoding ' + encoding); const names = fsCall('readdir', { path: String(path) }); return encoding === 'buffer' ? names.map(name => Buffer.from(name)) : names; };
      fs.mkdirSync = (path, options) => { options = typeof options === 'number' ? { mode: options } : options || {}; return fsCall('mkdir', { path: String(path), recursive: options.recursive === true, mode: options.mode }); };
      fs.rmSync = (path, options = {}) => { fsCall('rm', { path: String(path), recursive: options.recursive === true, force: options.force === true }); }; fs.unlinkSync = path => { fsCall('unlink', { path: String(path) }); };
      fs.renameSync = (path, to) => { fsCall('rename', { path: String(path), to: String(to) }); }; fs.copyFileSync = (path, to, flags = 0) => { if (flags !== 0 && flags !== 1) return unsupported('fs.copyFile clone flags'); fsCall('copyFile', { path: String(path), to: String(to), exclusive: flags === 1 }); };
      fs.constants = Object.freeze({ COPYFILE_EXCL: 1, F_OK: 0, R_OK: 4, W_OK: 2, X_OK: 1 });
      const promises = {}; for (const name of ['readFile', 'writeFile', 'appendFile', 'realpath', 'stat', 'lstat', 'readdir', 'mkdir', 'rm', 'unlink', 'rename', 'copyFile']) { promises[name] = (...args) => Promise.resolve().then(() => fs[name + 'Sync'](...args)); fs[name] = (...args) => { const callback = args.pop(); if (typeof callback !== 'function') throw error('ERR_INVALID_ARG_TYPE', 'fs.' + name + ' requires a callback'); promises[name](...args).then(value => callback(null, value), callback); }; }
      fs.promises = promises;
      function checkedAPI(object, prefix) { return new Proxy(object, { get(target, key) { if (typeof key !== 'string' || key in target || key === 'then') return target[key]; return function () { return unsupported(prefix + '.' + key); }; } }); }
      function normalize(path) { if (typeof path !== 'string') throw error('ERR_INVALID_ARG_TYPE', 'Path must be text'); const absolute = path.startsWith('/'), trailing = path.endsWith('/'), stack = []; for (const part of path.split('/')) { if (!part || part === '.') continue; if (part === '..') { if (stack.length && stack[stack.length - 1] !== '..') stack.pop(); else if (!absolute) stack.push('..'); } else stack.push(part); } let result = (absolute ? '/' : '') + stack.join('/'); if (!result) result = '.'; if (trailing && result !== '/') result += '/'; return result; }
      const path = { sep: '/', delimiter: ':', normalize, isAbsolute: value => typeof value === 'string' && value.startsWith('/'), join: (...values) => normalize(values.filter(v => v !== '').join('/')),
        resolve: (...values) => { let result = ''; for (let i = values.length - 1; i >= -1; i--) { const value = i >= 0 ? values[i] : cfg.cwd; if (typeof value !== 'string') throw error('ERR_INVALID_ARG_TYPE', 'Path must be text'); if (!value) continue; result = value + '/' + result; if (value.startsWith('/')) break; } return normalize(result).replace(/\/$/, '') || '/'; },
        dirname: value => { if (typeof value !== 'string') throw error('ERR_INVALID_ARG_TYPE', 'Path must be text'); value = value.replace(/\/+$/, ''); const slash = value.lastIndexOf('/'); return slash < 0 ? '.' : slash === 0 ? '/' : value.slice(0, slash); },
        basename: (value, suffix) => { const base = value.replace(/\/+$/, '').split('/').pop() || ''; return suffix && base.endsWith(suffix) ? base.slice(0, -suffix.length) : base; },
        extname: value => { const base = value.replace(/\/+$/, '').split('/').pop() || '', dot = base.lastIndexOf('.'); return dot <= 0 ? '' : base.slice(dot); } };
      path.relative = (from, to) => { const a = path.resolve(from).split('/').filter(Boolean), b = path.resolve(to).split('/').filter(Boolean); let common = 0; while (common < a.length && a[common] === b[common]) common++; return a.slice(common).map(() => '..').concat(b.slice(common)).join('/'); }; path.posix = path;
      path.parse = value => ({ root: value.startsWith('/') ? '/' : '', dir: path.dirname(value), base: path.basename(value), ext: path.extname(value), name: path.basename(value, path.extname(value)) });
      path.format = value => { const base = value.base || (value.name || '') + (value.ext || ''); return (value.dir || value.root) ? path.join(value.dir || value.root, base) : base; };
      const readline = { createInterface(options) { if (!options || !options.input || typeof options.input.on !== 'function') throw error('ERR_INVALID_ARG_TYPE', 'readline needs an input stream'); const result = new EventEmitter(), decoder = new StringDecoder('utf8'); let text = '', ended = false; const data = chunk => { text += typeof chunk === 'string' ? chunk : decoder.write(chunk); let at; while ((at = text.indexOf('\n')) >= 0) { const line = text.slice(0, at).replace(/\r$/, ''); if (Buffer.byteLength(line) > 262144) throw error('ERR_JSCORE_RESOURCE_LIMIT', 'readline line exceeds 262144 bytes'); text = text.slice(at + 1); result.emit('line', line); } if (Buffer.byteLength(text) > 262144) throw error('ERR_JSCORE_RESOURCE_LIMIT', 'readline line exceeds 262144 bytes'); }; const end = () => { text += decoder.end(); if (text) result.emit('line', text); text = ''; result.close(); }; result.close = () => { if (ended) return; ended = true; options.input.off('data', data); options.input.off('end', end); result.emit('close'); }; options.input.on('data', data); options.input.on('end', end); return result; } };
      modules.fs = checkedAPI(fs, 'fs'); modules['fs/promises'] = checkedAPI(promises, 'fs.promises'); modules.path = checkedAPI(path, 'path');
      path.posix = modules.path;
      modules.events = EventEmitter; EventEmitter.EventEmitter = EventEmitter; modules.buffer = { Buffer }; modules.process = process; modules.readline = checkedAPI(readline, 'readline');
      modules.timers = timerModule; modules['timers/promises'] = { setTimeout: (delay, value, options) => { if (options !== undefined) return unsupported('timers/promises options'); return new Promise(resolve => setTimeout(resolve, delay, value)); }, setImmediate: (value, options) => { if (options !== undefined) return unsupported('timers/promises options'); return new Promise(resolve => setTimeout(resolve, 1, value)); } };
      modules.string_decoder = { StringDecoder }; modules.console = console;
      globalThis.Buffer = Buffer; globalThis.process = process; globalThis.console = console; globalThis.global = globalThis;
      Object.assign(globalThis, timerModule); globalThis.queueMicrotask = fn => Promise.resolve().then(fn);
      globalThis.__td_builtins = modules;
      globalThis.__td_input = encoded => { if (stdin.destroyed) return; const chunk = from64(encoded); if (paused) { queuedBytes += chunk.length; if (queuedBytes > 8388608) throw error('ERR_JSCORE_RESOURCE_LIMIT', 'Paused stdin exceeds its staging limit'); queued.push(chunk); } else emitInput(chunk); };
      globalThis.__td_end = () => { if (!stdin.destroyed) { if (inputDecoder) { const tail = inputDecoder.end(); if (tail) stdin.emit('data', tail); } stdin.readable = false; stdin.emit('end'); } };
      globalThis.__td_dispose = () => { for (const id of timers.keys()) __td_cancel(id); timers.clear(); stdin.destroy(); process.removeAllListeners(); };
    })();
    """#
}
