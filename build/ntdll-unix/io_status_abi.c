/* SPDX-License-Identifier: LGPL-2.1-or-later
 * IOSB layout belongs to the request, not to the owning process's machine.
 * Native bootstrap/FEX I/O in a WoW64 process uses a native IOSB. Only the
 * actual wow64 IOSB thunk binds a converted 32-bit IOSB to its native proxy.
 */
#include "config.h"
#include <string.h>
#include <stdio.h>
#include <errno.h>
#include "ntstatus.h"
#include "windef.h"
#include "winternl.h"
#include "unix_private.h"
#include "io_status_abi.h"

C_ASSERT( sizeof(struct madeira_io_scope) == 24 );
C_ASSERT( sizeof(struct madeira_io_control) == 32 );

struct ios_io_record
{
    const struct madeira_io_scope *cookie;
    const IO_STATUS_BLOCK *native_iosb;
    void *guest_iosb;
    const void *teb, *peb;
    unsigned long long generation;
    unsigned int syscall;
};
static _Thread_local struct
{
    unsigned int depth;
    unsigned long long generation;
    struct ios_io_record records[MADEIRA_IO_SCOPE_LIMIT];
} io_scopes;

extern ULONG_PTR ios_wow_base(void);
extern BOOL ios_io_read_control( const void *, struct madeira_io_control * );
extern BOOL ios_io_buffer_writable( const void *, SIZE_T );
extern void ios_trace_io_scope( const struct madeira_io_control *, const char *, const void *,
                                unsigned long long, unsigned int, NTSTATUS );

static const char *io_api_name( unsigned int syscall )
{
    switch (syscall)
    {
#define IO_API(id, name) case id: return #name;
        MADEIRA_IO_THUNKS(IO_API)
#undef IO_API
    default: return "unknown";
    }
}

static BOOL io_record_owned( const struct ios_io_record *record )
{
    TEB *teb = NtCurrentTeb();
    return record && record->teb == teb && record->peb == (teb ? teb->Peb : NULL);
}

static void io_control_trace( const struct madeira_io_control *control, const struct ios_io_record *record,
                              NTSTATUS status, const void *input, ULONG size )
{
    static unsigned int normal, failures;
    unsigned int ticket = status ? __atomic_fetch_add( &failures, 1, __ATOMIC_RELAXED )
                                 : __atomic_fetch_add( &normal, 1, __ATOMIC_RELAXED );
    int saved_errno;
    if (ticket >= (status ? 16 : 12)) return;
    saved_errno = errno;
    dprintf( 2, "[io-control-v2] input=%p size=%u type=native-control expected=host "
                "operation=%u syscall=%04x scope-cookie=%p record=%p generation=%llu depth=%u status=%08x\n",
             input, size, control->operation & MADEIRA_IO_OPERATION_MASK,
             record ? record->syscall : control->operation >> MADEIRA_IO_SYSCALL_SHIFT,
             control->scope, record, record ? record->generation : 0, io_scopes.depth, (unsigned int)status );
    ios_trace_io_scope( control, io_api_name(record ? record->syscall : control->operation >> MADEIRA_IO_SYSCALL_SHIFT),
                        record, record ? record->generation : 0, io_scopes.depth, status );
    errno = saved_errno;
}

static BOOL io_guest_iosb_valid( const void *address )
{
    ULONG_PTR base = ios_wow_base(), value = (ULONG_PTR)address;
    /* This is already the wow64 thunk's translated host pointer. A raw guest
     * value is rejected, never "repaired" with a blind window-base addition. */
    if (base && (value < base || value - base > 0x100000000ULL - sizeof(IO_STATUS_BLOCK32))) return FALSE;
    return ios_io_buffer_writable( address, sizeof(IO_STATUS_BLOCK32) );
}

