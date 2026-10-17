// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

//! On-device remote pairing for Built-in StikJIT (iOS 27 and later).
//!
//! Madeira plays the computer in iOS 27's device-initiated pairing: it listens
//! on a TCP port, the app advertises that port as a
//! `_remotepairing-pairable-host._tcp` Bonjour service (through NetService, so no
//! multicast entitlement is needed), the user taps "Pair with Madeira" under
//! Settings > Privacy & Security > Developer Mode and types the PIN Madeira
//! shows. The result is the RPPairing plist StikJIT reads.
//!
//! The protocol is idevice's `PairableHost` (MIT, jkcoxson/idevice). This file
//! only binds the listener, hands the advertisement to Swift and returns the
//! pairing file as bytes.
//!
//! The same pairing file also renews Madeira's signing
//! (`madeira_rppairing_install_profile`, app/Madeira/SigningRefresh.swift): a
//! tunnel to the device through LocalDevVPN, as StikJIT opens one, then the
//! new provisioning profile goes to the device's misagent service. The Apple
//! ID sign-in that asks Apple for that profile, for a copy no installer left
//! one for, is in `apple_id`.

mod apple_id;

use std::ffi::{CStr, CString, c_char, c_void};
use std::net::{IpAddr, Ipv4Addr, SocketAddr, TcpListener};
use std::ptr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use idevice::RsdService;
use idevice::misagent::MisagentClient;
use idevice::remote_pairing::{
    PairableHost, PairableHostInfo, RemotePairingClient, RpPairingFile, RpPairingSocket, connect_tls_psk_tunnel_native,
};
use idevice::rsd::RsdHandshake;
use idevice::tcp::adapter::Adapter;
use tokio::sync::Notify;
use tokio::task::JoinSet;

/// iOS shows the host as a computer; keep this a Mac model identifier.
const HOST_MODEL: &str = "Mac17,7";
/// The name Madeira gives when it connects with a pairing file it holds.
const INSTALL_HOST: &str = "Madeira";

pub struct MadeiraRPPairing {
    port: u16,
    service_name: CString,
    txt: Vec<(CString, CString)>,
    listener: Mutex<Option<TcpListener>>,
    identity: Mutex<Option<(RpPairingFile, PairableHostInfo)>>,
    cancelled: AtomicBool,
    cancel: Notify,
}

pub type MadeiraRPPairingPinCallback = Option<extern "C" fn(pin: *const c_char, context: *mut c_void)>;

#[derive(Clone, Copy)]
struct PinTarget {
    callback: MadeiraRPPairingPinCallback,
    context: *mut c_void,
}
// The context is only handed back to the caller's callback, on the accepting thread.
unsafe impl Send for PinTarget {}
unsafe impl Sync for PinTarget {}

impl PinTarget {
    fn show(&self, pin: String) {
        if let (Some(callback), Ok(pin)) = (self.callback, CString::new(pin)) {
            callback(pin.as_ptr(), self.context);
        }
    }
}

enum Failure {
    Cancelled,
    Error(String),
}

fn set_error(out: *mut *mut c_char, message: impl Into<Vec<u8>>) {
    if !out.is_null() {
        unsafe { *out = CString::new(message).unwrap_or_default().into_raw() };
    }
}

