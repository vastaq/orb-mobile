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
  const sysroot = JSON.parse(await readFile(new URL('../assets/program_runner/sysroot.json', import.meta.url), 'utf8'));
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
      worker.postMessage({ compiler, sysroot, source, entry: 'src/main.c', files: {}, stdin: '', ...options });
      return await result;
    } finally {
      clearTimeout(timer);
      await worker.terminate();
    }
  }
  // The model generated this program during device UAT. In particular, sizeof
  // must measure the whole local array, and fgets must accept the real stdin.
  const counter = `#include <stdio.h>
#include <string.h>
#include <ctype.h>

int main() {
    char input[1024];
    if (fgets(input, sizeof(input), stdin) == NULL) {
        return 0;
    }
    int count = 0;
    for (int i = 0; input[i] != '\\0'; i++) {
        if (isdigit(input[i])) {
            count++;
        }
    }
    printf("%d\\n", count);
    return 0;
}`;
  for (const [stdin, stdout] of [['A7b25X4','4\n'], ['end9','1\n'], ['', '']]) {
    assert.deepEqual(await run(counter, { stdin }), { phase: 'run', exit_code: 0, stdout, stderr: '' });
  }

  const nested = await run('\ufeff#include "headers/settings.h"\nint main(){char s[4];int n=0;while(fgets(s,sizeof(s),stdin)){printf("%d ",(int)strlen(s));n++;}printf("lines=%d",n);return getchar()==EOF ? STATUS : 1;}', {
    files: {
      'src/headers/settings.h': '\ufeff#include "common.h"\n#define STATUS 7\n',
      'src/headers/common.h': '#include <stdio.h>\n#include <string.h>\n',
    }, stdin: '12345\nA',
  });
  assert.deepEqual(nested, { phase: 'run', exit_code: 7, stdout: '3 3 1 lines=3', stderr: '' });

  const csv = '\ufeff姓名,城市\n小吴,苏州😀\n';
  const echoed = await run('#include <stdio.h>\nint main(){int c;while((c=getchar())!=EOF)putchar(c);return 0;}', { stdin: csv });
  assert.deepEqual(echoed, { phase: 'run', exit_code: 0, stdout: csv, stderr: '' });
  const fileRead = await run(`#include <stdio.h>
int main(){
  FILE *f=fopen("sub/data.txt","r"); if(!f) return 1;
  if(fseek(f,3,SEEK_SET))return 2;
  int n=fgetc(f); if(fseek(f,0,SEEK_SET))return 3;
  while((n=fgetc(f))!=EOF)putchar(n);
  return fclose(f);
}`, { files: { 'sub/data.txt': csv } });
  assert.deepEqual(fileRead, { phase: 'run', exit_code: 0, stdout: csv, stderr: '' });

  const denied = await run(`#include <stdio.h>
#include <unistd.h>
int main(){
  if(fopen("../sibling.txt","r") || fopen("/usr/include/stdio.h","r"))return 1;
  if(fopen("data.txt","w") || fopen("new.txt","w") || fopen("/tmp/new","w") || unlink("data.txt")==0)return 2;
  FILE *f=fopen("data.txt","r");
  if(!f || fgetc(f)!='a')return 3;
  fclose(f);return 0;
}`, { files: { 'data.txt': 'abc' } });
  assert.deepEqual(denied, { phase: 'run', exit_code: 0, stdout: '', stderr: '' });

  const invalid = await run('#include <stdio.h>\nint main(){ return +; }');
  assert.equal(invalid.phase, 'compile');
  assert.notEqual(invalid.exit_code, 0);
  assert.match(invalid.stderr, /main\.c\(2\)/);
  const missing = await run('#include "../../outside.h"\nint main(){return 0;}');
  assert.equal(missing.phase, 'compile');
  assert.notEqual(missing.exit_code, 0);
  assert.match(missing.stderr, /outside\.h/);
  const largeObject = await run('char data[2200000]={1};int main(){return data[0]==1?0:1;}');
  assert.equal(largeObject.phase, 'compile');
  assert.notEqual(largeObject.exit_code, 0);
  assert.match(largeObject.stderr, /temporary file exceeds 2 MiB/);

  const binary = await run('#include <stdio.h>\nint main(){putchar(255);return 0;}');
  assert.equal(binary.phase, 'run');
  assert.notEqual(binary.exit_code, 0);
  assert.match(binary.stderr, /stdout contains invalid UTF-8/);
  const trapped = await run('#include <stdio.h>\nint main(){puts("before");fflush(stdout);return *(volatile int*)100000000;}');
  assert.equal(trapped.phase, 'run');
  assert.notEqual(trapped.exit_code, 0);
  assert.equal(trapped.stdout, 'before\n');
  assert.ok(trapped.stderr);
  const tooMuchMemory = await run('#include <stdlib.h>\nint main(){int n=70*1024*1024;volatile char *p=malloc(n);if(!p)return 12;p[n-1]=37;return p[n-1]==37?0:13;}');
  assert.equal(tooMuchMemory.phase, 'run');
  assert.notEqual(tooMuchMemory.exit_code, 0);

  const flood = await run('#include <stdio.h>\nint main(){while(1)putchar(88);return 0;}');
  assert.equal(flood.phase, 'run');
  assert.notEqual(flood.exit_code, 0);
  assert.match(flood.stderr, /Output exceeds/);
  assert.ok(flood.stdout.length > 0 && flood.stdout.length <= 65536);
  assert.equal(await run('int main(){while(1){} return 0;}', {}, 40), 'host-timeout');

  const large = 'x'.repeat(256 * 1024 - 1);
  const tooLarge = await run('int main(){return 0;}', {
    stdin: large, files: { 'one.txt': large, 'two.txt': large, 'three.txt': large },
  });
  assert.equal(tooLarge.phase, 'compile');
  assert.match(tooLarge.stderr, /1 MiB/);
  console.log('PASS: xcc, model-authored C, stdio/ctype/string, nested headers, UTF-8, read-only project files, compiler diagnostics, partial output and resource limits.');
}
