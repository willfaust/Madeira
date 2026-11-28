#!/usr/bin/env python3
"""Compile the real diagnostic expression through build.sh's SDK probe/flags.
Synthetic SDK headers cover both member layouts; on macOS also syntax-check
against the installed iPhoneOS SDK. No Wine build or downloaded binaries needed.
"""
from pathlib import Path
import os, re, shutil, subprocess, tempfile

ROOT = Path(__file__).resolve().parents[2]
build = (ROOT / 'build/ntdll-unix/build.sh').read_text()
server = (ROOT / 'build/ntdll-unix/server_ios.c').read_text()
# ri_runnable_time is in nanoseconds (not Mach ticks); the expression after it is page_wait_ms
line = next(s for s in server.splitlines() if '(double)(ru.ri_runnable_time - pru.ri_runnable_time) / 1e6, ' in s)
expression = line.split(' / 1e6, ', 1)[1].rstrip().rstrip(',')
setup = re.search(r'            double page_wait_ms = .*?#endif', server, re.S)
setup = setup.group(0) if setup else ''
fragment = '#include <sys/resource.h>\n#define XP_MS(x) ((double)(x) / 1000000.0)\n' + '''
double report(struct rusage_info_v6 ru, struct rusage_info_v6 pru) {
''' + setup + '\nreturn ' + expression + ';\n}\n'

with tempfile.TemporaryDirectory(prefix='madeira-sdk-') as name:
    temp = Path(name)
    compiler = shutil.which(os.environ.get('CC', 'cc'))
    assert compiler, 'C compiler required'
    # Adapter substitutes only the SDK header layout and target flags. The
    # real build script's probe and compile_one function are executed unchanged.
    adapter = temp / 'xcrun'
    adapter.write_text('''#!/usr/bin/env python3
import json, os, subprocess, sys
args=sys.argv[1:]
if '--show-sdk-path' in args:
 print(os.environ['TEST_SDK']);sys.exit(0)
assert 'clang' in args,args
args=args[args.index('clang')+1:]
with open(os.environ['TEST_CALLS'],'a') as log:log.write(json.dumps(args)+'\\n')
clean=[];i=0
while i<len(args):
 a=args[i]
 if a in ['-arch','-isysroot']:i+=2;continue
 if a.startswith('-miphoneos-version-min='):i+=1;continue
 clean.append(a);i+=1
sys.exit(subprocess.run([os.environ['TEST_CC'],'-I'+os.environ['TEST_SDK'],'-Werror']+clean).returncode)
''')
    adapter.chmod(0o755)
    for present in [False, True]:
        sdk = temp / ('present' if present else 'absent')
        (sdk / 'sys').mkdir(parents=True)
        (sdk / 'sys/resource.h').write_text('struct rusage_info_v6 { unsigned long long ri_runnable_time;' +
            (' unsigned long long ri_page_wait_time_mach;' if present else '') + ' };\n')
        source = temp / 'sample.c'
        source.write_text(fragment + '''
int main(void) {
 struct rusage_info_v6 ru={0},pru={0};
''' + ('ru.ri_page_wait_time_mach=9000000;pru.ri_page_wait_time_mach=3000000;\n' if present else '') +
            'return report(ru,pru) != ' + ('6.0' if present else '-1.0') + ';\n}\n')
        fake = temp / 'wine'
        (fake / 'include').mkdir(parents=True, exist_ok=True)
        (fake / 'include/config.h').write_text('')
        shim = temp / 'shim'
        (shim / 'shims').mkdir(parents=True, exist_ok=True)
        (shim / 'shims/wine_ios_exit.h').write_text('')
        driver = temp / 'driver.sh'
        driver.write_text(build.split('echo "=== Building ntdll unix (iOS) ==="')[0] + '''
WINE_BUILD="$TEST_WINE"
BUILD_DIR="$TEST_SHIM"
OBJ_DIR="$TEST_OBJ"
mkdir -p "$OBJ_DIR"
compile_one "$TEST_SOURCE" sample
[ "$FAILED" = 0 ]
''')
        # Its location determines ROOT in the production preamble. Only Wine,
        # shim and output paths are overridden after the probe/function setup.
        calls = temp / 'calls.jsonl'
        calls.write_text('')
        env = dict(os.environ, PATH=str(temp)+os.pathsep+os.environ['PATH'], TEST_CC=compiler,
                   TEST_SDK=str(sdk), TEST_CALLS=str(calls), TEST_WINE=str(fake),
                   TEST_SHIM=str(shim), TEST_OBJ=str(temp/'obj'), TEST_SOURCE=str(source))
        result = subprocess.run(['bash', str(driver)], env=env)
        if result.returncode:
            print((temp/'obj/sample.err').read_text(), flush=True)
            raise RuntimeError('production diagnostic did not compile')
        import json
        commands = [json.loads(s) for s in calls.read_text().splitlines()]
        compile_command = next(c for c in commands if '-c' in c)
        flag = '-DMADEIRA_HAVE_RUSAGE_PAGE_WAIT_TIME_MACH=1'
        assert (flag in compile_command) == present, compile_command
        exe = temp / 'sample'
        subprocess.run([compiler, str(temp/'obj/sample.o'), '-o', str(exe)], check=True)
        subprocess.run([str(exe)], check=True)
        print('PASS actual probe/compile_one, field', 'present: delta=6 ms' if present else 'absent: pgw=-1')

    if shutil.which('xcrun'):
        sdk = subprocess.check_output(['xcrun','--sdk','iphoneos','--show-sdk-path'], text=True).strip()
        common = ['xcrun','--sdk','iphoneos','clang','-arch','arm64','-isysroot',sdk,
                  '-miphoneos-version-min=17.0','-Werror','-x','c','-fsyntax-only','-']
        probe = '#include <sys/resource.h>\nvoid p(struct rusage_info_v6 *r){(void)r->ri_page_wait_time_mach;}\n'
        present = subprocess.run(common,input=probe,text=True,capture_output=True).returncode == 0
        subprocess.run(common[:-1]+(['-DMADEIRA_HAVE_RUSAGE_PAGE_WAIT_TIME_MACH=1'] if present else [])+['-'],
                       input=fragment,text=True,check=True)
        print('PASS installed iPhoneOS SDK diagnostic syntax, field present =',present)
print('PASS rusage SDK portability')
