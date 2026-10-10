#!/usr/bin/env python3
"""Credential-like values never reach a log through a command line.

Compiles the production build/madeira_redact.h into a small harness (ASan and
UBSan, -Wall -Wextra -Wconversion -Werror) and checks, on a POSIX host, with
fake values only:
  - the value of a credential option or key (-token VALUE, --access-token=VALUE,
    /password:VALUE, +server_password VALUE, password=VALUE, a URL's
    ?token=VALUE, any case and separators) becomes <redacted> and the name
    stays; a quoted value is hidden up to its closing quote, spaces included;
  - a value shaped like a signed ticket or bearer token is hidden on its own
    and after any -name= or -name:;
  - command lines without credentials are copied unchanged, byte for byte
    (paths, times, addresses, URLs, ordinary options, words that only contain
    a credential word);
  - the UTF-16 copy agrees with the char copy;
  - argv elements logged one per line carry an option's value to the next
    element, which is hidden whole;
  - for every output buffer size the copy is the full copy, cut and ended with
    "...", never longer than the buffer, and never shows a fake secret.
It also checks the wiring: every line that logs a command line or the
program's arguments (spawn_process and NtCreateUserProcess in process_ios.c,
its cmdline-tail echo, the environment trace in env_ios.c, the [WineProc] argv
lines in WineProcessBridge.m) goes through the header, no raw debugstr of a
command line is left in build/ntdll-unix, and the program still receives the
unredacted arguments.

No Wine, SDK, device or credentials are needed. Run with python3.
"""
import os, re, shutil, subprocess, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CC = os.environ.get("CC") or shutil.which("cc") or shutil.which("gcc") or shutil.which("clang")


def read(rel):
    return (ROOT / rel).read_text(encoding="utf-8").replace("\r\n", "\n")


def check(ok, what, detail=None):
    if not ok:
        raise SystemExit("FAIL: " + what + ("\n" + repr(detail) if detail is not None else ""))
    print("ok:", what)


# The harness. "line": each stdin line is redacted as a command line, char and
# UTF-16. "args": the program's own arguments are redacted as argv elements.
# "sweep": each stdin line is redacted into buffers of exactly 1..2n+24 units.
harness_c = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "madeira_redact.h"

static void wide(const char *in, size_t n, size_t cap, char *narrow)
{
    unsigned short *win = malloc((n + 1) * sizeof(*win)), *wout = malloc(cap * sizeof(*wout));
    size_t i, len;
    for (i = 0; i < n; i++) win[i] = (unsigned char)in[i];
    len = madeira_redact_line_w(win, n, wout, cap);
    for (i = 0; i < len; i++) narrow[i] = wout[i] < 128 ? (char)wout[i] : '?';
    narrow[len] = 0;
    if (wout[len]) narrow[0] = '!';             /* not terminated */
    free(win);
    free(wout);
}

