// 0.1.7 生产形态（控制台/native）驱动脚本 v1
// 用法: node /console-data/tmp/console-driver-v1.cjs <mode> [args]
//   probe            只读：会话/设置/模板/配置列表/系统/GPU
//   setup            注册权重 + 从官方模板建 profile（不启动）
//   start <id>       通过面板启动引擎（写操作）
//   stop <id>        通过面板停止引擎（写操作）
//   status <id>      引擎状态 + 最后日志
//   engineenv <pat>  读引擎进程 environ/cmdline（脱敏），用于与 CLI 档 diff
// 纪律：任何密钥值都不打印（VLLM_API_KEY / key / token / authorization 一律 ***）
const fs = require('fs');
const http = require('http');

const BASE = process.env.CONSOLE_BASE || 'http://127.0.0.1:1615';
const MODELS = process.env.BENCH_MODEL_DIR || '/models';
const TEMPLATE = process.env.BENCH_TEMPLATE || 'flash-next-tp8-256k-nomtp';
const CACHE_ROOT = process.env.BENCH_CACHE_ROOT || '/root/.cache/sm75-017';
const SECRET_KEYS = /^(vllm_api_key|key|token|authorization|password|secret|sm75_bench_key|api[-_]key)$/i;

function readToken() {
  // token 只用于请求头，绝不落日志
  return fs.readFileSync('/console-data/key', 'utf8').trim();
}

function request(method, path, body) {
  return new Promise((resolve, reject) => {
    const u = new URL(BASE + path);
    const payload = body === undefined ? null : Buffer.from(JSON.stringify(body));
    const req = http.request(
      {
        hostname: u.hostname,
        port: u.port,
        path: u.pathname + u.search,
        method,
        headers: Object.assign(
          { Authorization: 'Bearer ' + readToken() },
          payload ? { 'Content-Type': 'application/json', 'Content-Length': payload.length } : {},
        ),
        timeout: Number(process.env.CONSOLE_TIMEOUT_MS || 900000),
      },
      (res) => {
        let data = '';
        res.on('data', (c) => (data += c));
        res.on('end', () => {
          let parsed = data;
          try { parsed = JSON.parse(data); } catch (_) { /* 非 JSON 原样返回 */ }
          resolve({ status: res.statusCode, body: parsed });
        });
      },
    );
    req.on('timeout', () => req.destroy(Error('timeout')));
    req.on('error', reject);
    if (payload) req.write(payload);
    req.end();
  });
}

function mask(value, name = '') {
  if (SECRET_KEYS.test(name)) return '***';
  if (Array.isArray(value)) return value.map((v) => mask(v, name));
  if (value && typeof value === 'object') {
    const out = {};
    for (const [k, v] of Object.entries(value)) out[k] = mask(v, k);
    return out;
  }
  // 兜底：43 位 base64url 形态的密钥串
  if (typeof value === 'string' && /^[A-Za-z0-9_-]{40,}$/.test(value) && /key|token|secret/i.test(name)) return '***';
  return value;
}

function print(label, obj) {
  console.log('### ' + label);
  console.log(JSON.stringify(mask(obj), null, 1).slice(0, 12000));
}

async function probe() {
  const session = await request('GET', '/console-api/session');
  print('session ' + session.status, session.body);
  print('settings', (await request('GET', '/console-api/settings')).body);
  const tpl = (await request('GET', '/console-api/templates')).body;
  print('templates', {
    recommended: (tpl.recommended || []).map((p) => p.id),
    personal: (tpl.personal || []).map((p) => p.name || p.id),
  });
  const profiles = (await request('GET', '/console-api/profiles')).body;
  print('profiles', Array.isArray(profiles) ? profiles.map((p) => ({
    id: p.id, backend: p.backend, port: p.port, image: p.image, cacheRoot: p.cacheRoot,
    format: p.format, model: (p.args || [])[0], args_count: (p.args || []).length,
    power: p.power, env_keys: Object.keys(p.env || {}),
  })) : profiles);
  print('system', (await request('GET', '/console-api/system')).body);
  const hw = (await request('GET', '/console-api/hardware')).body;
  print('hardware(gpus)', Array.isArray(hw?.gpus) ? hw.gpus.map((g) => ({
    index: g.index ?? g.id, name: g.name, memoryGiB: g.memoryGiB ?? g.totalMemoryMiB,
    usedMiB: g.usedMiB ?? g.memoryUsedMiB, powerLimit: g.powerLimit ?? g.enforcedPowerLimit,
  })) : hw);
}

