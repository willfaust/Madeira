/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright 2026 David Brookes
 * Madeira Converter Exception: see LICENSE-EXCEPTION.md */
__declspec(dllexport) int ssd_probe_value(void) { return 73; }

int __stdcall DllMain(void *module, unsigned reason, void *reserved) { (void)module; (void)reason; (void)reserved; return 1; }
