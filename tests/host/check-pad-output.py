#!/usr/bin/env python3
"""ml2106: a game's controller output (DualSense output reports, XInput
rumble) on its way to the physical pad, checked on a POSIX host.

Compiles the production decoder (build/hidpad/hidpad_reports.h), the app's
effect mapping (app/Madeira/Winios/WiniosPadEffects.h) and the transport
(WiniosGamepad.c) and feeds them known DualSense output reports: the USB
report as Linux hid-playstation.c and SDL's SDL_hidapi_ps5.c write it, a
Bluetooth 0x31 report with its CRC-32 (seed 0xA2), and trigger effect blocks
produced by a C transcription of Nielk1's TriggerEffectGenerator (the encoder
libScePad's modes are documented by). Then checks the wiring that cannot be
compiled here: PadOutput.m's GameController/CoreHaptics calls, the Xcode
project and bridging header, GamepadInput.swift, the wineserver device and
win32u's vibration op.

No Wine build, SDK, controller or device. Run with python3; CC picks the
compiler.
"""
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]

test = r'''
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include "hidpad_reports.h"
#include "WiniosPadEffects.h"

static int near(float a, float b) { return fabsf(a - b) < 1e-4f; }

/* Nielk1's TriggerEffectGenerator, transcribed (gist 6d54cc2c...; MIT License,
 * John "Nielk1" Klein). Test-only: none of it ships in the app. */
static void gen_off(uint8_t *d) { memset(d, 0, 11); d[0] = 0x05; }
static void gen_zones(uint8_t *d, uint8_t mode, const uint8_t *level /* 10 x 0-8 */)
{
    uint32_t values = 0; uint16_t active = 0; int i;
    memset(d, 0, 11);
    for (i = 0; i < 10; i++)
        if (level[i]) { values |= (uint32_t)((level[i] - 1) & 7) << (3 * i); active |= 1 << i; }
    d[0] = mode; d[1] = active & 0xff; d[2] = active >> 8;
    d[3] = values & 0xff; d[4] = (values >> 8) & 0xff; d[5] = (values >> 16) & 0xff; d[6] = values >> 24;
}
static void gen_feedback(uint8_t *d, int position, int strength)
{
    uint8_t level[10] = {0}; int i;
    if (!strength) { gen_off(d); return; }
    for (i = position; i < 10; i++) level[i] = strength;
    gen_zones(d, 0x21, level);
}
static void gen_vibration(uint8_t *d, int position, int amplitude, int frequency)
{
    uint8_t level[10] = {0}; int i;
    if (!amplitude || !frequency) { gen_off(d); return; }
    for (i = position; i < 10; i++) level[i] = amplitude;
    gen_zones(d, 0x26, level);
    d[9] = frequency;
}
static void gen_span(uint8_t *d, uint8_t mode, int start, int end)
{
    uint16_t zones = (1 << start) | (1 << end);
    memset(d, 0, 11);
    d[0] = mode; d[1] = zones & 0xff; d[2] = zones >> 8;
}
static void gen_weapon(uint8_t *d, int start, int end, int strength)
{ gen_span(d, 0x25, start, end); d[3] = strength - 1; }
static void gen_bow(uint8_t *d, int start, int end, int strength, int snap)
{ gen_span(d, 0x22, start, end); d[3] = ((strength - 1) & 7) | (((snap - 1) & 7) << 3); }
static void gen_galloping(uint8_t *d, int start, int end, int first, int second, int freq)
{ gen_span(d, 0x23, start, end); d[3] = (second & 7) | ((first & 7) << 3); d[4] = freq; }
static void gen_machine(uint8_t *d, int start, int end, int a, int b, int freq, int period)
{ gen_span(d, 0x27, start, end); d[3] = (a & 7) | ((b & 7) << 3); d[4] = freq; d[5] = period; }

static int notified;
static void count_notify(void) { notified++; }

/* A USB effects report: report ID 0x02, the 47-byte common block. */
static void usb_report(uint8_t *r, uint8_t f0, uint8_t f1, uint8_t f2)
{
    memset(r, 0, HIDPAD_DS_OUT_USB_LEN);
    r[0] = 0x02; r[1] = f0; r[2] = f1; r[39] = f2;
}

static void check_decoder(void)
{
    struct winios_hidpad_output out = {0};
    uint8_t r[HIDPAD_DS_OUT_BT_LEN], bt[HIDPAD_DS_OUT_BT_LEN];
    uint32_t crc;
    unsigned int i;

    /* CRC-32 known answer (zlib/IEEE). */
    assert(hidpad_crc32(0, (const unsigned char *)"123456789", 9) == 0xcbf43926u);

    /* Linux hid-playstation, rumble v1: COMPATIBLE_VIBRATION | HAPTICS_SELECT. */
    usb_report(r, 0x03, 0, 0);
    r[3] = 0x40; r[4] = 0xc0;
    assert(hidpad_dualsense_output(r, HIDPAD_DS_OUT_USB_LEN, &out));
    assert(out.rumble_valid && out.rumble_right == 0x40 && out.rumble_left == 0xc0);
    assert(hidpad_dualsense_output_flags(r, HIDPAD_DS_OUT_USB_LEN) == 0x03);

    /* SDL, firmware 2.24+: "improved rumble emulation" in valid_flag2 alone. */
    usb_report(r, 0, 0, 0x04);
    r[3] = 0x11; r[4] = 0x22;
    assert(hidpad_dualsense_output(r, HIDPAD_DS_OUT_USB_LEN, &out));
    assert(out.rumble_right == 0x11 && out.rumble_left == 0x22);

    /* Triggers only, no rumble bit (what an audio-haptics game sends): the
     * motors stay as they were. Linux's 63-byte USB report is accepted too. */
    {
        uint8_t big[63];
        memset(big, 0, sizeof(big));
        big[0] = 0x02; big[1] = 0x0c; big[3] = 0xff; big[4] = 0xff;
        gen_feedback(big + 11, 3, 6);
        gen_weapon(big + 22, 2, 6, 8);
        assert(hidpad_dualsense_output(big, sizeof(big), &out));
        assert(out.rumble_right == 0x11 && out.rumble_left == 0x22);
        assert(out.trigger_valid[1] && out.trigger[1][0] == 0x21);
        assert(out.trigger_valid[0] && out.trigger[0][0] == 0x25);
    }

    /* Lightbar, player LEDs, mic LED, power reduction. */
    usb_report(r, 0, 0x01 | 0x04 | 0x10 | 0x40, 0);
    r[9] = 1; r[37] = 0x52; r[44] = 0x15; r[45] = 0x10; r[46] = 0x20; r[47] = 0x30;
    assert(hidpad_dualsense_output(r, HIDPAD_DS_OUT_USB_LEN, &out));
    assert(out.mute_led_valid && out.mute_led == 1);
    assert(out.power_valid && out.power_reduction == 0x52);
    assert(out.player_leds_valid && out.player_leds == 0x15);
    assert(out.lightbar_valid && out.red == 0x10 && out.green == 0x20 && out.blue == 0x30);
    assert(out.rumble_left == 0x22 && out.trigger[0][0] == 0x25);   /* untouched */

    /* Not an effects report / too short. */
    r[0] = 0x05;
    assert(!hidpad_dualsense_output(r, HIDPAD_DS_OUT_USB_LEN, &out));
    r[0] = 0x02;
    assert(!hidpad_dualsense_output(r, HIDPAD_DS_OUT_USB_LEN - 1, &out));

    /* Bluetooth 0x31 as SDL frames it: [1] tag/sequence, [2] 0x10, common
     * block at [3], CRC-32 of 0xA2 + report[0..73] at [74..77]. */
    memset(bt, 0, sizeof(bt));
    bt[0] = 0x31; bt[1] = 0x20; bt[2] = 0x10;
    bt[3] = 0x03 | 0x04; bt[4] = 0x04;
    bt[5] = 0x7f; bt[6] = 0x80;
    gen_vibration(bt + 3 + 10, 4, 8, 40);
    bt[3 + 44] = 0xff; bt[3 + 45] = 0x00; bt[3 + 46] = 0x80;
    crc = hidpad_dualsense_bt_crc(bt, sizeof(bt));
    for (i = 0; i < 4; i++) bt[74 + i] = (crc >> (8 * i)) & 0xff;
    {
        /* the same CRC computed in one go over 0xA2 + report */
        uint8_t framed[1 + 74];
        framed[0] = 0xa2; memcpy(framed + 1, bt, 74);
        assert(hidpad_crc32(0, framed, sizeof(framed)) == crc);
    }
    memset(&out, 0, sizeof(out));
    assert(hidpad_dualsense_output(bt, sizeof(bt), &out));
    assert(out.rumble_right == 0x7f && out.rumble_left == 0x80 && out.trigger[1][0] == 0x26);
    assert(out.lightbar_valid && out.red == 0xff && out.blue == 0x80);
    bt[74] ^= 1;
    memset(&out, 0, sizeof(out));
    assert(!hidpad_dualsense_output(bt, sizeof(bt), &out) && !out.rumble_valid);
    assert(!hidpad_dualsense_output(bt, sizeof(bt) - 1, &out));
}

static void plan(const uint8_t *e, unsigned int reduction, struct winios_trigger_plan *p)
{
    winios_trigger_plan_from_effect(e, reduction, p);
    assert(p->mode == e[0]);
}

static void check_triggers(void)
{
    struct winios_trigger_plan p;
    uint8_t e[11];
    int i;

    gen_off(e); plan(e, 0, &p); assert(p.kind == WINIOS_TRIGGER_OFF);
    memset(e, 0, sizeof(e)); plan(e, 0, &p); assert(p.kind == WINIOS_TRIGGER_OFF);

    gen_feedback(e, 3, 6); plan(e, 0, &p);
    assert(p.kind == WINIOS_TRIGGER_FEEDBACK && near(p.start, 3 / 9.0f) && near(p.strength, 6 / 8.0f));
    for (i = 0; i < 10; i++) assert(near(p.zones[i], i < 3 ? 0 : 6 / 8.0f));
    gen_feedback(e, 0, 8); plan(e, 0, &p);
    assert(p.kind == WINIOS_TRIGGER_FEEDBACK && near(p.start, 0) && near(p.strength, 1));
    gen_feedback(e, 0, 8); plan(e, 4, &p);                         /* 50 % trigger power */
    assert(near(p.strength, 0.5f) && near(p.zones[9], 0.5f));
    gen_feedback(e, 5, 0); plan(e, 0, &p); assert(p.kind == WINIOS_TRIGGER_OFF);

    {   /* MultiplePositionFeedback / SlopeFeedback: needs the positional mode */
        static const uint8_t slope[10] = { 0, 0, 1, 2, 3, 4, 5, 6, 7, 8 };
        gen_zones(e, 0x21, slope); plan(e, 0, &p);
        assert(p.kind == WINIOS_TRIGGER_FEEDBACK_ZONES && near(p.start, 2 / 9.0f) && near(p.strength, 1));
        for (i = 0; i < 10; i++) assert(near(p.zones[i], slope[i] / 8.0f));
    }
    {   /* a resistance band that ends before the trigger does */
        static const uint8_t band[10] = { 0, 0, 4, 4, 4, 0, 0, 0, 0, 0 };
        gen_zones(e, 0x21, band); plan(e, 0, &p);
        assert(p.kind == WINIOS_TRIGGER_FEEDBACK_ZONES && near(p.zones[4], 0.5f) && near(p.zones[5], 0));
    }

    gen_weapon(e, 2, 6, 8); plan(e, 0, &p);
    assert(p.kind == WINIOS_TRIGGER_WEAPON && near(p.start, 2 / 9.0f) && near(p.end, 6 / 9.0f) && near(p.strength, 1));
    gen_weapon(e, 4, 8, 3); plan(e, 0, &p);
    assert(near(p.start, 4 / 9.0f) && near(p.end, 8 / 9.0f) && near(p.strength, 3 / 8.0f));

    gen_vibration(e, 0, 8, 30); plan(e, 0, &p);
    assert(p.kind == WINIOS_TRIGGER_VIBRATION && near(p.start, 0) && near(p.amplitude, 1) && near(p.frequency, 30 / 255.0f));
    gen_vibration(e, 6, 2, 200); plan(e, 0, &p);
    assert(p.kind == WINIOS_TRIGGER_VIBRATION && near(p.start, 6 / 9.0f) && near(p.amplitude, 2 / 8.0f));
    {
        static const uint8_t amps[10] = { 8, 8, 4, 4, 0, 0, 2, 2, 2, 2 };
        gen_zones(e, 0x26, amps); e[9] = 60; plan(e, 0, &p);
        assert(p.kind == WINIOS_TRIGGER_VIBRATION_ZONES && near(p.frequency, 60 / 255.0f));
        for (i = 0; i < 10; i++) assert(near(p.zones[i], amps[i] / 8.0f));
        e[9] = 0; plan(e, 0, &p); assert(p.kind == WINIOS_TRIGGER_OFF);   /* 0 Hz */
    }

    gen_bow(e, 1, 5, 6, 8); plan(e, 0, &p);
    assert(p.kind == WINIOS_TRIGGER_WEAPON && near(p.start, 1 / 9.0f) && near(p.end, 5 / 9.0f) && near(p.strength, 6 / 8.0f));
    gen_galloping(e, 0, 9, 2, 5, 25); plan(e, 0, &p);
    assert(p.kind == WINIOS_TRIGGER_VIBRATION && near(p.start, 0) && near(p.frequency, 25 / 255.0f) && p.amplitude > 0);
    gen_machine(e, 2, 9, 3, 7, 10, 20); plan(e, 0, &p);
    assert(p.kind == WINIOS_TRIGGER_VIBRATION && near(p.start, 2 / 9.0f) && near(p.amplitude, 1) && near(p.frequency, 10 / 255.0f));
    gen_machine(e, 2, 9, 0, 0, 10, 20); plan(e, 0, &p); assert(p.kind == WINIOS_TRIGGER_OFF);

    memset(e, 0, sizeof(e)); e[0] = 0x01; e[1] = 0x40; e[2] = 0xff; plan(e, 0, &p);
    assert(p.kind == WINIOS_TRIGGER_FEEDBACK && near(p.start, 0x40 / 255.0f) && near(p.strength, 1));
    memset(e, 0, sizeof(e)); e[0] = 0x02; e[1] = 0x20; e[2] = 0x80; e[3] = 0x80; plan(e, 0, &p);
    assert(p.kind == WINIOS_TRIGGER_WEAPON && near(p.end, 0x80 / 255.0f) && near(p.strength, 0x80 / 255.0f));
    memset(e, 0, sizeof(e)); e[0] = 0x06; e[1] = 0x50; e[2] = 0xff; e[3] = 0x10; plan(e, 0, &p);
    assert(p.kind == WINIOS_TRIGGER_VIBRATION && near(p.frequency, 0x50 / 255.0f) && near(p.start, 0x10 / 255.0f));
    memset(e, 0, sizeof(e)); e[0] = 0x11; e[1] = 0x30; e[2] = 5; plan(e, 0, &p);
    assert(p.kind == WINIOS_TRIGGER_FEEDBACK && near(p.strength, 0.5f));
    memset(e, 0, sizeof(e)); e[0] = 0x12; e[1] = 0x10; e[2] = 0x50; e[3] = 10; plan(e, 0, &p);
    assert(p.kind == WINIOS_TRIGGER_WEAPON && near(p.strength, 1));
    memset(e, 0, sizeof(e)); e[0] = 0xfc; plan(e, 0, &p); assert(p.kind == WINIOS_TRIGGER_KEEP);
    memset(e, 0, sizeof(e)); e[0] = 0x7e; plan(e, 0, &p); assert(p.kind == WINIOS_TRIGGER_OFF);
    assert(!strcmp(winios_trigger_mode_name(0x25), "weapon") && !strcmp(winios_trigger_mode_name(0x7e), "unknown"));
}

static void check_levels(void)
{
    assert(near(winios_rumble_level(255, 0), 1) && near(winios_rumble_level(0, 0), 0));
    assert(near(winios_rumble_level(255, 4), 0.5f) && near(winios_rumble_level(255, 7), 0.125f));
    assert(near(winios_xinput_level(65535), 1) && near(winios_xinput_level(0), 0));
    /* Linux hid-playstation player_ids: players 1-4 exact, 5 and odd patterns by count. */
    assert(winios_player_index_from_leds(0x00) == -1);
    assert(winios_player_index_from_leds(0x04) == 0 && winios_player_index_from_leds(0x0a) == 1);
    assert(winios_player_index_from_leds(0x15) == 2 && winios_player_index_from_leds(0x1b) == 3);
    assert(winios_player_index_from_leds(0x1f) == 3 && winios_player_index_from_leds(0x01) == 0);
    assert(winios_player_index_from_leds(0x24) == 0);        /* bit 5 (instant) is not an LED */
}

static void check_transport(void)
{
    struct winios_hidpad_output out = {0}, seen;

    assert(sizeof(struct winios_hidpad_output) == 44);
    winios_pad_output_set_notify(count_notify);
    out.rumble_valid = 1; out.rumble_left = 3;
    winios_hidpad_set_output(&out);
    assert(notified == 1 && winios_hidpad_get_output(0, &seen) && seen.serial == 1);
    winios_hidpad_set_output(&out);                          /* no change, no notify */
    assert(notified == 1);
    out.power_valid = 1; out.power_reduction = 0x30;
    winios_hidpad_set_output(&out);
    assert(notified == 2 && winios_hidpad_get_output(1, &seen) && seen.power_reduction == 0x30);
    winios_pad_output_set_notify(NULL);
    out.rumble_left = 4;
    winios_hidpad_set_output(&out);
    assert(notified == 2);
}

int main(void)
{
    check_decoder();
    check_triggers();
    check_levels();
    check_transport();
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix='madeira-pad-output-') as tmp:
    source = Path(tmp) / 'check.c'
    binary = Path(tmp) / 'check'
    source.write_text(test)
    cc = os.environ.get('CC', 'cc')
    subprocess.run([cc, '-std=c11', '-Wall', '-Wextra', '-Werror', '-Wno-unused-function', '-O1', '-pthread',
                    '-I', str(root / 'build/hidpad'), '-I', str(root / 'app/Madeira/Winios'),
                    str(source), str(root / 'app/Madeira/Winios/WiniosGamepad.c'), '-lm', '-o', str(binary)],
                   check=True)
    subprocess.run([str(binary)], check=True)


# ---- wiring that cannot be compiled on this host (no SDK): read it.
def need(cond, what):
    if not cond:
        sys.exit('FAIL: ' + what)

pad = (root / 'app/Madeira/PadOutput.m').read_text()
for sel in ['setModeOff', 'setModeFeedbackWithStartPosition:', 'resistiveStrength:',
            'setModeWeaponWithStartPosition:', 'endPosition:', 'setModeVibrationWithStartPosition:',
            'amplitude:', 'frequency:', '@"setModeFeedbackWithResistiveStrengths:"',
            '@"setModeVibrationWithAmplitudes:frequency:"', 'respondsToSelector:',
            'createEngineWithLocality:', 'GCHapticsLocalityLeftHandle', 'GCHapticsLocalityRightHandle',
            'CHHapticEventTypeHapticContinuous', 'CHHapticDynamicParameterIDHapticIntensityControl',
            'createPlayerWithPattern:', 'stoppedHandler', 'resetHandler', 'light.color',
            'playerIndex', 'winios_pad_output_set_notify', 'winios_gamepad_set_rumble_caps',
            'winios_hidpad_get_output', 'winios_gamepad_get_vibration']:
    need(sel in pad, f'PadOutput.m lacks {sel}')
need(re.search(r'float values\[WINIOS_TRIGGER_ZONES\]', pad), 'positional struct must be float values[10]')
# Asking a DualSense for the advanced player broke the engine for the plain one
# too (God of War on device); game controllers get plain players only, and a
# failed set-up backs off and tries again instead of giving up.
need('createAdvancedPlayerWithPattern' not in pad, 'PadOutput.m must not ask a game controller for the advanced player')
need('_retryAt' in pad and 'RUMBLE_GIVE_UP' in pad, 'PadOutput.m must back off and retry a failed haptics set-up')
need('dispatch_get_main_queue' in pad and 'atomic_flag_test_and_set' in pad,
     'PadOutput.m must coalesce the notify into one main-thread pass')

proj = (root / 'app/Madeira.xcodeproj/project.pbxproj').read_text()
need(proj.count('PadOutput.m in Sources') == 2, 'PadOutput.m must be a build file and in the Sources phase')
need('path = PadOutput.m;' in proj and 'path = PadOutput.h;' in proj, 'PadOutput file references missing')
bridge = (root / 'app/Madeira/Madeira-Bridging-Header.h').read_text()
need('#import "PadOutput.h"' in bridge, 'bridging header must import PadOutput.h')

swift = (root / 'app/Madeira/GamepadInput.swift').read_text()
need('madeira_pad_output_configure(' in swift and 'madeira_pad_output_set_slot(Int32(i), controllers[i])' in swift
     and 'madeira_pad_output_set_active(' in swift, 'GamepadInput.swift must drive PadOutput')
# four exits (the HID mode's non-PlayStation pad takes XInput, ml2100) and the definition
need(swift.count('beginPadOutput(') == 5, 'every beginPadSession exit configures the output once')
need('MadeiraConfig.get("env.MADEIRA_PAD_OUTPUT")' in swift, 'the switch must be readable by the config catalog')

driver = (root / 'build/win32u-unix/driver_ios.c').read_text()
hidpad = (root / 'build/wineserver/hidpad_ios.c').read_text()
need('last handle closed' in hidpad and 'hidpad_output_log' in hidpad,
     'hidpad_ios.c must log [hidpad-out] and reset rumble/triggers when the game lets go')
need('case 2:' in driver and 'winios_gamepad_set_vibration( index, motors[0], motors[1] )' in driver,
     'driver_ios.c must store XInput vibration (op 2)')
# ml2190: a slot re-reads its controller's live extendedGamepad profile (env.MADEIRA_XINPUT_PROFILE_CHECK).
check_src = swift
assert 'static let profileCheck: Bool = flag("MADEIRA_XINPUT_PROFILE_CHECK")' in check_src
assert 'if Self.profileCheck, let i = controllers.firstIndex(where: { $0 === controller }) {' in check_src
assert 'if profiles[i] !== profile {' in check_src and 'attach(profile, slot: i)' in check_src
assert 'Timer.scheduledTimer(withTimeInterval: 2, repeats: true)' in check_src
print('PASS: DualSense output decoder (USB v1/v2 rumble, triggers-only, LEDs, power, Bluetooth 0x31 + CRC), '
      'trigger effects -> GameController modes (Nielk1 encodings), levels and player LEDs, notify transport, '
      'PadOutput/Xcode/bridging/GamepadInput/driver wiring')
