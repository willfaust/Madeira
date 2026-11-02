#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""[thread-qos] env.MADEIRA_THREAD_QOS = "Pattern*=class;...": a guest thread whose name matches a rule runs at
that QoS class instead of USER_INTERACTIVE (build/ntdll-unix/thread_ios.c, build/ntdll-unix/build.sh).

Static anchors only: the rules are parsed once, unknown classes are ignored, no rule means off, the hook only
replaces the USER_INTERACTIVE request (an ECO class passes through), sync.c's QoS call is routed through the hook
by the build, a thread's class follows its name and is dropped at exit, and the log lines.
"""
import re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
src = (ROOT / 'build/ntdll-unix/thread_ios.c').read_text(encoding='utf-8', errors='replace')
build = (ROOT / 'build/ntdll-unix/build.sh').read_text(encoding='utf-8', errors='replace')
failures = 0

def check(cond, text):
    global failures
    print(('PASS: ' if cond else 'FAIL: ') + text)
    if not cond: failures += 1

def body(start):
    b = src[src.index(start):]
    return b[:b.index('\n}\n')]

init = body('static void tq_init_once(void)')
check(re.search(r'const char \*e = getenv\( "MADEIRA_THREAD_QOS" \);', init) is not None and 'if (!e || !*e) return;' in init,
      'unset or empty: no rules')
check('pthread_once( &tq_once, tq_init_once );' in body('static int tq_enabled(void)'), 'the rules are parsed once')
check("char *semi = strchr( p, ';' )" in init and "if (!(eq = strrchr( p, '=' ))) continue;" in init
      and 'tq_rules[tq_nrules++].cls = c;' in init and 'tq_nrules < TQ_MAX_RULES' in init,
      'rules are pattern=class pairs separated by ;, at most TQ_MAX_RULES')
check('if ((c = tq_parse_class( cls )) == QOS_CLASS_UNSPECIFIED)' in init and '"[thread-qos] ignored rule \\"%s=%s\\": unknown class\\n"' in init,
      'an unknown class is ignored and logged')
check('tq_on = tq_nrules > 0;' in init and '"[thread-qos] MADEIRA_THREAD_QOS: %d rule(s)%s\\n"' in init,
      'the switch is on only with at least one valid rule; the rule count is logged')
cls = body('static qos_class_t tq_parse_class( const char *s )')
check(all(f'"{n}"' in cls for n in ('user-interactive', 'user-initiated', 'default', 'utility', 'background')),
      'classes: user-interactive, user-initiated, default, utility, background')

hook = body('int madeira_guest_qos_self( qos_class_t cls, int rel )')
check('if (cls == QOS_CLASS_USER_INTERACTIVE && tq_self_tid && tq_enabled())' in hook,
      'the hook replaces only the USER_INTERACTIVE request, and only when on')
check('int r = pthread_set_qos_class_self_np( want, 0 );' in hook and 'if (!r) return 0;' in hook
      and hook.rstrip().endswith('return pthread_set_qos_class_self_np( cls, rel );'),
      'a matched thread gets its class; everything else passes through unchanged')
# sync.c is compiled from a patched copy in $OBJ_DIR (the keyed-event rewrite), or straight from $src.
check(build.count('-Dpthread_set_qos_class_self_np=madeira_guest_qos_self') == 1
      and re.search(r'compile_one "\$(?:src|OBJ_DIR/sync_ios\.c)" "sync" -Dpthread_set_qos_class_self_np=madeira_guest_qos_self', build) is not None,
      "the build routes sync.c's QoS call (ios_eco_apply_self) through the hook")
check('if (!tq_enabled()) return;' in body('static void ios_thread_qos_named( HANDLE handle, const char *name )')
      and 'ios_thread_qos_named( handle, nm );' in src, 'naming a thread applies its rule, only when on')
check('if (tq_enabled()) tq_store( tid, QOS_CLASS_UNSPECIFIED, NULL );' in body('\nvoid ios_thread_qos_exit( unsigned tid )\n{')
      and 'ios_thread_qos_start( (unsigned)(ULONG_PTR)teb->ClientId.UniqueThread );' in src,
      'a thread named before it ran gets its class at start; a reused tid does not inherit one')

catalog = ROOT / 'app/Madeira/ConfigCatalog.generated.swift'
if catalog.exists():
    text = catalog.read_text(encoding='utf-8')
    check('key: "env.MADEIRA_THREAD_QOS"' in text, 'the config catalog documents env.MADEIRA_THREAD_QOS')

print(f'check-thread-qos-switch: {"OK" if not failures else f"{failures} FAILED"}')
sys.exit(1 if failures else 0)
