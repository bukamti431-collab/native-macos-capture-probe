import { createCipheriv, createDecipheriv, createHash, randomBytes } from 'node:crypto';
import { execFile as execFileCallback } from 'node:child_process';
import { lstat, readFile, realpath } from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { promisify } from 'node:util';

const execFile = promisify(execFileCallback);
const AAD = Buffer.from('native-macos-session-v1', 'utf8');
const MAX_DURATION_MS = 8 * 60_000;
const MAX_PNG_BYTES = 6 * 1024 * 1024;
const MAX_ENVELOPE_BYTES = 12 * 1024 * 1024;
const BUNDLE = 'ru.keepcoder.Telegram';
const pause = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
class SessionError extends Error { constructor(code) { super(code); this.code = code; } }
const requireValue = (condition, code = 'invalid_configuration') => { if (!condition) throw new SessionError(code); };

function base64(value, bytes, limit = MAX_ENVELOPE_BYTES) {
  requireValue(typeof value === 'string' && value.length <= limit && /^[A-Za-z0-9+/]*={0,2}$/.test(value), 'invalid_envelope');
  const data = Buffer.from(value, 'base64');
  requireValue(data.toString('base64') === value && (bytes === undefined || data.length === bytes), 'invalid_envelope');
  return data;
}

export function loadConfiguration(env) {
  try {
    const key = base64(env.NATIVE_SESSION_KEY, 32);
    const auth = env.NATIVE_SESSION_AUTH;
    requireValue(typeof auth === 'string' && /^[A-Za-z0-9._~+/-]{24,512}={0,2}$/.test(auth) && auth !== env.NATIVE_SESSION_KEY);
    const primary = env.NATIVE_SESSION_ENDPOINT, alias = env.NATIVE_SESSION_URL;
    requireValue(!primary || !alias || primary === alias);
    const endpoint = new URL(primary || alias);
    requireValue(endpoint.protocol === 'https:' && !endpoint.username && !endpoint.password && !endpoint.search && !endpoint.hash
      && endpoint.pathname === '/' && (!endpoint.port || endpoint.port === '443'));
    requireValue(typeof env.NATIVE_TARGET_BOT === 'string' && /^[A-Za-z0-9_]{5,32}$/.test(env.NATIVE_TARGET_BOT));
    return { key, auth, origin: endpoint.origin, targetBot: env.NATIVE_TARGET_BOT,
      intervalMs: 5000, durationMs: MAX_DURATION_MS, httpTimeoutMs: 4000, nativeTimeoutMs: 4000,
      maxConsecutiveFailures: 3, retryDelayMs: 100 };
  } catch { throw new SessionError('invalid_configuration'); }
}

export function encryptPayload(payload, key) {
  try {
    requireValue(Buffer.isBuffer(key) && key.length === 32, 'invalid_envelope');
    const iv = randomBytes(12), cipher = createCipheriv('aes-256-gcm', key, iv);
    cipher.setAAD(AAD);
    const plaintext = Buffer.from(JSON.stringify(payload), 'utf8');
    requireValue(plaintext.length <= MAX_ENVELOPE_BYTES, 'invalid_envelope');
    const data = Buffer.concat([cipher.update(plaintext), cipher.final()]);
    return { v: 1, iv: iv.toString('base64'), tag: cipher.getAuthTag().toString('base64'), data: data.toString('base64') };
  } catch { throw new SessionError('invalid_envelope'); }
}

export function decryptPayload(envelope, key) {
  try {
    requireValue(envelope && typeof envelope === 'object' && !Array.isArray(envelope) && envelope.v === 1, 'invalid_envelope');
    requireValue(Object.keys(envelope).sort().join(',') === 'data,iv,tag,v', 'invalid_envelope');
    const decipher = createDecipheriv('aes-256-gcm', key, base64(envelope.iv, 12));
    decipher.setAAD(AAD); decipher.setAuthTag(base64(envelope.tag, 16));
    const plaintext = Buffer.concat([decipher.update(base64(envelope.data)), decipher.final()]);
    const payload = JSON.parse(plaintext.toString('utf8'));
    requireValue(payload && typeof payload === 'object' && !Array.isArray(payload), 'invalid_envelope');
    return payload;
  } catch { throw new SessionError('invalid_envelope'); }
}

