# Store logos

The five store marks in `app/Madeira/Assets.xcassets/Store*.imageset` (Steam, Epic Games, GOG, itch.io, EA)
come from [Simple Icons](https://simpleicons.org) 16.35.0 (`steam`, `epicgames`, `gogdotcom`, `itchdotio`, `ea`),
which is released under CC0 1.0. They are single-colour vectors, drawn white on the store's colour by
`NewLookStoreIcon` (`NewLook.swift`) and are not editable in the app.

The marks are trademarks of their owners (Valve, Epic Games, CD PROJEKT, itch corp., Electronic Arts). Madeira
uses them only to say which store a row is about; it is not made by or endorsed by any of them. To use the
stores' own artwork instead, replace the SVG in an image set; no code changes.

## Software

The Software row (Stores tab) uses a plain four-pane Windows glyph, `StoreWindows.imageset/windows.svg`, drawn for
Madeira from four squares: Simple Icons has no Windows mark. It is drawn white on Windows blue (`#0078D4`) by
`NewLookSoftwareIcon`. Windows is a trademark of Microsoft; the glyph only says the row is about Windows software and
Madeira is not made by or endorsed by Microsoft.
