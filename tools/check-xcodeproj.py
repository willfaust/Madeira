#!/usr/bin/env python3
"""Structural check on app/Madeira.xcodeproj/project.pbxproj.

The project is an old-style pbxproj with no file-system-synchronized group, so
every source file is listed by hand in four places (PBXBuildFile,
PBXFileReference, the group's children, and the target's Sources phase). Hand
edits to it are invisible on any machine that cannot open Xcode: a mistake here
does not fail until someone with a Mac tries to build, which is the worst place
to find out.

Two things are checked, and the second is the one that actually bites:

  1. Internal consistency -- balanced braces, no duplicate object ids, and
     every id referenced by a build file or a build phase resolves to an
     object that exists.
  2. Registration completeness -- every compilable source file present in the
     tree is registered in the Sources phase, and every Sources entry points at
     a file that is actually on disk.

(2) is the failure that hid in this repo before: madeira-jit.js was edited for
weeks while the copy Xcode actually shipped was a stale base64 literal in
StikJITHelper.swift. A file that exists but is not in the target is not part of
the program.

Exit 0 if the project is sound, 1 otherwise.
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PBXPROJ = os.path.join(ROOT, "app", "Madeira.xcodeproj", "project.pbxproj")
SOURCE_ROOT = os.path.join(ROOT, "app", "Madeira")

# Extensions the target compiles. Headers are listed for navigation only.
COMPILED = (".swift", ".c", ".m", ".mm")

# Files present under app/Madeira that are deliberately not in the target.
NOT_COMPILED = {
    "WiFi_ExportOptions.plist",
}

# Object ids in this project are hand-written 8-character tags, not the
# 24-character UUIDs Xcode generates; accept both.
_ID_PATTERN = r"[0-9A-Fa-f]{8,24}"
# Definitions sit at the start of a line. Anchoring there keeps the pattern
# from matching assignment values inside a body (buildSettings = { ... }).
_ID_RE = re.compile(r"(?m)^[ \t]*(%s)(?:[ \t]*/\*[^\n]*?\*/)?[ \t]*=[ \t]*\{"
                    % _ID_PATTERN)


class Project:
    def __init__(self, text):
        self.text = text
        self.objects = {}        # id -> body
        self.duplicates = []
        self._parse()

    def _parse(self):
        text = self.text
        # A target id can legitimately reappear as a key inside another object's
        # buildSettings (per-target overrides), so only definitions sitting
        # directly inside the `objects = { ... }` dict are objects. Locate that
        # dict rather than assuming a literal depth.
        depths = [0] * (len(text) + 1)
        depth = 0
        for i, ch in enumerate(text):
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
            depths[i + 1] = depth

        objects_decl = re.search(r"objects\s*=\s*\{", text)
        if not objects_decl:
            return
        objects_depth = depths[objects_decl.end()]

        for match in _ID_RE.finditer(text):
            if depths[match.start()] != objects_depth:
                continue
            obj_id = match.group(1)
            start = text.index("{", match.end() - 1)
            end = self._match_brace(start)
            if end < 0:
                continue
            if obj_id in self.objects:
                self.duplicates.append(obj_id)
            self.objects[obj_id] = text[start + 1:end]

    def _match_brace(self, start):
        depth = 0
        for i in range(start, len(self.text)):
            ch = self.text[i]
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    return i
        return -1

    def of_type(self, isa):
        return {i: b for i, b in self.objects.items()
                if re.search(r"isa\s*=\s*%s\s*;" % isa, b)}

    def field(self, body, name):
        m = re.search(r"\b%s\s*=\s*([^;]+);" % name, body)
        if not m:
            return None
        # Values carry a trailing /* comment */ (fileRef, path, name); strip it.
        value = re.sub(r"/\*.*?\*/", "", m.group(1), flags=re.S).strip()
        return value or None

    def id_list(self, body, name):
        m = re.search(r"\b%s\s*=\s*\((.*?)\);" % name, body, re.S)
        if not m:
            return []
        return re.findall(_ID_PATTERN, m.group(1))


def check_braces(text):
    depth = 0
    for i, ch in enumerate(text):
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth < 0:
                return "unbalanced '}' at byte offset %d" % i
    if depth != 0:
        return "%d unclosed '{'" % depth
    return None


def registered_sources(project):
    """Return (ids_of_registered_files, list_of_errors)."""
    build_files = project.of_type("PBXBuildFile")
    errors = []
    sources = project.of_type("PBXSourcesBuildPhase")

    registered = set()
    for phase_id, body in sources.items():
        for build_file_id in project.id_list(body, "files"):
            if build_file_id not in build_files:
                errors.append("Sources phase %s references undefined build file %s"
                              % (phase_id, build_file_id))
                continue
            file_ref = project.field(build_files[build_file_id], "fileRef")
            if not file_ref:
                errors.append("build file %s has no fileRef" % build_file_id)
                continue
            if file_ref not in project.objects:
                errors.append("build file %s references undefined fileRef %s"
                              % (build_file_id, file_ref))
                continue
            registered.add(file_ref)
    return registered, errors


def on_disk_sources():
    found = {}
    for dirpath, dirnames, filenames in os.walk(SOURCE_ROOT):
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        for name in filenames:
            if name.endswith(COMPILED) and name not in NOT_COMPILED:
                rel = os.path.relpath(os.path.join(dirpath, name), SOURCE_ROOT)
                found[rel] = os.path.join(dirpath, name)
    return found


def main():
    with open(PBXPROJ, encoding="utf-8") as handle:
        text = handle.read()

    problems = []

    brace_problem = check_braces(text)
    if brace_problem:
        problems.append("project.pbxproj: %s" % brace_problem)

    project = Project(text)
    for obj_id in project.duplicates:
        problems.append("object id %s is defined more than once" % obj_id)

    registered, errors = registered_sources(project)
    problems.extend(errors)

    # Every registered file must exist on disk.
    for file_ref in sorted(registered):
        body = project.objects[file_ref]
        rel = project.field(body, "path") or project.field(body, "name")
        if not rel:
            continue
        rel = rel.strip('"')
        if not rel.endswith(COMPILED):
            continue
        if not os.path.exists(os.path.join(SOURCE_ROOT, rel)):
            problems.append("Sources phase lists %s, which does not exist in app/Madeira"
                            % rel)

    # Every compilable file on disk must be in the target.
    registered_paths = set()
    for file_ref in registered:
        rel = project.field(project.objects[file_ref], "path")
        if rel:
            registered_paths.add(rel.strip('"'))

    for rel in sorted(on_disk_sources()):
        if rel not in registered_paths:
            problems.append("%s exists in app/Madeira but is not in the Sources phase"
                            % rel)

    if problems:
        for problem in problems:
            print("check-xcodeproj: FAIL -- %s" % problem)
        return 1

    print("check-xcodeproj: OK -- %d objects, %d files in the Sources phase, "
          "all registered files present on disk"
          % (len(project.objects), len(registered)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
