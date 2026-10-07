// Static syntax reader only. Never imports/executes product source or tests.
const fs = require('fs');
const modules = ['../tasks/task-tools', '../tasks/local-task-tools', '../tasks/goal-tools', '../knowledge/knowledge-tools', '../servers/tools'];
const rows = [];
for (const module of modules) {
  const path = `src/main/deck-control/${module}.ts`;
  const source = fs.readFileSync(path, 'utf8');
  const matches = [...source.matchAll(/(?:\bid:\s*|\bconst id\s*=\s*)'((?:tasks|crm|knowledge|servers|hoot)\.[^']+)'/g)];
  function expression(text, key) {
    const match = new RegExp('\\b' + key + '\\s*:').exec(text);
    if (!match) return undefined;
    let index = match.index + match[0].length, depth = 0, quote = null, out = '';
    for (; index < text.length; index++) {
      const c = text[index];
      if (quote) {
        out += c;
        if (c === '\\') { out += text[++index]; continue; }
        if (c === quote) quote = null;
      } else {
        if (c === "'" || c === '"' || c === '`') { quote = c; out += c; }
        else if ('[{('.includes(c)) { depth++; out += c; }
        else if (']})'.includes(c)) { depth--; out += c; }
        else if (c === ',' && depth === 0) return out.trim();
        else if (c === '/' && text[index + 1] === '/') { index = text.indexOf('\n', index); if (index < 0) break; }
        else if (c === '/' && text[index + 1] === '*') { index = text.indexOf('*/', index + 2) + 1; }
        else out += c;
      }
    }
    throw new Error(`Unterminated ${key} metadata in ${path}`);
  }
  function literal(expr) {
    if (expr === 'null') return null;
    if (expr.startsWith('[')) return [...expr.matchAll(/'((?:\\.|[^'\\])*)'/g)].map(m => decode(m[1]));
    const tokens = [...expr.matchAll(/'((?:\\.|[^'\\])*)'|"((?:\\.|[^"\\])*)"/g)];
    let leftover = expr;
    for (const token of tokens) leftover = leftover.replace(token[0], '');
    if (leftover.replace(/[+\s]/g, '') !== '' || tokens.length === 0) throw new Error(`Nonliteral metadata in ${path}: ${expr}`);
    return tokens.map(m => decode(m[1] ?? m[2])).join('');
  }
  function decode(value) {
    return value.replace(/\\(?:u([0-9a-fA-F]{4})|x([0-9a-fA-F]{2})|(.))/g, (_, u, x, c) => {
      if (u || x) return String.fromCharCode(parseInt(u ?? x, 16));
      return ({n:'\n',r:'\r',t:'\t',b:'\b',f:'\f',v:'\v','0':'\0'})[c] ?? c;
    });
  }
  for (let i = 0; i < matches.length; i++) {
    const text = source.slice(matches[i].index, matches[i+1]?.index ?? source.length);
    if (!/\bwire\s*:/.test(text) || !/\binputSchema\s*:/.test(text)) continue;
    const row = { module, id: matches[i][1], wire: literal(expression(text, 'wire')), title: literal(expression(text, 'title')) };
    for (const name of ['index', 'aliases', 'audience', 'keyIndex', 'keyGrant']) {
      const expr = expression(text, name); if (expr !== undefined) row[name] = literal(expr);
    }
    if (!['browser.import', 'browser.extensions'].includes(row.id)) rows.push(row);
  }
}
if (rows.length < 15 || new Set(rows.map(x => x.id)).size !== rows.length) throw new Error('Unexpected active browser descriptor inventory');
const output = `import Foundation\nimport TerminalDeckNativeCore\n\n/// Source task/knowledge/server title/index/audience over real native specs. Schemas, tiers,\n/// handlers and capability descriptions remain their native owners' actual values.\npublic enum BackendDeckCoreSupplementMetadata {\n    public static let retiredIDs: Set<String> = ["browser.import", "browser.extensions"]\n    public static func entries(specs: [BackendMCPTool], requireComplete: Bool = false) throws -> [BackendDeckCoreCatalogueMetadata] {\n        let rows = try NativeRPCValue.parseJSON(Data(literals.utf8)).elements ?? []\n        if requireComplete {\n            let expected = Set(rows.compactMap { $0["id"].string })\n            let actual = Set(specs.filter { !retiredIDs.contains($0.id) }.map(\\.id))\n            guard actual == expected else { throw BackendSessionFailure.missingCapability("the complete source-compatible task/knowledge/server contribution") }\n        }\n        var names = Set<String>()\n        return try specs.filter { !retiredIDs.contains($0.id) }.map { spec in\n            guard names.insert(spec.id).inserted else {\n                throw NativeRPCError.invalidArguments("Supplement metadata needs distinct real tool specs.")\n            }\n            guard let row = rows.first(where: { $0["id"].string == spec.id }), row["wire"].string == spec.wireName else {\n                throw BackendSessionFailure.missingCapability("the source supplementary metadata for \\(spec.id)")\n            }\n            return .init(tool: spec, title: try row["title"].requireString("source supplementary title"),\n                aliases: row["aliases"].elements?.compactMap(\\.string) ?? [], index: row["index"].string,\n                audience: row["audience"].string, keyIndex: row["keyIndex"].string, keyGrant: row["keyGrant"].string)\n        }\n    }\n    /// The source rows are inspectable; they are descriptors, never invented tools.\n    public static func sourceDescriptors() throws -> [NativeRPCValue] { try NativeRPCValue.parseJSON(Data(literals.utf8)).elements ?? [] }\n    private static let literals = ####"""\n${JSON.stringify(rows,null,2)}\n"""####\n}\n`;
const destination = 'macos/TerminalDeckNative/Sources/TerminalDeckBackend/BackendDeckCoreSupplementMetadata.swift';
if (process.argv.includes('--print')) { process.stdout.write(output); process.exit(0); }
fs.writeFileSync(destination, output, { flag: 'wx' });
process.stdout.write(`Written ${rows.length} source supplement descriptors to ${destination}\n`);
