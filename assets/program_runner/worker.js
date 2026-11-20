// A single-use Web Worker compiles one C translation unit and runs its Wasm output.
'use strict';

const encoder = new TextEncoder();
const decoder = new TextDecoder('utf-8', { ignoreBOM: true });
const strictText = new TextDecoder('utf-8', { ignoreBOM: true, fatal: true });
const FILE_LIMIT = 256 * 1024 - 1;
const PROJECT_LIMIT = 1024 * 1024;
const BINARY_LIMIT = 2 * 1024 * 1024;
const OUTPUT_LIMIT = 64 * 1024;
const MAX_PAGES = 1024; // 64 MiB per module, including the compiler
const WASI = { badFd: 8, exists: 20, invalid: 28, directory: 31, notFound: 44, notDirectory: 54, notSeekable: 70, denied: 76 };

// xcc and its output define their own 32-bit linear memory. Set its maximum
// in the module before instantiation so even memory.grow inside a tight loop is bounded.
function withMemoryCeiling(bytes) {
  let offset = 8;
  function readU32() {
    let value = 0;
    for (let shift = 0; shift <= 28 && offset < bytes.length; shift += 7) {
      const byte = bytes[offset++];
      value += (byte & 127) * 2 ** shift;
      if (byte < 128 && value <= 0xffffffff) return value;
    }
    throw Error('Invalid Wasm section length.');
  }
  while (offset < bytes.length) {
    const start = offset;
    const section = bytes[offset++];
    const size = readU32();
    const end = offset + size;
    if (end > bytes.length) throw Error('Incomplete Wasm section.');
    if (section !== 5) {
      offset = end;
      continue;
    }
    if (readU32() !== 1) throw Error('Expected one Wasm memory.');
    const flags = readU32();
    if (flags !== 0 && flags !== 1) throw Error('Unsupported Wasm memory.');
    const minimum = readU32();
    const maximum = flags === 1 ? Math.min(readU32(), MAX_PAGES) : MAX_PAGES;
    if (minimum > maximum || offset !== end) throw Error('Program exceeds the memory limit.');
    // Both limits fit in two unsigned LEB128 bytes.
    const leb = value => value < 128 ? [value] : [(value & 127) | 128, value >> 7];
    const payload = [1, 1, ...leb(minimum), ...leb(maximum)];
    const rewritten = new Uint8Array(start + 2 + payload.length + bytes.length - end);
    rewritten.set(bytes.subarray(0, start));
    rewritten.set([5, payload.length, ...payload], start);
    rewritten.set(bytes.subarray(end), start + 2 + payload.length);
    return rewritten;
  }
  throw Error('Program has no Wasm memory.');
}

function canonicalPath(path) {
  if (!path || path.length > 1024 || path.startsWith('/') || /[\\:\x00-\x1f]/.test(path)) return null;
  const parts = [];
  for (const part of path.split('/')) {
    if (!part || part === '.') continue;
    if (part === '..') {
      if (!parts.length) return null;
      parts.pop();
    } else {
      parts.push(part);
    }
  }
  return parts.join('/') || null;
}

function encodeText(value, limit, label) {
  if (typeof value !== 'string' || value.length > limit) throw Error(label + ' is too large or invalid.');
  const bytes = encoder.encode(value);
  if (bytes.length > limit) throw Error(label + ' exceeds the byte limit.');
  return bytes;
}

function prepareProject({ entry, files, source }, stdinSize) {
  if (typeof entry !== 'string' || canonicalPath(entry) !== entry) throw Error('Invalid entry path.');
  if (!files || typeof files !== 'object' || Array.isArray(files)) throw Error('Invalid project files.');
  const names = Object.keys(files);
  if (names.length > 32) throw Error('Project exceeds 32 input files.');
  const contents = new Map();
  const sourceBytes = encodeText(source, FILE_LIMIT, 'Source');
  if (source.includes('\0')) throw Error('C source contains a null byte.');
  let total = sourceBytes.length + stdinSize;
  for (const name of names) {
    if (canonicalPath(name) !== name) throw Error('Invalid project file path.');
    const value = encodeText(files[name], FILE_LIMIT, name);
    total += value.length;
    if (total > PROJECT_LIMIT) throw Error('Project exceeds 1 MiB.');
    contents.set(name, value);
  }
  contents.set(entry, sourceBytes);
  return contents;
}

