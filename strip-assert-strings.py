#!/usr/bin/env python3
"""
strip-assert-strings.py

Removes && "string literal" suffixes from eigen_assert() conditions so that
__builtin_assume receives the actual boolean constraint rather than a
vacuously-true pointer expression.

Before:  eigen_assert(rows > 0 && "matrix must have at least one row");
After:   eigen_assert(rows > 0);

Only touches lines containing eigen_assert( with a && "..." pattern.
Handles the string literal appearing anywhere after && inside the parens.
"""

import re
import sys
from pathlib import Path

# Matches:  && "any string"  optionally followed by whitespace before the closing )
# The string may contain escaped quotes.
PATTERN = re.compile(r'\s*&&\s*"(?:[^"\\]|\\.)*"')

def strip_line(line: str) -> str:
    """Remove && "..." from an eigen_assert condition. Returns the modified line."""
    if 'eigen_assert(' not in line or '"' not in line:
        return line
    return PATTERN.sub('', line)

def process_file(path: Path, dry_run: bool = False) -> int:
    """Returns number of lines changed."""
    original = path.read_text(encoding='utf-8', errors='replace')
    lines = original.splitlines(keepends=True)
    changed = 0
    new_lines = []
    for line in lines:
        new_line = strip_line(line)
        if new_line != line:
            changed += 1
        new_lines.append(new_line)
    if changed and not dry_run:
        path.write_text(''.join(new_lines), encoding='utf-8')
    return changed

def main():
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', nargs='?', default='Eigen',
                        help='Directory to search (default: Eigen)')
    parser.add_argument('--dry-run', action='store_true',
                        help='Report changes without writing files')
    args = parser.parse_args()

    root = Path(args.root)
    headers = sorted(root.rglob('*.h'))

    total_files = 0
    total_lines = 0
    for path in headers:
        n = process_file(path, dry_run=args.dry_run)
        if n:
            total_files += 1
            total_lines += n
            print(f"  {'(dry) ' if args.dry_run else ''}{'modified' if not args.dry_run else 'would modify'} {path}  ({n} line{'s' if n != 1 else ''})")

    print(f"\n{'Would modify' if args.dry_run else 'Modified'} {total_lines} line(s) across {total_files} file(s).")

if __name__ == '__main__':
    main()
