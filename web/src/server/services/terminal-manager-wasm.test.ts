import { mkdir, mkdtemp, rm, writeFile } from 'fs/promises';
import { tmpdir } from 'os';
import path from 'path';
import { afterEach, describe, expect, it } from 'vitest';
import { resolveGhosttyWasmPath } from './terminal-manager.js';

describe('resolveGhosttyWasmPath', () => {
  let testRoot: string | undefined;

  afterEach(async () => {
    if (testRoot) {
      await rm(testRoot, { recursive: true, force: true });
      testRoot = undefined;
    }
  });

  it('finds the wasm asset next to a bundled npm package lib directory', async () => {
    testRoot = await mkdtemp(path.join(tmpdir(), 'vibetunnel-wasm-'));
    const moduleDir = path.join(testRoot, 'lib');
    const wasmPath = path.join(testRoot, 'public', 'ghostty-vt.wasm');
    await mkdir(moduleDir, { recursive: true });
    await mkdir(path.dirname(wasmPath), { recursive: true });
    await writeFile(wasmPath, 'wasm');

    expect(resolveGhosttyWasmPath(moduleDir)).toBe(wasmPath);
  });

  it('finds the installed ghostty-web wasm before assets are copied', () => {
    expect(resolveGhosttyWasmPath(path.join(tmpdir(), 'missing-module'))).toContain(
      'ghostty-web/ghostty-vt.wasm'
    );
  });
});
