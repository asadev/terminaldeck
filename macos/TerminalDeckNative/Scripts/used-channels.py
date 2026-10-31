#!/usr/bin/env python3
"""Write Sources/TerminalDeckNative/EngineBridgeUsedChannels.swift: every channel the
app's screens name for an EngineBridge call, with the files that name it.

At launch NativeCompositionRoot compares this list with the sealed native routes, so a
renamed or retired channel is reported then, not when someone taps it.

A channel counts when it is the literal first argument of an EngineBridge invoke/send,
or of a helper that passes its own first `_ x: String` parameter straight on to one
(`call("tasks:state")`, `RemoteCall.invoke(...)`, `EngineDeadline.invoke(...)`).
A channel put together at run time, a closure handed in by a caller, an event the app
listens to and a direct registry or host call are not in the list.

    python3 macos/TerminalDeckNative/Scripts/used-channels.py

AAINT2ProductionStartupSmokeTests runs it again and fails while the committed list is stale.
"""
import pathlib
import re

PACKAGE = pathlib.Path(__file__).resolve().parent.parent
SOURCES = PACKAGE / 'Sources' / 'TerminalDeckNative'
OUTPUT = SOURCES / 'EngineBridgeUsedChannels.swift'

BRIDGE_CALLS = {'invoke': 'invoke', 'invokeOrdered': 'invoke', 'invokeNativeValue': 'invoke', 'send': 'send'}
# A file's own `bridge` counts only where it is declared as the EngineBridge.
BRIDGE_ALIAS = re.compile(r'\bbridge\s*(?::\s*EngineBridge\b|=\s*EngineBridge\.shared\b)')
CALL = re.compile(r'((?:[A-Za-z_]\w*\s*\.\s*)*)\b([A-Za-z_]\w*)\(\s*(?:"([^"\\\n]+)"|([A-Za-z_]\w*))\s*[,)]')
FUNC = re.compile(r'\bfunc\s+(\w+)\s*(?:<[^>()]*>)?\(\s*(?:_\s+(\w+)\s*:\s*String\b)?|\binit\s*[?!]?\s*\(')
TYPE = re.compile(r'\b(?:class|struct|enum|actor|extension)\s+(\w+)')
COMMENT_OR_STRING = re.compile(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\\n])*"', re.S)


def code(text):
    """The source with its comments blanked, so an example in a comment is not a call."""
    return COMMENT_OR_STRING.sub(lambda m: m[0] if m[0].startswith('"') else re.sub(r'[^\n]', ' ', m[0]), text)


def last_before(matches, position, depth=None):
    found = None
    for match in matches:
        if match.start() >= position:
            break
        if depth is None or depth(match.start()) == depth(position) - 1:
            found = match
    return found


def depths(text):
    """Brace depth at each position, string contents left out."""
    plain = re.sub(r'"(?:\\.|[^"\\\n])*"', lambda m: ' ' * len(m[0]), text)
    levels, level = [], 0
    for character in plain:
        levels.append(level)
        level += (character == '{') - (character == '}')
    return levels.__getitem__


def calls():
    """Every call with a literal or a plain name as its first argument, and where it sits."""
    found = []
    for path in sorted(SOURCES.rglob('*.swift')):
        if path == OUTPUT:
            continue
        text = code(path.read_text(encoding='utf-8'))
        funcs, types, depth = list(FUNC.finditer(text)), list(TYPE.finditer(text)), depths(text)
        aliased = BRIDGE_ALIAS.search(text) is not None
        for match in CALL.finditer(text):
            receiver = re.sub(r'\s', '', match[1]).removesuffix('.').removeprefix('self.').removesuffix('.shared')
            inside = last_before(funcs, match.start())
            helper = None
            if inside and inside[2] and match[4] == inside[2]:
                owner = last_before(types, inside.start(), depth)
                helper = (path.name, owner[1] if owner else '', inside[1])
            found.append({'file': path.relative_to(SOURCES).as_posix(), 'name': path.name,
                          'bridge': (receiver == 'EngineBridge' or (receiver == 'bridge' and aliased)) and match[2] in BRIDGE_CALLS,
                          'receiver': receiver, 'call': match[2], 'channel': match[3], 'helper': helper})
    return found


def scan():
    sites = calls()
    by_file, by_type = {}, {}

    def kind(site):
        if site['bridge']:
            return BRIDGE_CALLS[site['call']]
        if site['receiver'] == '':
            return by_file.get((site['name'], site['call']))
        return by_type.get((site['receiver'], site['call']))

    # A helper that hands its channel to the bridge (or to another such helper) is a bridge call too.
    grew = True
    while grew:
        grew = False
        for site in sites:
            found = kind(site)
            if found and site['helper'] and (site['helper'][0], site['helper'][2]) not in by_file:
                file, owner, name = site['helper']
                by_file[(file, name)] = found
                if owner:
                    by_type.setdefault((owner, name), found)
                grew = True
    used = {'invoke': {}, 'send': {}}
    for site in sites:
        found = kind(site)
        if found and site['channel']:
            used[found].setdefault(site['channel'], set()).add(site['file'])
    return used


def swift(used):
    def rows(channels):
        return ''.join(f'        ("{name}", "{", ".join(sorted(files))}"),\n' for name, files in sorted(channels.items()))
    return (
        '// Generated by Scripts/used-channels.py from the EngineBridge calls in this target. Do not edit:\n'
        '// run the script again after adding, renaming or removing a channel.\n'
        '// NativeCompositionRoot checks every entry against the sealed native routes at launch.\n'
        'enum EngineBridgeUsedChannels {\n'
        '    static let invokes: [(channel: String, files: String)] = [\n'
        + rows(used['invoke']) +
        '    ]\n'
        '    static let sends: [(channel: String, files: String)] = [\n'
        + rows(used['send']) +
        '    ]\n'
        '}\n'
    )


if __name__ == '__main__':
    used = scan()
    text = swift(used)
    old = OUTPUT.read_text(encoding='utf-8') if OUTPUT.exists() else None
    if text != old:
        OUTPUT.write_text(text, encoding='utf-8')
    print(f"{'updated' if text != old else 'unchanged'}: {len(used['invoke'])} invoke and {len(used['send'])} send channels")
