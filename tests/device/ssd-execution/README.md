# External Windows execution fixture

Set `MINGW_BIN` to an llvm-mingw bin directory and run `./build.sh`. The output
contains `ssd_probe.exe`, its companion DLL and `assets/input.txt`. Copy that output
into a dedicated test directory in the registered SSD library and launch the
executable through the runtime being tested. The fixture writes a result file and
a beside-executable save. It sets its own working directory, so a pass does not
prove the app's native working-directory bridge. No Steam account is required. Use a fresh scratch directory per run: the save
checks deliberately refuse to overwrite existing fixture saves.

This fixture tests execution only. The independent `../ssd-probe` app tests scoped
data access and bookmark recovery. Use a separately signed test app and preserve
any existing game installation and saves.
