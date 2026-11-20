import { execFileSync, spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { mkdir, mkdtemp, realpath, rm, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { tmpdir } from 'node:os';
import { equalLines, scoreArguments } from './score.mjs';

// Each probe compiles submitted source into a fresh executable. Only the
// scratch copy and the system toolchain are accessible to the child process.
const profile = `
(version 1)
(allow default)
(deny file-read*)
(deny file-write*)
(deny network*)
(deny mach-lookup)
(deny appleevent-send)
(deny process-info*)
(deny process-codesigning*)
(deny signal)
(allow process-info* (target self))
(allow signal (target self))
(import "dyld-support.sb")
(allow file-read-metadata (path-ancestors (param "SCRATCH")) (path-ancestors (param "DEVELOPER")))
(allow file-read*
  (subpath "/bin") (subpath "/usr/bin") (subpath "/usr/lib") (subpath "/usr/share")
  (subpath "/usr/libexec") (subpath "/System/Library") (subpath "/Library/Apple/System")
  (subpath "/dev/fd") (literal "/dev/null") (literal "/dev/random") (literal "/dev/urandom")
  (literal "/private/var/select/sh") (subpath (param "DEVELOPER")) (subpath (param "SCRATCH")))
(allow file-write* (subpath (param "SCRATCH")) (literal "/dev/null") (subpath "/dev/fd"))
`;

function nativeToolchain() {
  if (process.platform !== 'darwin') throw Error('Native scoring requires macOS with sandbox-exec and the Xcode developer tools.');
  const clt = '/Library/Developer/CommandLineTools';
  const developer = existsSync(join(clt, 'usr/bin/clang')) ? clt :
    execFileSync('/usr/bin/xcode-select', ['-p'], { encoding: 'utf8' }).trim();
  const find = args => execFileSync('/usr/bin/xcrun', args, {
    env: { DEVELOPER_DIR: developer, PATH: '/usr/bin:/bin' }, encoding: 'utf8',
  }).trim();
  return { developer, clang: find(['--find', 'clang']), sdk: find(['--sdk', 'macosx', '--show-sdk-path']) };
}

async function createNativeRunner(files) {
  const tools = nativeToolchain();
  return async (source, stdin, expected, entry = 'main.c') => {
    if (typeof source !== 'string') return false;
    const scratch = await realpath(await mkdtemp(join(tmpdir(), 'orb-native-probe-')));
    try {
      const work = join(scratch, 'project');
      const binary = join(scratch, 'program');
      await mkdir(work);
      for (const [name, contents] of Object.entries({ ...files, ['project/' + entry]: source })) {
        if (!name.startsWith('project/')) continue;
        const parts = name.slice(8).split('/');
        if (parts.some(part => !part || part === '.' || part === '..')) throw Error('Invalid submission path');
        const target = join(work, ...parts);
        await mkdir(dirname(target), { recursive: true });
        await writeFile(target, contents);
      }
      const env = {
        HOME: scratch, TMPDIR: scratch, PATH: '/usr/bin:/bin', DEVELOPER_DIR: tools.developer,
        SDKROOT: tools.sdk, LANG: 'C', TZ: 'UTC',
      };
      function invoke(args, isGuest = false) {
        const rules = isGuest ? profile + '\n(deny process-fork)\n' : profile;
        const cmd = [
          '-D', 'SCRATCH=' + scratch, '-D', 'DEVELOPER=' + tools.developer, '-p', rules,
          '/bin/bash', '-c', 'ulimit -t 12; ulimit -f 8192; ulimit -c 0; exec "$@"', 'probe', ...args,
        ];
        return spawnSync('/usr/bin/sandbox-exec', cmd, {
          env, cwd: work, input: isGuest ? stdin : '', encoding: 'utf8', timeout: 15000,
          killSignal: 'SIGKILL', maxBuffer: 128 * 1024,
        });
      }
      const compiled = invoke([tools.clang, '-std=c11', '-O0', join(work, entry), '-o', binary]);
      if (compiled.error || compiled.status !== 0) return false;
      const ran = invoke([binary], true);
      return !ran.error && ran.status === 0 && equalLines(ran.stdout, expected);
    } finally {
      await rm(scratch, { recursive: true, force: true });
    }
  };
}

console.log(JSON.stringify(await scoreArguments(process.argv.slice(2), createNativeRunner)));
