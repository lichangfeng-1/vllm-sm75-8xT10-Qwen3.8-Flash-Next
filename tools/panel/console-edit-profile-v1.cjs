// console-edit-profile-v1.cjs — 带护栏地改面板 profile：setenv / rmenv / setarg
// 用法: node console-edit-profile-v1.cjs <profileId> setenv  <KEY> <value>
//       node console-edit-profile-v1.cjs <profileId> rmenv   <KEY>
//       node console-edit-profile-v1.cjs <profileId> setarg  <--flag> <newValue>
// 护栏：① 引擎在跑就拒绝（面板自己也会拒，这里提前）；② setarg 要求该 flag 已存在且只替换其值，
//       不接受"顺手加一个参数"；③ ENV KEY 只允许大写；④ POST 后回读整档做逐项比对，
//       除本次声明的那一处改动外任何字段/任何 argv 位置变了都算意外 ⇒ 立刻 POST 原档回滚并非零退出。
// 密钥：token 只进请求头；env 里名字含 key/token/secret/password 的值一律脱敏。
const http = require('http');
const fs = require('fs');

const BASE = process.env.CONSOLE_BASE || 'http://127.0.0.1:1615';
const SECRET = /key|token|secret|password/i;

function req(method, path, body) {
  return new Promise((resolve, reject) => {
    const u = new URL(BASE + path);
    const payload = body === undefined ? null : Buffer.from(JSON.stringify(body));
    const r = http.request({
      hostname: u.hostname, port: u.port, path: u.pathname, method,
      headers: { Authorization: 'Bearer ' + fs.readFileSync('/console-data/key', 'utf8').trim() },
      timeout: 60000,
    }, (res) => {
      let d = '';
      res.on('data', (c) => (d += c));
      res.on('end', () => { let p = d; try { p = JSON.parse(d); } catch (e) {} resolve({ status: res.statusCode, body: p }); });
    });
    r.on('timeout', () => r.destroy(new Error('timeout')));
    r.on('error', reject);
    if (payload) r.write(payload);
    r.end();
  });
}

function envDiff(a, b) {
  const out = [];
  for (const k of new Set([...Object.keys(a || {}), ...Object.keys(b || {})])) {
    if (String((a || {})[k]) !== String((b || {})[k])) out.push('env.' + k);
  }
  return out.sort();
}
// argv 逐项比对（要求长度相同；不同就整体判意外）
function argDiff(a, b) {
  a = a || []; b = b || [];
  if (a.length !== b.length) return ['args_LENGTH(' + a.length + '->' + b.length + ')'];
  const out = [];
  for (let i = 0; i < a.length; i++) if (String(a[i]) !== String(b[i])) out.push('args[' + i + ']');
  return out;
}
function otherDiff(a, b) {
  const keys = new Set([...Object.keys(a), ...Object.keys(b)]);
  const out = [];
  for (const k of keys) {
    if (k === 'env' || k === 'args') continue;
    if (JSON.stringify(a[k]) !== JSON.stringify(b[k])) out.push(k);
  }
  return out.sort();
}
function shown(p) {
  const e = {};
  for (const [k, v] of Object.entries(p.env || {})) e[k] = SECRET.test(k) ? '***' : v;
  return { args: p.args, env: e };
}

