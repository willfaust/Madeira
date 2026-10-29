# Playport game import port

Source: [Playport 412de5f](https://github.com/playportdev/playport/tree/412de5f8c0bdd26d84e0127eb5776ba992e3b152). Original source headers and license notices are retained. Playport's Madeira Converter Exception covers the imported app code. This work has no dependency on the upcoming BCD port.

Adds a saved import queue under Add game. Users can select a game folder or ZIP, choose local or registered external storage, pause or resume a job, and move a waiting job to the front. Copying resumes after a pause or app restart. A game launch pauses active imports. Source files stay in place.

The Playport importer checks Windows filenames, ZIP paths, cloud placeholders, symlinks and free space. Madeira adds per-job staging, a saved source identity, a final source check, and repeated external-drive identity checks. Completed imports are scanned through Madeira's existing library code.

Validation: 13 importer tests and 15 ContentKit tests passed. The package builds for the iOS 17 simulator target. All 101 production Swift source files typecheck together against that target. An isolated simulator app using the actual new view and queue completed a sample ZIP import; destination selection and the document picker opened correctly.

Draft: the isolated UI app stubs the game runtime. A full Madeira link and physical-device external-drive, provider permission, relaunch-resume and game-pause tests remain. No BCD UI or runtime changes are included.