/// Generates a fresh host identity and binds a TCP listener on all IPv4
/// interfaces. Returns NULL on failure, with `*error` set (free it with
/// `madeira_rppairing_string_free`).
///
/// # Safety
/// `name` must be a valid NUL-terminated string. `error` must be NULL or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn madeira_rppairing_new(name: *const c_char, error: *mut *mut c_char) -> *mut MadeiraRPPairing {
    if name.is_null() {
        set_error(error, "missing host name");
        return ptr::null_mut();
    }
    let name = match unsafe { CStr::from_ptr(name) }.to_str() {
        Ok(name) if !name.is_empty() => name.to_string(),
        _ => {
            set_error(error, "invalid host name");
            return ptr::null_mut();
        }
    };

    let listener = match TcpListener::bind((Ipv4Addr::UNSPECIFIED, 0)) {
        Ok(listener) => listener,
        Err(e) => {
            set_error(error, format!("could not open the pairing port: {e}"));
            return ptr::null_mut();
        }
    };
    let port = match listener.local_addr().and_then(|addr| listener.set_nonblocking(true).map(|_| addr.port())) {
        Ok(port) => port,
        Err(e) => {
            set_error(error, format!("could not open the pairing port: {e}"));
            return ptr::null_mut();
        }
    };

    // The device only offers pair-setup to a host it does not recognise, so a
    // new identity per run is intended: the identifier stays the same (it is
    // derived from the name) and the device replaces its record for it.
    let pairing_file = RpPairingFile::generate(&name);
    let host_info = PairableHostInfo::generate(&name, HOST_MODEL);
    let identifier = pairing_file.identifier.clone();
    let txt = host_info
        .mdns_txt_records(&identifier)
        .into_iter()
        .filter_map(|(k, v)| Some((CString::new(k).ok()?, CString::new(v).ok()?)))
        .collect();

    Box::into_raw(Box::new(MadeiraRPPairing {
        port,
        service_name: CString::new(identifier).unwrap_or_default(),
        txt,
        listener: Mutex::new(Some(listener)),
        identity: Mutex::new(Some((pairing_file, host_info))),
        cancelled: AtomicBool::new(false),
        cancel: Notify::new(),
    }))
}

/// # Safety
/// `session` must be a live pointer from `madeira_rppairing_new`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn madeira_rppairing_port(session: *const MadeiraRPPairing) -> u16 {
    unsafe { &*session }.port
}

/// The Bonjour service instance name to publish. Owned by the session.
///
/// # Safety
/// `session` must be a live pointer from `madeira_rppairing_new`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn madeira_rppairing_service_name(session: *const MadeiraRPPairing) -> *const c_char {
    unsafe { &*session }.service_name.as_ptr()
}

/// # Safety
/// `session` must be a live pointer from `madeira_rppairing_new`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn madeira_rppairing_txt_count(session: *const MadeiraRPPairing) -> usize {
    unsafe { &*session }.txt.len()
}

/// TXT record key at `index`, or NULL past the end. Owned by the session.
///
/// # Safety
/// `session` must be a live pointer from `madeira_rppairing_new`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn madeira_rppairing_txt_key(session: *const MadeiraRPPairing, index: usize) -> *const c_char {
    unsafe { &*session }.txt.get(index).map_or(ptr::null(), |(k, _)| k.as_ptr())
}

/// TXT record value at `index`, or NULL past the end. Owned by the session.
///
/// # Safety
/// `session` must be a live pointer from `madeira_rppairing_new`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn madeira_rppairing_txt_value(session: *const MadeiraRPPairing, index: usize) -> *const c_char {
    unsafe { &*session }.txt.get(index).map_or(ptr::null(), |(_, v)| v.as_ptr())
}

