import { execFile } from 'child_process';
import { promisify } from 'util';

const execFileAsync = promisify(execFile);
const TEST_PORT_RANGE = '3000-3005';

export default async function globalSetup(): Promise<void> {
  try {
    const { stdout } = await execFileAsync('lsof', [
      '-t',
      `-iTCP:${TEST_PORT_RANGE}`,
      '-sTCP:LISTEN',
    ]);
    const pids = new Set(
      stdout
        .split(/\s+/)
        .map(Number)
        .filter((pid) => Number.isInteger(pid) && pid > 0)
    );

    for (const pid of pids) {
      try {
        process.kill(pid, 'SIGKILL');
      } catch {
        // Process may have exited after lsof returned.
      }
    }
  } catch {
    // No listener, lsof unavailable, or cleanup failed; tests report any real port collision.
  }
}