async function setup() {
  // 1) 缓存根（native 模式下引擎直接吃这些路径；必须在 bind 内才会持久化到宿主）
  for (const sub of ['awq/vllm', 'awq/triton', 'awq/inductor', 'shared/torch_extensions',
                     'shared/cuda', 'shared/flashinfer', 'shared/flashinfer-home/.cache']) {
    fs.mkdirSync(CACHE_ROOT + '/' + sub, { recursive: true });
  }
  fs.accessSync(CACHE_ROOT, fs.constants.W_OK);
  console.log('CACHE_ROOT ' + CACHE_ROOT + ' writable=yes');

  // 只提交要改的字段：saveSettings 会与既有设置合并并逐项校验
  const saved = await request('POST', '/console-api/settings', { cacheRoot: CACHE_ROOT });
  print('settings/save', saved.status === 200 ? { cacheRoot: saved.body.cacheRoot, modelRoot: saved.body.modelRoot } : { status: saved.status, body: saved.body });

  // 2) 注册权重
  const reg = await request('POST', '/console-api/models/register', { path: MODELS });
  print('models/register', reg.status === 200 ? reg.body : { status: reg.status, body: reg.body });
  const modelId = reg.body && reg.body.id;
  if (!modelId) { console.log('SETUP_ABORT no-model-id'); return; }

  // 3) 走官方模型模板分支（base: 前缀才会命中 inferenceProfile 展开 ${MODEL}）
  const use = await request('POST', '/console-api/models/use', {
    model: modelId, template: 'base:' + TEMPLATE, start: false,
  });
  print('models/use', use.status === 200 ? { profile: use.body.profile, keys: Object.keys(use.body || {}) } : { status: use.status, body: use.body });
  const pid = use.body && use.body.profile;
  if (!pid) { console.log('SETUP_ABORT no-profile'); return; }

  // 4) 回读整份 profile，逐字存档用
  const profiles = (await request('GET', '/console-api/profiles')).body;
  const p = (profiles || []).find((x) => x.id === pid);
  console.log('PROFILE_ID ' + pid);
  print('profile/full', p);
  const prev = await request('GET', `/console-api/profiles/${pid}/preview`);
  print('preview', prev.body);
}

async function start(id) {
  const r = await request('POST', `/console-api/profiles/${id}/start`, {});
  print('start/' + id, r.body);
  console.log('START_HTTP ' + r.status);
}

async function stop(id) {
  print('stop/' + id, (await request('POST', `/console-api/profiles/${id}/stop`, {})).body);
}

async function status(id) {
  print('status', (await request('GET', `/console-api/profiles/${id}/status`)).body);
  const logs = (await request('GET', `/console-api/profiles/${id}/logs`)).body;
  const text = typeof logs === 'string' ? logs : (logs && logs.text) || '';
  const tail = text.split('\n').filter((l) => l && !l.startsWith('{')).slice(-40).join('\n');
  console.log('### logtail\n' + tail.slice(-6000));
}

function engineEnv(pattern) {
  // 在控制台容器内找引擎进程，读 /proc/<pid>/environ 与 cmdline
  const pids = fs.readdirSync('/proc').filter((n) => /^\d+$/.test(n));
  const hits = [];
  for (const pid of pids) {
    let cmd = '';
    try { cmd = fs.readFileSync(`/proc/${pid}/cmdline`, 'utf8').replace(/\0/g, ' ').trim(); } catch (_) { continue; }
    if (!cmd || !cmd.includes(pattern)) continue;
    if (cmd.includes('engineenv')) continue;   // 别把自己算进去
    hits.push({ pid, cmd });
  }
  if (!hits.length) { console.log('NO_ENGINE_PROCESS pattern=' + pattern); return; }
  // 引擎主进程的 argv 最长（vllm serve + 几十参数），按长度取头部，避免抓到控制台自身进程
  hits.sort((a, b) => b.cmd.length - a.cmd.length);
  const chosen = hits.slice(0, 1);
  for (const h of chosen) {
    console.log('=== PID ' + h.pid + ' ARGV (one per line)');
    fs.readFileSync(`/proc/${h.pid}/cmdline`, 'utf8').split('\0').filter(Boolean).forEach((a) => console.log(a));
    let env = [];
    try { env = fs.readFileSync(`/proc/${h.pid}/environ`, 'utf8').split('\0').filter(Boolean); } catch (_) {}
    console.log('=== PID ' + h.pid + ' ENV (sorted, secrets masked)');
    env.sort().forEach((line) => {
      const i = line.indexOf('=');
      const k = i < 0 ? line : line.slice(0, i);
      const v = i < 0 ? '' : line.slice(i + 1);
      console.log(k + '=' + (SECRET_KEYS.test(k) ? '***' : v));
    });
  }
  console.log('ENGINE_PROCESS_COUNT ' + hits.length);
}

(async () => {
  const mode = process.argv[2] || 'probe';
  const arg = process.argv[3];
  try {
    if (mode === 'probe') await probe();
    else if (mode === 'setup') await setup();
    else if (mode === 'start') await start(arg);
    else if (mode === 'stop') await stop(arg);
    else if (mode === 'status') await status(arg);
    else if (mode === 'engineenv') engineEnv(arg || 'vllm');
    else console.log('UNKNOWN_MODE ' + mode);
  } catch (e) {
    console.log('DRIVER_ERROR ' + (e && e.message));
    process.exitCode = 1;
  }
})();