class OutputBuffer {
  constructor(limit) {
    this.storage = new Uint8Array(Math.min(1024, limit));
    this.limit = limit;
    this.used = 0;
  }
  append(bytes) {
    const needed = this.used + bytes.length;
    if (needed > this.limit) throw Error('Output exceeds ' + this.limit + ' bytes.');
    if (needed > this.storage.length) {
      const next = new Uint8Array(Math.min(this.limit, Math.max(needed, this.storage.length * 2)));
      next.set(this.storage);
      this.storage = next;
    }
    this.storage.set(bytes, this.used);
    this.used = needed;
  }
  bytes() { return this.storage.subarray(0, this.used); }
  text() { return decoder.decode(this.bytes()); }
  outputText(stream) {
    try {
      return strictText.decode(this.bytes());
    } catch {
      throw Error(stream + ' contains invalid UTF-8. Workspace output files require UTF-8 text.');
    }
  }
}

// The compiler sees /usr's packaged headers and libraries, the project, and a
// bounded writable /tmp. The guest gets a fresh instance with only project files.
class VirtualFiles {
  constructor(project, sysroot) {
    this.compiler = sysroot !== undefined;
    this.files = new Map();
    this.directories = new Set(['/work']);
    this.tempCapacity = 0;
    this.tempFilesCreated = 0;
    for (const [path, bytes] of project) {
      // Strip a UTF-8 BOM only in source text passed to the C compiler.
      const strip = this.compiler && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf;
      this.mount('/work/' + path, strip ? bytes.subarray(3) : bytes);
    }
    this.preopens = new Map([[3, { label: '.', base: '/work' }]]);
    if (this.compiler) {
      this.directories.add('/tmp');
      this.preopens.set(4, { label: '/', base: '' });
      for (const [path, data] of Object.entries(sysroot)) {
        if (!path.startsWith('/usr/include/') && !path.startsWith('/usr/lib/')) {
          throw Error('Invalid packaged C library path.');
        }
        this.mount(path, Uint8Array.from(atob(data), c => c.charCodeAt(0)));
      }
    }
  }

  mount(path, bytes) {
    this.files.set(path, { bytes, size: bytes.length, writable: false });
    for (let pos = path.indexOf('/', 1); pos !== -1; pos = path.indexOf('/', pos + 1)) {
      this.directories.add(path.slice(0, pos));
    }
  }

  resolve(fd, name) {
    const mount = this.preopens.get(fd);
    if (!mount || !name || name.startsWith('/') || /[\\:\x00-\x1f]/.test(name)) return null;
    if (name === '.') return mount.base || '/';
    const relative = canonicalPath(name);
    return relative ? mount.base + '/' + relative : null;
  }

  create(path) {
    if (++this.tempFilesCreated > 64) throw Error('Too many compiler temporary files.');
    const file = { bytes: new Uint8Array(0), size: 0, writable: true };
    this.files.set(path, file);
    return file;
  }

  write(handle, bytes) {
    const file = handle.file;
    if (handle.append) handle.pos = file.size;
    const end = handle.pos + bytes.length;
    if (end > BINARY_LIMIT) throw Error('Compiler temporary file exceeds 2 MiB.');
    if (end > file.bytes.length) {
      const capacity = Math.min(BINARY_LIMIT, Math.max(end, 1024, file.bytes.length * 2));
      this.tempCapacity += capacity - file.bytes.length;
      // Charge capacity for the entire run, including files already unlinked.
      if (this.tempCapacity > 8 * 1024 * 1024) throw Error('Compiler temporary files exceed 8 MiB.');
      const grown = new Uint8Array(capacity);
      grown.set(file.bytes.subarray(0, file.size));
      file.bytes = grown;
    }
    if (handle.pos > file.size) file.bytes.fill(0, file.size, handle.pos);
    file.bytes.set(bytes, handle.pos);
    file.size = Math.max(file.size, end);
    handle.pos = end;
  }
}