async function bounded(operation, milliseconds, code, controller) {
  requireValue(milliseconds > 0, 'expired');
  let timer;
  try {
    return await Promise.race([Promise.resolve().then(operation), new Promise((_, reject) => {
      timer = setTimeout(() => { controller?.abort(); reject(new SessionError(code)); }, milliseconds);
    })]);
  } finally { clearTimeout(timer); }
}

async function readLimited(response, limit) {
  requireValue(response.body?.getReader, 'invalid_response');
  const reader = response.body.getReader(); let size = 0; const chunks = [];
  try {
    while (true) {
      const part = await reader.read(); if (part.done) break;
      size += part.value.length; requireValue(size <= limit, 'invalid_response'); chunks.push(Buffer.from(part.value));
    }
    return Buffer.concat(chunks).toString('utf8');
  } finally { try { reader.releaseLock(); } catch {} }
}

async function request(config, pathname, method, body, fetchImpl, remaining) {
  for (let attempt = 0; attempt < 2; attempt++) {
    const controller = new AbortController();
    try {
      return await bounded(async () => {
        const headers = { authorization: `Bearer ${config.auth}` };
        if (body !== undefined) headers['content-type'] = 'application/json';
        const response = await fetchImpl(new URL(pathname, config.origin).href,
          { method, headers, body, signal: controller.signal, redirect: 'error', cache: 'no-store', credentials: 'omit' });
        if (!response.ok) {
          try { response.body?.cancel()?.catch(() => {}); } catch {}
          if (response.status === 401 || response.status === 403) throw new SessionError('authorization_rejected');
          const retry = [408, 429].includes(response.status) || response.status >= 500;
          throw new SessionError(retry ? 'transport_unavailable' : 'invalid_response');
        }
        if (method === 'POST') { try { response.body?.cancel()?.catch(() => {}); } catch {} return null; }
        const text = await readLimited(response, 16 * 1024);
        try { return decryptPayload(JSON.parse(text), config.key); } catch { throw new SessionError('invalid_response'); }
      }, Math.min(config.httpTimeoutMs, remaining()), 'transport_unavailable', controller);
    } catch (error) {
      const code = error instanceof SessionError ? error.code : 'transport_unavailable';
      if (code !== 'transport_unavailable' || attempt === 1 || remaining() <= 0) throw new SessionError(code);
      await pause(Math.min(config.retryDelayMs, remaining()));
    } finally { controller.abort(); }
  }
}

function framePayload(capture, seq, state) {
  const probe = capture?.window_probe, png = capture?.png;
  requireValue(probe?.bundle_identifier === BUNDLE && probe.expected_application_running === true && probe.frontmost_bundle_identifier === BUNDLE
    && Number.isSafeInteger(probe.window_id) && probe.window_id > 0, 'native_unavailable');
  requireValue(Buffer.isBuffer(png) && png.length >= 33 && png.length <= MAX_PNG_BYTES
    && png.subarray(0, 16).equals(Buffer.from('89504e470d0a1a0a0000000d49484452', 'hex'))
    && png.readUInt32BE(16) >= 200 && png.readUInt32BE(20) >= 160, 'native_unavailable');
  return { type: 'frame', seq, window_probe: probe, files: [{ name: 'window.png',
    sha256: createHash('sha256').update(png).digest('hex'), data_base64: png.toString('base64') }], state };
}