NTSTATUS ios_io_status_control( HANDLE thread, const void *data, ULONG size )
{
    struct madeira_io_control request = {0};
    const struct madeira_io_control *control = &request;
    struct ios_io_record *record = io_scopes.depth && io_scopes.depth <= MADEIRA_IO_SCOPE_LIMIT ?
                                  &io_scopes.records[io_scopes.depth - 1] : NULL;
    NTSTATUS status = STATUS_SUCCESS;
    unsigned int i, operation;
    TEB *teb = NtCurrentTeb();

    if (thread != NtCurrentThread()) { status = STATUS_INVALID_HANDLE; goto done; }
    if (size != sizeof(*control)) { status = STATUS_INFO_LENGTH_MISMATCH; goto done; }
    if (!data || !ios_io_read_control( data, &request )) { status = STATUS_ACCESS_VIOLATION; goto done; }
    if (control->version != MADEIRA_IO_ABI_VERSION) { status = STATUS_REVISION_MISMATCH; goto done; }
    if (io_scopes.depth > MADEIRA_IO_SCOPE_LIMIT) { status = STATUS_INVALID_PARAMETER; goto done; }
    operation = control->operation & MADEIRA_IO_OPERATION_MASK;
    if (record && !io_record_owned(record)) { status = STATUS_INVALID_PARAMETER; goto done; }
    switch (operation)
    {
    case MADEIRA_IO_ENTER:
        if (!control->scope || !teb || io_scopes.depth == MADEIRA_IO_SCOPE_LIMIT) { status = STATUS_INVALID_PARAMETER; break; }
        for (i = 0; i < io_scopes.depth; i++)
            if (io_scopes.records[i].cookie == control->scope) { status = STATUS_INVALID_PARAMETER; goto done; }
        if ((ULONG_PTR)control->scope % sizeof(void *) ||
            (ULONG_PTR)control->scope < (ULONG_PTR)teb->Tib.StackLimit ||
            (ULONG_PTR)control->scope > (ULONG_PTR)teb->Tib.StackBase ||
            (ULONG_PTR)teb->Tib.StackBase - (ULONG_PTR)control->scope < sizeof(*control->scope) ||
            !ios_io_buffer_writable( control->scope, sizeof(*control->scope) ))
        { status = STATUS_ACCESS_VIOLATION; break; }
        record = &io_scopes.records[io_scopes.depth++];
        memset( record, 0, sizeof(*record) );
        record->cookie = control->scope;
        record->teb = teb; record->peb = teb ? teb->Peb : NULL;
        if (!++io_scopes.generation) ++io_scopes.generation;
        record->generation = io_scopes.generation;
        record->syscall = control->operation >> MADEIRA_IO_SYSCALL_SHIFT;
        {
            static unsigned int announced;
            if (!__atomic_exchange_n( &announced, 1, __ATOMIC_RELAXED ))
            {
                int saved_errno = errno;
                dprintf( 2, "[io-abi] v2 native-owned IOSB scopes active\n" );
                errno = saved_errno;
            }
        }
        break;
    case MADEIRA_IO_LEAVE:
        if (!record || control->scope != record->cookie) { status = STATUS_INVALID_PARAMETER; break; }
        /* Pop native metadata even if the producer stack has gone away. The
         * cookie is compared by value and is never read, followed or zeroed. */
        io_control_trace( control, record, STATUS_SUCCESS, data, size );
        memset( record, 0, sizeof(*record) );
        --io_scopes.depth;
        return STATUS_SUCCESS;
    case MADEIRA_IO_BIND:
        if (!record || !control->native_iosb || !control->guest_iosb) { status = STATUS_INVALID_PARAMETER; break; }
        if (record->native_iosb && record->native_iosb != control->native_iosb) { status = STATUS_INVALID_PARAMETER; break; }
        if (!ios_io_buffer_writable( control->native_iosb, sizeof(IO_STATUS_BLOCK) ) ||
            !io_guest_iosb_valid(control->guest_iosb)) { status = STATUS_ACCESS_VIOLATION; break; }
        record->native_iosb = control->native_iosb;
        record->guest_iosb = control->guest_iosb;
        break;
    case MADEIRA_IO_UNBIND:
        if (!record || !control->native_iosb) { status = STATUS_INVALID_PARAMETER; break; }
        /* Some PE validation failures call put_iosb without issuing native
         * I/O or binding a proxy. Preserve their real status and leave an
         * outer scope's binding alone. */
        if (!record->native_iosb) break;
        if (record->native_iosb != control->native_iosb) { status = STATUS_INVALID_PARAMETER; break; }
        record->native_iosb = NULL; record->guest_iosb = NULL;
        break;
    default:
        status = STATUS_INVALID_PARAMETER;
    }
done:
    io_control_trace( control, record, status, data, size );
    return status;
}

void *ios_io_status_proxy( const IO_STATUS_BLOCK *native )
{
    unsigned int i;
    if (!native) return NULL;
    if (io_scopes.depth > MADEIRA_IO_SCOPE_LIMIT) return NULL;
    for (i = io_scopes.depth; i; i--)
        if (io_record_owned(&io_scopes.records[i - 1]) && io_scopes.records[i - 1].native_iosb == native)
            return io_scopes.records[i - 1].guest_iosb;
    return NULL;
}

BOOL ios_io_status_target32( client_ptr_t target )
{
    unsigned int i;
    if (!target) return FALSE;
    if (io_scopes.depth > MADEIRA_IO_SCOPE_LIMIT) return FALSE;
    for (i = io_scopes.depth; i; i--)
        if (io_record_owned(&io_scopes.records[i - 1]) && (client_ptr_t)(ULONG_PTR)io_scopes.records[i - 1].guest_iosb == target) return TRUE;
    return FALSE;
}

void ios_complete_io_status( client_ptr_t address, NTSTATUS status, ULONG_PTR information, BOOL guest32 )
{
    if (!address) return;
    if (guest32)
    {
        IO_STATUS_BLOCK32 *io = wine_server_get_ptr( address );
        io->Information = information;
        WriteRelease( &io->Status, status );
    }
    else
    {
        IO_STATUS_BLOCK *io = wine_server_get_ptr( address );
        io->Information = information;
        WriteRelease( &io->Status, status );
    }
}
