// Run with node tool/test_program_worker.mjs. The same script that ships on mobile
// receives messages inside a real worker; terminate() is the embedding host's job.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { Worker, isMainThread, parentPort } from 'node:worker_threads';

if (!isMainThread) {
  globalThis.self = globalThis;
  self.postMessage = value => parentPort.postMessage(value);
  await import('../assets/program_runner/worker.js');
  parentPort.on('message', data => self.onmessage({ data }));
} else {
  const compiler = await readFile(new URL('../assets/program_runner/compiler.wasm', import.meta.url));
  async function run(source, options = {}, runTimeout) {
    const worker = new Worker(new URL(import.meta.url));
    let timer;
    try {
      const result = new Promise((resolve, reject) => {
        worker.on('error', reject);
        timer = setTimeout(() => reject(Error('Worker did not finish')), 10000);
        worker.on('message', data => {
          if (!data.started) resolve(data);
          else if (runTimeout !== undefined) {
            clearTimeout(timer);
            timer = setTimeout(() => resolve('host-timeout'), runTimeout);
          }
        });
      });
      worker.postMessage({ compiler, source, entry: 'src/main.c', files: {}, stdin: '', ...options });
      return await result;
    } finally {
      clearTimeout(timer);
      await worker.terminate();
    }
  }
  const project = await run('#include "answer.h"\nint main(){int c=getchar(); printf("%d:%c",ANSWER,c); return 7;}', {
    files: { 'src/answer.h': '#define ANSWER 42\n' }, stdin: 'X',
  });
  assert.deepEqual(project, { phase: 'run', exit_code: 7, stdout: '42:X', stderr: '' });

  const csv = '\ufeff姓名,城市\n小吴,苏州😀\n';
  const echoed = await run('int main(){int c;while((c=getchar())!=-1)putchar(c);return 0;}', { stdin: csv });
  assert.deepEqual(echoed, { phase: 'run', exit_code: 0, stdout: csv, stderr: '' });

  const bomProject = await run('\ufeff#include "v.h"\nint main(){char b[8];int f=__open_file("data",4);int n=__read_file(f,b,8);int i;for(i=0;i<n;i++)putchar(b[i]);return V;}', {
    files: { 'src/v.h': '\ufeff#define V 3\n', 'src/data': '\ufeffabc' },
  });
  assert.deepEqual(bomProject, { phase: 'run', exit_code: 3, stdout: '\ufeffabc', stderr: '' });

  const stdio = '#include <stdio.h>\nint main(){int n=0;while(getchar()!=EOF)n++;printf("%d:%d",n,__LINE__);return 0;}';
  assert.deepEqual(await run(stdio, { stdin: '123' }), { phase: 'run', exit_code: 0, stdout: '3:2', stderr: '' });
  const header = '# include <stdio.h> // EOF required here\n';
  const viaHeader = await run('#include "io.h"\nint main(){char b[9];int f=__open_file("io.h",4);int n=__read_file(f,b,8);b[n]=0;printf("%s",b);return getchar()==EOF ? 0 : 1;}', {
    files: { 'src/io.h': header },
  });
  assert.deepEqual(viaHeader, { phase: 'run', exit_code: 0, stdout: header.slice(0, 8), stderr: '' });

  const binary = await run('int main(){putchar(255);return 0;}');
  assert.equal(binary.phase, 'run');
  assert.notEqual(binary.exit_code, 0);
  assert.match(binary.stderr, /stdout contains invalid UTF-8/);
  assert.equal((await run('int main(){putchar(255);return 7;}')).exit_code, 7);

  const file = await run('int main(){char b[8];int f=__open_file("data.txt",8);int n=__read_file(f,b,3);__close_file(f);b[n]=0;puts(b);return 0;}', {
    files: { 'data.txt': 'abc' },
  });
  assert.deepEqual(file, { phase: 'run', exit_code: 0, stdout: 'abc\n', stderr: '' });

  const invalid = await run('int main(){ return +; }');
  assert.equal(invalid.phase, 'compile');
  assert.notEqual(invalid.exit_code, 0);
  assert.match(invalid.stderr, /error|unexpected|expected/i);

  const missing = await run('#include "../outside.h"\nint main(){return 0;}');
  assert.equal(missing.phase, 'compile');
  assert.notEqual(missing.exit_code, 0);

  const blocked = await run('int main(){return __open_file("../../sibling.txt",17) == -1 ? 0 : 1;}', {
    files: { 'sibling.txt': 'must not resolve across project root' },
  });
  assert.equal(blocked.exit_code, 0);

  const unsupported = await run('int main(){FILE *f=fopen("x","r");return 0;}');
  assert.equal(unsupported.phase, 'compile');
  assert.notEqual(unsupported.exit_code, 0);
  assert.match(unsupported.stderr, /error/i);

  const trap = await run('int main(){char *b;puts("before");b=malloc(68000000);b[67999999]=21;return b[67999999];}');
  assert.equal(trap.phase, 'run');
  assert.notEqual(trap.exit_code, 0);
  assert.equal(trap.stdout, 'before\n');
  assert.ok(trap.stderr);

  const flood = await run('int main(){while(1) putchar(88);return 0;}');
  assert.equal(flood.phase, 'run');
  assert.notEqual(flood.exit_code, 0);
  assert.match(flood.stderr, /Output exceeds/);
  assert.equal(flood.stdout.length, 65536);
  const endless = await run('int main(){while(1){} return 0;}', {}, 40);
  assert.equal(endless, 'host-timeout');
  const large = 'x'.repeat(256 * 1024 - 1);
  const tooLarge = await run('int main(){return 0;}', {
    stdin: large, files: { 'one.txt': large, 'two.txt': large, 'three.txt': large },
  });
  assert.equal(tooLarge.phase, 'compile');
  assert.match(tooLarge.stderr, /1 MiB/);
  console.log('PASS: execution, stdin, exit codes, quoted include, file reads, compile diagnostics, unsupported fopen, project boundary, partial output on trap, input/output/memory limits and worker termination.');
}