/// Blocks until a device pairs, pairing fails, or `madeira_rppairing_cancel`
/// is called. `pin_callback` runs on this thread with the 6-digit code to show.
///
/// Returns 0 on success (`*out_plist`/`*out_len` hold the RPPairing plist, free
/// with `madeira_rppairing_bytes_free`; `*out_device_name` the device's name),
/// 1 on failure (`*error` set), 2 when cancelled. Call at most once per session.
///
/// # Safety
/// `session` must be a live pointer from `madeira_rppairing_new`; the out
/// pointers must be NULL or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn madeira_rppairing_accept(
    session: *const MadeiraRPPairing,
    pin_callback: MadeiraRPPairingPinCallback,
    pin_context: *mut c_void,
    out_plist: *mut *mut u8,
    out_len: *mut usize,
    out_device_name: *mut *mut c_char,
    error: *mut *mut c_char,
) -> i32 {
    let session = unsafe { &*session };
    let listener = session.listener.lock().ok().and_then(|mut l| l.take());
    let identity = session.identity.lock().ok().and_then(|mut i| i.take());
    let (Some(listener), Some((pairing_file, host_info))) = (listener, identity) else {
        set_error(error, "this pairing session has already been used");
        return 1;
    };

    let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(runtime) => runtime,
        Err(e) => {
            set_error(error, format!("could not start the pairing runtime: {e}"));
            return 1;
        }
    };
    let target = PinTarget { callback: pin_callback, context: pin_context };

    match runtime.block_on(accept(session, listener, pairing_file, host_info, target)) {
        Ok((file, device_name)) => {
            let bytes = file.to_bytes().into_boxed_slice();
            if !out_len.is_null() {
                unsafe { *out_len = bytes.len() };
            }
            if !out_plist.is_null() {
                unsafe { *out_plist = Box::into_raw(bytes) as *mut u8 };
            }
            if !out_device_name.is_null() {
                unsafe { *out_device_name = CString::new(device_name).unwrap_or_default().into_raw() };
            }
            0
        }
        Err(Failure::Cancelled) => 2,
        Err(Failure::Error(message)) => {
            set_error(error, message);
            1
        }
    }
}

async fn attempt(
    stream: tokio::net::TcpStream,
    mut file: RpPairingFile,
    host_info: PairableHostInfo,
    target: PinTarget,
    pin_shown: Arc<AtomicBool>,
) -> Result<(RpPairingFile, String), idevice::IdeviceError> {
    let mut host = PairableHost::new(RpPairingSocket::new_device(stream), host_info);
    let peer = host
        .accept(&mut file, |pin| {
            pin_shown.store(true, Ordering::SeqCst);
            target.show(pin);
            async {}
        })
        .await?;
    Ok((file, peer.name))
}

async fn accept(
    session: &MadeiraRPPairing,
    listener: TcpListener,
    pairing_file: RpPairingFile,
    host_info: PairableHostInfo,
    target: PinTarget,
) -> Result<(RpPairingFile, String), Failure> {
    let listener = tokio::net::TcpListener::from_std(listener)
        .map_err(|e| Failure::Error(format!("could not listen for the device: {e}")))?;
    let pin_shown = Arc::new(AtomicBool::new(false));

    // Every connection is served at once, so one that stays open without
    // speaking cannot keep the device from reaching Madeira.
    let pair = async {
        let mut attempts = JoinSet::new();
        loop {
            tokio::select! {
                connection = listener.accept() => {
                    let (stream, _) = connection
                        .map_err(|e| Failure::Error(format!("could not accept the device's connection: {e}")))?;
                    attempts.spawn(attempt(stream, pairing_file.clone(), host_info.clone(), target, pin_shown.clone()));
                }
                Some(done) = attempts.join_next() => match done {
                    Ok(Ok(paired)) => return Ok(paired),
                    // Failing before the PIN step means it was not the
                    // device's pairing attempt; keep listening.
                    _ if !pin_shown.load(Ordering::SeqCst) => continue,
                    Ok(Err(e)) => return Err(Failure::Error(format!("pairing failed: {e}"))),
                    Err(e) => return Err(Failure::Error(format!("pairing failed: {e}"))),
                },
            }
        }
    };

    if session.cancelled.load(Ordering::SeqCst) {
        return Err(Failure::Cancelled);
    }
    tokio::select! {
        biased;
        _ = session.cancel.notified() => Err(Failure::Cancelled),
        result = pair => result,
    }
}

/// Ends a running or future `madeira_rppairing_accept` with result 2. Safe from
/// any thread, any number of times.
///
/// # Safety
/// `session` must be a live pointer from `madeira_rppairing_new`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn madeira_rppairing_cancel(session: *const MadeiraRPPairing) {
    let session = unsafe { &*session };
    session.cancelled.store(true, Ordering::SeqCst);
    session.cancel.notify_one();
}

