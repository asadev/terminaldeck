#!/usr/bin/env python3
"""Join the reviewed C partial run to only its remaining checks, or validate a UI receipt.

No test is executed here. The immutable ZIP, original receipt/TRX, source tree and
reviewed fixture-only correction are checked before any old pass is retained.
"""
import argparse
import datetime
import hashlib
import io
import json
import os
import pathlib
import re
import subprocess
import xml.etree.ElementTree as ET
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[3]
SCOPE = 'windows/scripts/windows/ui-check-scope.json'
PIN = dict(runId=44244418695, artifactId=14400449087,
    artifactSha256='005ecb222deb43fb142a6974c7093d69afd3c7fafa363155df11f208566af7ab',
    runHead='e603246694fcf7bec88070fd86a2eb420f46c70d',
    testedSourceCommit='288cd69d180ebab6432fa23dbb5fab9e65545867',
    sourceTree='11f471cff3e93013f58f713d6c5f8604e080a2ac',
    correctionCommit='847da8f34ce6aa4cb6727dfab816d8555d2330f1')
MCP = 'TerminalDeck.Core.Tests.Mcp.W12ShellContractTests.'
BUDGET = 'TerminalDeck.Core.Tests.Cloud.CloudTaskBudgetTests.The_existing_shared_token_budget_reaches_the_runtime_field_and_never_widens_from_another_device'
NEW_MCP = MCP + 'SupportedStoreAndCodeAliasPinsUseTheExistingActContract'
CORE = r'tests\TerminalDeck.Core.Tests\TerminalDeck.Core.Tests.csproj'
CHAT = r'tests\TerminalDeck.Chat.Windows.Tests\TerminalDeck.Chat.Windows.Tests.csproj'
SHELL = r'src\TerminalDeck.App\Views\Windows\Tests\TerminalDeck.Shell.Tests.csproj'
FRESH = [dict(project=CORE, names=[NEW_MCP, BUDGET]),
    dict(project=CHAT, names=['TerminalDeck.Chat.Windows.Tests.AgentAddonLaunchTests']),
    dict(project=SHELL, names=['TerminalDeck.App.Shell.SidebarStateTests'])]
FIXTURES = {'windows/tests/TerminalDeck.Core.Tests/Mcp/W12ShellContractTests.cs',
    'windows/tests/TerminalDeck.Core.Tests/Cloud/CloudTaskBudgetTests.cs'}
MACHINERY = {SCOPE, 'windows/scripts/windows/ui-check-evidence.py',
    '.github/workflows/ci.yml', '.github/workflows/windows-release.yml',
    'windows/docs/WINDOWS-C-CHECK-RETENTION-20261118.md'}
FAILED_IDS = {'96eef165-56c9-c40c-5310-40d771a719a4', 'e30a7c6a-595a-a620-830d-4c928b380a96'}


def require(value, reason):
    if not value:
        raise RuntimeError(reason)


def command(*args):
    return subprocess.check_output(args, cwd=ROOT)


def git(*args):
    return command('git', *args).decode().strip()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def select(names):
    return '(' + '|'.join('FullyQualifiedName~' + name for name in names) + ')&Group!=RealPc&Group!=Unix'


def basename(value):
    return re.split(r'[/\\]', value)[-1]


def results(data):
    root = ET.fromstring(data)
    definitions = {}
    for test in root.iter():
        if test.tag.rsplit('}', 1)[-1] != 'UnitTest':
            continue
        method = next((n for n in test.iter() if n.tag.rsplit('}', 1)[-1] == 'TestMethod'), None)
        if method is not None:
            definitions[test.get('id')] = method.get('className', '') + '.' + method.get('name', '')
    rows = [dict(testId=n.get('testId'), testName=n.get('testName'), outcome=n.get('outcome'),
        method=definitions.get(n.get('testId'), '')) for n in root.iter() if n.tag.rsplit('}', 1)[-1] == 'UnitTestResult']
    require(len({r['testId'] for r in rows}) == len(rows), 'Duplicate result identity')
    return rows


