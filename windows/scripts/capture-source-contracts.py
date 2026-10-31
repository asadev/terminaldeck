#!/usr/bin/env python3
"""Capture contract data, not implementations, from the sibling Mac source.

Runtime-built schemas and action-specific authorization still require the factory
sources named in the output. This is a review aid, not an advertised tool list.
"""
import hashlib
import json
import re
from pathlib import Path

root = Path(__file__).resolve().parents[1]
source = root.parent / 'td-native-shell/macos/TerminalDeckNative/Sources/TerminalDeckBackend'
names = ['BackendDeckCoreCatalogueLiterals.swift', 'BackendDeckCoreEventsToolDefinitions.swift',
         'BackendDeckToolsSessionsCatalogue.swift', 'BackendDeckToolsMachinesCatalogue.swift',
         'BackendDeckToolsAppMetadata.swift']
allowed = {'sessions', 'chats', 'browser', 'accounts', 'mcp', 'remote', 'devices', 'windows', 'usage', 'assets'}
controls = {'agents.controls', 'agents.models', 'agents.set_control'}
rows = []
sources = {}


def add(row, filename):
    if row.get('id', '').split('.')[0] not in allowed and row.get('id') not in controls:
        return
    row = {k: row[k] for k in ['id', 'wire', 'tier', 'inputSchema'] if k in row}
    row['source'] = filename
    rows.append(row)


for filename in names:
    text = (source / filename).read_text()
    sources[filename] = hashlib.sha256(text.encode()).hexdigest()
    for block in re.findall(r'#"""(.*?)"""#', text, re.S):
        try:
            data = json.loads(block)
        except json.JSONDecodeError:
            continue
        if isinstance(data, list):
            for row in data:
                if isinstance(row, dict):
                    add(row, filename)
    if filename == 'BackendDeckToolsSessionsCatalogue.swift':
        pattern = r'Entry\(sourceModule:.*?id: #"([^"]+)"#, wire: #"([^"]+)"#.*?tier: \.(\w+),\s*schemaJSON: #"(.*?)"#\)'
        for ident, wire, tier, schema in re.findall(pattern, text, re.S):
            add(dict(id=ident, wire=wire, tier=tier, inputSchema=json.loads(schema)), filename)
    for line in text.splitlines():
        identity = re.search(r'id: "([^"]+)", wireName: "([^"]+)"', line)
        tier = re.search(r'tier: \.(\w+)', line)
        schema = re.search(r'inputSchema:.*?Data\("((?:[^"\\]|\\.)*)"\.utf8\)', line)
        raw_schema = re.search(r'inputSchema:.*?Data\(#"(.*?)"#\.utf8\)', line)
        if identity and tier and (schema or raw_schema):
            value = json.loads(json.loads('"' + schema[1] + '"')) if schema else json.loads(raw_schema[1])
            add(dict(id=identity[1], wire=identity[2], tier=tier[1], inputSchema=value), filename)

identities = {(row['id'], row['source']) for row in rows}
if len(identities) != len(rows):
    raise SystemExit('Duplicate source rows: review extraction before overwriting.')
output = {
    'note': 'Static source contracts only. No handlers implemented or advertised by this file. Different factories can override a static schema/tier; consult runtimeSources before W1(d).',
    'sourceRevision': 'e700ddbe5b61aaef42b084fbbe50a818ca34c174',
    'sourceHashes': sources,
    'runtimeSources': ['BackendBrowserFactories.swift', 'BackendBrowserScrapingMCP.swift', 'BackendBrowserRecipes.swift',
                       'BackendINT2PhoneAccessMCP.swift', 'BackendDeckCoreSecurityControl.swift', 'BackendMCPTools.swift'],
    'entries': sorted(rows, key=lambda row: (row['id'], row['source']))
}
target = root / 'docs/contracts/deck-tools-static-source.json'
target.parent.mkdir(parents=True, exist_ok=True)
target.write_text(json.dumps(output, indent=2, ensure_ascii=False) + '\n')
print(f'Captured {len(rows)} static contracts for {len(set(row["id"] for row in rows))} distinct tools.')
