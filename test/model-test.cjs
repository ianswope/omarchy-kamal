const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const model = {};
vm.createContext(model);
vm.runInContext(fs.readFileSync(path.join(__dirname, '../Model.js'), 'utf8'), model);

const sha = 'a'.repeat(40);
const app = {
  name: 'Test', repo: '/tmp/repo', env: '/tmp/env', branch: 'main',
  deployHosts: ['web', 'jobs'], configError: '',
  local: {headSha: sha, headShort: sha.slice(0, 7), currentBranch: 'feature',
    headSubject: 'Actual change', toDeploy: 1, removed: 2, behind: 9, unpushed: 1},
  secrets: {checked: true, missing: [], error: ''},
  deployed: {versions: [sha], roles: []}
};
const preview = model.deployPreview(app);
assert.match(preview, /feature.*aaaaaaa/);
assert.match(preview, /1 added commit\(s\), 2 removed/);
assert.match(preview, /differs from tracked branch main/);
assert.doesNotMatch(preview, /9.*commit|Nothing new/);
assert.equal(model.deployBlockReason(app), '');
for (const secrets of [
  {checked: false, missing: [], error: ''},
  {checked: false, missing: [], error: 'unreadable'},
  {checked: true, missing: ['TOKEN'], error: ''},
  {checked: true, missing: [], error: 'parse failure'}
]) {
  assert.notEqual(model.deployBlockReason({...app, secrets}), '');
}
assert.notEqual(model.deployBlockReason({...app, local: {headSha: '$(touch /tmp/no)'}}), '');
console.log('ok - preview uses checkout changes; failed or missing secrets checks block deployment');

const role = {name: 'web', available: 1, expected: 2, running: 1,
  missing: 0, unknown: 1, hosts: [{host: 'second', error: 'SSH failed', running: 0}]};
let status = {ok: true, configured: true, apps: [{...app, deployed: {roles: [role], versions: [sha]}}]};
assert.equal(model.health(status).level, 'warn');
assert.equal(model.deadRoles(status.apps[0]).length, 0);
assert.equal(model.attentionCount(status), 1);
assert.match(model.rolesSummary(status.apps[0]), /1\/2.*1 unknown/);
role.missing = 1; role.unknown = 0; role.hosts[0].error = '';
assert.equal(model.health(status).level, 'critical');
status.apps[0].deployed = {roles: [], versions: [sha, 'b'.repeat(40)]};
assert.equal(model.health(status).level, 'warn');
assert.match(model.driftText(status.apps[0]), /mixed/);
console.log('ok - unknown hosts, confirmed missing instances and mixed revisions have distinct status');

const malicious = '<img src="https://invalid/">&\u202e';
const parsed = model.parseStatus(JSON.stringify({ok: true, configured: true, apps: [{
  ...app, name: malicious, deployHosts: [malicious],
  local: {...app.local, headSubject: malicious, currentBranch: malicious},
  deployed: {versions: [malicious, sha], roles: [{...role, name: malicious,
    hosts: [{host: malicious, error: malicious, running: 0}]}]}
}]}));
assert.doesNotMatch(model.deployPreview(parsed.apps[0]).split('\n\n')[0], /[<>&\u202e]/);
assert.doesNotMatch(JSON.stringify(model.health(parsed)), /[<>&\u202e]/);
console.log('ok - new preview and fault fields neutralize markup before shared QML components');

for (const phase of ['launching', 'running', 'verifying']) assert.equal(model.deploymentActive({phase}), true);
for (const phase of ['succeeded', 'failed', 'interrupted', 'incomplete']) assert.equal(model.deploymentActive({phase}), false);
assert.match(model.deploymentLabel({phase: 'incomplete'}), /incomplete/);
assert.doesNotMatch(model.deploymentDetail({phase: 'failed', sha, reason: malicious}), /[<>&\u202e]/);
console.log('ok - deployment phases remain distinct and result text is sanitized');