export async function runSession(config, { nativeAdapter, fetchImpl = globalThis.fetch, onEvent = () => {} } = {}) {
  const deadline = performance.now() + Math.min(config.durationMs, MAX_DURATION_MS);
  const remaining = () => Math.max(0, deadline - performance.now());
  let seq = 0, frames = 0, failures = 0, targetOpened = false, state = 'awaiting_user';
  const event = value => { try { onEvent(value); } catch {} };
  const nativeOperation = async operation => {
    const controller = new AbortController();
    try { return await bounded(() => operation(controller.signal), Math.min(config.nativeTimeoutMs, remaining()), 'native_unavailable', controller); }
    finally { controller.abort(); }
  };
  while (remaining() > 0) {
    const cycleStarted = performance.now(); let category = 'native_unavailable';
    try {
      const capture = await nativeOperation(signal => nativeAdapter.captureFrame({ signal }));
      const frame = framePayload(capture, ++seq, state);
      const body = JSON.stringify(encryptPayload(frame, config.key));
      requireValue(Buffer.byteLength(body) <= MAX_ENVELOPE_BYTES, 'native_unavailable');
      category = 'transport_unavailable';
      await request(config, '/api/frame', 'POST', body, fetchImpl, remaining);
      frames++; event({ event: 'frame_sent', seq });
      const command = await request(config, '/api/command', 'GET', undefined, fetchImpl, remaining);
      if (!['wait', 'open_target', 'finish'].includes(command.action)) return { reason: 'invalid_command', frames };
      if (command.action === 'finish') return { reason: 'finished', frames };
      if (command.action === 'open_target' && !targetOpened) {
        category = 'native_unavailable';
        await nativeOperation(signal => nativeAdapter.openTarget(config.targetBot, { signal }));
        targetOpened = true; state = 'target_requested'; event({ event: 'target_requested' });
      }
      failures = 0;
    } catch (error) {
      if (remaining() <= 0 || error?.code === 'expired') break;
      if (error?.code === 'authorization_rejected') return { reason: 'authorization_rejected', frames };
      failures++; event({ event: 'cycle_failed', category });
      if (failures >= config.maxConsecutiveFailures) return { reason: category, frames };
    }
    await pause(Math.min(Math.max(0, config.intervalMs - (performance.now() - cycleStarted)), remaining()));
  }
  return { reason: 'expired', frames };
}

export async function createNativeAdapter(env) {
  requireValue(process.platform === 'darwin' && env.GITHUB_ACTIONS === 'true' && env.RUNNER_ENVIRONMENT === 'github-hosted', 'unsupported_host');
  requireValue(typeof env.RUNNER_TEMP === 'string' && path.isAbsolute(env.RUNNER_TEMP));
  const work = path.join(await realpath(env.RUNNER_TEMP), 'native-macos-capture', 'work');
  const app = path.join(work, 'Telegram.app'), helper = path.join(work, 'window_probe'), screenshot = path.join(work, 'private-session-window.png');
  for (const item of [work, app, helper]) requireValue(await realpath(item) === item, 'native_unavailable');
  requireValue((await lstat(app)).isDirectory() && (await lstat(helper)).isFile(), 'native_unavailable');
  const invoke = async (executable, args, signal) => {
    try { return await execFile(executable, args, { signal, encoding: 'utf8', timeout: 3500, maxBuffer: 128 * 1024, windowsHide: true }); }
    catch { throw new SessionError('native_unavailable'); }
  };
  return {
    async captureFrame({ signal } = {}) {
      let probe; try { probe = JSON.parse((await invoke(helper, [app, 'inspect'], signal)).stdout); } catch { throw new SessionError('native_unavailable'); }
      requireValue(probe.bundle_identifier === BUNDLE && probe.expected_application_running === true && probe.frontmost_bundle_identifier === BUNDLE
        && Number.isSafeInteger(probe.window_id) && probe.window_id > 0, 'native_unavailable');
      await invoke('/usr/sbin/screencapture', ['-x', '-o', '-l', String(probe.window_id), screenshot], signal);
      const info = await lstat(screenshot); requireValue(info.isFile() && info.size <= MAX_PNG_BYTES, 'native_unavailable');
      return { window_probe: probe, png: await readFile(screenshot) };
    },
    async openTarget(bot, { signal } = {}) {
      requireValue(/^[A-Za-z0-9_]{5,32}$/.test(bot), 'invalid_command');
      await invoke('/usr/bin/open', ['-a', app, `tg://resolve?domain=${bot}`], signal);
    }
  };
}

async function main() {
  if (process.platform !== 'darwin' || process.env.GITHUB_ACTIONS !== 'true' || process.env.RUNNER_ENVIRONMENT !== 'github-hosted') {
    process.stderr.write('native_session unsupported_host\n'); return 2;
  }
  try {
    const config = loadConfiguration(process.env), nativeAdapter = await createNativeAdapter(process.env);
    const result = await runSession(config, { nativeAdapter });
    process.stderr.write(`native_session ${result.reason}\n`);
    return ['finished', 'expired'].includes(result.reason) ? 0 : 1;
  } catch { process.stderr.write('native_session setup_rejected\n'); return 1; }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) process.exitCode = await main();
