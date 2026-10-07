// Static source reader only: no source module imports, application execution,
// build, typecheck or test. Kept so metadata can be compared at integration.
const fs = require('fs');
const ts = require('../node_modules/typescript/lib/typescript.js');
const modules = ['files-tools', 'project-tools', 'asset-tools', 'tour-tool'];
const defaults = { BRAND: { name: 'Terminal Deck', assistant: 'Hoot' }, MAX_TOUR_STOPS: 12, MAX_QUOTE_CHARS: 600, MAX_NOTE_CHARS: 160 };
const all = [];
for (const module of modules) {
  const path = `src/main/deck-control/${module}.ts`;
  const source = ts.createSourceFile(path, fs.readFileSync(path, 'utf8'), ts.ScriptTarget.Latest, true);
  const env = { ...defaults }, nodes = new Map();
  function collect(node) {
    if (ts.isVariableDeclaration(node) && ts.isIdentifier(node.name) && node.initializer) nodes.set(node.name.text, node.initializer);
    ts.forEachChild(node, collect);
  }
  collect(source);
  function evaluate(node) {
    if (ts.isStringLiteralLike(node)) return node.text;
    if (ts.isNumericLiteral(node)) return Number(node.text);
    if (node.kind === ts.SyntaxKind.TrueKeyword) return true;
    if (node.kind === ts.SyntaxKind.FalseKeyword) return false;
    if (node.kind === ts.SyntaxKind.NullKeyword) return null;
    if (ts.isIdentifier(node)) {
      if (Object.hasOwn(env, node.text)) return env[node.text];
      if (!nodes.has(node.text)) throw new Error(`unresolved ${node.text}`);
      return env[node.text] = evaluate(nodes.get(node.text));
    }
    if (ts.isParenthesizedExpression(node) || ts.isAsExpression(node) || ts.isSatisfiesExpression(node)) return evaluate(node.expression);
    if (ts.isPropertyAccessExpression(node)) return evaluate(node.expression)[node.name.text];
    if (ts.isArrayLiteralExpression(node)) return node.elements.map(evaluate);
    if (ts.isObjectLiteralExpression(node)) {
      const out = {};
      for (const p of node.properties) {
        if (!ts.isPropertyAssignment(p)) throw new Error(`unsupported property ${p.getText(source)}`);
        out[p.name.text] = evaluate(p.initializer);
      }
      return out;
    }
    if (ts.isTemplateExpression(node)) return node.head.text + node.templateSpans.map(s => String(evaluate(s.expression)) + s.literal.text).join('');
    if (ts.isBinaryExpression(node)) {
      const a = evaluate(node.left), b = evaluate(node.right);
      switch(node.operatorToken.kind) {
        case ts.SyntaxKind.PlusToken: return a + b;
        case ts.SyntaxKind.AsteriskToken: return a * b;
        case ts.SyntaxKind.SlashToken: return a / b;
        default: throw new Error(`unsupported operator ${node.getText(source)}`);
      }
    }
    if (ts.isCallExpression(node) && node.expression.getText(source) === 'Math.floor') return Math.floor(evaluate(node.arguments[0]));
    throw new Error(`unsupported expression ${node.getText(source)}`);
  }
  function visit(node) {
    if (ts.isObjectLiteralExpression(node)) {
      const props = Object.fromEntries(node.properties.filter(ts.isPropertyAssignment).map(p => [p.name.text, p.initializer]));
      if (props.id && props.wire && props.inputSchema) {
        const item = { module };
        for (const key of ['id','wire','tier','title','description','index','inputSchema']) if (props[key]) item[key] = evaluate(props[key]);
        all.push(item);
      }
    }
    ts.forEachChild(node, visit);
  }
  visit(source);
}
if (all.length !== 19 || new Set(all.map(x => x.id)).size !== all.length) throw new Error('unexpected source catalogue');
const output = `import Foundation\nimport TerminalDeckNativeCore\n\n/// Verbatim metadata statically extracted from the four source tool factories.\npublic enum BackendDeckToolsCatalogue {\n    public struct Entry: Sendable {\n        public let module: String, title: String\n        public let index: String?\n        public let spec: BackendMCPTool\n    }\n    public static func entries() throws -> [Entry] {\n        let raw = try NativeRPCValue.parseJSON(Data(metadata.utf8))\n        return try (raw.elements ?? []).map { item in\n            guard let tier = BackendMCPTier(rawValue: item["tier"].string ?? "") else { throw NativeRPCError.malformed("Invalid source tool tier") }\n            return Entry(module: item["module"].string!, title: item["title"].string!, index: item["index"].string,\n                spec: try BackendMCPTool(id: item["id"].string!, wireName: item["wire"].string!, description: item["description"].string!, inputSchema: item["inputSchema"], tier: tier))\n        }\n    }\n    private static let metadata = ####"""\n${JSON.stringify(all,null,2)}\n"""####\n}\n`;
const destination = 'macos/TerminalDeckNative/Sources/TerminalDeckBackend/BackendDeckToolsCatalogue.swift';
fs.writeFileSync(destination, output, { flag: 'wx' });
process.stdout.write(`Written ${all.length} metadata entries to ${destination}\n`);