/// # Safety
/// `session` must be NULL or a pointer from `madeira_rppairing_new` whose
/// accept, if any, has returned.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn madeira_rppairing_free(session: *mut MadeiraRPPairing) {
    if !session.is_null() {
        drop(unsafe { Box::from_raw(session) });
    }
}

/// Why a profile could not be installed, as `madeira_rppairing_install_profile` returns it.
enum InstallFailure {
    /// Nothing answered at the device's address: LocalDevVPN is off or not routing.
    Unreachable(String),
    /// The device answered and does not accept this pairing file.
    Pairing(String),
    Other(String),
}

impl InstallFailure {
    fn code(&self) -> i32 {
        match self {
            InstallFailure::Unreachable(_) => 1,
            InstallFailure::Pairing(_) => 2,
            InstallFailure::Other(_) => 3,
        }
    }

    fn message(self) -> String {
        match self {
            InstallFailure::Unreachable(m) | InstallFailure::Pairing(m) | InstallFailure::Other(m) => m,
        }
    }
}

impl From<idevice::IdeviceError> for InstallFailure {
    fn from(e: idevice::IdeviceError) -> Self {
        InstallFailure::Other(e.to_string())
    }
}

impl From<std::io::Error> for InstallFailure {
    fn from(e: std::io::Error) -> Self {
        InstallFailure::Other(e.to_string())
    }
}

/// Opens a tunnel to the device at `address` (its remote-pairing port, reached
/// through LocalDevVPN) with `file`, and installs `profile` there.
async fn install_profile(mut file: RpPairingFile, address: SocketAddr, profile: Vec<u8>) -> Result<(), InstallFailure> {
    let stream = tokio::net::TcpStream::connect(address)
        .await
        .map_err(|e| InstallFailure::Unreachable(format!("could not reach this device: {e}")))?;
    let mut client = RemotePairingClient::new(RpPairingSocket::new(stream), INSTALL_HOST);
    // Verify only. `connect` would go on to a new pairing when the device
    // refuses the file, and wait for a code nobody is shown.
    client
        .attempt_pair_verify()
        .await
        .map_err(|e| InstallFailure::Pairing(format!("this device refused the pairing: {e}")))?;
    client
        .validate_pairing(&mut file)
        .await
        .map_err(|e| InstallFailure::Pairing(format!("this device no longer accepts the pairing file: {e}")))?;

    // The device opens a port for the tunnel and names no host: it is the
    // address the device answered at.
    let port = client.create_tcp_listener().await?;
    let stream = tokio::net::TcpStream::connect((address.ip(), port)).await?;
    let tunnel = connect_tls_psk_tunnel_native(stream, client.encryption_key()).await?;

    let parse = |address: &str| {
        address.parse::<IpAddr>().map_err(|e| InstallFailure::Other(format!("the tunnel gave an invalid address: {e}")))
    };
    let (ours, theirs) = (parse(&tunnel.info.client_address)?, parse(&tunnel.info.server_address)?);
    let (mtu, rsd_port) = (tunnel.info.mtu as usize, tunnel.info.server_rsd_port);
    let mut adapter = Adapter::new(Box::new(tunnel.into_inner()), ours, theirs);
    adapter.set_mss(mtu.saturating_sub(60));
    let mut adapter = adapter.to_async_handle();

    let mut handshake = RsdHandshake::new(adapter.connect(rsd_port).await?).await?;
    let mut misagent = MisagentClient::connect_rsd(&mut adapter, &mut handshake).await?;
    misagent.install(profile).await?;
    Ok(())
}