function execute(bytes, args, stdin, fs, stdout, stderr) {
  const exitSignal = {};
  const handles = new Map([[0, { file: { bytes: stdin, size: stdin.length }, pos: 0, read: true }]]);
  const argv = args.map(arg => encoder.encode(arg + '\0'));
  let memory;
  let exitCode = 0;
  let nextFd = 5;
  const view = () => new DataView(memory.buffer);
  const slice = (ptr, len) => new Uint8Array(memory.buffer, ptr >>> 0, len >>> 0);
  const write32 = (ptr, value) => view().setUint32(ptr, value, true);
  const write64 = (ptr, value) => view().setBigUint64(ptr, BigInt(value), true);
  const pathAt = (fd, ptr, len) => len > 1024 ? null : fs.resolve(fd, decoder.decode(slice(ptr, len)));

  function transfer(iovs, count, result, consume) {
    const descriptors = view();
    let total = 0;
    for (let i = 0; i < count; ++i) {
      const ptr = descriptors.getUint32(iovs + i * 8, true);
      const size = descriptors.getUint32(iovs + i * 8 + 4, true);
      const processed = consume(slice(ptr, size));
      total += processed;
      if (processed < size) break;
    }
    write32(result, total);
    return 0;
  }

  function stat(output, type, size) {
    slice(output, 64).fill(0);
    view().setUint8(output + 16, type);
    write64(output + 24, 1);
    write64(output + 32, size);
    return 0;
  }

  const wasi = {
    proc_exit(code) {
      exitCode = code;
      throw exitSignal;
    },
    args_sizes_get(count, size) {
      write32(count, argv.length);
      write32(size, argv.reduce((sum, arg) => sum + arg.length, 0));
      return 0;
    },
    args_get(pointers, buffer) {
      for (const arg of argv) {
        write32(pointers, buffer);
        slice(buffer, arg.length).set(arg);
        pointers += 4;
        buffer += arg.length;
      }
      return 0;
    },
    fd_write(fd, iovs, count, result) {
      const handle = handles.get(fd);
      if (fd !== 1 && fd !== 2 && !handle?.write) return WASI.badFd;
      return transfer(iovs, count, result, bytes => {
        if (fd === 1 || fd === 2) (fd === 1 ? stdout : stderr).append(bytes);
        else fs.write(handle, bytes);
        return bytes.length;
      });
    },
    fd_read(fd, iovs, count, result) {
      const handle = handles.get(fd);
      if (!handle?.read) return WASI.badFd;
      return transfer(iovs, count, result, target => {
        const file = handle.file;
        const chunk = file.bytes.subarray(handle.pos, Math.min(file.size, handle.pos + target.length));
        target.set(chunk);
        handle.pos += chunk.length;
        return chunk.length;
      });
    },
    fd_close(fd) { return handles.delete(fd) ? 0 : WASI.badFd; },
    fd_seek(fd, offset, whence, output) {
      if (fd < 3) return WASI.notSeekable;
      const handle = handles.get(fd);
      if (!handle) return WASI.badFd;
      const start = [0, handle.pos, handle.file.size][whence];
      const position = start + Number(offset);
      if (start === undefined || !Number.isSafeInteger(position) || position < 0) return WASI.invalid;
      handle.pos = position;
      write64(output, position);
      return 0;
    },
    fd_filestat_get(fd, output) {
      if (fd >= 0 && fd < 3) return stat(output, 2, 0);
      if (fs.preopens.has(fd)) return stat(output, 3, 0);
      const handle = handles.get(fd);
      return handle ? stat(output, 4, handle.file.size) : WASI.badFd;
    },
    fd_prestat_get(fd, output) {
      const mount = fs.preopens.get(fd);
      if (!mount) return WASI.badFd;
      slice(output, 8).fill(0);
      write32(output + 4, mount.label.length);
      return 0;
    },
    fd_prestat_dir_name(fd, output, len) {
      const mount = fs.preopens.get(fd);
      if (!mount || len < mount.label.length) return WASI.badFd;
      slice(output, mount.label.length).set(encoder.encode(mount.label));
      return 0;
    },
    path_filestat_get(fd, _flags, ptr, len, output) {
      const path = pathAt(fd, ptr, len);
      if (path === null) return WASI.denied;
      if (fs.directories.has(path)) return stat(output, 3, 0);
      const file = fs.files.get(path);
      return file ? stat(output, 4, file.size) : WASI.notFound;
    },
    path_unlink_file(fd, ptr, len) {
      const path = pathAt(fd, ptr, len);
      if (!fs.compiler || !path?.startsWith('/tmp/')) return WASI.denied;
      return fs.files.delete(path) ? 0 : WASI.notFound;
    },
    path_open(fd, _flags, ptr, len, openFlags, rights, _inherited, fdFlags, output) {
      const path = pathAt(fd, ptr, len);
      if (path === null) return WASI.denied;
      if (fs.directories.has(path)) return WASI.directory;
      if (openFlags & 2) return WASI.notDirectory;
      const write = Boolean(rights & 64n);
      const creating = Boolean(openFlags & 1);
      if ((write || creating || (openFlags & 8) || (fdFlags & 1)) &&
          !(fs.compiler && path.startsWith('/tmp/'))) return WASI.denied;
      let file = fs.files.get(path);
      if (!file && !creating) return WASI.notFound;
      if (file && creating && (openFlags & 4)) return WASI.exists;
      if (!file && !fs.directories.has(path.slice(0, path.lastIndexOf('/')))) return WASI.notFound;
      if (!file) file = fs.create(path);
      if (openFlags & 8) file.size = 0;
      if (handles.size >= 128) throw Error('Too many open files.');
      const number = nextFd++;
      handles.set(number, { file, pos: 0, append: Boolean(fdFlags & 1), read: Boolean(rights & 2n), write });
      write32(output, number);
      return 0;
    },
    random_get(ptr, len) {
      const target = slice(ptr, len);
      for (let i = 0; i < target.length; i += 65536) {
        self.crypto.getRandomValues(target.subarray(i, i + 65536));
      }
      return 0;
    },
  };
  const module = new WebAssembly.Module(withMemoryCeiling(bytes));
  for (const imported of WebAssembly.Module.imports(module)) {
    if (imported.module !== 'wasi_snapshot_preview1' || imported.kind !== 'function' ||
        !Object.prototype.hasOwnProperty.call(wasi, imported.name)) {
      throw Error('This local runtime does not provide ' + imported.name + '. Edit the source before rerunning.');
    }
  }
  const instance = new WebAssembly.Instance(module, { wasi_snapshot_preview1: wasi });
  memory = instance.exports.memory;
  try {
    instance.exports._start();
  } catch (error) {
    if (error !== exitSignal) throw error;
  }
  return exitCode;
}