int main(int argc, char **argv)
{
    static char line[8192], out[16384], wout[16384];
    int i;

    if (argc > 1 && !strcmp(argv[1], "args"))
    {
        int pending = 0;
        for (i = 2; i < argc; i++)
        {
            madeira_redact_arg_a(argv[i], &pending, out, sizeof(out));
            printf("%s\n", out);
        }
        return 0;
    }
    while (fgets(line, sizeof(line), stdin))
    {
        size_t n = strcspn(line, "\n"), cap;
        line[n] = 0;
        if (!strcmp(argv[1], "line"))
        {
            madeira_redact_line_a(line, n, out, sizeof(out));
            wide(line, n, sizeof(out), wout);
            printf("%s\n%s\n", out, wout);
            continue;
        }
        for (cap = 1; cap <= 2 * n + 24; cap++)
        {
            char *buf = malloc(cap);                /* exactly cap: ASan reports any write past it */
            size_t len = madeira_redact_line_a(line, n, buf, cap);
            wide(line, n, cap, wout);
            printf("%zu\x1f%zu\x1f%s\x1f%s\n", cap, len, buf, wout);
            free(buf);
        }
        printf("end\n");
    }
    return 0;
}
'''

R = "<redacted>"
TICKET = "v1:player:42:1700000000:FAKESIGNATUREFAKESIGNATURE"
BEARER = "eyJhbGciOiJub25lIn0.eyJzdWIiOiJGQUtFIn0.FAKESIGNATUREFAKESIGNATURE"
FAKE = ("FAKE", "SECRET", "SIGNATURE", "hunter2")   # every fake secret below contains one of these

redacted = [
    ("-name VALUE", "C:\\Games\\game.exe -token FAKE-TOKEN-1 -windowed", "C:\\Games\\game.exe -token " + R + " -windowed"),
    ("--name=VALUE", "game.exe --access-token=FAKE-TOKEN-2 -w 1280", "game.exe --access-token=" + R + " -w 1280"),
    ("/name:VALUE", "game.exe /password:hunter2 /quiet", "game.exe /password:" + R + " /quiet"),
    ("+name VALUE", "game.exe +server_password hunter2 +map start", "game.exe +server_password " + R + " +map start"),
    ("case and separators", "game.exe -USER_PASSWORD=FAKE -Session-Ticket FAKE2 -sessionid:FAKE3 -x",
     "game.exe -USER_PASSWORD=" + R + " -Session-Ticket " + R + " -sessionid:" + R + " -x"),
    ("other credential names", "g.exe -client_secret FAKE1 -apiKey FAKE2 --x-api-key=FAKE3 -credentials FAKE4 -authcode FAKE5 -passphrase FAKE6",
     "g.exe -client_secret " + R + " -apiKey " + R + " --x-api-key=" + R + " -credentials " + R + " -authcode " + R + " -passphrase " + R),
    ("pass and pwd as whole names", "g.exe -pass hunter2 -pwd hunter2 -x", "g.exe -pass " + R + " -pwd " + R + " -x"),
    ("name=VALUE", "game.exe password=hunter2 user=player1", "game.exe password=" + R + " user=player1"),
    ("quoted value with spaces", "game.exe -token \"FAKE WITH SPACES\" -next", "game.exe -token \"" + R + "\" -next"),
    ("quoted option=value", "game.exe \"--password=FAKE WITH SPACES\" -next", "game.exe \"--password=" + R + "\" -next"),
    ("option=quoted value", "game.exe --password=\"FAKE WITH SPACES\" -next", "game.exe --password=\"" + R + "\" -next"),
    ("escaped quote inside a value", "game.exe -token \"FA\\\"KE WITH SPACES\" -next", "game.exe -token \"" + R + "\" -next"),
    ("quoted header", "game.exe \"Authorization: Bearer FAKE\" -next", "game.exe \"Authorization: " + R + "\" -next"),
    ("URL query", "game.exe app://launch?user=player1&token=FAKE&lang=en -x", "game.exe app://launch?user=player1&token=" + R + " -x"),
    ("-name= VALUE", "game.exe -token= FAKE -x", "game.exe -token= " + R + " -x"),
    ("a value that looks like an option is still the value", "game.exe -token -FAKE-dash -x", "game.exe -token " + R + " -x"),
    ("two credentials", "game.exe -token FAKE1 --password=FAKE2", "game.exe -token " + R + " --password=" + R),
    ("whitespace kept", "game.exe   -token\tFAKE  z", "game.exe   -token\t" + R + "  z"),
    ("ticket after an option", "game.exe -launch " + TICKET + " -x", "game.exe -launch " + R + " -x"),
    ("ticket after -name=", "game.exe -k=" + TICKET + " -x", "game.exe -k=" + R + " -x"),
    ("ticket after /name:", "game.exe /k:" + TICKET, "game.exe /k:" + R),
    ("ticket alone", "game.exe " + TICKET + " tail", "game.exe " + R + " tail"),
    ("ticket after name=", "game.exe t=" + TICKET, "game.exe t=" + R),
    ("ticket in a URL query", "app://x?a=1&s=" + TICKET + "&b=2", "app://x?a=1&s=" + R),
    ("bearer token alone", "game.exe " + BEARER + " x", "game.exe " + R + " x"),
    ("bearer token quoted", "game.exe \"" + BEARER + "\"", "game.exe \"" + R + "\""),
]
unchanged = [
    "",
    "\"C:\\Program Files\\Game\\game.exe\" /c a:b:c --lang=en -w 1280 -h 720 D:\\data\\file:1:2:3",
    "x.exe 12:34:56:123 C:\\a\\b.txt http://host:80/path?q=1&page=2 [::1]:7777 fe80::1:2:3:4 aa:bb:cc:dd:ee:ff",
    "x.exe -tokenizer fast --no-token-cache 1 --token-file C:\\t.txt -bypass 2 -cwd C:\\ -passes 3 tokens.txt -ticketing on",
    "x.exe \"a password hint\" -passwordless -hash 0123456789abcdef0123456789abcdef {0F3A8C6E-2B4D-4E5F-9A1B-3C4D5E6F7A8B} 1.2.3.4",
    "x.exe -token",
    "x.exe -token \"\" -x",
    "x.exe -dx11 -windowed -ResX=1920 -ResY=1080 -nosplash +map start /desktop=shell,1280x720 explorer.exe",
]
args = [
    ("value element hidden whole", ["-token", "FAKE VALUE WITH SPACES", "-windowed"], ["-token", R, "-windowed"]),
    ("option=value element", ["--password=FAKE WITH SPACES", "-x"], ["--password=" + R, "-x"]),
    ("empty value element", ["-token", "", "-x"], ["-token", "", "-x"]),
    ("ticket element", ["-launch", TICKET], ["-launch", R]),
    ("option inside an element", ["-a -token FAKE b", "-x"], ["-a -token " + R, "-x"]),
    ("no credentials", ["C:\\Program Files\\Game\\game.exe", "-w", "1280", "a b"], ["C:\\Program Files\\Game\\game.exe", "-w", "1280", "a b"]),
    ("option last", ["-x", "-token"], ["-x", "-token"]),
]

with tempfile.TemporaryDirectory(prefix="madeira-redact-") as tmp:
    tmp = Path(tmp)
    (tmp / "h.c").write_text(harness_c, encoding="utf-8")
    exe = tmp / "h"
    subprocess.run([CC, "-std=gnu11", "-Wall", "-Wextra", "-Wconversion", "-Werror",
                    "-fsanitize=address,undefined", "-fno-sanitize-recover=all", "-g",
                    "-I", str(ROOT / "build"), str(tmp / "h.c"), "-o", str(exe)], check=True)

    def run(mode, stdin="", extra=()):
        r = subprocess.run([str(exe), mode, *extra], input=stdin, capture_output=True, text=True)
        if r.returncode or r.stderr:
            raise SystemExit("FAIL: harness (" + mode + ")\n" + r.stderr)
        return r.stdout

    inputs = [i for _, i, _ in redacted] + unchanged
    out = run("line", "".join(i + "\n" for i in inputs)).split("\n")
    narrow, wide = out[0:2 * len(inputs):2], out[1:2 * len(inputs):2]
    for (what, line, want), got in zip(redacted, narrow):
        check(got == want, "redacted: " + what, (line, got, want))
    for line, got in zip(unchanged, narrow[len(redacted):]):
        check(got == line, "unchanged: " + (line[:48] or "(empty line)"), got)
    check(wide == narrow, "the UTF-16 copy agrees with the char copy (%d lines)" % len(inputs),
          [(a, b) for a, b in zip(narrow, wide) if a != b])
    leaks = [g for g in narrow if any(f in g for f in FAKE)]
    check(not leaks, "no fake secret in any copy", leaks)

    for what, elements, want in args:
        got = run("args", extra=elements).split("\n")[:-1]
        check(got == want, "argv: " + what, (elements, got, want))

    sweep_lines = [i for _, i, _ in redacted] + unchanged[1:3]
    sweep = run("sweep", "".join(i + "\n" for i in sweep_lines)).split("end\n")
    caps = 0
    for line, block in zip(sweep_lines, sweep):
        full = narrow[inputs.index(line)]
        for row in block.splitlines():
            cap, length, got, got_w = row.split("\x1f")
            cap, length = int(cap), int(length)
            want = full if len(full) < cap else (full[:cap - 4] + "..." if cap > 4 else full[:cap - 1])
            if got != want or length != len(got) or got_w != got or any(f in got for f in FAKE):
                check(False, "every buffer size gives the full copy cut with \"...\"",
                      (line, cap, got, got_w, want))
            caps += 1
    check(caps > 1000, "every buffer size gives the full copy cut with \"...\", never more, no secret (%d sizes, char and UTF-16)" % caps)

# wiring
nt = ROOT / "build/ntdll-unix"
proc = read("build/ntdll-unix/process_ios.c")
env = read("build/ntdll-unix/env_ios.c")
bridge = read("app/Madeira/WineProcessBridge.m")
include = '#define MADEIRA_REDACT_WINE\n#include "../madeira_redact.h"'
check(include in proc and include in env, "process_ios.c and env_ios.c include the header with MADEIRA_REDACT_WINE")
raw = re.compile(r"debugstr_(?:us|w|wn)\s*\(\s*&?\s*(?:params\s*->\s*CommandLine|cmdline|cmd_line)\b")
hits = [f.name for f in sorted(nt.glob("*.c")) if raw.search(f.read_text(encoding="utf-8"))]
check(not hits, "no raw debugstr of a command line in build/ntdll-unix", hits)
check(re.search(r"creating child thread for %s[^;]*madeira_debugstr_cmdline_us\(\s*&params->CommandLine", proc, re.S),
      "spawn_process logs the redacted command line")
check(len(re.findall(r"madeira_debugstr_cmdline_us\(\s*&params->CommandLine\s*\)", proc)) == 3,
      "spawn_process ERR, NtCreateUserProcess ERR and TRACE: all three redacted")
check("madeira_debugstr_cmdline_w(cmdline)" in env, "env_ios.c's command-line TRACE is redacted")
tail = proc[proc.index("cmdline-tail(ml428)") - 1200:proc.index("cmdline-tail(ml428)")]
check("madeira_redact_line_w( (const unsigned short *)nbuf" in tail and "tail[ti] = (char)shown[" in tail,
      "the cmdline-tail echo is cut from the redacted line")
check('#include "../../build/madeira_redact.h"' in bridge
      and "madeira_redact_arg_a(extra_argv[i], &credential_next, shown, sizeof(shown));" in bridge
      and 'argv[%d] = %s\\n", 2 + i, shown);' in bridge
      and 'argv[%d] = %s\\n", 2 + i, extra_argv[i]);' not in bridge,
      "WineProcessBridge.m logs each argument redacted")
check("for (int i = 0; i < extra_argc; i++) argv[argc++] = extra_argv[i];" in bridge,
      "the program still receives the unredacted arguments")

print("PASS: credential-like values are redacted from every logged command line")
