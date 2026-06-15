#!/usr/bin/env node

const { execFileSync } = require('child_process');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');

const webRoot = path.join(__dirname, '..');
const repoRoot = path.join(webRoot, '..');
const zigProjectCandidates = [
  process.env.VT_FWD_SOURCE_DIR,
  path.join(repoRoot, 'native', 'vt-fwd'),
  path.join(webRoot, 'native', 'vt-fwd'),
].filter(Boolean);
const zigProject = zigProjectCandidates.find((candidate) =>
  fs.existsSync(path.join(candidate, 'build.zig')),
);
if (!zigProject) {
  console.error('ERROR: Could not find vt-fwd source directory.');
  console.error('Checked:');
  for (const candidate of zigProjectCandidates) {
    console.error(`  - ${candidate}`);
  }
  console.error(
    'Set VT_FWD_SOURCE_DIR to the vt-fwd directory or ensure native/vt-fwd is available.',
  );
  process.exit(1);
}

const pkgPath = path.join(webRoot, 'package.json');
const pkg = fs.existsSync(pkgPath) ? JSON.parse(fs.readFileSync(pkgPath, 'utf8')) : {};
const version = pkg.version || 'unknown';
const requiredZigVersion = '0.16.0';

const zigOut = path.join(zigProject, 'zig-out', 'bin', 'vibetunnel-fwd');
const nativeOutDir = path.join(webRoot, 'native');
const binOutDir = path.join(webRoot, 'bin');
const args = process.argv.slice(2);

function getArgValue(name) {
  const index = args.indexOf(name);
  return index === -1 ? null : args[index + 1];
}

const target = getArgValue('--target');
const output = getArgValue('--output');
const nativeArch = getArgValue('--native-arch');
if (
  (args.includes('--target') && !target) ||
  (args.includes('--output') && !output) ||
  (args.includes('--native-arch') && !nativeArch)
) {
  console.error('ERROR: --target, --native-arch, and --output require values.');
  process.exit(1);
}
if (target && nativeArch) {
  console.error('ERROR: --target and --native-arch are mutually exclusive.');
  process.exit(1);
}
if (target?.includes('macos')) {
  console.error('ERROR: macOS forwarders must use --native-arch to avoid broken cross-target binaries.');
  process.exit(1);
}
if (nativeArch && !['arm64', 'x64'].includes(nativeArch)) {
  console.error(`ERROR: Unsupported native architecture: ${nativeArch}`);
  process.exit(1);
}
if (nativeArch && process.platform !== 'darwin') {
  console.error('ERROR: --native-arch is only supported on macOS.');
  process.exit(1);
}

function ensureDir(dir) {
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
}

console.log('Building zig forwarder...');
const zigFromEnv = process.env.ZIG;
const zigCandidates = zigFromEnv
  ? [zigFromEnv]
  : ['/usr/local/bin/zig', '/usr/bin/zig', '/bin/zig'];
let zigBinary =
  zigCandidates.find((candidate) => fs.existsSync(candidate)) ||
  (process.platform === 'win32' ? 'zig.exe' : 'zig');

let zigRunner = zigBinary;
let zigRunnerArgs = [];

if (nativeArch === 'arm64' && process.arch !== 'arm64') {
  console.error('ERROR: arm64 macOS forwarders must be built on Apple Silicon.');
  process.exit(1);
}

if (nativeArch === 'x64' && process.arch !== 'x64') {
  const archiveName = `zig-x86_64-macos-${requiredZigVersion}`;
  const cacheDir = path.join(
    os.homedir(),
    '.cache',
    'vibetunnel',
    'zig',
    requiredZigVersion,
    'x86_64-macos'
  );
  const cachedZig = path.join(cacheDir, archiveName, 'zig');
  if (!fs.existsSync(cachedZig)) {
    ensureDir(cacheDir);
    const archivePath = path.join(cacheDir, `${archiveName}.tar.xz`);
    const archiveUrl = `https://ziglang.org/download/${requiredZigVersion}/${archiveName}.tar.xz`;
    const expectedSha256 = '0387557ed1877bc6a2e1802c8391953baddba76081876301c522f52977b52ba7';
    console.log(`Downloading pinned x86_64 Zig ${requiredZigVersion}...`);
    execFileSync('curl', ['-fL', archiveUrl, '-o', archivePath], { stdio: 'inherit' });
    const actualSha256 = crypto
      .createHash('sha256')
      .update(fs.readFileSync(archivePath))
      .digest('hex');
    if (actualSha256 !== expectedSha256) {
      throw new Error(`x86_64 Zig checksum mismatch: ${actualSha256}`);
    }
    execFileSync('tar', ['-xJf', archivePath, '-C', cacheDir], { stdio: 'inherit' });
    fs.rmSync(archivePath);
  }
  zigBinary = cachedZig;
  zigRunner = 'arch';
  zigRunnerArgs = ['-x86_64', zigBinary];
}

const actualZigVersion = execFileSync(zigRunner, [...zigRunnerArgs, 'version'], {
  encoding: 'utf8',
}).trim();
if (actualZigVersion !== requiredZigVersion) {
  console.error(`ERROR: vibetunnel-fwd requires Zig ${requiredZigVersion}.`);
  console.error(`Found Zig ${actualZigVersion} at ${zigBinary}.`);
  process.exit(1);
}
const buildArgs = ['build', '-Doptimize=ReleaseFast', `-Dversion=${version}`];
if (target) {
  buildArgs.push(`-Dtarget=${target}`);
}
execFileSync(zigRunner, [...zigRunnerArgs, ...buildArgs], {
  cwd: zigProject,
  stdio: 'inherit',
});

if (!fs.existsSync(zigOut)) {
  console.error('ERROR: zig build did not produce vibetunnel-fwd binary');
  process.exit(1);
}

if (output) {
  const outputPath = path.resolve(webRoot, output);
  ensureDir(path.dirname(outputPath));
  fs.copyFileSync(zigOut, outputPath);
  fs.chmodSync(outputPath, 0o755);
  if (nativeArch) {
    const executableRunner = nativeArch === 'x64' && process.arch !== 'x64' ? 'arch' : outputPath;
    const executableArgs =
      executableRunner === 'arch' ? ['-x86_64', outputPath, '--help'] : ['--help'];
    execFileSync(executableRunner, executableArgs, {
      encoding: 'utf8',
      timeout: 5000,
    });
  }
  console.log(`✓ zig forwarder built: ${path.relative(repoRoot, outputPath)}`);
  process.exit(0);
}

ensureDir(nativeOutDir);
ensureDir(binOutDir);
const nativeDest = path.join(nativeOutDir, 'vibetunnel-fwd');
const binDest = path.join(binOutDir, 'vibetunnel-fwd');

fs.copyFileSync(zigOut, nativeDest);
fs.copyFileSync(zigOut, binDest);
fs.chmodSync(nativeDest, 0o755);
fs.chmodSync(binDest, 0o755);

console.log(`✓ zig forwarder built: ${path.relative(repoRoot, nativeDest)}`);
console.log(`✓ zig forwarder installed: ${path.relative(repoRoot, binDest)}`);
