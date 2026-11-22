import { readFile, readdir, lstat } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { Worker, isMainThread, parentPort } from 'node:worker_threads';
import { isDeepStrictEqual } from 'node:util';
import { cases } from './cases.mjs';

// This file and the host's probes stay outside every participating workspace.
const assets = new URL('../../assets/program_runner/', import.meta.url);
if (!isMainThread) {
  globalThis.self = globalThis;
  self.postMessage = message => parentPort.postMessage(message);
  await import(new URL('worker.js', assets));
  parentPort.once('message', data => self.onmessage({ data }));
}

async function createRunner(files) {
  const compiler = await readFile(new URL('compiler.wasm', assets));
  const sysroot = JSON.parse(await readFile(new URL('sysroot.json', assets), 'utf8'));
  const inputs = Object.fromEntries(Object.entries(files)
    .filter(([name]) => name.startsWith('project/'))
    .map(([name, value]) => [name.slice('project/'.length), value]));
  return async (source, stdin, expected, entry = 'main.c') => {
    if (typeof source !== 'string') return false;
    const worker = new Worker(new URL(import.meta.url));
    let timer;
    try {
      const result = new Promise((done, reject) => {
        timer = setTimeout(() => done(null), 10000);
        worker.on('message', message => { if (!message.started) done(message); });
        worker.on('error', reject);
        worker.on('exit', () => done(null));
      });
      const visible = { ...inputs };
      delete visible[entry];
      worker.postMessage({ compiler, sysroot, source, entry, files: visible, stdin });
      const reply = await result;
      return reply?.phase === 'run' && reply.exit_code === 0 && equalLines(reply.stdout, expected);
    } finally {
      clearTimeout(timer);
      await worker.terminate();
    }
  };
}

function lines(text) {
  return typeof text === 'string' ? text.replace(/^\uFEFF/, '').trim().split(/\r?\n/).map(line => line.trim()) : [];
}
export function equalLines(text, expected) {
  return isDeepStrictEqual(lines(text), expected);
}

function agendaChecks(text) {
  const rows = lines(text);
  const sessions = [['声音地图', '09:50', 'K7'], ['纸桥搭建', '11:20', 'K2'], ['纸偶排演', '16:00', 'H4']];
  const normalized = rows.map(s => s.normalize('NFKC').toUpperCase());
  const include = normalized.map(s => sessions.filter(([name]) => s.includes(name)).length);
  const times = s => [...s.matchAll(/(?<!\d)(\d{1,2})\s*:\s*(\d{2})(?!\d)/g)]
    .map(m => m[1].padStart(2, '0') + ':' + m[2]);
  const rooms = s => [...s.matchAll(/(?<![A-Z0-9])[HK]\d+(?![A-Z0-9])/g)].map(m => m[0]);
  const where = sessions.map(([name]) => normalized.findIndex(s => s.includes(name)));
  const onlyScheduled = !normalized.some(s => s.includes('树叶拓印')) &&
    normalized.every((s, i) => include[i] <= 1 && (include[i] === 1 || (!times(s).length && !rooms(s).length)));
  return {
    final_sessions: onlyScheduled && sessions.every(([name]) => normalized.filter(s => s.includes(name)).length === 1),
    final_times_and_rooms: sessions.every(([, time, room], i) => where[i] >= 0 &&
      isDeepStrictEqual(times(normalized[where[i]]), [time]) && isDeepStrictEqual(rooms(normalized[where[i]]), [room])),
    chronological: where[0] >= 0 && where[0] < where[1] && where[1] < where[2],
  };
}

