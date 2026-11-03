import Foundation
import TerminalDeckNativeCore

/// SRV2: keeps Terminal Deck's addresses on an existing Caddy across Caddy's
/// own restarts and reboots, without editing the owner's settings beyond ONE
/// approved line. `--resume` Caddys already reload their saved state; a
/// Caddyfile Caddy gets `import <folder>/*.caddy` (our own folder next to it).
public struct BackendAppsSRV2CaddyKeep: Sendable {
    public let runtime: BackendAppsRuntime
    public let store: BackendAppsStore
    let deployer: BackendAppsSRV2Deployer
    public init(runtime: BackendAppsRuntime, store: BackendAppsStore, routerProbe: BackendAppsSRV2Deployer.RouterProbe? = nil) {
        self.runtime = runtime; self.store = store; self.deployer = BackendAppsSRV2Deployer(runtime: runtime, store: store, routerProbe: routerProbe)
    }

    /// Read-only: the live Caddy process decides (saved router facts give its admin port).
    public func facts(_ serverID: String) async throws -> BackendAppsSRV2Router.Facts {
        let facts = try await deployer.resolvedFacts(serverID, nil)
        guard facts.mode == .caddy || facts.mode == .ownCaddy else { return facts }
        return try await BackendAppsSRV2Router.withPersistence(facts, runtime: runtime, serverID: serverID, prefix: runtime.resourcePrefix)
    }

    public func plan(_ serverID: String) async throws -> NativeAppsRouterPersistence {
        var plan = try await facts(serverID).persistence
        plan.owned = (try? await receipt(serverID)) ?? nil
        return plan
    }

    // MARK: receipt (written ONLY when our own apply adds the line)

    public static let receiptName = ".caddy-import-receipt"
    static func receiptPath(_ runtime: BackendAppsRuntime) -> String { runtime.stateRoot + "/" + receiptName }

    /// The line Terminal Deck itself added, as its server receipt recorded it.
    /// nil when there is none (or it can't be trusted): then nothing is ever undone.
    public func receipt(_ serverID: String) async throws -> NativeAppsRouterPersistence.OwnedImport? {
        let q = BackendAppsRuntime.quote, path = Self.receiptPath(runtime)
        let result = try await runtime.run(serverID, "R=\(q(path)); [ -L \"$R\" ] && exit 66; [ -f \"$R\" ] || exit 44; head -c 4096 -- \"$R\"", timeoutMS: 15_000, maximumBytes: 8192)
        guard result.code == 0, !result.truncated else { return nil }
        return Self.parseReceipt(result.stdout, namespace: runtime.resourcePrefix)
    }

