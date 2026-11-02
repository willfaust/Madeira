#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 ft7t8drgwf-wq
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Games and downloads keep going when Madeira leaves the screen
(app/Madeira/BackgroundRun.swift, build/ntdll-unix/audio_null_ios.c).

Source checks (every host): the "audio" background mode in Info.plist; the
audio driver's keepalive / mute / halt switch and interruption restart, with
the endpoint never started while halted and kept while keepalive holds it;
the bridging header's declarations; the app starts BackgroundRun; every store
download (Steam and Epic, GOG, EA, itch.io) takes its background time through
BackgroundRun instead of UIApplication; the catalog lines; the project file.

The Swift fixture compiles the real BackgroundRun.swift against stand-ins for
UIKit, AVFoundation, UserNotifications and the driver, and drives it through
the app's notifications: a game keeps running (muted) and stops when its
minutes are used up; background-run = 0 halts the endpoint as before; a
download keeps going past iOS's grace period while Madeira runs, and pauses
when nothing keeps it; background-download = 0 leaves iOS's grace period
alone. Linux hosts without Swift run the source checks; --require-swift turns
a missing compiler into a failure.
"""
from pathlib import Path
import argparse
import os
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--require-swift', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
run_src = (app / 'BackgroundRun.swift').read_text()
driver = (root / 'build/ntdll-unix/audio_null_ios.c').read_text()
plist = (app / 'Info.plist').read_text()
bridging = (app / 'Madeira-Bridging-Header.h').read_text()
madeira_app = (app / 'MadeiraApp.swift').read_text()
catalog = (app / 'ConfigCatalog.generated.swift').read_text()
gen = (root / 'build/tools/gen-config-catalog.py').read_text()
project = (root / 'app/Madeira.xcodeproj/project.pbxproj').read_text()
failures = 0


def check(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


def body(source, start):
    i = source.index(start)
    return source[i:source.index('\n}\n', i)]


check('<key>UIBackgroundModes</key>\n\t<array>\n\t\t<string>audio</string>\n\t</array>' in plist,
      'Info.plist declares the audio background mode')
bg = body(driver, 'int madeira_audio_background(int keepalive, int mute, int halt)')
check('g_bg_keepalive = keepalive && !halt;' in bg and 'g_bg_halt = halt ? 1 : 0;' in bg, 'halt wins over keepalive')
check('ios_dev_create_locked(&fmt)' in bg and 'fmt.sample_rate = IOS_AUDIO_SAMPLE_RATE;' in bg,
      'keepalive makes the endpoint at the driver mix format when no client has')
check('if (g_dev.au && !g_dev.running && !g_bg_halt && (any || g_bg_keepalive))' in bg, 'starts unless halted')
check('(g_bg_halt || (!any && !g_bg_keepalive))' in bg, 'stops when halted, or when nothing wants it')
check('pthread_mutex_lock(&g_dev_lock);' in bg and 'pthread_mutex_unlock(&g_dev_lock);' in bg, 'under g_dev_lock')
start = body(driver, 'static void ios_dev_start(void)')
check('!g_dev.running && !g_bg_halt' in start, 'a client start does not restart a halted endpoint')
idle = body(driver, 'static void ios_dev_stop_if_idle(void)')
check('!any && !g_bg_keepalive' in idle, 'the last client stopping keeps a keepalive endpoint running')
cb = body(driver, 'static OSStatus ios_audio_render_cb(')
check(cb.index('ios_mix_stream(s, out') < cb.index('g_bg_mute') < cb.index('cb_epoch'),
      'mute silences after mixing, so rings drain and clocks keep time')
resume = body(driver, 'void madeira_audio_resume_after_interruption(void)')
check('AudioOutputUnitStop(g_dev.au);' in resume and 'AudioOutputUnitStart(g_dev.au);' in resume
      and 'g_dev.running' in resume, 'a running endpoint is restarted after an interruption')
check('int madeira_audio_background(int keepalive, int mute, int halt);' in bridging
      and 'void madeira_audio_resume_after_interruption(void);' in bridging, 'bridging header')
check('BackgroundRun.shared.start()' in madeira_app, 'the app starts BackgroundRun')
for name, label in [('SteamDownloadBackground.swift', 'Steam and Epic')]:
    src = (app / name).read_text()
    check('BackgroundRun.shared.beginTask(' in src and 'BackgroundRun.shared.endTask(' in src
          and 'beginBackgroundTask' not in src and 'endBackgroundTask' not in src,
          f'{label} downloads take their background time through BackgroundRun')
for key, kind, default in [('background-run', '.int', '10'), ('background-download', '.int', '60'),
                           ('background-sound', '.bool', '0'), ('background-gpu-gate', '.bool', '1'),
                           ('background-cpu', '.int', '50')]:
    check(f'ConfigOption(key: "{key}", ' in catalog and f'kind: {kind}, defaultValue: "{default}", category: "App & front end"'
          in catalog.split(f'ConfigOption(key: "{key}", ')[1].split('\n')[0] and f'"{key}": {{' in gen,
          f'catalog: {key} ({default})')
    check(f'MadeiraConfig.get("{key}")' in run_src, f'BackgroundRun reads {key}')
check(sum('BackgroundRun.swift' in line for line in project.splitlines()) == 4, 'BackgroundRun.swift is in the app target')
check(sum('Winios/BackgroundCPUCap.c' in line for line in project.splitlines()) == 4, 'BackgroundCPUCap.c is in the app target')
cap = (app / 'Winios/BackgroundCPUCap.c').read_text()
loop = body(cap, 'static void *cap_main(void *arg)')
check(loop.index('cap_resume_all()') < loop.index('pthread_mutex_lock(&cap_lock);\n            stop')
      and loop.index('if (stop) break;') < loop.index('if (credit < 0) cap_hold_all();'),
      'CPU cap: held threads run again first each tick, and nothing is held once it is told to stop')
check('if (credit > 2.0) credit = 2.0;' in loop and 'credit += dt * percent / 100.0 - (cpu - last_cpu);' in loop,
      'CPU cap: budget of percent of one core with at most 2 s of credit')
hold = body(cap, 'static void cap_hold_all(void)')
check(hold.index('cap_exempt(list[i])') < hold.index('thread_suspend('), 'CPU cap: names and policies are read before any thread is held')
ex = body(cap, 'static int cap_exempt(thread_act_t t)')
check('t == cap_main_port' in ex and 'THREAD_TIME_CONSTRAINT_POLICY' in ex and '!get_default' in ex and 'AURemoteIO' in ex,
      'CPU cap: the main thread, real-time threads and the audio threads keep running')
check('list[i] == self' in hold, 'CPU cap: the governor never holds itself')
stopfn = body(cap, 'void madeira_bg_cpu_cap(int percent)')
check('while (!cap_idle && pthread_cond_timedwait' in stopfn, 'CPU cap: turning it off waits until every thread runs again')
check(run_src.index('madeira_bg_cpu_cap(0)') < run_src.index('_ = madeira_audio_background(0, 0, 0)')
      and 'madeira_bg_cpu_cap(cap)' in run_src, 'BackgroundRun: cap on while keeping, off before anything else on return')
check('int madeira_audio_check(void)' in driver and 'if (last_valid && e == last_epoch)' in driver,
      'audio: a running endpoint that rendered nothing between two checks is restarted')
check('if (ios_dev_create_locked(&fmt) && !failed_before) g_dev.failed = 0;' in driver,
      'audio: a keep-alive that cannot make the endpoint does not take the game\'s sound away')
check('_ = madeira_audio_background(1, 0, 0)' in body(run_src, '    private func leaving()'),
      'BackgroundRun: the endpoint starts while Madeira is still in front, unmuted')
check(sum('Winios/MetalBackgroundGate.m' in line for line in project.splitlines()) == 4, 'MetalBackgroundGate.m is in the app target')
gate = (app / 'Winios/MetalBackgroundGate.m').read_text()
commit = body(gate, 'static void mbg_commit(id self, SEL cmd)')
check('if (![NSThread isMainThread]) mbg_wait();' in commit and commit.index('mbg_wait') < commit.index('(self, cmd)'),
      'Metal gate: off the main thread a commit waits first, then the original runs')
check('UIApplicationWillResignActiveNotification' in gate and 'UIApplicationDidBecomeActiveNotification' in gate
      and 'while (mbg_inactive) pthread_cond_wait' in gate, 'Metal gate: waits from WillResignActive until DidBecomeActive')
check('class_addMethod(cls, @selector(commit), (IMP)mbg_commit' in gate and 'method_setImplementation(m, (IMP)mbg_commit)' in gate,
      'Metal gate: an inherited commit is overridden on the class, its own replaced')
check('int madeira_metal_gate_install(void);' in bridging and 'MadeiraConfig.get("background-gpu-gate") != "0"' in run_src,
      'Metal gate: installed at start unless background-gpu-gate = 0')

stubs = r'''
import Foundation

struct UIBackgroundTaskIdentifier: Equatable { let raw: Int; static let invalid = UIBackgroundTaskIdentifier(raw: 0) }
final class UIApplication {
    nonisolated(unsafe) static let shared = UIApplication()
    static let willResignActiveNotification = Notification.Name("willResign")
    static let didEnterBackgroundNotification = Notification.Name("didEnterBackground")
    static let didBecomeActiveNotification = Notification.Name("didBecomeActive")
    var next = 1
    var tasks: [Int: () -> Void] = [:]
    func beginBackgroundTask(withName: String, expirationHandler: (() -> Void)?) -> UIBackgroundTaskIdentifier {
        next += 1; tasks[next] = expirationHandler ?? {}; return UIBackgroundTaskIdentifier(raw: next)
    }
    func endBackgroundTask(_ id: UIBackgroundTaskIdentifier) { tasks[id.raw] = nil }
    /// iOS's grace period ends for every task still begun.
    func expireAll() { let t = tasks; for (_, h) in t.sorted(by: { $0.key < $1.key }) { h() } }
}

let AVAudioSessionInterruptionTypeKey = "type"
final class AVAudioSession {
    nonisolated(unsafe) static let shared = AVAudioSession()
    static func sharedInstance() -> AVAudioSession { shared }
    static let interruptionNotification = Notification.Name("interruption")
    enum Category { case playback }
    struct CategoryOptions: OptionSet { let rawValue: Int; static let mixWithOthers = CategoryOptions(rawValue: 1) }
    struct SetActiveOptions: OptionSet { let rawValue: Int; static let notifyOthersOnDeactivation = SetActiveOptions(rawValue: 1) }
    enum InterruptionType: UInt { case began = 1, ended = 0 }
    var options: CategoryOptions = []
    var active = false
    func setCategory(_ c: Category, options: CategoryOptions) throws { self.options = options }
    func setActive(_ a: Bool) throws { active = a }
    func setActive(_ a: Bool, options: SetActiveOptions) throws { active = a }
}

enum UNAuthorizationStatus { case authorized, provisional, denied }
final class UNNotificationSettings { let authorizationStatus = UNAuthorizationStatus.authorized }
final class UNMutableNotificationContent { var title = ""; var body = "" }
final class UNNotificationRequest { let content: UNMutableNotificationContent
    init(identifier: String, content: UNMutableNotificationContent, trigger: Any?) { self.content = content } }
final class UNUserNotificationCenter {
    nonisolated(unsafe) static let shared = UNUserNotificationCenter()
    static func current() -> UNUserNotificationCenter { shared }
    var posted: [String] = []
    func getNotificationSettings(_ done: @escaping (UNNotificationSettings) -> Void) { done(UNNotificationSettings()) }
    func add(_ r: UNNotificationRequest) { posted.append(r.content.title) }
}

enum MadeiraConfig {
    nonisolated(unsafe) static var values: [String: String] = [:]
    static func get(_ key: String) -> String? { values[key] }
    static func gameValue(_ key: String) -> String? { nil }
}
final class LogStore {
    nonisolated(unsafe) static let shared = LogStore()
    var lines: [String] = []
    func log(_ m: String) { lines.append(m); print("  log: " + m) }
}
nonisolated(unsafe) var wineRunning: Int32 = 0
func wine_process_is_running() -> Int32 { wineRunning }
nonisolated(unsafe) var audioCalls: [[Int32]] = []
nonisolated(unsafe) var endpointStarts = true
func madeira_audio_background(_ k: Int32, _ m: Int32, _ h: Int32) -> Int32 {
    audioCalls.append([k, m, h]); return (k == 1 && endpointStarts) ? 1 : 0
}
func madeira_metal_gate_install() -> Int32 { 1 }
nonisolated(unsafe) var capCalls: [Int32] = []
func madeira_bg_cpu_cap(_ p: Int32) { capCalls.append(p) }
func madeira_bg_cpu_stats(_ c: UnsafeMutablePointer<Double>, _ w: UnsafeMutablePointer<Double>, _ h: UnsafeMutablePointer<Double>) {
    c.pointee = 30; w.pointee = 60; h.pointee = 20
}
nonisolated(unsafe) var checks = 0
func madeira_audio_check() -> Int32 { checks += 1; return 0 }
nonisolated(unsafe) var resumes = 0
func madeira_audio_resume_after_interruption() { resumes += 1 }
'''

main = r'''
import Foundation

nonisolated(unsafe) var failed = 0
func check(_ ok: Bool, _ label: String) { print((ok ? "PASS: " : "FAIL: ") + label); if !ok { failed += 1 } }
func post(_ name: Notification.Name, _ info: [AnyHashable: Any]? = nil) {
    NotificationCenter.default.post(name: name, object: nil, userInfo: info)
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
}

MainActor.assumeIsolated {
    let run = BackgroundRun.shared
    run.start()
    let session = AVAudioSession.shared

    // A game, defaults: keeps running, muted, mixing with other apps' audio.
    wineRunning = 1
    post(UIApplication.willResignActiveNotification)
    check(session.options.contains(.mixWithOthers), "leaving with a game: other apps' audio may play")
    check(audioCalls.last == [1, 0, 0], "leaving with a game: endpoint started while still in front, not muted")
    post(UIApplication.didEnterBackgroundNotification)
    check(audioCalls.last == [1, 1, 0], "game in the background: endpoint kept running, muted")
    check(capCalls.last == 50, "game in the background: CPU held under 50% of one core")
    check(LogStore.shared.lines.last?.contains("keeping Madeira running in the background for: game") == true, "log names the game")
    post(AVAudioSession.interruptionNotification, [AVAudioSessionInterruptionTypeKey: UInt(0)])
    check(resumes == 1, "an interruption that ended restarts the endpoint")
    post(UIApplication.didBecomeActiveNotification)
    check(audioCalls.last == [0, 0, 0] && session.options.isEmpty, "back: endpoint as the game wants it, category restored")
    check(capCalls.last == 0, "back: CPU cap off")
    let checksBefore = checks
    RunLoop.main.run(until: Date().addingTimeInterval(2))
    check(checks == checksBefore + 1, "back: the endpoint is checked again 1.5 s later")
    check(LogStore.shared.lines.contains { $0.contains("Madeira is active again: 50% of one core") }, "back: log gives the CPU use")
    MadeiraConfig.values["background-cpu"] = "0"
    post(UIApplication.didEnterBackgroundNotification)
    check(capCalls.last == 0 && LogStore.shared.lines.last?.contains("no CPU cap") == true, "background-cpu = 0: no cap")
    post(UIApplication.didBecomeActiveNotification)
    MadeiraConfig.values["background-cpu"] = nil

    // background-sound = 1: not muted.
    MadeiraConfig.values["background-sound"] = "1"
    post(UIApplication.didEnterBackgroundNotification)
    check(audioCalls.last == [1, 0, 0], "background-sound = 1: the game stays audible")
    post(UIApplication.didBecomeActiveNotification)
    MadeiraConfig.values["background-sound"] = nil

    // The game's minutes are used up: stop, halt, notify.
    MadeiraConfig.values["background-run"] = "0.001"
    post(UIApplication.didEnterBackgroundNotification)
    check(audioCalls.last == [1, 1, 0], "short limit: kept running at first")
    RunLoop.main.run(until: Date().addingTimeInterval(16))
    check(audioCalls.last == [0, 1, 1] && capCalls.last == 0, "after its minutes: cap off, endpoint halted so iOS suspends Madeira")
    check(UNUserNotificationCenter.shared.posted == ["Your game is paused"], "a notification says the game is paused")
    post(UIApplication.didBecomeActiveNotification)
    check(audioCalls.last == [0, 0, 0], "back: halt lifted")

    // background-run = 0: halted at once, as before the background mode existed.
    MadeiraConfig.values["background-run"] = "0"
    post(UIApplication.willResignActiveNotification)
    check(session.options.isEmpty, "background-run = 0: category untouched")
    post(UIApplication.didEnterBackgroundNotification)
    check(audioCalls.last == [0, 1, 1], "background-run = 0: endpoint halted at once")
    post(UIApplication.didBecomeActiveNotification)
    MadeiraConfig.values["background-run"] = nil

    // A download with no game: the session is made active, the download survives iOS's grace period.
    wineRunning = 0
    var paused = 0
    post(UIApplication.didEnterBackgroundNotification)
    check(audioCalls.last == [0, 1, 1], "nothing running: halted")
    var token: BackgroundRun.Token? = run.beginTask("GOG download") { paused += 1 }
    check(session.active && audioCalls.last == [1, 1, 0], "a download in the background: session active, endpoint running")
    UIApplication.shared.expireAll()
    check(paused == 0, "iOS's grace period ends: the download goes on while Madeira runs")
    run.endTask(token!); token = nil
    check(audioCalls.last == [0, 1, 1], "download finished: endpoint halted")
    post(UIApplication.didBecomeActiveNotification)
    check(!session.active, "back: the session made active for the download is inactive again")

    // A download that began in front: counts from when Madeira leaves.
    token = run.beginTask("EA download") { paused += 1 }
    check(audioCalls.last == [0, 0, 0], "in front: nothing started")
    post(UIApplication.didEnterBackgroundNotification)
    check(audioCalls.last == [1, 1, 0], "download begun in front keeps Madeira running once it leaves")
    post(UIApplication.didBecomeActiveNotification)
    run.endTask(token!)

    // The endpoint cannot start: the old grace period, then the pause.
    endpointStarts = false
    post(UIApplication.didEnterBackgroundNotification)
    token = run.beginTask("itch.io download") { paused += 1 }
    check(LogStore.shared.lines.last?.contains("cannot keep running") == true, "endpoint refused: logged")
    UIApplication.shared.expireAll()
    check(paused == 1, "endpoint refused: the download pauses when iOS's grace period ends")
    post(UIApplication.didBecomeActiveNotification)
    endpointStarts = true

    // background-download = 0: iOS's grace period only.
    MadeiraConfig.values["background-download"] = "0"
    post(UIApplication.didEnterBackgroundNotification)
    token = run.beginTask("Steam download") { paused += 1 }
    check(audioCalls.last == [0, 1, 1], "background-download = 0: nothing kept running")
    UIApplication.shared.expireAll()
    check(paused == 2, "background-download = 0: paused at the end of iOS's grace period, as before")
    post(UIApplication.didBecomeActiveNotification)
}
if failed > 0 { print("\(failed) failure(s)"); exit(1) }
'''

with tempfile.TemporaryDirectory(prefix='madeira-bg-run-') as directory:
    temporary = Path(directory)
    compiler = os.environ.get('SWIFTC') or shutil.which('swiftc')
    if compiler:
        source = run_src.replace('import AVFoundation\nimport UIKit\nimport UserNotifications\n', 'import Foundation\n')
        check(source != run_src, 'fixture: BackgroundRun.swift imports as expected')
        (temporary / 'BackgroundRun.swift').write_text(source)
        (temporary / 'Stubs.swift').write_text(stubs)
        (temporary / 'main.swift').write_text(main)
        binary = temporary / 'bgrun'
        subprocess.run([compiler, str(temporary / 'BackgroundRun.swift'), str(temporary / 'Stubs.swift'),
                        str(temporary / 'main.swift'), '-o', str(binary)], check=True)
        result = subprocess.run([str(binary)])
        check(result.returncode == 0, 'Swift fixture')
    elif args.require_swift:
        raise SystemExit('Swift compiler required for the background-run fixture')
    else:
        print('SKIP: Swift compiler unavailable locally; macOS CI must run this check with --require-swift')

if failures:
    raise SystemExit(f'{failures} check(s) failed')
print('All background-run checks passed')
