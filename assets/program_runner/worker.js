// Dedicated, single-use worker. Only the packaged compiler and its Wasm output execute.
// One C translation unit can include quoted project headers. Both includes and guest
// file reads look in the entry directory, then the project root. c2wasm provides
// __open_file(path, length), __read_file(fd, buffer, length), and __close_file(fd).
// Its built-in C subset has getchar/printf; it does not implement standard fopen.
'use strict';

const encoder = new TextEncoder();
const decoder = new TextDecoder('utf-8', { ignoreBOM: true });
const strictText = new TextDecoder('utf-8', { ignoreBOM: true, fatal: true });
const FILE_LIMIT = 256 * 1024 - 1; // c2wasm's maximum quoted include size
const PROJECT_LIMIT = 1024 * 1024;
const BINARY_LIMIT = 2 * 1024 * 1024;
const OUTPUT_LIMIT = 64 * 1024;
const MAX_PAGES = 1024; // 64 MiB per module, including the compiler
const WASI = { badFd: 8, invalid: 28, notFound: 44, notSeekable: 70, denied: 76 };

// c2wasm and its output define their own 32-bit linear memory. Set its maximum
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

// c2wasm skips system headers and implements getchar/printf directly. Supply the
// stdio EOF macro on that same directive line, preserving __LINE__ and diagnostics.
// These edits apply only to compilation; guest project reads retain the original bytes.
function cSource(bytes) {
  const source = bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf ? bytes.subarray(3) : bytes;
  const text = decoder.decode(source);
  const stdio = /^[ \t]*#[ \t]*include[ \t]*<stdio\.h>(?=[ \t]*(?:\/\/|\/\*|\r?$))/gm;
  const adjusted = text.replace(stdio, '#define EOF -1');
  return adjusted === text ? source : encoder.encode(adjusted);
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
  return { contents, directory: entry.substring(0, entry.lastIndexOf('/') + 1), sourceBytes };
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

function execute(bytes, args, stdin, project, stdout, stderr) {
  const exitSignal = {};
  const handles = new Map([[0, { bytes: stdin, pos: 0 }]]);
  const argv = args.map(arg => encoder.encode(arg + '\0'));
  let memory;
  let exitCode = 0;
  let nextFd = 4;
  const view = () => new DataView(memory.buffer);
  const slice = (ptr, len) => new Uint8Array(memory.buffer, ptr >>> 0, len >>> 0);
  const write32 = (ptr, value) => view().setUint32(ptr, value, true);

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
      if (fd !== 1 && fd !== 2) return WASI.badFd;
      const output = fd === 1 ? stdout : stderr;
      return transfer(iovs, count, result, bytes => {
        output.append(bytes);
        return bytes.length;
      });
    },
    fd_read(fd, iovs, count, result) {
      const handle = handles.get(fd);
      if (!handle) return WASI.badFd;
      return transfer(iovs, count, result, target => {
        const chunk = handle.bytes.subarray(handle.pos, handle.pos + target.length);
        target.set(chunk);
        handle.pos += chunk.length;
        return chunk.length;
      });
    },
    fd_close(fd) { return handles.delete(fd) ? 0 : WASI.badFd; },
    fd_seek() { return WASI.notSeekable; },
    fd_fdstat_set_flags(fd, flags) { return flags === 0 ? 0 : WASI.denied; },
    fd_fdstat_get(fd, output) {
      if (fd > 3 && !handles.has(fd)) return WASI.badFd;
      slice(output, 24).fill(0);
      const type = fd === 3 ? 3 : fd <= 2 ? 2 : 4;
      view().setUint8(output, type);
      // A read-only preopen. libc consults these rights when resolving fopen(..., "r").
      const read = 2n, write = 64n, openPath = 8192n;
      view().setBigUint64(output + 8, fd === 3 ? openPath : fd === 1 || fd === 2 ? write : read, true);
      if (fd === 3) view().setBigUint64(output + 16, read, true);
      return 0;
    },
    fd_prestat_get(fd, output) {
      if (fd !== 3) return WASI.badFd;
      slice(output, 8).fill(0);
      write32(output + 4, 1);
      return 0;
    },
    fd_prestat_dir_name(fd, output, len) {
      if (fd !== 3 || len < 1) return WASI.badFd;
      slice(output, 1)[0] = 46;
      return 0;
    },
    path_open(fd, _flags, ptr, len, openFlags, rights, _inherited, fdFlags, output) {
      if (fd !== 3) return WASI.badFd;
      if (openFlags || fdFlags || (rights & 64n)) return WASI.denied;
      if (len > 1024) return WASI.invalid;
      const name = decoder.decode(slice(ptr, len));
      if (name.startsWith('/') || name.includes('\\') || name.includes(':')) return WASI.denied;
      const nearEntry = canonicalPath(project.directory + name);
      const fromRoot = canonicalPath(name);
      const file = project.contents.get(nearEntry) ?? project.contents.get(fromRoot);
      if (!file) return WASI.notFound;
      // c2wasm's C preprocessor treats an embedded NUL in a quoted include as EOF.
      if (args[1] === '-b' && file.includes(0)) throw Error('C include contains a null byte.');
      if (handles.size >= 128) return 33; // ENFILE
      const number = nextFd++;
      handles.set(number, { bytes: args[1] === '-b' ? cSource(file) : file, pos: 0 });
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
      throw Error('Unsupported Wasm import: ' + imported.name);
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
  let stdout = new OutputBuffer(BINARY_LIMIT);
  let stderr = new OutputBuffer(OUTPUT_LIMIT);
  try {
    const stdin = encodeText(request.stdin, FILE_LIMIT, 'Standard input');
    const project = prepareProject(request, stdin.length);
    const compiler = new Uint8Array(request.compiler);
    if (compiler.length > BINARY_LIMIT) throw Error('Packaged compiler exceeds the byte limit.');
    const compileExit = execute(compiler, ['c2wasm', '-b'], cSource(project.sourceBytes), project, stdout, stderr);
    if (compileExit !== 0) {
      // Upstream writes syntax diagnostics to stdout even in binary mode.
      const diagnostic = decoder.decode(stdout.bytes().subarray(0, OUTPUT_LIMIT));
      return { phase, exit_code: compileExit, stdout: '', stderr: (stderr.text() + diagnostic).slice(0, OUTPUT_LIMIT) };
    }
    const program = stdout.bytes();
    if (!WebAssembly.validate(program)) throw Error('Compiler produced invalid WebAssembly.');
    const warnings = stderr.text();
    phase = 'run';
    stdout = new OutputBuffer(OUTPUT_LIMIT);
    stderr = new OutputBuffer(OUTPUT_LIMIT);
    stderr.append(encoder.encode(warnings));
    self.postMessage({ started: 'run' });
    const exit = execute(program, [request.entry], stdin, project, stdout, stderr);
    failureCode = exit || 1;
    return { phase, exit_code: exit, stdout: stdout.outputText('stdout'), stderr: stderr.outputText('stderr') };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const diagnostic = stderr.text().slice(0, OUTPUT_LIMIT - 1024);
    return { phase, exit_code: failureCode, stdout: phase === 'run' ? stdout.text() : '', stderr: diagnostic + (diagnostic ? '\n' : '') + message.slice(0, 1024) };
  }
}

self.onmessage = event => self.postMessage(report(event.data));