function report(request) {
  let phase = 'compile';
  let failureCode = 1;
  let stdout = new OutputBuffer(OUTPUT_LIMIT);
  let stderr = new OutputBuffer(OUTPUT_LIMIT);
  try {
    const stdin = encodeText(request.stdin, FILE_LIMIT, 'Standard input');
    const project = prepareProject(request, stdin.length);
    const compiler = new Uint8Array(request.compiler);
    if (compiler.length > BINARY_LIMIT || !request.sysroot) throw Error('Invalid packaged C toolchain.');
    const fs = new VirtualFiles(project, request.sysroot);
    const destination = '/tmp/orb-program.wasm';
    const args = ['/usr/bin/cc', '-I/work', '-o', destination, '/work/' + request.entry];
    const compileExit = execute(compiler, args, new Uint8Array(0), fs, stdout, stderr);
    if (compileExit !== 0) return { phase, exit_code: compileExit, stdout: stdout.text(), stderr: stderr.text() };
    const output = fs.files.get(destination);
    if (!output) throw Error('Compiler did not produce a Wasm program.');
    const program = output.bytes.subarray(0, output.size);
    if (!WebAssembly.validate(program)) throw Error('Compiler produced invalid WebAssembly.');
    phase = 'run';
    stdout = new OutputBuffer(OUTPUT_LIMIT);
    stderr = new OutputBuffer(OUTPUT_LIMIT);
    self.postMessage({ started: 'run' });
    const exit = execute(program, [request.entry], stdin, new VirtualFiles(project), stdout, stderr);
    failureCode = exit || 1;
    return { phase, exit_code: exit, stdout: stdout.outputText('stdout'), stderr: stderr.outputText('stderr') };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const diagnostic = stderr.text().slice(0, OUTPUT_LIMIT - 1024);
    return { phase, exit_code: failureCode, stdout: stdout.text(), stderr: diagnostic + (diagnostic ? '\n' : '') + message.slice(0, 1024) };
  }
}
self.onmessage = event => self.postMessage(report(event.data));