(async () => {
  const [, , id, mode, k1, k2] = process.argv;
  if (!id || !mode) { console.log('ARGS_BAD 需要 profileId 与模式'); process.exit(2); }

  const st = await req('GET', '/console-api/profiles/' + id + '/status');
  if (st.body && st.body.running) { console.log('ABORT 引擎在跑，先停'); process.exit(3); }
  const before = ((await req('GET', '/console-api/profiles')).body || []).find((x) => x.id === id);
  if (!before) { console.log('ABORT 找不到 profile ' + id); process.exit(4); }
  const snapshot = JSON.parse(JSON.stringify(before));

  const next = JSON.parse(JSON.stringify(before));
  next.env = Object.assign({}, next.env || {});
  let expected = [];

  if (mode === 'setenv' || mode === 'rmenv') {
    if (!/^VLLM_[A-Z0-9_]+$/.test(k1 || '')) { console.log('ARGS_BAD ENV KEY 不合规: ' + k1); process.exit(2); }
    if (mode === 'setenv') {
      if (k2 === undefined) { console.log('ARGS_BAD setenv 需要值'); process.exit(2); }
      next.env[k1] = k2;
    } else {
      if (!Object.prototype.hasOwnProperty.call(next.env, k1)) { console.log('NOOP rmenv 该键本来就没有: ' + k1); process.exit(0); }
      delete next.env[k1];
    }
    expected = ['env.' + k1];
  } else if (mode === 'setarg') {
    if (!/^--[a-z0-9-]+$/.test(k1 || '')) { console.log('ARGS_BAD flag 不合规: ' + k1); process.exit(2); }
    if (k2 === undefined) { console.log('ARGS_BAD setarg 需要新值'); process.exit(2); }
    const i = (next.args || []).indexOf(k1);
    if (i < 0) { console.log('ABORT setarg 只允许改已有参数，模板里没有 ' + k1); process.exit(5); }
    if (i + 1 >= next.args.length) { console.log('ABORT ' + k1 + ' 后面没有值，不敢当开关处理'); process.exit(6); }
    console.log('OLD_ARG[' + (i + 1) + ']=' + next.args[i + 1]);
    next.args[i + 1] = k2;
    expected = ['args[' + (i + 1) + ']'];
  } else { console.log('UNKNOWN_MODE ' + mode); process.exit(2); }

  const post = await req('POST', '/console-api/profiles', next);
  if (post.status !== 200) {
    console.log('POST_FAIL status=' + post.status + ' body=' + JSON.stringify(post.body).slice(0, 400));
    process.exit(7);
  }
  const after = ((await req('GET', '/console-api/profiles')).body || []).find((x) => x.id === id);
  if (!after) { console.log('LOST_PROFILE 回读不到，尝试回滚'); after_missing(); }

  const got = [...envDiff(snapshot.env, after.env), ...argDiff(snapshot.args, after.args), ...otherDiff(snapshot, after)].sort();
  const unexpected = got.filter((d) => !expected.includes(d));
  const missing = expected.filter((e) => !got.includes(e));
  console.log('EXPECTED=' + expected.join(',') + '  GOT=' + (got.join(',') || 'none'));
  if (mode === 'setarg') console.log('NEW_ARG=' + (after.args[(snapshot.args || []).indexOf(k1) + 1]));
  if (mode !== 'setarg') console.log('NOW_ENV=' + (SECRET.test(k1) ? '***' : String((after.env || {})[k1])));

  if (unexpected.length || missing.length) {
    console.log('UNEXPECTED=' + unexpected.join(',') + ' MISSING=' + missing.join(','));
    console.log('BEFORE=' + JSON.stringify(shown(snapshot)).slice(0, 900));
    console.log('AFTER=' + JSON.stringify(shown(after)).slice(0, 900));
    const rb = await req('POST', '/console-api/profiles', snapshot);
    const back = ((await req('GET', '/console-api/profiles')).body || []).find((x) => x.id === id);
    const resid = [...envDiff(snapshot.env, back.env), ...argDiff(snapshot.args, back.args), ...otherDiff(snapshot, back)];
    console.log('ROLLBACK_POST=' + rb.status + ' RESIDUAL=' + (resid.join(',') || 'none'));
    process.exit(8);
  }
  console.log('EDIT_OK 仅声明的那一处变了，其余逐字段一致');
})().catch((e) => { console.log('DRIVER_ERROR ' + e.message); process.exit(1); });

function after_missing() { console.log('ABORT 档位丢了'); process.exit(9); }
