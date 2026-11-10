#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 ft7t8drgwf-wq
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Makes app/Madeira/game-config-folders.txt from the Ludusavi manifest.

The manifest (https://github.com/mtkennerly/ludusavi-manifest, data/manifest.yaml,
MIT) lists where games keep their files; its paths come from PCGamingWiki. Only
the folder paths of files tagged "config" that apply on Windows are kept.

    python3 build/tools/gen-game-config-folders.py manifest.yaml app/Madeira/game-config-folders.txt

Output, one game per line: its names (the Steam install folder names and the
title, lower case, joined by |), a tab, then its paths joined by tabs. A path
keeps the manifest's placeholders (<base>, <winLocalAppData>...): the app fills
them in for the game's Wine drive (GameConfigFolders in GameIniFiles.swift).
"""
import re, sys
import yaml

ALLOWED = {'<base>', '<game>', '<root>', '<home>', '<winAppData>', '<winLocalAppData>', '<winLocalAppDataLow>',
           '<winDocuments>', '<winPublic>', '<winProgramData>', '<winDir>', '<storeUserId>', '<storeGameId>', '<osUserName>'}


def windows(meta):
    whens = meta.get('when') or []
    return not whens or any(w.get('os') in (None, 'windows') for w in whens)


def main(source, target, commit=''):
    with open(source, encoding='utf-8') as f:
        manifest = yaml.safe_load(f)
    lines = {}
    for title, game in manifest.items():
        if not isinstance(game, dict):
            continue
        paths = []
        for path, meta in (game.get('files') or {}).items():
            meta = meta or {}
            if 'config' not in (meta.get('tags') or []) or not windows(meta):
                continue
            path = path.replace('\\', '/').rstrip('/')
            if '\t' in path or '|' in path or not path.startswith('<'):
                continue
            if any(p not in ALLOWED for p in re.findall(r'<[^>]+>', path)):
                continue
            if path not in paths:
                paths.append(path)
        if not paths:
            continue
        names = [n.strip().lower() for n in (game.get('installDir') or {})]
        names.append(title.strip().lower())
        names = [n for n in dict.fromkeys(names) if n and '|' not in n and '\t' not in n]
        key = '|'.join(names)
        lines[key] = lines.get(key, []) + [p for p in paths if p not in lines.get(key, [])]
    with open(target, 'w', encoding='utf-8', newline='\n') as out:
        out.write('# Where games keep their settings files, on Windows. Made by build/tools/gen-game-config-folders.py\n')
        out.write('# from the Ludusavi manifest (github.com/mtkennerly/ludusavi-manifest, MIT' +
                  (f', {commit}' if commit else '') + '),\n')
        out.write('# whose paths come from PCGamingWiki (pcgamingwiki.com). names|...<TAB>path<TAB>path\n')
        for key in sorted(lines):
            out.write(key + '\t' + '\t'.join(lines[key]) + '\n')
    print(f'{len(lines)} games')


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else '')
