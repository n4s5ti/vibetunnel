import { describe, expect, it } from 'vitest';
import { ProcessTreeAnalyzer } from './process-tree-analyzer.js';

describe('ProcessTreeAnalyzer', () => {
  it('keeps the full Linux start timestamp out of the command', () => {
    const analyzer = new ProcessTreeAnalyzer() as unknown as {
      parseUnixProcessOutput(
        output: string,
        isMacOS: boolean
      ): Array<{
        startTime?: string;
        command: string;
      }>;
    };
    const output = [
      'PID PPID PGID SID TTY STAT STARTED COMMAND',
      '123 1 123 123 pts/0 S Mon Jun 23 23:44:31 2025 /usr/bin/bash -l',
    ].join('\n');

    expect(analyzer.parseUnixProcessOutput(output, false)).toEqual([
      expect.objectContaining({
        startTime: 'Mon Jun 23 23:44:31 2025',
        command: '/usr/bin/bash -l',
      }),
    ]);
  });
});
