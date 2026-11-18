#!/usr/bin/env python3
"""Reuse the reviewed B receipt only while every tested source stays byte-identical."""
import datetime, hashlib, io, json, os, pathlib, subprocess, zipfile
ROOT = pathlib.Path(__file__).resolve().parents[3]
SCOPE = 'windows/scripts/windows/ui-check-scope.json'
PROOF = {
    'windows/src/TerminalDeck.App/Views/Browser/BrowserPane.ParityProof.cs',
    'windows/src/TerminalDeck.App/Views/BrowserPane.xaml.cs',
    'windows/src/TerminalDeck.App/Views/ShellWindow.xaml.cs',
}
MACHINERY = {SCOPE, 'windows/scripts/windows/reuse-ui-check.py', '.github/workflows/ci.yml', '.github/workflows/windows-release.yml'}
def command(*args):
    return subprocess.check_output(args, cwd=ROOT).decode().strip()
def require(condition, reason):
    if not condition: raise RuntimeError(reason)
def git(*args): return command('git', *args)
def api(path): return json.loads(command('gh', 'api', f'repos/{repo}/{path}'))
scope = json.loads((ROOT / SCOPE).read_text())
config = scope['reuseFrom']
# These reviewed bounds cannot be expanded merely by editing scope metadata.
expected = dict(runId=44240608454, artifactId=14399596502,
    artifactSha256='20be7b15295096e4b64c12f24850459433addda2f58058a620979c25859a9c14',
    runHead='9518658856e7131819692d3e2fef89e682d0a1a4',
    testedSourceCommit='050cdf0473aaace4e62ae5c357b4aa21f352db76',
    sourceTree='35065a58eece3e52873cc1acc2ce60fb46fa280c',
    proofSourceCommit='2da36690124ca18d29a382ffa20b241c5c4abd90')
require(config == expected, 'Reuse must name the reviewed B proof and original green run')
repo = os.environ.get('GITHUB_REPOSITORY', 'asadev/terminaldeck')
require(repo == 'asadev/terminaldeck', 'Unexpected repository')
latest = git('rev-parse', 'HEAD')
for commit in [config['testedSourceCommit'], config['proofSourceCommit']]:
    if subprocess.run(['git','cat-file','-e',commit+'^{commit}'], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
        subprocess.run(['git','fetch','--no-tags','--depth=1','origin',commit], cwd=ROOT, check=True)
require(git('rev-parse', config['testedSourceCommit']+'^{tree}') == config['sourceTree'], 'Original tested source tree mismatch')
proof_delta = set(git('diff','--name-only',config['testedSourceCommit'],config['proofSourceCommit']).splitlines())
require(proof_delta == PROOF, 'Approved proof commit changed another owner')
changed = set(git('diff','--name-only',config['proofSourceCommit'],latest).splitlines())
require(changed <= MACHINERY, 'New source changes require their own focused checks: '+', '.join(sorted(changed-MACHINERY)))
# A later edit in an allowed proof file is rejected by the proof-commit comparison above.
old_scope = json.loads(git('show', config['testedSourceCommit']+':'+SCOPE))
require({k:v for k,v in scope.items() if k != 'reuseFrom'} == old_scope, 'Focused part/project/class selection changed')
run = api('actions/runs/'+str(config['runId']))
require(run['status']=='completed' and run['conclusion']=='success' and run['head_sha']==config['runHead'] and run['path']=='.github/workflows/ci.yml', 'Original CI run is not the reviewed green run')
artifact = api('actions/artifacts/'+str(config['artifactId']))
require(not artifact['expired'] and artifact['name']=='windows-ui-check' and artifact['workflow_run']['id']==config['runId'] and artifact['digest']=='sha256:'+config['artifactSha256'], 'Original artifact provenance mismatch')
archive = subprocess.check_output(['gh','api',f"repos/{repo}/actions/artifacts/{config['artifactId']}/zip"], cwd=ROOT)
require(hashlib.sha256(archive).hexdigest()==config['artifactSha256'], 'Original artifact ZIP hash mismatch')
with zipfile.ZipFile(io.BytesIO(archive)) as zipped:
    receipts = [name for name in zipped.namelist() if pathlib.PurePosixPath(name).name=='receipt.json']
    require(len(receipts)==1, 'Expected exactly one original receipt')
    original_bytes = zipped.read(receipts[0])
receipt = json.loads(original_bytes)
require(receipt['sourceCommit']==config['testedSourceCommit'] and receipt['outcome']=='passed' and receipt['part']=='B' and receipt['configuration']=='Release' and receipt['platform']=='x64', 'Original receipt identity mismatch')
rows = receipt['tests']
require(len(rows)==len(old_scope['checks']) and sum(row['total'] for row in rows)==62, 'Original test count mismatch')
for row, check in zip(rows, old_scope['checks']):
    selection = '('+'|'.join('FullyQualifiedName~'+name for name in check['names'])+')&Group!=RealPc&Group!=Unix'
    require(row['project']==check['project'] and row['filter']==selection and row['passed']==row['total'] and row['total']>0 and row['failed']==0 and row['skippedOrOther']==0, 'Original test selection/outcome mismatch')
# Preserve the untouched original receipt and its original test paths/counts.
out = ROOT/'windows/.artifacts/windows-check/ui/reused'
out.mkdir(parents=True, exist_ok=False)
(out/'original-receipt.json').write_bytes(original_bytes)
receipt.update(sourceTree=config['sourceTree'], sourceRun=config['runId'], sourceArtifact=config['artifactId'],
    latestSourceCommit=latest, latestSourceTree=git('rev-parse','HEAD^{tree}'), testsRerun=False,
    reusedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(), approvedProofSourceCommit=config['proofSourceCommit'],
    reuseChangedPaths=sorted(changed), originalReceiptSha256=hashlib.sha256(original_bytes).hexdigest())
(out/'receipt.json').write_text(json.dumps(receipt, indent=2)+'\n')
print(f"Reused 62/62 tests from run {config['runId']}; original tested source {config['testedSourceCommit']}; latest source {latest}. No tests rerun.")
