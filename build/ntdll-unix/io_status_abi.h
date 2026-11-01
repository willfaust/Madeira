/* SPDX-License-Identifier: LGPL-2.1-or-later
 * Private Wine PE/Unix ABI. All pointers are host addresses. The producer
 * scope is an opaque stack-lifetime cookie, never a linked-list node. Native
 * storage owns all links/bindings. No structure crosses the server protocol.
 * Version 2 rejects old producers which scope nonlocal/control syscalls. */
#ifndef MADEIRA_IO_STATUS_ABI_H
#define MADEIRA_IO_STATUS_ABI_H
#define MADEIRA_IO_ABI_VERSION 2
#define MADEIRA_THREAD_IO_ABI 1011
#define MADEIRA_IO_SCOPE_LIMIT 64
#define MADEIRA_IO_OPERATION_MASK 0xffu
#define MADEIRA_IO_SYSCALL_SHIFT 8
#define MADEIRA_IO_ENTER_OPERATION(num) (((num) << MADEIRA_IO_SYSCALL_SHIFT) | MADEIRA_IO_ENTER)
enum madeira_io_operation { MADEIRA_IO_ENTER, MADEIRA_IO_LEAVE, MADEIRA_IO_BIND, MADEIRA_IO_UNBIND };
/* Keep the 24-byte ABI layout; historical fields are reserved, never read or
 * written by the controller. Only this object's address is an opaque cookie. */
struct madeira_io_scope
{
    struct madeira_io_scope *previous;
    void *native_iosb;
    void *guest_iosb;
};
struct madeira_io_control
{
    unsigned int version;
    unsigned int operation; /* low 8: operation; upper 24: ENTER syscall number */
    struct madeira_io_scope *scope;
    void *native_iosb;
    void *guest_iosb;
};
/* Function-pointer selection does not depend on these numbers. They label
 * diagnostics; the host test verifies numbers and complete thunk coverage. */
#define MADEIRA_IO_THUNKS(X) \
    X( 0x005d, NtCancelIoFile ) \
    X( 0x006e, NtCancelIoFileEx ) \
    X( 0x006f, NtCancelSynchronousIoFile ) \
    X( 0x0055, NtCreateFile ) \
    X( 0x007d, NtCreateMailslotFile ) \
    X( 0x007f, NtCreateNamedPipeFile ) \
    X( 0x0007, NtDeviceIoControlFile ) \
    X( 0x004b, NtFlushBuffersFile ) \
    X( 0x0092, NtFlushBuffersFileEx ) \
    X( 0x0039, NtFsControlFile ) \
    X( 0x00a5, NtLockFile ) \
    X( 0x00ab, NtNotifyChangeDirectoryFile ) \
    X( 0x0033, NtOpenFile ) \
    X( 0x0035, NtQueryDirectoryFile ) \
    X( 0x00bd, NtQueryEaFile ) \
    X( 0x0011, NtQueryInformationFile ) \
    X( 0x0049, NtQueryVolumeInformationFile ) \
    X( 0x0006, NtReadFile ) \
    X( 0x002e, NtReadFileScatter ) \
    X( 0x0009, NtRemoveIoCompletion ) \
    X( 0x00e2, NtSetEaFile ) \
    X( 0x0027, NtSetInformationFile ) \
    X( 0x00f1, NtSetVolumeInformationFile ) \
    X( 0x00fc, NtUnlockFile ) \
    X( 0x0008, NtWriteFile ) \
    X( 0x001b, NtWriteFileGather ) \
    X( 0x00a4, NtLoadKeyEx ) \
    X( 0x00ac, NtNotifyChangeKey ) \
    X( 0x00ad, NtNotifyChangeMultipleKeys )
#endif