/// Installs a provisioning profile (the bytes of a `.mobileprovision`) on the
/// device that `pairing` (an RPPairing plist) belongs to, reached at
/// `host`:`port` (10.7.0.1:49152 through LocalDevVPN). An app the profile
/// covers stays valid until the profile expires, without being installed again.
/// Blocks, for at most `timeout_seconds`.
///
/// Returns 0 on success; otherwise `*error` is set (free it with
/// `madeira_rppairing_string_free`) and the result is 1 when the device could
/// not be reached, 2 when it does not accept the pairing file, 3 for anything
/// else.
///
/// # Safety
/// `pairing`/`pairing_len` and `profile`/`profile_len` must be readable; `host`
/// a valid NUL-terminated string; `error` NULL or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn madeira_rppairing_install_profile(
    pairing: *const u8,
    pairing_len: usize,
    host: *const c_char,
    port: u16,
    profile: *const u8,
    profile_len: usize,
    timeout_seconds: u32,
    error: *mut *mut c_char,
) -> i32 {
    if pairing.is_null() || profile.is_null() || host.is_null() || profile_len == 0 {
        set_error(error, "missing pairing file, profile or address");
        return 3;
    }
    let file = match RpPairingFile::from_bytes(unsafe { std::slice::from_raw_parts(pairing, pairing_len) }) {
        Ok(file) => file,
        Err(e) => {
            set_error(error, format!("the pairing file could not be read: {e}"));
            return 2;
        }
    };
    let address = match unsafe { CStr::from_ptr(host) }.to_str().ok().and_then(|host| host.parse::<IpAddr>().ok()) {
        Some(ip) => SocketAddr::new(ip, port),
        None => {
            set_error(error, "invalid device address");
            return 3;
        }
    };
    let profile = unsafe { std::slice::from_raw_parts(profile, profile_len) }.to_vec();

    let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(runtime) => runtime,
        Err(e) => {
            set_error(error, format!("could not start the runtime: {e}"));
            return 3;
        }
    };
    let limit = Duration::from_secs(timeout_seconds.max(1).into());
    let result = runtime.block_on(async {
        match tokio::time::timeout(limit, install_profile(file, address, profile)).await {
            Ok(result) => result,
            Err(_) => Err(InstallFailure::Unreachable("this device did not answer in time".to_string())),
        }
    });
    match result {
        Ok(()) => 0,
        Err(failure) => {
            let code = failure.code();
            set_error(error, failure.message());
            code
        }
    }
}

/// # Safety
/// `bytes`/`len` must come from `madeira_rppairing_accept`, or `bytes` be NULL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn madeira_rppairing_bytes_free(bytes: *mut u8, len: usize) {
    if !bytes.is_null() {
        drop(unsafe { Box::from_raw(ptr::slice_from_raw_parts_mut(bytes, len)) });
    }
}