def source_bounds():
    for commit in [PIN['testedSourceCommit'], PIN['correctionCommit']]:
        probe = subprocess.run(['git', 'cat-file', '-e', commit + '^{commit}'], cwd=ROOT,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if probe.returncode:
            subprocess.run(['git', 'fetch', '--no-tags', '--depth=1', 'origin', commit], cwd=ROOT, check=True)
    require(git('rev-parse', PIN['testedSourceCommit'] + '^{tree}') == PIN['sourceTree'], 'Original tested tree changed')
    require(set(git('diff', '--name-only', PIN['testedSourceCommit'], PIN['correctionCommit']).splitlines()) == FIXTURES,
        'The reviewed correction must change exactly the two failed fixtures')
    changed = set(git('diff', '--name-only', PIN['correctionCommit'], 'HEAD').splitlines())
    require(changed <= MACHINERY, 'Retained tests cannot cover new product/fixture changes: ' + ', '.join(sorted(changed - MACHINERY)))
    scope = json.loads((ROOT / SCOPE).read_text())
    require(scope == dict(part='C', checks=FRESH, retainFrom=PIN), 'C remainder selection or provenance changed')
    return sorted(changed)


def original(archive):
    require(sha(archive) == PIN['artifactSha256'], 'Original ZIP SHA-256 mismatch')
    with zipfile.ZipFile(io.BytesIO(archive)) as zipped:
        receipts = [p for p in zipped.namelist() if basename(p) == 'receipt.json']
        require(len(receipts) == 1, 'Expected one original receipt')
        receipt_bytes = zipped.read(receipts[0])
        receipt = json.loads(receipt_bytes)
        require(receipt['sourceCommit'] == PIN['testedSourceCommit'] and receipt['part'] == 'C'
            and receipt['configuration'] == 'Release' and receipt['platform'] == 'x64'
            and receipt['outcome'] == 'failed', 'Original receipt identity mismatch')
        old_scope = json.loads(git('show', PIN['testedSourceCommit'] + ':' + SCOPE))
        require(len(receipt['tests']) == 1, 'Original run must stop after Core')
        row = receipt['tests'][0]
        require(row['project'] == CORE and row['filter'] == select(old_scope['checks'][0]['names'])
            and [row[k] for k in ['total', 'passed', 'failed', 'skippedOrOther']] == [155, 153, 2, 0], 'Original selection/count mismatch')
        paths = [p for p in zipped.namelist() if basename(p) == basename(row['trx'])]
        require(len(paths) == 1, 'Original Core TRX missing or ambiguous')
        trx_bytes = zipped.read(paths[0])
    rows = results(trx_bytes)
    passed = [r for r in rows if r['outcome'] == 'Passed']
    failed = [r for r in rows if r['outcome'] == 'Failed']
    require(len(rows) == 155 and len(passed) == 153 and {r['testId'] for r in failed} == FAILED_IDS, 'Original TRX result identities differ')
    require({r['method'] for r in failed} == {MCP + 'RemovedOrUnsupportedOptionsCannotSlipThroughTheSharedContract', BUDGET}, 'Original failed methods differ')
    return receipt_bytes, trx_bytes, passed, failed


def fresh(receipt, folder):
    require(receipt['sourceCommit'] == git('rev-parse', 'HEAD') and receipt['part'] == 'C'
        and receipt['configuration'] == 'Release' and receipt['platform'] == 'x64'
        and receipt['outcome'] == 'passed', 'New receipt is not green for the current source')
    require(len(receipt['tests']) == 3, 'All three remaining project selections are required')
    combined = []
    for row, check, count in zip(receipt['tests'], FRESH, [2, 7, 1]):
        require(row['project'] == check['project'] and row['filter'] == select(check['names'])
            and [row[k] for k in ['total', 'passed', 'failed', 'skippedOrOther']] == [count, count, 0, 0], 'New selection/count mismatch')
        data = (folder / basename(row['trx'])).read_bytes()
        parsed = results(data)
        require(len(parsed) == count and all(r['outcome'] == 'Passed' for r in parsed), 'New TRX does not match its receipt')
        require(all(any(r['method'] == name or r['method'].startswith(name + '.') for name in check['names']) for r in parsed), 'New TRX contains a test outside the remainder')
        combined.extend(parsed)
    require({r['method'] for r in combined if r['method'].startswith((MCP, BUDGET))} == {NEW_MCP, BUDGET}, 'Each corrected method must pass once')
    return combined


def retain(receipt_path):
    changed = source_bounds()
    repo = os.environ.get('GITHUB_REPOSITORY', 'asadev/terminaldeck')
    require(repo == 'asadev/terminaldeck', 'Unexpected repository')
    def api(path):
        return json.loads(command('gh', 'api', 'repos/' + repo + '/' + path))
    run = api('actions/runs/' + str(PIN['runId']))
    require(run['status'] == 'completed' and run['conclusion'] == 'failure' and run['head_sha'] == PIN['runHead']
        and run['path'] == '.github/workflows/ci.yml', 'Original CI provenance mismatch')
    artifact = api('actions/artifacts/' + str(PIN['artifactId']))
    require(not artifact['expired'] and artifact['name'] == 'windows-ui-check' and artifact['workflow_run']['id'] == PIN['runId']
        and artifact['digest'] == 'sha256:' + PIN['artifactSha256'], 'Original artifact provenance mismatch')
    archive = command('gh', 'api', f"repos/{repo}/actions/artifacts/{PIN['artifactId']}/zip")
    old_receipt, old_trx, passed, failed = original(archive)
    current = json.loads(receipt_path.read_text())
    now = fresh(current, receipt_path.parent)
    require(not ({r['testId'] for r in now} & {r['testId'] for r in passed}), 'A previously passed test was rerun')
    prior = receipt_path.parent / 'prior'; prior.mkdir(exist_ok=False)
    (prior / 'artifact.zip').write_bytes(archive)
    (prior / 'receipt.original.json').write_bytes(old_receipt)
    (prior / 'Core.original.trx').write_bytes(old_trx)
    current['retained'] = dict(**PIN, passed=153, excludedFailed=2, results=passed, failedResults=failed,
        originalReceiptSha256=sha(old_receipt), originalTrxSha256=sha(old_trx), sourceChanges=changed,
        artifactFile='prior/artifact.zip', receiptFile='prior/receipt.original.json', trxFile='prior/Core.original.trx',
        retainedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(), testsRerun=False)
    current['combined'] = dict(total=163, passed=163, failed=0, retainedPassed=153, newlyPassed=10,
        originalFailuresCountedAsPasses=False)
    current['sourceTree'] = git('rev-parse', 'HEAD^{tree}')
    receipt_path.write_text(json.dumps(current, indent=2) + '\n')
    validate(receipt_path, current['sourceCommit'])
    print('C receipt: 153 original passes retained + 10 newly passed = 163; no original pass rerun.')


def validate(receipt_path, commit):
    receipt = json.loads(receipt_path.read_text())
    require((receipt.get('latestSourceCommit') or receipt.get('sourceCommit')) == commit and receipt['outcome'] == 'passed', 'Receipt does not cover this exact source commit')
    if 'retained' not in receipt:
        require(all(r['total'] > 0 and r['passed'] == r['total'] and r['failed'] == 0 and r['skippedOrOther'] == 0 for r in receipt['tests']), 'UI receipt contains missing/failed tests')
        return
    require(commit == git('rev-parse', 'HEAD'), 'Validate retained evidence from its exact source checkout')
    changed = source_bounds()
    retained = receipt['retained']
    require(all(retained[k] == v for k, v in PIN.items()) and retained['testsRerun'] is False, 'Retained provenance changed')
    old_receipt, old_trx, passed, failed = original((receipt_path.parent / retained['artifactFile']).read_bytes())
    require((receipt_path.parent / retained['receiptFile']).read_bytes() == old_receipt
        and (receipt_path.parent / retained['trxFile']).read_bytes() == old_trx, 'Preserved original evidence differs')
    require(retained['originalReceiptSha256'] == sha(old_receipt) and retained['originalTrxSha256'] == sha(old_trx)
        and retained['results'] == passed and retained['failedResults'] == failed and retained['passed'] == 153
        and retained['excludedFailed'] == 2 and retained['sourceChanges'] == changed, 'Retained cases or source bounds changed')
    now = fresh(receipt, receipt_path.parent)
    require(not ({r['testId'] for r in now} & {r['testId'] for r in passed}), 'A retained pass was rerun')
    require(receipt['combined'] == dict(total=163, passed=163, failed=0, retainedPassed=153, newlyPassed=10,
        originalFailuresCountedAsPasses=False) and receipt['sourceTree'] == git('rev-parse', 'HEAD^{tree}'), 'Combined counts/tree mismatch')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['preflight', 'retain', 'validate'])
    parser.add_argument('--receipt', type=pathlib.Path)
    parser.add_argument('--root', type=pathlib.Path)
    parser.add_argument('--commit')
    args = parser.parse_args()
    if args.mode == 'preflight':
        source_bounds()
        print('C source and remainder selection match the reviewed fixture-only correction.')
    else:
        candidates = [args.receipt] if args.receipt else list(args.root.rglob('receipt.json')) if args.root else []
        require(len(candidates) == 1, 'Expected exactly one current UI receipt')
        if args.mode == 'retain':
            retain(candidates[0])
        else:
            require(bool(args.commit), 'The exact commit is required for validation')
            validate(candidates[0], args.commit)
            print('UI receipt source, results and retained evidence validated.')
