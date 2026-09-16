//
//  MadeiraPad.h
//  Host gamepad state for XInput.
//
//  GamepadBridge.swift pushes GameController.framework pads in here; Wine's
//  xinput reads them back through its unixlib (build/ntdll-unix/
//  xinput_host_ios.c). Indices are XInput user slots 0-3. Buttons use the
//  XINPUT_GAMEPAD_* bit values (guide = 0x0400), sticks are -32768..32767
//  with +Y up, triggers 0..255.
//

#ifndef MADEIRA_PAD_H
#define MADEIRA_PAD_H

#ifdef __cplusplus
extern "C" {
#endif

void madeira_pad_set_connected(int index, int connected, int vendor_id, int product_id, int has_rumble);
void madeira_pad_update(int index, int buttons, int left_trigger, int right_trigger,
                        int thumb_lx, int thumb_ly, int thumb_rx, int thumb_ry);
/// Current requested motor speeds (0..65535). Returns a serial that changes
/// whenever the game asks for different values.
int  madeira_pad_get_vibration(int index, int *left_motor, int *right_motor);

#ifdef __cplusplus
}
#endif

#endif
