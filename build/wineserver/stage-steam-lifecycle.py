#!/usr/bin/env python3
"""Observe actual Windows process death without modifying pinned Wine sources."""
from pathlib import Path
import sys

def stage(source: str) -> str:
    marker = 'static void process_killed( struct process *process )\n{\n'
    assert source.count(marker) == 1, 'Wine process-death entry changed'
    hook = '''    /* Metadata-only callback: no server/guest call under the registry lock.
     * Last Windows thread death also covers exits from native worker threads. */
#ifdef WINE_IOS
    extern void madeira_child_server_exited(unsigned, int) __attribute__((weak));
    if (madeira_child_server_exited) madeira_child_server_exited(process->id, process->exit_code);
#endif
'''
    return source.replace(marker, marker + hook, 1)

if __name__ == '__main__':
    source, destination = map(Path, sys.argv[1:])
    destination.write_text(stage(source.read_text()))