/// # Safety
/// `string` must be NULL or a string returned by this library.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn madeira_rppairing_string_free(string: *mut c_char) {
    if !string.is_null() {
        drop(unsafe { CString::from_raw(string) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::net::TcpStream;
    use std::thread;
    use std::time::Duration;

    struct Session(*mut MadeiraRPPairing);
    unsafe impl Send for Session {}
    unsafe impl Sync for Session {}

    fn new_session() -> Session {
        let mut error = ptr::null_mut();
        let session = unsafe { madeira_rppairing_new(c"Madeira".as_ptr(), &mut error) };
        assert!(!session.is_null() && error.is_null());
        Session(session)
    }

    fn accept(session: &Session) -> (i32, Option<String>) {
        let (mut bytes, mut len, mut name, mut error) = (ptr::null_mut(), 0, ptr::null_mut(), ptr::null_mut());
        let status = unsafe {
            madeira_rppairing_accept(session.0, None, ptr::null_mut(), &mut bytes, &mut len, &mut name, &mut error)
        };
        assert!(bytes.is_null() && name.is_null());
        let message = (!error.is_null()).then(|| {
            let text = unsafe { CStr::from_ptr(error) }.to_string_lossy().into_owned();
            unsafe { madeira_rppairing_string_free(error) };
            text
        });
        (status, message)
    }

    fn string(p: *const c_char) -> String {
        unsafe { CStr::from_ptr(p) }.to_str().unwrap().to_string()
    }

    #[test]
    fn advertisement_matches_the_host_identity() {
        let session = new_session();
        unsafe {
            assert_ne!(madeira_rppairing_port(session.0), 0);
            let identifier = string(madeira_rppairing_service_name(session.0));
            assert_eq!(identifier.len(), 36, "a UUID");
            let txt: Vec<(String, String)> = (0..madeira_rppairing_txt_count(session.0))
                .map(|i| (string(madeira_rppairing_txt_key(session.0, i)), string(madeira_rppairing_txt_value(session.0, i))))
                .collect();
            let get = |key: &str| txt.iter().find(|(k, _)| k == key).map(|(_, v)| v.clone());
            assert_eq!(get("name").as_deref(), Some("Madeira"));
            assert_eq!(get("identifier"), Some(identifier));
            assert_eq!(get("model").as_deref(), Some(HOST_MODEL));
            assert!(get("authTag").is_some_and(|tag| !tag.is_empty()));
            assert!(txt.iter().all(|(k, v)| k.len() + v.len() < 255), "every TXT entry fits one length byte");
            assert!(madeira_rppairing_txt_key(session.0, txt.len()).is_null());
            madeira_rppairing_free(session.0);
        }
    }

    #[test]
    fn identifier_is_stable_across_runs() {
        let (a, b) = (new_session(), new_session());
        unsafe {
            assert_eq!(string(madeira_rppairing_service_name(a.0)), string(madeira_rppairing_service_name(b.0)));
            assert_ne!(madeira_rppairing_port(a.0), madeira_rppairing_port(b.0));
            madeira_rppairing_free(a.0);
            madeira_rppairing_free(b.0);
        }
    }

    #[test]
    fn cancel_before_accept_returns_cancelled() {
        let session = new_session();
        unsafe { madeira_rppairing_cancel(session.0) };
        assert_eq!(accept(&session), (2, None));
        let (status, message) = accept(&session);
        assert_eq!(status, 1, "a session is single use");
        assert!(message.is_some());
        unsafe { madeira_rppairing_free(session.0) };
    }

    #[test]
    fn stray_connections_do_not_end_the_wait_and_cancel_does() {
        let session = new_session();
        let port = unsafe { madeira_rppairing_port(session.0) };
        thread::scope(|scope| {
            let waiter = scope.spawn(|| accept(&session));
            // A connection that closes, then one that sends garbage, before any PIN.
            drop(TcpStream::connect((Ipv4Addr::LOCALHOST, port)).unwrap());
            let mut junk = TcpStream::connect((Ipv4Addr::LOCALHOST, port)).unwrap();
            junk.write_all(b"GET / HTTP/1.1\r\n\r\n").unwrap();
            drop(junk);
            thread::sleep(Duration::from_millis(300));
            assert!(!waiter.is_finished(), "still listening for the device");
            unsafe { madeira_rppairing_cancel(session.0) };
            assert_eq!(waiter.join().unwrap(), (2, None));
        });
        unsafe { madeira_rppairing_free(session.0) };
    }

    #[test]
    fn a_silent_connection_does_not_block_the_next_one() {
        use std::io::{ErrorKind, Read};
        let session = new_session();
        let port = unsafe { madeira_rppairing_port(session.0) };
        thread::scope(|scope| {
            let waiter = scope.spawn(|| accept(&session));
            let _silent = TcpStream::connect((Ipv4Addr::LOCALHOST, port)).unwrap();
            thread::sleep(Duration::from_millis(100));
            // Half-closed: the server reads to the end, fails the attempt and
            // hangs up, which the read below sees -- unless it never reads.
            let mut junk = TcpStream::connect((Ipv4Addr::LOCALHOST, port)).unwrap();
            junk.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
            junk.write_all(b"not rppairing\r\n\r\n").unwrap();
            junk.shutdown(std::net::Shutdown::Write).unwrap();
            let served = match junk.read(&mut [0u8; 64]) {
                Ok(_) => true,
                Err(e) => !matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut),
            };
            unsafe { madeira_rppairing_cancel(session.0) };
            assert_eq!(waiter.join().unwrap(), (2, None));
            assert!(served, "the second connection was not served while the first stayed silent");
        });
        unsafe { madeira_rppairing_free(session.0) };
    }
}
