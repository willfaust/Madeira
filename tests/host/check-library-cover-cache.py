#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Run the production cover cache on macOS, synthetic URLs/data only; no simulator or game data.

UIKit's bitmap wrapper and the grid frame callback have host adapters. The actual
Core Image spot baker runs on macOS. The production cache class is compiled with its
folder/session and initializer redirected to fixtures, plus bake gating, job-lifetime and disk-write counters. ImageIO, NSCache, operations and cache logic are production.
The SwiftUI bridge is separately typechecked against the iOS Simulator SDK.
"""
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
baseline = '--baseline' in sys.argv
source = (subprocess.check_output(['git', 'show', '8b52c1810a0b77614238001ed86199978865afd1:app/Madeira/LibraryCoverCache.swift'], cwd=root, text=True)
          if baseline else (root / 'app/Madeira/LibraryCoverCache.swift').read_text())
private_tmp = Path.home() / 'tmp'
private_tmp.mkdir(mode=0o700, exist_ok=True)
private_tmp.chmod(0o700)
with tempfile.TemporaryDirectory(prefix='pi-poster-cache.', dir=private_tmp) as directory:
    tmp = Path(directory)
    env = dict(os.environ, TMPDIR=directory, TMP=directory, TEMP=directory)
    end = source.index('\n/// The SwiftUI cards') if '\n/// The SwiftUI cards' in source else len(source)
    core = source[source.index('@MainActor\nfinal class LibraryCoverCache'):end]
    core, folder_replacements = re.subn(r'nonisolated static let folder: URL = .*?\.appendingPathComponent\("madeira-covers", isDirectory: true\)',
                  'nonisolated static let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)', core, flags=re.S)
    assert folder_replacements == 1 and '.cachesDirectory' not in core, 'fixture must never touch app caches'
    assert core.count('URLSession.shared') == 1, 'fixture must replace the production transport'
    core = core.replace('private init()', 'init()').replace('URLSession.shared', 'Fixture.session').replace('LibraryCoverSpot.baked(plain)', 'Fixture.bake(plain)')
    core = core.replace('@MainActor private final class Job {', '@MainActor private final class Job { deinit { Fixture.finishedJob() }')
    core = core.replace('self.source = source; self.bucket = bucket;', 'Fixture.startedJob(); self.source = source; self.bucket = bucket;')
    core = core.replace('static func didWriteDisk(bytes: Int) {', 'static func didWriteDisk(bytes: Int) { Fixture.wrote(bytes)')
    core = core.replace('static func trimDisk(cap: Int) {', 'static func trimDisk(cap: Int) { Fixture.trimmed()')
    core += '''
extension LibraryCoverCache {
    func fixtureRepeatNetwork(for key: String) {
        guard let job = loading[key] else { return }
        needsNetwork(job)
        needsNetwork(job)
    }
}
'''
    if baseline:
        # Only adapt the new ownership API so the old scheduler can run the same backpressure assertion.
        core += '''
extension LibraryCoverCache {
    func image(for source: Source, pixelWidth: Int, demand: UUID) -> (image: UIImage, exact: Bool)? {
        image(for: source, pixelWidth: pixelWidth)
    }
    func releaseDemand(_ token: UUID) {}
}
'''
    (tmp / 'Cache.swift').write_text('import Foundation\nimport Combine\nimport ImageIO\n' + core)
    files = root / 'tests/host/library-cover-cache'
    cell = (root / 'app/Madeira/LibraryGridCardCell.swift').read_text()
    refresh = cell[cell.index('    func refreshCover('):cell.index('    var coverSourceKey:')]
    (tmp / 'Cell.swift').write_text('''import Foundation
@MainActor final class CellCover {
    var image: UIImage?; var exact = false
    func setImage(_ image: UIImage?, exact: Bool) { self.image = image; self.exact = exact }
}
@MainActor final class CellHarness {
    struct Content { var source: LibraryCoverCache.Source? }
    var content: Content?
    var cover: CellCover? = CellCover()
    var coverKey: String?; var coverPixels = 0; var coverExact = false
    let coverDemand = UUID()
    var displayed = true
    let traitCollection = (displayScale: CGFloat(1), unused: 0)
    let bounds = CGRect(x: 0, y: 0, width: 96, height: 144)
''' + refresh + '}')
    glow = (root / 'app/Madeira/LibraryGridGlow.swift').read_text()
    entry = glow[glow.index('    private struct Entry {'):glow.index('    private var entries:')]
    entry = entry.replace('MTLTexture?', 'Int?').replace('LibraryGlowView.artPixels.width', 'GlowHarness.artPixels.width')
    release = glow[glow.index('    private func releaseCoverDemands'):glow.index('    private var raysBySeed:')]
    prepare = glow[glow.index('    private func prepare('):glow.index('    nonisolated private func makeTexture(')]
    (tmp / 'Glow.swift').write_text('''import Foundation
import CoreGraphics
struct AmbientMovie { init(seed: Int) {} }
struct LibraryGlowCard {
    let key: String; let frame: CGRect; let seed: Int; let dimmed: Bool
    let sourceKey: String?; let card: LibraryCoverCache.Source
}
@MainActor final class LibraryGridHostController {
    var page: Int?
    static func coverSource(_ source: LibraryCoverCache.Source, page: Int?) -> LibraryCoverCache.Source? { source }
}
enum LibraryGlowBase {
    static func render(cover: CGImage, dark: Bool, dimmed: Bool, artPixels: Int) -> [UInt16] { [0] }
}
@MainActor final class GlowHarness {
    nonisolated static let artPixels = CGSize(width: 100, height: 150)
    nonisolated static func artPixels(scale: CGFloat) -> Int { 100 }
    nonisolated static func scale(artWidth: CGFloat, reference: CGFloat) -> CGFloat { 1 }
    let referenceArt: CGFloat = 96
    let queueWork = DispatchQueue(label: "fixture.glow")
    var host: LibraryGridHostController?
    private var raysBySeed: [Int: Int] = [:]
    private var entries: [String: Entry] = [:]
    private var coverDemands: [String: UUID] = [:]
    nonisolated private func makeTexture(_ pixels: [UInt16], artPixels: Int) -> Int? { 1 }
    private func makeRays(seed: Int) -> Int? { 1 }
    private func markDirty() {}
    func render(_ card: LibraryGlowCard) {
        releaseCoverDemands(except: [card.key])
        var entry = entries[card.key] ?? Entry()
        prepare(&entry, card: card, dark: false)
        entries[card.key] = entry
    }
    func leave() { releaseCoverDemands() }
    func hasTexture(_ key: String) -> Bool { entries[key]?.texture != nil }
    func exact(_ key: String) -> Bool { entries[key]?.builtExact ?? false }
''' + entry + release + prepare + '}')
    spot = (root / 'app/Madeira/LibraryCoverSpot.swift').read_text().replace('import UIKit', 'import Foundation')
    (tmp / 'Spot.swift').write_text(spot)
    subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', str(files / 'Stubs.swift'), str(tmp / 'Cache.swift'), str(tmp / 'Spot.swift'),
                    str(tmp / 'Cell.swift'), str(tmp / 'Glow.swift'), str(files / 'Main.swift'), '-o', str(tmp / 'check')], env=env, check=True)
    subprocess.run([str(tmp / 'check'), str(tmp / 'covers')], env=env, check=True, timeout=180)
    if not baseline:
        library = (root / 'app/Madeira/Library.swift').read_text()
        steam = (root / 'app/Madeira/SteamGames.swift').read_text()
        views = library[library.index('struct LibraryArtwork: View {'):library.index('/// Which glow')]
        views += library[library.index('private struct AmbientGlowCard: View {'):library.index('/// Whether the app\'s liquid metal')]
        views += steam[steam.index('struct SteamGameArtwork: View {'):steam.index('// MARK: - Cards')]
        cell_deinit = cell[cell.index('    deinit {'):cell.index('    override init(frame:')]
        glow_deinit = glow[glow.index('    deinit {'):glow.index('    private func releaseCoverDemands')]
        views += 'final class CellLifetime: UICollectionViewCell { let coverDemand = UUID()\n' + cell_deinit + '}\n'
        views += 'final class GlowLifetime: UIView { var coverDemands: [String: UUID] = [:]\n' + glow_deinit + '}\n'
        (tmp / 'Views.swift').write_text('import SwiftUI\nimport UIKit\n' + views)
        sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
        subprocess.run(['xcrun', 'swiftc', '-typecheck', '-swift-version', '5', '-target', 'arm64-apple-ios17.0-simulator',
                        '-sdk', sdk, str(files / 'Typecheck.swift'), str(root / 'app/Madeira/LibraryCoverCache.swift'),
                        str(root / 'app/Madeira/LibraryCoverSpot.swift'), str(tmp / 'Views.swift')], env=env, check=True)
        print('PASS: actual cache, SwiftUI card/glow views and spot baker typecheck against iOS Simulator SDK (no session launched)')
