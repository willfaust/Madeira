#!/usr/bin/env python3
"""The SwiftUI cards take their covers from LibraryCoverCache (LibraryCachedArtwork), not AsyncImage. A big
library (370 Steam games) stuttered and covers kept popping in: AsyncImage decoded every full-size cover on the main
thread, kept nothing on disk and fetched a cover again when its card scrolled back. Read from the sources.

1. LibraryCachedArtwork asks the cache at the card's pixel width, redraws when its key lands, and keeps the shown
   bitmap only for its own key (a reused card never shows another game's cover).
2. The Steam, GOG, itch.io, Epic Games and EA artwork views and LibraryArtwork (cards, not the backdrop) use it while
   env.MADEIRA_LIBRARY_COVER_CACHE is on; AsyncImage stays as the fallback.
3. A not-downloaded Steam card gets the cache's baked blur spot (Source.spot), not three live blurred copies.
"""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[2]
app = root / "app/Madeira"
cache = (app / "LibraryCoverCache.swift").read_text(encoding="utf-8")
steam = (app / "SteamGames.swift").read_text(encoding="utf-8")
lib = (app / "Library.swift").read_text(encoding="utf-8")
cat = (app / "ConfigCatalog.generated.swift").read_text(encoding="utf-8")
ok = True


def check(what, cond):
    global ok
    print(("ok   " if cond else "FAIL ") + what)
    ok &= bool(cond)


start = cache.index("struct LibraryCachedArtwork: View {")
view = cache[start:cache.index("\n}\n", start)]
check("asks the cache at the card's pixel width",
      "geometry.size.width * scale" in view and "LibraryCoverCache.shared.image(for: source, pixelWidth: pixels)" in view)
check("redraws when its cover lands", "LibraryCoverCache.shared.updates" in view and "key == source?.variant" in view)
check("shows a bitmap only for its own key", "shownKey == source?.variant" in view and "onChange(of: source?.variant)" in view)
check("switch", 'MadeiraConfig.flag("MADEIRA_LIBRARY_COVER_CACHE")' in view)
check("a card off screen before its cover landed withdraws its request (cover-withdraw)",
      ".onDisappear { if let source, shownKey != source.variant { LibraryCoverCache.shared.withdraw(source) } }" in view)
start = cache.index("    func withdraw(_ source: Source) {")
wd = cache[start:cache.index("\n    }\n", start)]
check("withdraw drops only a waiting view request (not decoding, not a reconsider, not the ahead lane)",
      "job.lane == .demand, !job.reconsider, !job.decodingDownload" in wd and "!(job.op?.isExecuting ?? false)" in wd
      and "job.demanded = false" in wd and "if job.cancelable { cancel(job) }" in wd)
check("the SwiftUI cards keep about 150 covers resident, up to the ceiling, never lowering the grid's budget",
      "keepAtLeast(cards: 150, pixelWidth: pixels)" in view and "min(Self.budgetCeiling," in cache and "if bytes > budgetBytes { setBudget(bytes) }" in cache)
check("store sources keyed by store and game", 'Self(key: "\\(store)-\\(id)", urls: [url])' in cache)

for name, store in [("EpicGames", "epic"), ("GOGGames", "gog"), ("ItchGames", "itch"), ("EAGames", "ea")]:
    src = (app / f"{name}.swift").read_text(encoding="utf-8")
    use = f'LibraryCachedArtwork(source: .store("{store}", "\\(item.id)", item.cover))'
    check(f"{name}: cached cover, AsyncImage as fallback",
          "} else if LibraryCachedArtwork.enabled {" in src and use in src
          and src.index(use) < src.index("AsyncImage(url: item.cover)"))

start = steam.index("struct SteamGameArtwork: View {")
art = steam[start:steam.index("\n}\n", start)]
check("Steam: cached cover with the baked spot when not downloaded",
      "LibraryCoverCache.Source.steam(appID)" in art and "source.spot = notDownloaded" in art
      and "glyph: notDownloaded ? nil" in art and art.index("LibraryCachedArtwork(") < art.index("AsyncImage("))
start = lib.index("struct LibraryArtwork: View {")
art = lib[start:lib.index("\n}\n", start)]
check("LibraryArtwork: cards cached, the backdrop as before",
      "if !backdrop, LibraryCachedArtwork.enabled, let source = LibraryCoverCache.Source.entry(entry) {" in art
      and "UIImage(contentsOfFile:" in art.split("private var plain")[1])
check("catalog lists the switch", 'key: "env.MADEIRA_LIBRARY_COVER_CACHE", title: "Library covers from the cover cache"' in cat)

print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