    public static func parseReceipt(_ text: String, namespace: String) -> NativeAppsRouterPersistence.OwnedImport? {
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let equal = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equal])
            guard values[key] == nil else { return nil }
            values[key] = String(line[line.index(after: equal)...])
        }
        guard values["version"] == "1", values["namespace"] == namespace, let file = values["file"], let line = values["line"], let folder = values["folder"],
              let token = values["token"], token.range(of: #"^[0-9a-f]{32}$"#, options: .regularExpression) != nil,
              ["0", "1"].contains(values["newline"] ?? "") else { return nil }
        let owned = NativeAppsRouterPersistence.OwnedImport(file: file, line: line, folder: folder)
        return (try? validate(owned, namespace: namespace)) == nil ? nil : owned
    }

    /// Exact shape only: absolute plain paths, our folder named after the
    /// namespace, and the one line that imports it.
    static func validate(_ owned: NativeAppsRouterPersistence.OwnedImport, namespace: String) throws {
        let path = #"^/[A-Za-z0-9/_.@+-]+$"#
        guard owned.file.range(of: path, options: .regularExpression) != nil, owned.folder.range(of: path, options: .regularExpression) != nil,
              !owned.file.contains("/../"), !owned.folder.contains("/../"), !owned.file.hasSuffix("/.."), !owned.folder.hasSuffix("/.."),
              owned.folder.hasSuffix("/" + namespace), owned.folder.split(separator: "/").count >= 2,
              owned.line == "import " + owned.folder + "/*.caddy" else {
            throw NativeRPCError.invalidArguments("That isn't the line Terminal Deck added.")
        }
    }

    /// Adds exactly the approved line (and our folder). The caller's approval
    /// showed `file` and `line`; a changed server plan is refused.
    public func apply(_ serverID: String, file: String, line: String) async throws -> NativeRPCValue {
        let current = try await facts(serverID)
        let plan = current.persistence
        guard plan.mode == "caddyfile", let folder = current.caddySnippets, let expectedFile = current.caddyfile, let expectedLine = current.importLine else {
            throw NativeRPCError(code: "conflict", message: "This server's Caddy doesn't need the line any more. Check again.")
        }
        guard file == expectedFile, line == expectedLine else {
            throw NativeRPCError(code: "conflict", message: "The server's Caddy settings changed since you looked. Check again before adding the line.")
        }
        if !plan.ready {
            let q = BackendAppsRuntime.quote
            let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let script = Self.applyScript(file: q(file), line: q(line), folder: q(folder), binary: q(current.caddyBinary ?? "/usr/bin/caddy"),
                                          receipt: q(Self.receiptPath(runtime)), token: q(token), namespace: q(runtime.resourcePrefix))
            let result = try await runtime.run(serverID, script, timeoutMS: 60_000, maximumBytes: 4096)
            guard result.code == 0 else {
                if result.code == 65 { throw NativeRPCError(code: "conflict", message: "Caddy couldn't read its settings with the new line, so the file was put back exactly as it was. Nothing changed.") }
                if result.code == 64 { throw NativeRPCError(code: "conflict", message: "A folder with Terminal Deck's name already exists next to the Caddy settings and isn't Terminal Deck's. Nothing changed.") }
                throw NativeRPCError(code: "unavailable", message: "The line could not be added. Check that Terminal Deck has administrator access on this server.")
            }
        }
        // Write every running app's address file now, so a restart right away keeps them.
        var kept = 0, skipped = 0
        var reasons: [NativeRPCValue] = []
        for record in (try? await store.list(serverID)) ?? [] {
            guard let app = record["id"].string, record["kind"].string == "app", record["activeDeploymentId"].string != nil else { continue }
            do {
                let deployer = self.deployer, store = self.store, runtime = self.runtime
                _ = try await store.withLock(serverID, app) {
                    let fresh = try await store.read(serverID, app)
                    try await BackendAppsSRV2Deployer.refuseWhileDeploying(runtime: runtime, store: store, serverID, app, record: fresh)
                    try await deployer.writeRecipe(serverID, app, record: fresh)
                    return try await deployer.route(serverID, app, action: "persist-route")
                }
                kept += 1
            } catch {
                skipped += 1
                reasons.append(.string(app + ": " + ((error as? NativeRPCError)?.message ?? String(describing: error))))
            }
        }
        var note = "Done. Your apps keep their addresses when Caddy restarts."
        if skipped > 0 { note += " \(skipped) app\(skipped == 1 ? " was" : "s were") busy; \(skipped == 1 ? "it keeps its" : "they keep their") address after the next deploy." }
        return BackendAppsValidation.object([("ready", .bool(true)), ("note", .string(note)), ("apps", .number(Double(kept))), ("skipped", .array(reasons))])
    }

    /// Owner-approved change: our folder (with its owner marker), a receipt, then
    /// exactly one line at the end of the Caddyfile. Caddy must read the result;
    /// otherwise the file is put back and the receipt removed. An import that is
    /// already there belongs to the owner: no receipt, nothing claimed.
    /// Never reloads or restarts the owner's Caddy.
    static func applyScript(file: String, line: String, folder: String, binary: String, receipt: String, token: String, namespace: String) -> String {
        """
        set -u
        umask 077
        file=\(file); line=\(line); dir=\(folder); bin=\(binary); R=\(receipt); token=\(token); ns=\(namespace)
        [ -f "$file" ] && [ ! -L "$file" ] || exit 44
        [ "$(realpath -- "$file")" = "$file" ] || exit 44
        parent=$(dirname -- "$dir")
        [ -d "$parent" ] && [ "$(realpath -- "$parent")" = "$parent" ] || exit 44
        case "$dir" in */"$ns") ;; *) exit 44 ;; esac
        rdir=$(dirname -- "$R")
        [ ! -L "$rdir" ] || exit 44
        mkdir -p -- "$rdir" && chmod 700 "$rdir" || exit 45
        [ ! -L "$R" ] || exit 44
        n=$(grep -cxF -- "$line" "$file"); rc=$?
        [ "$rc" -le 1 ] || exit 45
        [ "$n" -eq 0 ] || exit 0
        if [ -e "$dir" ] || [ -L "$dir" ]; then
          [ -d "$dir" ] && [ ! -L "$dir" ] || exit 64
          if [ -f "$dir/.terminaldeck-owner" ] && [ ! -L "$dir/.terminaldeck-owner" ]; then token=$(head -c 64 -- "$dir/.terminaldeck-owner")
          elif [ -n "$(ls -A -- "$dir")" ]; then exit 64; fi
        else
          mkdir -- "$dir" || exit 45
        fi
        case "$token" in *[!0-9a-f]*|'') exit 45 ;; esac
        [ "${#token}" -eq 32 ] || exit 45
        printf '%s\\n' "$token" > "$dir/.terminaldeck-owner" && chmod 600 "$dir/.terminaldeck-owner" || exit 45
        if getent group caddy >/dev/null 2>&1; then chgrp caddy "$dir"; chmod 750 "$dir"; else chmod 755 "$dir"; fi
        if [ ! -e "$dir/README.caddy" ] && [ ! -L "$dir/README.caddy" ]; then
          printf '# Terminal Deck keeps its app addresses in this folder. Remove the import line from the Caddyfile to stop using it.\\n' > "$dir/README.caddy"; chmod 644 "$dir/README.caddy"
        fi
        nl=0; [ -z "$(tail -c 1 -- "$file")" ] || nl=1
        { printf 'version=1\\n'; printf 'namespace=%s\\n' "$ns"; printf 'file=%s\\n' "$file"; printf 'line=%s\\n' "$line"
          printf 'folder=%s\\n' "$dir"; printf 'token=%s\\n' "$token"; printf 'newline=%s\\n' "$nl"; } > "$R.tmp" && mv -f -- "$R.tmp" "$R" || { rm -f -- "$R.tmp"; exit 45; }
        cp -p -- "$file" "$dir/.Caddyfile.before-terminaldeck" || { rm -f -- "$R"; exit 45; }
        if ! { if [ "$nl" = 1 ]; then printf '\\n'; fi; printf '%s\\n' "$line"; } >> "$file"; then cat -- "$dir/.Caddyfile.before-terminaldeck" > "$file"; rm -f -- "$R"; exit 45; fi
        if [ -x "$bin" ] && ! "$bin" adapt --adapter caddyfile --config "$file" >/dev/null 2>&1; then cat -- "$dir/.Caddyfile.before-terminaldeck" > "$file"; rm -f -- "$R"; exit 65; fi
        exit 0
        """
    }

    // MARK: undo (Remove Terminal Deck from this server)

    /// Takes back exactly what our apply added, after the person saw it: the
    /// receipt must still match `expected`. Idempotent; never touches an import
    /// the owner added, never follows links, never rewrites the Caddyfile after
    /// a read error, deletes only files Terminal Deck wrote, removes the folder
    /// only when empty, and keeps the receipt until everything is verified gone.
    public static func undo(runtime: BackendAppsRuntime, serverID: String, expected: NativeAppsRouterPersistence.OwnedImport) async throws -> NativeRPCValue {
        try validate(expected, namespace: runtime.resourcePrefix)
        let q = BackendAppsRuntime.quote
        let script = undoScript(receipt: q(receiptPath(runtime)), file: q(expected.file), line: q(expected.line), folder: q(expected.folder), namespace: q(runtime.resourcePrefix))
        let result = try await runtime.run(serverID, script, timeoutMS: 60_000, maximumBytes: 8192)
        let values = BackendAppsSRV2Recipe.result(result.stdout)
        switch result.code {
        case 0:
            if values["undo"]?.last == "nothing" {
                return BackendAppsValidation.object([("undone", .bool(false)), ("note", .string("Terminal Deck has no added line on record here, so the Caddy settings were left as they are."))])
            }
            var note = values["line"]?.last == "removed" ? "The line Terminal Deck added was taken out of \(expected.file)." : "The line was already gone from \(expected.file)."
            if values["folder"]?.last == "kept-other-files" { note += " Its folder was kept because it holds files Terminal Deck didn't create." }
            return BackendAppsValidation.object([("undone", .bool(true)), ("line", .string(values["line"]?.last ?? "")), ("folder", .string(values["folder"]?.last ?? "")), ("note", .string(note))])
        case 68: throw NativeRPCError(code: "conflict", message: "Terminal Deck's record of the added line changed since you looked. Nothing was removed; check again.")
        case 66: throw NativeRPCError(code: "conflict", message: "The Caddy settings file or Terminal Deck's folder isn't the one Terminal Deck changed (it is a link or belongs to someone else). Nothing was removed.")
        default: throw NativeRPCError(code: "unavailable", message: "The Caddy settings file couldn't be read or written safely, so it was left as it was. Nothing was removed; try again.")
        }
    }

    static func undoScript(receipt: String, file: String, line: String, folder: String, namespace: String) -> String {
        """
        set -u
        umask 077
        export LC_ALL=C
        R=\(receipt); want_file=\(file); want_line=\(line); want_dir=\(folder); ns=\(namespace)
        if [ ! -e "$R" ] && [ ! -L "$R" ]; then echo undo=nothing; exit 0; fi
        [ -f "$R" ] && [ ! -L "$R" ] || { echo error=receipt; exit 66; }
        get() { sed -n "s/^$1=//p" "$R" | head -n 1; }
        f=$(get file); l=$(get line); d=$(get folder); t=$(get token); nl=$(get newline)
        [ "$(get version)" = 1 ] && [ "$(get namespace)" = "$ns" ] || { echo error=receipt; exit 66; }
        [ "$f" = "$want_file" ] && [ "$l" = "$want_line" ] && [ "$d" = "$want_dir" ] || { echo error=changed; exit 68; }
        [ "$l" = "import $d/*.caddy" ] || { echo error=receipt; exit 66; }
        case "$d" in /*/"$ns") ;; *) echo error=receipt; exit 66 ;; esac
        case "$t" in *[!0-9a-f]*|'') echo error=receipt; exit 66 ;; esac
        [ "${#t}" -eq 32 ] || { echo error=receipt; exit 66; }
        # Check everything before changing anything.
        if [ -e "$f" ] || [ -L "$f" ]; then
          [ -f "$f" ] && [ ! -L "$f" ] && [ "$(realpath -- "$f")" = "$f" ] || { echo error=caddyfile-not-regular; exit 66; }
          n=$(grep -cxF -- "$l" "$f"); rc=$?
          [ "$rc" -le 1 ] || { echo error=caddyfile-read; exit 67; }
        else
          n=0
        fi
        if [ -e "$d" ] || [ -L "$d" ]; then
          [ -d "$d" ] && [ ! -L "$d" ] && [ "$(realpath -- "$d")" = "$d" ] || { echo error=folder-not-ours; exit 66; }
          m="$d/.terminaldeck-owner"
          [ -f "$m" ] && [ ! -L "$m" ] && [ "$(head -n 1 -- "$m")" = "$t" ] || { echo error=folder-not-ours; exit 66; }
        fi
        work=$(mktemp -d) || exit 67
        trap 'rm -rf -- "$work"' EXIT
        # 1. The one line, from the Caddyfile (other bytes, mode and owner kept).
        if [ "$n" -gt 0 ]; then
          cat -- "$f" > "$work/before" || { echo error=caddyfile-read; exit 67; }
          total=$(awk 'END { print NR }' "$work/before") || exit 67
          last=$(awk -v target="$l" '$0 == target { last = NR } END { print last + 0 }' "$work/before") || exit 67
          awk -v target="$l" -v last="$last" 'NR != last { print }' "$work/before" > "$work/after" || exit 67
          if [ "$nl" = 1 ] && [ "$last" -eq "$total" ] && [ -s "$work/after" ]; then truncate -s -1 "$work/after" || exit 67; fi
          if [ -n "$(tail -c 1 -- "$work/before")" ] && [ -s "$work/after" ]; then truncate -s -1 "$work/after" || exit 67; fi
          left=$(grep -cxF -- "$l" "$work/after"); [ "$left" -eq $((n - 1)) ] || { echo error=caddyfile-read; exit 67; }
          cat -- "$work/after" > "$f" || { cat -- "$work/before" > "$f"; echo error=caddyfile-write; exit 67; }
          cmp -s -- "$work/after" "$f" || { cat -- "$work/before" > "$f"; echo error=caddyfile-write; exit 67; }
          echo line=removed
        else
          echo line=absent
        fi
        # 2. Files Terminal Deck wrote in its own folder; the folder only when empty.
        if [ -d "$d" ]; then
          kept=0
          for p in "$d"/* "$d"/.[!.]* "$d"/..?*; do
            [ -e "$p" ] || [ -L "$p" ] || continue
            name=${p##*/}
            [ "$name" = .terminaldeck-owner ] && continue
            if [ ! -f "$p" ] || [ -L "$p" ]; then kept=1; continue; fi
            case "$name" in
              .Caddyfile.before-terminaldeck) rm -f -- "$p" || exit 67 ;;
              README.caddy|"$ns"-*.caddy|."$ns"-*.caddy.tmp)
                if head -n 1 -- "$p" | grep -q '^# Terminal Deck'; then rm -f -- "$p" || exit 67; else kept=1; fi ;;
              *) kept=1 ;;
            esac
          done
          if [ "$kept" = 0 ]; then rm -f -- "$d/.terminaldeck-owner" && rmdir -- "$d" || { echo error=folder; exit 67; }; echo folder=removed
          else echo folder=kept-other-files; fi
        else
          echo folder=absent
        fi
        # 3. The receipt goes last, only after everything above is verified.
        rm -f -- "$R" || exit 67
        echo receipt=removed
        echo undo=done
        """
    }
}