export async function score(id, files, makeRunner = createRunner) {
  const task = cases.find(t => t.id === id);
  if (!task) throw Error('Unknown benchmark task');
  const read = name => files['project/' + name];
  const unchanged = name => read(name) === task.files['project/' + name];
  const checks = {};
  if (id === 'screening-list') {
    const queue = lines(read('blue.m3u'));
    if (queue[0] === '#EXTM3U') queue.shift();
    const expected = ['linen-cloud', 'paper-orbit', 'underpass', 'glass-garden', 'salt-window'].map(x => 'reels/' + x + '.mp4');
    checks.schedule_intact = unchanged('schedule.tsv');
    checks.film_selection = isDeepStrictEqual([...queue].sort(), [...expected].sort());
    checks.play_order = isDeepStrictEqual(queue, expected);
  } else if (id === 'event-brief') {
    checks.sources_intact = unchanged('agenda.md') && unchanged('updates.md');
    Object.assign(checks, agendaChecks(read('brief.md')));
  } else if (id === 'active-profile') {
    const active = 'versions/fir/settings.json';
    checks.index_and_other_profiles_intact = Object.entries(task.files)
      .every(([path, text]) => path === 'project/' + active || text === files[path]);
    let config;
    try { config = JSON.parse(read(active)); } catch { /* Missing or invalid JSON is a failed delivery. */ }
    const reference = JSON.parse(task.files['project/' + active]);
    checks.active_delay = config?.network?.retry_delay_seconds === 4;
    reference.network.retry_delay_seconds = config?.network?.retry_delay_seconds;
    checks.other_active_settings = isDeepStrictEqual(config, reference);
  } else {
    const run = await makeRunner(files);
    const main = read('main.c');
    if (id === 'rgb-export') {
      const sample = ['#020FA0', '#00FFFF'];
      checks.sample_intact = unchanged('sample.txt');
      checks.saved_colors = equalLines(read('colors.txt'), sample);
      checks.sample_execution = await run(main, task.files['project/sample.txt'], sample);
      checks.unseen_colors = await run(main, '0 1 12\n99 101 254\n-13 2048 16\n255 255 255\n',
        ['#00010C', '#6365FE', '#00FF10', '#FFFFFF']);
      const caller = '#include <stdio.h>\n#include "include/pixel.h"\nint main(void){ int x[]={-9,0,2,100,101,254,255,299}; for(int i=0;i<8;i++)printf("%d\\n",pixel_channel(x[i]));return 0;}\n';
      checks.independent_header_caller = await run(caller, '', ['0','0','2','100','101','254','255','255'], '__independent_color_check.c');
    } else if (id === 'parcel-lines') {
      const sample = ['parcels=3'];
      checks.list_intact = unchanged('incoming.txt');
      checks.saved_count = equalLines(read('count.txt'), sample);
      checks.sample_execution = await run(main, task.files['project/incoming.txt'], sample);
      checks.empty_input = await run(main, '', ['parcels=0']);
      checks.completed_and_unterminated_lines = await run(main, '\r\n \t\r\nAX 31  \r\n\n B07\n  最后一件', ['parcels=3']);
      checks.terminated_line_kept = await run(main, '\nX\nY\n\nZ\n', ['parcels=3']);
    } else if (id === 'shift-span') {
      const sample = ['45', '30', '0'];
      checks.schedule_intact = unchanged('shifts.txt');
      checks.saved_minutes = equalLines(read('minutes.txt'), sample);
      checks.sample_execution = await run(main, task.files['project/shifts.txt'], sample);
      checks.unseen_shifts = await run(main, '23:59 00:00\n00:01 23:59\n06:47 06:09\n04:05 04:05\n', ['1','1438','1402','0']);
    }
  }
  const values = Object.values(checks);
  return { id, passed: values.every(v => v), passed_checks: values.filter(Boolean).length, total_checks: values.length, checks };
}

const decoder = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true });
async function readSubmission(directory) {
  const files = Object.create(null);
  const root = resolve(directory);
  async function walk(rel) {
    const path = join(root, rel);
    const stat = await lstat(path);
    // Local CLI tools may leave symlinks, executables or object files beside
    // their source. They are never followed or executed by the scorer.
    if (stat.isSymbolicLink()) return;
    if (stat.isDirectory()) {
      for (const entry of await readdir(path)) {
        if (entry !== '.git') await walk(rel + '/' + entry);
      }
    } else if (stat.isFile() && stat.size <= 1024 * 1024) {
      const bytes = await readFile(path);
      if (!bytes.includes(0)) {
        try { files[rel] = decoder.decode(bytes); } catch { /* Binary artifact. */ }
      }
    }
  }
  try { await walk('project'); } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  return files;
}

export async function scoreArguments(args, makeRunner = createRunner) {
  const [id, source, file] = args;
  if (!id || !source || (source === '--json' && !file)) throw Error('Usage: score.mjs CASE WORKSPACE_ROOT | CASE --json SNAPSHOT');
  let files;
  if (source === '--json') {
    const decoded = JSON.parse(await readFile(file, 'utf8'));
    files = decoded.files ?? decoded;
    if (!files || typeof files !== 'object' || Array.isArray(files) ||
        !Object.entries(files).every(([p, value]) => p.startsWith('project/') && typeof value === 'string')) {
      throw Error('Expected a UTF-8 project path to text mapping');
    }
  } else {
    files = await readSubmission(source);
  }
  return score(id, files, makeRunner);
}

if (isMainThread && process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  console.log(JSON.stringify(await scoreArguments(process.argv.slice(2))));
}
