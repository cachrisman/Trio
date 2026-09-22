#!/usr/bin/env python3
import argparse
import glob
import json
import os
import re
import sys

KEY_RE = re.compile(r'TRIO-\d+')
FRONT_RE = re.compile(r'^\s*(key|title)\s*=\s*"((?:[^"\\]|\\.)*)"\s*$')
BULLET_RE = re.compile(r'^\s*[-*]\s+')


def task_files(tasks_dir):
    return sorted(glob.glob(os.path.join(tasks_dir, '*.md'))) + \
        sorted(glob.glob(os.path.join(tasks_dir, 'archive', '**', '*.md'), recursive=True))


def parse_task(path):
    with open(path, encoding='utf-8') as fh:
        lines = fh.read().splitlines()
    if not lines or lines[0].strip() != '+++':
        return None
    meta = {}
    body = []
    i = 1
    while i < len(lines) and lines[i].strip() != '+++':
        m = FRONT_RE.match(lines[i])
        if m:
            meta[m.group(1)] = m.group(2).replace('\\"', '"').replace('\\\\', '\\')
        i += 1
    if i < len(lines):
        body = lines[i + 1:]
    return {'key': meta.get('key'), 'title': meta.get('title', ''), 'body': body}


def find_task(tasks_dir, key):
    for path in task_files(tasks_dir):
        task = parse_task(path)
        if task and task['key'] == key:
            return task
    return None


def section_lines(body, names):
    # Return the lines under the first '## <name>' heading (case-insensitive,
    # trailing text after the name ignored), stopping at the next '## ' heading.
    out = []
    inside = False
    for line in body:
        if line.startswith('## '):
            if inside:
                break
            heading = line[3:].strip().lower()
            inside = any(heading == n or heading.startswith(n + ' ') for n in names)
            continue
        if inside:
            out.append(line)
    return out if inside else None


def child_keys(epic):
    keys = []
    for line in section_lines(epic['body'], ['contains']) or []:
        if BULLET_RE.match(line):
            for k in KEY_RE.findall(line):
                if k not in keys:
                    keys.append(k)
    return keys


def release_note(task):
    lines = section_lines(task['body'], ['release note', 'release notes'])
    if lines is None:
        return None
    text = '\n'.join(lines).strip()
    paragraphs = [' '.join(p.split()) for p in re.split(r'\n\s*\n', text) if p.strip()]
    return ' '.join(paragraphs) or None


# Section conventions:
#   - An epic lists its children under a '## Contains' heading, one task key
#     (TRIO-NNN) per '- ' or '* ' bullet line.
#   - A child task describes itself for the release body under a
#     '## Release note' heading; without one, its front-matter title is used.
def main():
    ap = argparse.ArgumentParser(description="Render the 'What's in this build' section for an epic")
    ap.add_argument('--epic', required=True, help='epic task key, e.g. TRIO-060')
    ap.add_argument('--tasks-dir', default='tasks', help='task graph directory (default: tasks)')
    ap.add_argument('--format', choices=['markdown', 'json'], default='markdown')
    args = ap.parse_args()

    epic = find_task(args.tasks_dir, args.epic)
    if epic is None:
        sys.stderr.write(f'build-task-notes: epic {args.epic} not found under {args.tasks_dir}\n')
        sys.exit(2)

    children = []
    for key in child_keys(epic):
        task = find_task(args.tasks_dir, key)
        if task is None:
            children.append({'key': key, 'title': None, 'release_note': None})
        else:
            children.append({'key': key, 'title': task['title'], 'release_note': release_note(task)})

    if args.format == 'json':
        print(json.dumps({'epic': epic['key'], 'epic_title': epic['title'], 'children': children}, indent=2))
        return
    if not children:
        return
    print("What's in this build:")
    for child in children:
        if child['title'] is None:
            print(f"- {child['key']} — (task file not found)")
        else:
            print(f"- {child['key']} — {child['release_note'] or child['title']}")
    print()


if __name__ == '__main__':
    main()
