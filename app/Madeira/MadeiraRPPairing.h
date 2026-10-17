// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// On-device remote pairing (iOS 27 and later), installing a provisioning
// profile with the pairing file, and the Apple ID sign-in that asks Apple for
// one: build/rppairing-ios, linked as libmadeira_rppairing.a. Keep in step with
// build/rppairing-ios/src/lib.rs and src/apple_id.rs.

#ifndef MADEIRA_RPPAIRING_H
#define MADEIRA_RPPAIRING_H

#include <stddef.h>
#include <stdint.h>

typedef struct MadeiraRPPairing MadeiraRPPairing;
typedef void (*MadeiraRPPairingPinCallback)(const char *pin, void *context);

/// New host identity and a listener on all IPv4 interfaces. NULL on failure,
/// with *error set (free with madeira_rppairing_string_free).
MadeiraRPPairing *madeira_rppairing_new(const char *name, char **error);
uint16_t madeira_rppairing_port(const MadeiraRPPairing *session);
/// The Bonjour instance name to publish; owned by the session.
const char *madeira_rppairing_service_name(const MadeiraRPPairing *session);
size_t madeira_rppairing_txt_count(const MadeiraRPPairing *session);
const char *madeira_rppairing_txt_key(const MadeiraRPPairing *session, size_t index);
const char *madeira_rppairing_txt_value(const MadeiraRPPairing *session, size_t index);
/// Blocks until paired (0), failed (1, *error set) or cancelled (2). On success
/// *out_plist/*out_len hold the RPPairing plist (madeira_rppairing_bytes_free)
/// and *out_device_name the device's name (madeira_rppairing_string_free).
int32_t madeira_rppairing_accept(const MadeiraRPPairing *session,
                                 MadeiraRPPairingPinCallback pin_callback, void *pin_context,
                                 uint8_t **out_plist, size_t *out_len,
                                 char **out_device_name, char **error);
/// Ends a running or future accept with 2. Any thread.
void madeira_rppairing_cancel(const MadeiraRPPairing *session);
/// Only after accept has returned (or was never called).
void madeira_rppairing_free(MadeiraRPPairing *session);
void madeira_rppairing_bytes_free(uint8_t *bytes, size_t len);
void madeira_rppairing_string_free(char *string);

/// Installs a provisioning profile (the bytes of a .mobileprovision) on the
/// device the RPPairing plist `pairing` belongs to, reached at host:port
/// (10.7.0.1:49152 through LocalDevVPN). Blocks, for at most timeout_seconds.
/// Returns 0 on success; otherwise *error is set (madeira_rppairing_string_free)
/// and the result is 1 when the device could not be reached, 2 when it does not
/// accept the pairing file, 3 for anything else.
int32_t madeira_rppairing_install_profile(const uint8_t *pairing, size_t pairing_len,
                                          const char *host, uint16_t port,
                                          const uint8_t *profile, size_t profile_len,
                                          uint32_t timeout_seconds, char **error);

/// Asks the user for the second factor of an Apple ID sign-in. `request` is
/// JSON: `method` ("device": a code went to the account's trusted devices,
/// "sms": one was texted to `selectedNumberId`, "choose": the last way failed
/// and none is on its way), `lastError` and `numbers` (`id`, `number`,
/// `pushMode`). The answer goes NUL-terminated into `reply`, which holds
/// `reply_capacity` bytes: {"action":"code","code":"123456"},
/// {"action":"sms","id":1}, {"action":"devices"} or {"action":"resend"}.
/// Returns 1 when it wrote one, 0 to give up the sign-in. Called on the thread
/// that called madeira_apple_sign_in, and may block.
typedef int32_t (*MadeiraAppleTwoFactorCallback)(void *context, const char *request,
                                                 char *reply, size_t reply_capacity);

/// Signs in to an Apple ID for the developer portal, through the anisette
/// server at `anisette_server`. Blocks until Apple has answered. `identity`
/// (16 bytes) and `provisioning` are the anisette identity of an earlier
/// sign-in to sign in as again, or NULL for a new one. Returns 0 with *result
/// set to JSON: `adsID`, `token`, `tokenExpires` (Unix seconds, or null),
/// `anisetteIdentifier` and `anisetteProvisioning` (base64) and `teams` (`id`,
/// `name`, `type`). Otherwise *error is set and the result is 1 when the user
/// gave up at the second factor, 2 when the anisette server gave nothing Apple
/// takes (another may), 3 for anything else, Apple's refusal included. Free
/// both strings with madeira_rppairing_string_free. Nothing is written to disk
/// and the password is not kept.
int32_t madeira_apple_sign_in(const char *apple_id, const char *password,
                              const char *anisette_server,
                              const uint8_t *identity, size_t identity_len,
                              const uint8_t *provisioning, size_t provisioning_len,
                              MadeiraAppleTwoFactorCallback two_factor, void *context,
                              char **result, char **error);

#endif
