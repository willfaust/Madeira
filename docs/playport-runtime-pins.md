# Playport runtime integration

This pins FEX to 18d891e677392689158b33f492c48e1e565ee987 and DXMT to f50fdccc3e3e0b84433b34a72a3209753e10bcba.

Review the component changes first:
- https://github.com/willfaust/FEX/pull/35
- https://github.com/willfaust/dxmt/pull/50
- https://github.com/willfaust/dxmt/pull/51

The DXMT commit merges both component branches. The only merge conflict was the test list; both regression targets are retained. Both component commits are ancestors of the pin. No BCD changes are included.

The three changed DXMT production units and both regression sources cross-compile together for ARM64EC. FEX IR generation and both changed FEX C++ units compile. GPU execution, assembly regression execution and a complete Madeira runtime/device build remain merge gates. These source pins do not replace the checked-in runtime binaries; build them through the existing runtime CI workflow before release.
