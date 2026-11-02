/*
 * NT threads support
 *
 * Copyright 1996, 2003 Alexandre Julliard
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301, USA
 */

#if 0
#pragma makedep unix
#endif

#include "config.h"

#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <pthread/qos.h>
volatile long long ios_affinity_sets;   /* ml1117 */
#include <signal.h>
#include <sys/types.h>
#include <unistd.h>
#include <sys/mman.h>
#ifdef HAVE_SCHED_H
#include <sched.h>
#endif
#ifdef HAVE_SYS_TIMES_H
#include <sys/times.h>
#endif
#ifdef HAVE_SYS_SYSCALL_H
#include <sys/syscall.h>
#endif
#ifdef HAVE_SYS_SYSCTL_H
#include <sys/sysctl.h>
#endif
#ifdef HAVE_SYS_PARAM_H
#include <sys/param.h>
#endif
#ifdef HAVE_SYS_QUEUE_H
#include <sys/queue.h>
#endif
#ifdef HAVE_SYS_USER_H
#include <sys/user.h>
#endif
#ifdef HAVE_LIBPROCSTAT_H
#include <libprocstat.h>
#endif

#ifdef __APPLE__
#include <mach/mach.h>
#endif
#ifdef __FreeBSD__
#include <sys/thr.h>
#endif

#include "ntstatus.h"
#include "winternl.h"
#include "ddk/wdm.h"
#include "wine/server.h"
#include "wine/debug.h"
#include "unix_private.h"
#include "ios_wow.h"

WINE_DEFAULT_DEBUG_CHANNEL(thread);
WINE_DECLARE_DEBUG_CHANNEL(seh);
WINE_DECLARE_DEBUG_CHANNEL(syscall);
WINE_DECLARE_DEBUG_CHANNEL(threadname);

pthread_key_t teb_key = 0;

static LONG nb_threads = 1;

static inline int get_unix_exit_code( NTSTATUS status )
{
    /* prevent a nonzero exit code to end up truncated to zero in unix */
    if (status && !(status & 0xff)) return 1;
    return status;
}


/***********************************************************************
 *           fpux_to_fpu
 *
 * Build a standard i386 FPU context from an extended one.
 */
void fpux_to_fpu( I386_FLOATING_SAVE_AREA *fpu, const XMM_SAVE_AREA32 *fpux )
{
    unsigned int i, tag, stack_top;

    fpu->ControlWord   = fpux->ControlWord;
    fpu->StatusWord    = fpux->StatusWord;
    fpu->ErrorOffset   = fpux->ErrorOffset;
    fpu->ErrorSelector = fpux->ErrorSelector | (fpux->ErrorOpcode << 16);
    fpu->DataOffset    = fpux->DataOffset;
    fpu->DataSelector  = fpux->DataSelector;
    fpu->Cr0NpxState   = fpux->StatusWord | 0xffff0000;

    stack_top = (fpux->StatusWord >> 11) & 7;
    fpu->TagWord = 0xffff0000;
    for (i = 0; i < 8; i++)
    {
        memcpy( &fpu->RegisterArea[10 * i], &fpux->FloatRegisters[i], 10 );
        if (!(fpux->TagWord & (1 << i))) tag = 3;  /* empty */
        else
        {
            const M128A *reg = &fpux->FloatRegisters[(i - stack_top) & 7];
            if ((reg->High & 0x7fff) == 0x7fff)  /* exponent all ones */
            {
                tag = 2;  /* special */
            }
            else if (!(reg->High & 0x7fff))  /* exponent all zeroes */
            {
                if (reg->Low) tag = 2;  /* special */
                else tag = 1;  /* zero */
            }
            else
            {
                if (reg->Low >> 63) tag = 0;  /* valid */
                else tag = 2;  /* special */
            }
        }
        fpu->TagWord |= tag << (2 * i);
    }
}


/***********************************************************************
 *           fpu_to_fpux
 *
 * Fill extended i386 FPU context from standard one.
 */
void fpu_to_fpux( XMM_SAVE_AREA32 *fpux, const I386_FLOATING_SAVE_AREA *fpu )
{
    unsigned int i;

    fpux->ControlWord   = fpu->ControlWord;
    fpux->StatusWord    = fpu->StatusWord;
    fpux->ErrorOffset   = fpu->ErrorOffset;
    fpux->ErrorSelector = fpu->ErrorSelector;
    fpux->ErrorOpcode   = fpu->ErrorSelector >> 16;
    fpux->DataOffset    = fpu->DataOffset;
    fpux->DataSelector  = fpu->DataSelector;
    fpux->TagWord       = 0;
    for (i = 0; i < 8; i++)
    {
        if (((fpu->TagWord >> (i * 2)) & 3) != 3) fpux->TagWord |= 1 << i;
        memcpy( &fpux->FloatRegisters[i], &fpu->RegisterArea[10 * i], 10 );
    }
}


/***********************************************************************
 *           get_server_context_flags
 */
static unsigned int get_server_context_flags( const void *context, USHORT machine )
{
    unsigned int flags = 0, ret = 0;

    switch (machine)
    {
    case IMAGE_FILE_MACHINE_I386:
        flags = ((const I386_CONTEXT *)context)->ContextFlags & ~CONTEXT_i386;
        if (flags & CONTEXT_I386_CONTROL) ret |= SERVER_CTX_CONTROL;
        if (flags & CONTEXT_I386_INTEGER) ret |= SERVER_CTX_INTEGER;
        if (flags & CONTEXT_I386_SEGMENTS) ret |= SERVER_CTX_SEGMENTS;
        if (flags & CONTEXT_I386_FLOATING_POINT) ret |= SERVER_CTX_FLOATING_POINT;
        if (flags & CONTEXT_I386_DEBUG_REGISTERS) ret |= SERVER_CTX_DEBUG_REGISTERS;
        if (flags & CONTEXT_I386_EXTENDED_REGISTERS) ret |= SERVER_CTX_EXTENDED_REGISTERS | SERVER_CTX_FLOATING_POINT;
        if (flags & CONTEXT_I386_XSTATE) ret |= SERVER_CTX_YMM_REGISTERS;
        break;
    case IMAGE_FILE_MACHINE_AMD64:
        flags = ((const AMD64_CONTEXT *)context)->ContextFlags & ~CONTEXT_AMD64;
        if (flags & CONTEXT_AMD64_CONTROL) ret |= SERVER_CTX_CONTROL;
        if (flags & CONTEXT_AMD64_INTEGER) ret |= SERVER_CTX_INTEGER;
        if (flags & CONTEXT_AMD64_SEGMENTS) ret |= SERVER_CTX_SEGMENTS;
        if (flags & CONTEXT_AMD64_FLOATING_POINT) ret |= SERVER_CTX_FLOATING_POINT;
        if (flags & CONTEXT_AMD64_DEBUG_REGISTERS) ret |= SERVER_CTX_DEBUG_REGISTERS;
        if (flags & CONTEXT_AMD64_XSTATE) ret |= SERVER_CTX_YMM_REGISTERS;
        break;
    case IMAGE_FILE_MACHINE_ARMNT:
        flags = ((const ARM_CONTEXT *)context)->ContextFlags & ~CONTEXT_ARM;
        if (flags & CONTEXT_ARM_CONTROL) ret |= SERVER_CTX_CONTROL;
        if (flags & CONTEXT_ARM_INTEGER) ret |= SERVER_CTX_INTEGER;
        if (flags & CONTEXT_ARM_FLOATING_POINT) ret |= SERVER_CTX_FLOATING_POINT;
        if (flags & CONTEXT_ARM_DEBUG_REGISTERS) ret |= SERVER_CTX_DEBUG_REGISTERS;
        break;
    case IMAGE_FILE_MACHINE_ARM64:
        flags = ((const ARM64_NT_CONTEXT *)context)->ContextFlags & ~CONTEXT_ARM64;
        if (flags & CONTEXT_ARM64_CONTROL) ret |= SERVER_CTX_CONTROL;
        if (flags & CONTEXT_ARM64_INTEGER) ret |= SERVER_CTX_INTEGER;
        if (flags & CONTEXT_ARM64_FLOATING_POINT) ret |= SERVER_CTX_FLOATING_POINT;
        if (flags & CONTEXT_ARM64_DEBUG_REGISTERS) ret |= SERVER_CTX_DEBUG_REGISTERS;
        break;
    }
    if (flags & CONTEXT_EXCEPTION_REQUEST) ret |= SERVER_CTX_EXEC_SPACE;
    return ret;
}


/***********************************************************************
 *           get_native_context_flags
 *
 * Get flags for registers that are set from the native context in WoW mode.
 */
static unsigned int get_native_context_flags( USHORT native_machine, USHORT wow_machine )
{
    switch (MAKELONG( native_machine, wow_machine ))
    {
    case MAKELONG( IMAGE_FILE_MACHINE_AMD64, IMAGE_FILE_MACHINE_I386 ):
        return SERVER_CTX_DEBUG_REGISTERS | SERVER_CTX_FLOATING_POINT | SERVER_CTX_YMM_REGISTERS | SERVER_CTX_EXEC_SPACE;
    case MAKELONG( IMAGE_FILE_MACHINE_ARM64, IMAGE_FILE_MACHINE_ARMNT ):
        return SERVER_CTX_DEBUG_REGISTERS | SERVER_CTX_FLOATING_POINT | SERVER_CTX_EXEC_SPACE;
    default:
        return SERVER_CTX_EXEC_SPACE;
    }
}


/***********************************************************************
 *           xstate_to_server
 *
 * Copy xstate to the server format.
 */
static void xstate_to_server( struct context_data *to, const CONTEXT_EX *xctx )
{
    const XSTATE *xs = (const XSTATE *)((const char *)xctx + xctx->XState.Offset);

    if (xs->CompactionMask && !(xs->CompactionMask & 4)) return;
    to->flags |= SERVER_CTX_YMM_REGISTERS;
    if (xs->Mask & 4) memcpy( &to->ymm.regs.ymm_high, &xs->YmmContext, sizeof(xs->YmmContext) );
}


/***********************************************************************
 *           exception_request_flags_to_server
 *
 * Copy exception reporting flags to the server format.
 */
static void exception_request_flags_to_server( struct context_data *to, DWORD context_flags )
{
    if (!(context_flags & CONTEXT_EXCEPTION_REPORTING)) return;
    to->flags |= SERVER_CTX_EXEC_SPACE;
    if (context_flags & CONTEXT_SERVICE_ACTIVE)        to->exec_space.space.space = EXEC_SPACE_SYSCALL;
    else if (context_flags & CONTEXT_EXCEPTION_ACTIVE) to->exec_space.space.space = EXEC_SPACE_EXCEPTION;
    else                                               to->exec_space.space.space = EXEC_SPACE_USERMODE;
}


/***********************************************************************
 *           context_to_server
 *
 * Convert a register context to the server format.
 */
static NTSTATUS context_to_server( struct context_data *to, USHORT to_machine, const void *src, USHORT from_machine )
{
    DWORD i, flags;

    memset( to, 0, sizeof(*to) );
    to->machine = to_machine;

    switch (MAKELONG( from_machine, to_machine ))
    {
    case MAKELONG( IMAGE_FILE_MACHINE_I386, IMAGE_FILE_MACHINE_I386 ):
    {
        const I386_CONTEXT *from = src;

        flags = from->ContextFlags & ~CONTEXT_i386;
        if (flags & CONTEXT_I386_CONTROL)
        {
            to->flags |= SERVER_CTX_CONTROL;
            to->ctl.i386_regs.ebp    = from->Ebp;
            to->ctl.i386_regs.esp    = from->Esp;
            to->ctl.i386_regs.eip    = from->Eip;
            to->ctl.i386_regs.cs     = from->SegCs;
            to->ctl.i386_regs.ss     = from->SegSs;
            to->ctl.i386_regs.eflags = from->EFlags;
        }
        if (flags & CONTEXT_I386_INTEGER)
        {
            to->flags |= SERVER_CTX_INTEGER;
            to->integer.i386_regs.eax = from->Eax;
            to->integer.i386_regs.ebx = from->Ebx;
            to->integer.i386_regs.ecx = from->Ecx;
            to->integer.i386_regs.edx = from->Edx;
            to->integer.i386_regs.esi = from->Esi;
            to->integer.i386_regs.edi = from->Edi;
        }
        if (flags & CONTEXT_I386_SEGMENTS)
        {
            to->flags |= SERVER_CTX_SEGMENTS;
            to->seg.i386_regs.ds = from->SegDs;
            to->seg.i386_regs.es = from->SegEs;
            to->seg.i386_regs.fs = from->SegFs;
            to->seg.i386_regs.gs = from->SegGs;
        }
        if (flags & CONTEXT_I386_FLOATING_POINT)
        {
            to->flags |= SERVER_CTX_FLOATING_POINT;
            to->fp.i386_regs.ctrl     = from->FloatSave.ControlWord;
            to->fp.i386_regs.status   = from->FloatSave.StatusWord;
            to->fp.i386_regs.tag      = from->FloatSave.TagWord;
            to->fp.i386_regs.err_off  = from->FloatSave.ErrorOffset;
            to->fp.i386_regs.err_sel  = from->FloatSave.ErrorSelector;
            to->fp.i386_regs.data_off = from->FloatSave.DataOffset;
            to->fp.i386_regs.data_sel = from->FloatSave.DataSelector;
            to->fp.i386_regs.cr0npx   = from->FloatSave.Cr0NpxState;
            memcpy( to->fp.i386_regs.regs, from->FloatSave.RegisterArea, sizeof(to->fp.i386_regs.regs) );
        }
        if (flags & CONTEXT_I386_DEBUG_REGISTERS)
        {
            to->flags |= SERVER_CTX_DEBUG_REGISTERS;
            to->debug.i386_regs.dr0 = from->Dr0;
            to->debug.i386_regs.dr1 = from->Dr1;
            to->debug.i386_regs.dr2 = from->Dr2;
            to->debug.i386_regs.dr3 = from->Dr3;
            to->debug.i386_regs.dr6 = from->Dr6;
            to->debug.i386_regs.dr7 = from->Dr7;
        }
        if (flags & CONTEXT_I386_EXTENDED_REGISTERS)
        {
            to->flags |= SERVER_CTX_EXTENDED_REGISTERS;
            memcpy( to->ext.i386_regs, from->ExtendedRegisters, sizeof(to->ext.i386_regs) );
        }
        if (flags & CONTEXT_I386_XSTATE)
            xstate_to_server( to, (const CONTEXT_EX *)(from + 1) );
        exception_request_flags_to_server( to, flags );
        return STATUS_SUCCESS;
    }

    case MAKELONG( IMAGE_FILE_MACHINE_I386, IMAGE_FILE_MACHINE_AMD64 ):
    {
        const I386_CONTEXT *from = src;

        flags = from->ContextFlags & ~CONTEXT_i386;
        if (flags & CONTEXT_I386_CONTROL)
        {
            to->flags |= SERVER_CTX_CONTROL;
            to->ctl.x86_64_regs.rsp    = from->Esp;
            to->ctl.x86_64_regs.rip    = from->Eip;
            to->ctl.x86_64_regs.cs     = from->SegCs;
            to->ctl.x86_64_regs.ss     = from->SegSs;
            to->ctl.x86_64_regs.flags  = from->EFlags;

            to->integer.x86_64_regs.rbp = from->Ebp;
        }
        if (flags & CONTEXT_I386_INTEGER)
        {
            to->flags |= SERVER_CTX_INTEGER;
            to->integer.x86_64_regs.rax = from->Eax;
            to->integer.x86_64_regs.rbx = from->Ebx;
            to->integer.x86_64_regs.rcx = from->Ecx;
            to->integer.x86_64_regs.rdx = from->Edx;
            to->integer.x86_64_regs.rsi = from->Esi;
            to->integer.x86_64_regs.rdi = from->Edi;
        }
        if (flags & CONTEXT_I386_SEGMENTS)
        {
            to->flags |= SERVER_CTX_SEGMENTS;
            to->seg.x86_64_regs.ds = from->SegDs;
            to->seg.x86_64_regs.es = from->SegEs;
            to->seg.x86_64_regs.fs = from->SegFs;
            to->seg.x86_64_regs.gs = from->SegGs;
        }
        if (flags & CONTEXT_I386_DEBUG_REGISTERS)
        {
            to->flags |= SERVER_CTX_DEBUG_REGISTERS;
            to->debug.x86_64_regs.dr0 = from->Dr0;
            to->debug.x86_64_regs.dr1 = from->Dr1;
            to->debug.x86_64_regs.dr2 = from->Dr2;
            to->debug.x86_64_regs.dr3 = from->Dr3;
            to->debug.x86_64_regs.dr6 = from->Dr6;
            to->debug.x86_64_regs.dr7 = from->Dr7;
        }
        if (flags & CONTEXT_I386_EXTENDED_REGISTERS)
        {
            to->flags |= SERVER_CTX_FLOATING_POINT;
            memcpy( to->fp.x86_64_regs.fpregs, from->ExtendedRegisters, sizeof(to->fp.x86_64_regs.fpregs) );
        }
        else if (flags & CONTEXT_I386_FLOATING_POINT)
        {
            to->flags |= SERVER_CTX_FLOATING_POINT;
            fpu_to_fpux( (XMM_SAVE_AREA32 *)to->fp.x86_64_regs.fpregs, &from->FloatSave );
        }
        if (flags & CONTEXT_I386_XSTATE)
            xstate_to_server( to, (const CONTEXT_EX *)(from + 1) );
        exception_request_flags_to_server( to, flags );
        return STATUS_SUCCESS;
    }

    case MAKELONG( IMAGE_FILE_MACHINE_AMD64, IMAGE_FILE_MACHINE_AMD64 ):
    {
        const AMD64_CONTEXT *from = src;

        flags = from->ContextFlags & ~CONTEXT_AMD64;
        if (flags & CONTEXT_AMD64_CONTROL)
        {
            to->flags |= SERVER_CTX_CONTROL;
            to->ctl.x86_64_regs.rip   = from->Rip;
            to->ctl.x86_64_regs.rsp   = from->Rsp;
            to->ctl.x86_64_regs.cs    = from->SegCs;
            to->ctl.x86_64_regs.ss    = from->SegSs;
            to->ctl.x86_64_regs.flags = from->EFlags;
        }
        if (flags & CONTEXT_AMD64_INTEGER)
        {
            to->flags |= SERVER_CTX_INTEGER;
            to->integer.x86_64_regs.rax = from->Rax;
            to->integer.x86_64_regs.rcx = from->Rcx;
            to->integer.x86_64_regs.rdx = from->Rdx;
            to->integer.x86_64_regs.rbx = from->Rbx;
            to->integer.x86_64_regs.rbp = from->Rbp;
            to->integer.x86_64_regs.rsi = from->Rsi;
            to->integer.x86_64_regs.rdi = from->Rdi;
            to->integer.x86_64_regs.r8  = from->R8;
            to->integer.x86_64_regs.r9  = from->R9;
            to->integer.x86_64_regs.r10 = from->R10;
            to->integer.x86_64_regs.r11 = from->R11;
            to->integer.x86_64_regs.r12 = from->R12;
            to->integer.x86_64_regs.r13 = from->R13;
            to->integer.x86_64_regs.r14 = from->R14;
            to->integer.x86_64_regs.r15 = from->R15;
        }
        if (flags & CONTEXT_AMD64_SEGMENTS)
        {
            to->flags |= SERVER_CTX_SEGMENTS;
            to->seg.x86_64_regs.ds = from->SegDs;
            to->seg.x86_64_regs.es = from->SegEs;
            to->seg.x86_64_regs.fs = from->SegFs;
            to->seg.x86_64_regs.gs = from->SegGs;
        }
        if (flags & CONTEXT_AMD64_FLOATING_POINT)
        {
            to->flags |= SERVER_CTX_FLOATING_POINT;
            memcpy( to->fp.x86_64_regs.fpregs, &from->FltSave, sizeof(to->fp.x86_64_regs.fpregs) );
            ((XSAVE_FORMAT *)to->fp.x86_64_regs.fpregs)->MxCsr = from->MxCsr;
        }
        if (flags & CONTEXT_AMD64_DEBUG_REGISTERS)
        {
            to->flags |= SERVER_CTX_DEBUG_REGISTERS;
            to->debug.x86_64_regs.dr0 = from->Dr0;
            to->debug.x86_64_regs.dr1 = from->Dr1;
            to->debug.x86_64_regs.dr2 = from->Dr2;
            to->debug.x86_64_regs.dr3 = from->Dr3;
            to->debug.x86_64_regs.dr6 = from->Dr6;
            to->debug.x86_64_regs.dr7 = from->Dr7;
        }
        if (flags & CONTEXT_AMD64_XSTATE)
            xstate_to_server( to, (const CONTEXT_EX *)(from + 1) );
        exception_request_flags_to_server( to, flags );
        return STATUS_SUCCESS;
    }

    case MAKELONG( IMAGE_FILE_MACHINE_AMD64, IMAGE_FILE_MACHINE_I386 ):
    {
        const AMD64_CONTEXT *from = src;

        flags = from->ContextFlags & ~CONTEXT_AMD64;
        if (flags & CONTEXT_AMD64_CONTROL)
        {
            to->flags |= SERVER_CTX_CONTROL;
            to->ctl.i386_regs.eip    = from->Rip;
            to->ctl.i386_regs.esp    = from->Rsp;
            to->ctl.i386_regs.cs     = from->SegCs;
            to->ctl.i386_regs.ss     = from->SegSs;
            to->ctl.i386_regs.eflags = from->EFlags;
        }
        if (flags & CONTEXT_AMD64_INTEGER)
        {
            to->flags |= SERVER_CTX_INTEGER;
            to->integer.i386_regs.eax = from->Rax;
            to->integer.i386_regs.ecx = from->Rcx;
            to->integer.i386_regs.edx = from->Rdx;
            to->integer.i386_regs.ebx = from->Rbx;
            to->integer.i386_regs.esi = from->Rsi;
            to->integer.i386_regs.edi = from->Rdi;

            to->ctl.i386_regs.ebp = from->Rbp;
        }
        if (flags & CONTEXT_AMD64_SEGMENTS)
        {
            to->flags |= SERVER_CTX_SEGMENTS;
            to->seg.i386_regs.ds = from->SegDs;
            to->seg.i386_regs.es = from->SegEs;
            to->seg.i386_regs.fs = from->SegFs;
            to->seg.i386_regs.gs = from->SegGs;
        }
        if (flags & CONTEXT_AMD64_FLOATING_POINT)
        {
            I386_FLOATING_SAVE_AREA fpu;

            to->flags |= SERVER_CTX_EXTENDED_REGISTERS | SERVER_CTX_FLOATING_POINT;
            memcpy( to->ext.i386_regs, &from->FltSave, sizeof(to->ext.i386_regs) );
            fpux_to_fpu( &fpu, &from->FltSave );
            to->fp.i386_regs.ctrl     = fpu.ControlWord;
            to->fp.i386_regs.status   = fpu.StatusWord;
            to->fp.i386_regs.tag      = fpu.TagWord;
            to->fp.i386_regs.err_off  = fpu.ErrorOffset;
            to->fp.i386_regs.err_sel  = fpu.ErrorSelector;
            to->fp.i386_regs.data_off = fpu.DataOffset;
            to->fp.i386_regs.data_sel = fpu.DataSelector;
            to->fp.i386_regs.cr0npx   = fpu.Cr0NpxState;
            memcpy( to->fp.i386_regs.regs, fpu.RegisterArea, sizeof(to->fp.i386_regs.regs) );
        }
        if (flags & CONTEXT_AMD64_DEBUG_REGISTERS)
        {
            to->flags |= SERVER_CTX_DEBUG_REGISTERS;
            to->debug.i386_regs.dr0 = from->Dr0;
            to->debug.i386_regs.dr1 = from->Dr1;
            to->debug.i386_regs.dr2 = from->Dr2;
            to->debug.i386_regs.dr3 = from->Dr3;
            to->debug.i386_regs.dr6 = from->Dr6;
            to->debug.i386_regs.dr7 = from->Dr7;
        }
        if (flags & CONTEXT_AMD64_XSTATE)
            xstate_to_server( to, (const CONTEXT_EX *)(from + 1) );
        exception_request_flags_to_server( to, flags );
        return STATUS_SUCCESS;
    }

    case MAKELONG( IMAGE_FILE_MACHINE_ARMNT, IMAGE_FILE_MACHINE_ARMNT ):
    {
        const ARM_CONTEXT *from = src;

        flags = from->ContextFlags & ~CONTEXT_ARM;
        if (flags & CONTEXT_ARM_CONTROL)
        {
            to->flags |= SERVER_CTX_CONTROL;
            to->ctl.arm_regs.sp   = from->Sp;
            to->ctl.arm_regs.lr   = from->Lr;
            to->ctl.arm_regs.pc   = from->Pc;
            to->ctl.arm_regs.cpsr = from->Cpsr;
        }
        if (flags & CONTEXT_ARM_INTEGER)
        {
            to->flags |= SERVER_CTX_INTEGER;
            to->integer.arm_regs.r[0]  = from->R0;
            to->integer.arm_regs.r[1]  = from->R1;
            to->integer.arm_regs.r[2]  = from->R2;
            to->integer.arm_regs.r[3]  = from->R3;
            to->integer.arm_regs.r[4]  = from->R4;
            to->integer.arm_regs.r[5]  = from->R5;
            to->integer.arm_regs.r[6]  = from->R6;
            to->integer.arm_regs.r[7]  = from->R7;
            to->integer.arm_regs.r[8]  = from->R8;
            to->integer.arm_regs.r[9]  = from->R9;
            to->integer.arm_regs.r[10] = from->R10;
            to->integer.arm_regs.r[11] = from->R11;
            to->integer.arm_regs.r[12] = from->R12;
        }
        if (flags & CONTEXT_ARM_FLOATING_POINT)
        {
            to->flags |= SERVER_CTX_FLOATING_POINT;
            for (i = 0; i < 32; i++) to->fp.arm_regs.d[i] = from->D[i];
            to->fp.arm_regs.fpscr = from->Fpscr;
        }
        if (flags & CONTEXT_ARM_DEBUG_REGISTERS)
        {
            to->flags |= SERVER_CTX_DEBUG_REGISTERS;
            for (i = 0; i < ARM_MAX_BREAKPOINTS; i++) to->debug.arm_regs.bvr[i] = from->Bvr[i];
            for (i = 0; i < ARM_MAX_BREAKPOINTS; i++) to->debug.arm_regs.bcr[i] = from->Bcr[i];
            for (i = 0; i < ARM_MAX_WATCHPOINTS; i++) to->debug.arm_regs.wvr[i] = from->Wvr[i];
            for (i = 0; i < ARM_MAX_WATCHPOINTS; i++) to->debug.arm_regs.wcr[i] = from->Wcr[i];
        }
        exception_request_flags_to_server( to, flags );
        return STATUS_SUCCESS;
    }

    case MAKELONG( IMAGE_FILE_MACHINE_ARM64, IMAGE_FILE_MACHINE_ARM64 ):
    {
        const ARM64_NT_CONTEXT *from = src;

        flags = from->ContextFlags & ~CONTEXT_ARM64;
        if (flags & CONTEXT_ARM64_CONTROL)
        {
            to->flags |= SERVER_CTX_CONTROL;
            to->integer.arm64_regs.x[29] = from->Fp;
            to->integer.arm64_regs.x[30] = from->Lr;
            to->ctl.arm64_regs.sp     = from->Sp;
            to->ctl.arm64_regs.pc     = from->Pc;
            to->ctl.arm64_regs.pstate = from->Cpsr;
        }
        if (flags & CONTEXT_ARM64_INTEGER)
        {
            to->flags |= SERVER_CTX_INTEGER;
            for (i = 0; i <= 28; i++) to->integer.arm64_regs.x[i] = from->X[i];
        }
        if (flags & CONTEXT_ARM64_FLOATING_POINT)
        {
            to->flags |= SERVER_CTX_FLOATING_POINT;
            for (i = 0; i < 32; i++)
            {
                to->fp.arm64_regs.q[i].low = from->V[i].Low;
                to->fp.arm64_regs.q[i].high = from->V[i].High;
            }
            to->fp.arm64_regs.fpcr = from->Fpcr;
            to->fp.arm64_regs.fpsr = from->Fpsr;
        }
        if (flags & CONTEXT_ARM64_DEBUG_REGISTERS)
        {
            to->flags |= SERVER_CTX_DEBUG_REGISTERS;
            for (i = 0; i < ARM64_MAX_BREAKPOINTS; i++) to->debug.arm64_regs.bcr[i] = from->Bcr[i];
            for (i = 0; i < ARM64_MAX_BREAKPOINTS; i++) to->debug.arm64_regs.bvr[i] = from->Bvr[i];
            for (i = 0; i < ARM64_MAX_WATCHPOINTS; i++) to->debug.arm64_regs.wcr[i] = from->Wcr[i];
            for (i = 0; i < ARM64_MAX_WATCHPOINTS; i++) to->debug.arm64_regs.wvr[i] = from->Wvr[i];
        }
        exception_request_flags_to_server( to, flags );
        return STATUS_SUCCESS;
    }

    case MAKELONG( IMAGE_FILE_MACHINE_ARM64, IMAGE_FILE_MACHINE_I386 ):
    case MAKELONG( IMAGE_FILE_MACHINE_I386, IMAGE_FILE_MACHINE_ARM64 ):
        return STATUS_SUCCESS;

    default:
        return STATUS_INVALID_PARAMETER;
    }
}


/***********************************************************************
 *           xstate_from_server
 *
 * Copy xstate from the server format.
 */
static void xstate_from_server( CONTEXT_EX *xctx, const struct context_data *from )
{
    XSTATE *xs = (XSTATE *)((char *)xctx + xctx->XState.Offset);
    unsigned int i;

    xs->Mask &= ~(ULONG64)4;

    if (xs->CompactionMask)
    {
        xs->CompactionMask &= ~(UINT64)3;
        if (!(xs->CompactionMask & 4)) return;
    }

    for (i = 0; i < ARRAY_SIZE( from->ymm.regs.ymm_high); i++)
    {
        if (!from->ymm.regs.ymm_high[i].low && !from->ymm.regs.ymm_high[i].high) continue;
        memcpy( &xs->YmmContext, &from->ymm.regs, sizeof(xs->YmmContext) );
        xs->Mask |= 4;
        break;
    }
}


/***********************************************************************
 *           exception_request_flags_from_server
 *
 * Copy exception reporting flags from the server format.
 */
static void exception_request_flags_from_server( DWORD *context_flags, const struct context_data *from )
{
    if (!(*context_flags & CONTEXT_EXCEPTION_REQUEST) || !(from->flags & SERVER_CTX_EXEC_SPACE)) return;
    *context_flags = (*context_flags & ~(CONTEXT_SERVICE_ACTIVE | CONTEXT_EXCEPTION_ACTIVE)) | CONTEXT_EXCEPTION_REPORTING;
    if (from->exec_space.space.space == EXEC_SPACE_SYSCALL)        *context_flags |= CONTEXT_SERVICE_ACTIVE;
    else if (from->exec_space.space.space == EXEC_SPACE_EXCEPTION) *context_flags |= CONTEXT_EXCEPTION_ACTIVE;
}


/***********************************************************************
 *           context_from_server
 *
 * Convert a register context from the server format.
 */
static NTSTATUS context_from_server( void *dst, const struct context_data *from, USHORT machine )
{
    DWORD i, to_flags;

    switch (MAKELONG( from->machine, machine ))
    {
    case MAKELONG( IMAGE_FILE_MACHINE_I386, IMAGE_FILE_MACHINE_I386 ):
    {
        I386_CONTEXT *to = dst;

        to_flags = to->ContextFlags & ~CONTEXT_i386;
        if ((from->flags & SERVER_CTX_CONTROL) && (to_flags & CONTEXT_I386_CONTROL))
        {
            to->ContextFlags |= CONTEXT_I386_CONTROL;
            to->Ebp    = from->ctl.i386_regs.ebp;
            to->Esp    = from->ctl.i386_regs.esp;
            to->Eip    = from->ctl.i386_regs.eip;
            to->SegCs  = from->ctl.i386_regs.cs;
            to->SegSs  = from->ctl.i386_regs.ss;
            to->EFlags = from->ctl.i386_regs.eflags;
        }
        if ((from->flags & SERVER_CTX_INTEGER) && (to_flags & CONTEXT_I386_INTEGER))
        {
            to->ContextFlags |= CONTEXT_I386_INTEGER;
            to->Eax = from->integer.i386_regs.eax;
            to->Ebx = from->integer.i386_regs.ebx;
            to->Ecx = from->integer.i386_regs.ecx;
            to->Edx = from->integer.i386_regs.edx;
            to->Esi = from->integer.i386_regs.esi;
            to->Edi = from->integer.i386_regs.edi;
        }
        if ((from->flags & SERVER_CTX_SEGMENTS) && (to_flags & CONTEXT_I386_SEGMENTS))
        {
            to->ContextFlags |= CONTEXT_I386_SEGMENTS;
            to->SegDs = from->seg.i386_regs.ds;
            to->SegEs = from->seg.i386_regs.es;
            to->SegFs = from->seg.i386_regs.fs;
            to->SegGs = from->seg.i386_regs.gs;
        }
        if ((from->flags & SERVER_CTX_FLOATING_POINT) && (to_flags & CONTEXT_I386_FLOATING_POINT))
        {
            to->ContextFlags |= CONTEXT_I386_FLOATING_POINT;
            to->FloatSave.ControlWord   = from->fp.i386_regs.ctrl;
            to->FloatSave.StatusWord    = from->fp.i386_regs.status;
            to->FloatSave.TagWord       = from->fp.i386_regs.tag;
            to->FloatSave.ErrorOffset   = from->fp.i386_regs.err_off;
            to->FloatSave.ErrorSelector = from->fp.i386_regs.err_sel;
            to->FloatSave.DataOffset    = from->fp.i386_regs.data_off;
            to->FloatSave.DataSelector  = from->fp.i386_regs.data_sel;
            to->FloatSave.Cr0NpxState   = from->fp.i386_regs.cr0npx;
            memcpy( to->FloatSave.RegisterArea, from->fp.i386_regs.regs, sizeof(to->FloatSave.RegisterArea) );
        }
        if ((from->flags & SERVER_CTX_DEBUG_REGISTERS) && (to_flags & CONTEXT_I386_DEBUG_REGISTERS))
        {
            to->ContextFlags |= CONTEXT_I386_DEBUG_REGISTERS;
            to->Dr0 = from->debug.i386_regs.dr0;
            to->Dr1 = from->debug.i386_regs.dr1;
            to->Dr2 = from->debug.i386_regs.dr2;
            to->Dr3 = from->debug.i386_regs.dr3;
            to->Dr6 = from->debug.i386_regs.dr6;
            to->Dr7 = from->debug.i386_regs.dr7;
        }
        if ((from->flags & SERVER_CTX_EXTENDED_REGISTERS) && (to_flags & CONTEXT_I386_EXTENDED_REGISTERS))
        {
            to->ContextFlags |= CONTEXT_I386_EXTENDED_REGISTERS;
            memcpy( to->ExtendedRegisters, from->ext.i386_regs, sizeof(to->ExtendedRegisters) );
        }
        if ((from->flags & SERVER_CTX_YMM_REGISTERS) && (to_flags & CONTEXT_I386_XSTATE))
            xstate_from_server( (CONTEXT_EX *)(to + 1), from );
        exception_request_flags_from_server( &to->ContextFlags, from );
        return STATUS_SUCCESS;
    }

    case MAKELONG( IMAGE_FILE_MACHINE_AMD64, IMAGE_FILE_MACHINE_I386 ):
    {
        I386_CONTEXT *to = dst;

        to_flags = to->ContextFlags & ~CONTEXT_i386;
        if ((from->flags & SERVER_CTX_CONTROL) && (to_flags & CONTEXT_I386_CONTROL))
        {
            to->ContextFlags |= CONTEXT_I386_CONTROL;
            to->Esp    = from->ctl.x86_64_regs.rsp;
            to->Eip    = from->ctl.x86_64_regs.rip;
            to->SegCs  = from->ctl.x86_64_regs.cs;
            to->SegSs  = from->ctl.x86_64_regs.ss;
            to->EFlags = from->ctl.x86_64_regs.flags;
        }
        if ((from->flags & SERVER_CTX_INTEGER) && (to_flags & CONTEXT_I386_INTEGER))
        {
            to->ContextFlags |= CONTEXT_I386_INTEGER;
            to->Eax = from->integer.x86_64_regs.rax;
            to->Ebx = from->integer.x86_64_regs.rbx;
            to->Ecx = from->integer.x86_64_regs.rcx;
            to->Edx = from->integer.x86_64_regs.rdx;
            to->Esi = from->integer.x86_64_regs.rsi;
            to->Edi = from->integer.x86_64_regs.rdi;
        }
        if ((from->flags & SERVER_CTX_INTEGER) && (to_flags & CONTEXT_I386_CONTROL))
        {
            to->Ebp = from->integer.x86_64_regs.rbp;
        }
        if ((from->flags & SERVER_CTX_SEGMENTS) && (to_flags & CONTEXT_I386_SEGMENTS))
        {
            to->ContextFlags |= CONTEXT_I386_SEGMENTS;
            to->SegDs = from->seg.x86_64_regs.ds;
            to->SegEs = from->seg.x86_64_regs.es;
            to->SegFs = from->seg.x86_64_regs.fs;
            to->SegGs = from->seg.x86_64_regs.gs;
        }
        if (from->flags & SERVER_CTX_FLOATING_POINT)
        {
            if (to_flags & CONTEXT_I386_EXTENDED_REGISTERS)
            {
                to->ContextFlags |= CONTEXT_I386_EXTENDED_REGISTERS;
                memcpy( to->ExtendedRegisters, from->fp.x86_64_regs.fpregs, sizeof(to->ExtendedRegisters) );
            }
            if (to_flags & CONTEXT_I386_FLOATING_POINT)
            {
                to->ContextFlags |= CONTEXT_I386_FLOATING_POINT;
                fpux_to_fpu( &to->FloatSave, (XMM_SAVE_AREA32 *)from->fp.x86_64_regs.fpregs );
            }
        }
        if ((from->flags & SERVER_CTX_DEBUG_REGISTERS) && (to_flags & CONTEXT_I386_DEBUG_REGISTERS))
        {
            to->ContextFlags |= CONTEXT_I386_DEBUG_REGISTERS;
            to->Dr0 = from->debug.x86_64_regs.dr0;
            to->Dr1 = from->debug.x86_64_regs.dr1;
            to->Dr2 = from->debug.x86_64_regs.dr2;
            to->Dr3 = from->debug.x86_64_regs.dr3;
            to->Dr6 = from->debug.x86_64_regs.dr6;
            to->Dr7 = from->debug.x86_64_regs.dr7;
        }
        if ((from->flags & SERVER_CTX_YMM_REGISTERS) && (to_flags & CONTEXT_I386_XSTATE))
            xstate_from_server( (CONTEXT_EX *)(to + 1), from );
        exception_request_flags_from_server( &to->ContextFlags, from );
        return STATUS_SUCCESS;
    }

    case MAKELONG( IMAGE_FILE_MACHINE_AMD64, IMAGE_FILE_MACHINE_AMD64 ):
    {
        AMD64_CONTEXT *to = dst;

        to_flags = to->ContextFlags & ~CONTEXT_AMD64;
        if ((from->flags & SERVER_CTX_CONTROL) && (to_flags & CONTEXT_AMD64_CONTROL))
        {
            to->ContextFlags |= CONTEXT_AMD64_CONTROL;
            to->Rip    = from->ctl.x86_64_regs.rip;
            to->Rsp    = from->ctl.x86_64_regs.rsp;
            to->SegCs  = from->ctl.x86_64_regs.cs;
            to->SegSs  = from->ctl.x86_64_regs.ss;
            to->EFlags = from->ctl.x86_64_regs.flags;
        }
        if ((from->flags & SERVER_CTX_INTEGER) && (to_flags & CONTEXT_AMD64_INTEGER))
        {
            to->ContextFlags |= CONTEXT_AMD64_INTEGER;
            to->Rax = from->integer.x86_64_regs.rax;
            to->Rcx = from->integer.x86_64_regs.rcx;
            to->Rdx = from->integer.x86_64_regs.rdx;
            to->Rbx = from->integer.x86_64_regs.rbx;
            to->Rbp = from->integer.x86_64_regs.rbp;
            to->Rsi = from->integer.x86_64_regs.rsi;
            to->Rdi = from->integer.x86_64_regs.rdi;
            to->R8  = from->integer.x86_64_regs.r8;
            to->R9  = from->integer.x86_64_regs.r9;
            to->R10 = from->integer.x86_64_regs.r10;
            to->R11 = from->integer.x86_64_regs.r11;
            to->R12 = from->integer.x86_64_regs.r12;
            to->R13 = from->integer.x86_64_regs.r13;
            to->R14 = from->integer.x86_64_regs.r14;
            to->R15 = from->integer.x86_64_regs.r15;
        }
        if ((from->flags & SERVER_CTX_SEGMENTS) && (to_flags & CONTEXT_AMD64_SEGMENTS))
        {
            to->ContextFlags |= CONTEXT_AMD64_SEGMENTS;
            to->SegDs = from->seg.x86_64_regs.ds;
            to->SegEs = from->seg.x86_64_regs.es;
            to->SegFs = from->seg.x86_64_regs.fs;
            to->SegGs = from->seg.x86_64_regs.gs;
        }
        if ((from->flags & SERVER_CTX_FLOATING_POINT) && (to_flags & CONTEXT_AMD64_FLOATING_POINT))
        {
            to->ContextFlags |= CONTEXT_AMD64_FLOATING_POINT;
            memcpy( &to->FltSave, from->fp.x86_64_regs.fpregs, sizeof(from->fp.x86_64_regs.fpregs) );
            to->MxCsr = to->FltSave.MxCsr;
        }
        if ((from->flags & SERVER_CTX_DEBUG_REGISTERS) && (to_flags & CONTEXT_AMD64_DEBUG_REGISTERS))
        {
            to->ContextFlags |= CONTEXT_AMD64_DEBUG_REGISTERS;
            to->Dr0 = from->debug.x86_64_regs.dr0;
            to->Dr1 = from->debug.x86_64_regs.dr1;
            to->Dr2 = from->debug.x86_64_regs.dr2;
            to->Dr3 = from->debug.x86_64_regs.dr3;
            to->Dr6 = from->debug.x86_64_regs.dr6;
            to->Dr7 = from->debug.x86_64_regs.dr7;
        }
        if ((from->flags & SERVER_CTX_YMM_REGISTERS) && (to_flags & CONTEXT_AMD64_XSTATE))
            xstate_from_server( (CONTEXT_EX *)(to + 1), from );
        exception_request_flags_from_server( &to->ContextFlags, from );
        return STATUS_SUCCESS;
    }

    case MAKELONG( IMAGE_FILE_MACHINE_I386, IMAGE_FILE_MACHINE_AMD64 ):
    {
        AMD64_CONTEXT *to = dst;

        to_flags = to->ContextFlags & ~CONTEXT_AMD64;
        if ((from->flags & SERVER_CTX_CONTROL) && (to_flags & CONTEXT_AMD64_CONTROL))
        {
            to->ContextFlags |= CONTEXT_AMD64_CONTROL;
            to->Rip    = from->ctl.i386_regs.eip;
            to->Rsp    = from->ctl.i386_regs.esp;
            to->SegCs  = from->ctl.i386_regs.cs;
            to->SegSs  = from->ctl.i386_regs.ss;
            to->EFlags = from->ctl.i386_regs.eflags;
        }
        if ((from->flags & SERVER_CTX_INTEGER) && (to_flags & CONTEXT_AMD64_INTEGER))
        {
            to->ContextFlags |= CONTEXT_AMD64_INTEGER;
            to->Rax = from->integer.i386_regs.eax;
            to->Rcx = from->integer.i386_regs.ecx;
            to->Rdx = from->integer.i386_regs.edx;
            to->Rbx = from->integer.i386_regs.ebx;
            to->Rsi = from->integer.i386_regs.esi;
            to->Rdi = from->integer.i386_regs.edi;
        }
        if ((from->flags & SERVER_CTX_CONTROL) && (to_flags & CONTEXT_AMD64_INTEGER))
        {
            to->Rbp = from->ctl.i386_regs.ebp;
        }
        if ((from->flags & SERVER_CTX_SEGMENTS) && (to_flags & CONTEXT_AMD64_SEGMENTS))
        {
            to->ContextFlags |= CONTEXT_AMD64_SEGMENTS;
            to->SegDs = from->seg.i386_regs.ds;
            to->SegEs = from->seg.i386_regs.es;
            to->SegFs = from->seg.i386_regs.fs;
            to->SegGs = from->seg.i386_regs.gs;
        }
        if ((from->flags & SERVER_CTX_EXTENDED_REGISTERS) && (to_flags & CONTEXT_AMD64_FLOATING_POINT))
        {
            to->ContextFlags |= CONTEXT_AMD64_FLOATING_POINT;
            memcpy( &to->FltSave, from->ext.i386_regs, sizeof(to->FltSave) );
        }
        else if ((from->flags & SERVER_CTX_FLOATING_POINT) && (to_flags & CONTEXT_AMD64_FLOATING_POINT))
        {
            I386_FLOATING_SAVE_AREA fpu;

            to->ContextFlags |= CONTEXT_AMD64_FLOATING_POINT;
            fpu.ControlWord   = from->fp.i386_regs.ctrl;
            fpu.StatusWord    = from->fp.i386_regs.status;
            fpu.TagWord       = from->fp.i386_regs.tag;
            fpu.ErrorOffset   = from->fp.i386_regs.err_off;
            fpu.ErrorSelector = from->fp.i386_regs.err_sel;
            fpu.DataOffset    = from->fp.i386_regs.data_off;
            fpu.DataSelector  = from->fp.i386_regs.data_sel;
            fpu.Cr0NpxState   = from->fp.i386_regs.cr0npx;
            memcpy( fpu.RegisterArea, from->fp.i386_regs.regs, sizeof(fpu.RegisterArea) );
            fpu_to_fpux( &to->FltSave, &fpu );
        }
        if ((from->flags & SERVER_CTX_DEBUG_REGISTERS) && (to_flags & CONTEXT_AMD64_DEBUG_REGISTERS))
        {
            to->ContextFlags |= CONTEXT_AMD64_DEBUG_REGISTERS;
            to->Dr0 = from->debug.i386_regs.dr0;
            to->Dr1 = from->debug.i386_regs.dr1;
            to->Dr2 = from->debug.i386_regs.dr2;
            to->Dr3 = from->debug.i386_regs.dr3;
            to->Dr6 = from->debug.i386_regs.dr6;
            to->Dr7 = from->debug.i386_regs.dr7;
        }
        if ((from->flags & SERVER_CTX_YMM_REGISTERS) && (to_flags & CONTEXT_AMD64_XSTATE))
            xstate_from_server( (CONTEXT_EX *)(to + 1), from );
        exception_request_flags_from_server( &to->ContextFlags, from );
        return STATUS_SUCCESS;
    }

    case MAKELONG( IMAGE_FILE_MACHINE_ARMNT, IMAGE_FILE_MACHINE_ARMNT ):
    {
        ARM_CONTEXT *to = dst;

        to_flags = to->ContextFlags & ~CONTEXT_ARM;
        if ((from->flags & SERVER_CTX_CONTROL) && (to_flags & CONTEXT_ARM_CONTROL))
        {
            to->ContextFlags |= CONTEXT_ARM_CONTROL;
            to->Sp   = from->ctl.arm_regs.sp;
            to->Lr   = from->ctl.arm_regs.lr;
            to->Pc   = from->ctl.arm_regs.pc;
            to->Cpsr = from->ctl.arm_regs.cpsr;
        }
        if ((from->flags & SERVER_CTX_INTEGER) && (to_flags & CONTEXT_ARM_INTEGER))
        {
            to->ContextFlags |= CONTEXT_ARM_INTEGER;
            to->R0  = from->integer.arm_regs.r[0];
            to->R1  = from->integer.arm_regs.r[1];
            to->R2  = from->integer.arm_regs.r[2];
            to->R3  = from->integer.arm_regs.r[3];
            to->R4  = from->integer.arm_regs.r[4];
            to->R5  = from->integer.arm_regs.r[5];
            to->R6  = from->integer.arm_regs.r[6];
            to->R7  = from->integer.arm_regs.r[7];
            to->R8  = from->integer.arm_regs.r[8];
            to->R9  = from->integer.arm_regs.r[9];
            to->R10 = from->integer.arm_regs.r[10];
            to->R11 = from->integer.arm_regs.r[11];
            to->R12 = from->integer.arm_regs.r[12];
        }
        if ((from->flags & SERVER_CTX_FLOATING_POINT) && (to_flags & CONTEXT_ARM_FLOATING_POINT))
        {
            to->ContextFlags |= CONTEXT_ARM_FLOATING_POINT;
            for (i = 0; i < 32; i++) to->D[i] = from->fp.arm_regs.d[i];
            to->Fpscr = from->fp.arm_regs.fpscr;
        }
        if ((from->flags & SERVER_CTX_DEBUG_REGISTERS) && (to_flags & CONTEXT_ARM_DEBUG_REGISTERS))
        {
            to->ContextFlags |= CONTEXT_ARM_DEBUG_REGISTERS;
            for (i = 0; i < ARM_MAX_BREAKPOINTS; i++) to->Bvr[i] = from->debug.arm_regs.bvr[i];
            for (i = 0; i < ARM_MAX_BREAKPOINTS; i++) to->Bcr[i] = from->debug.arm_regs.bcr[i];
            for (i = 0; i < ARM_MAX_WATCHPOINTS; i++) to->Wvr[i] = from->debug.arm_regs.wvr[i];
            for (i = 0; i < ARM_MAX_WATCHPOINTS; i++) to->Wcr[i] = from->debug.arm_regs.wcr[i];
        }
        exception_request_flags_from_server( &to->ContextFlags, from );
        return STATUS_SUCCESS;
    }

    case MAKELONG( IMAGE_FILE_MACHINE_ARM64, IMAGE_FILE_MACHINE_ARM64 ):
    {
        ARM64_NT_CONTEXT *to = dst;

        to_flags = to->ContextFlags & ~CONTEXT_ARM64;
        if ((from->flags & SERVER_CTX_CONTROL) && (to_flags & CONTEXT_ARM64_CONTROL))
        {
            to->ContextFlags |= CONTEXT_ARM64_CONTROL;
            to->Fp   = from->integer.arm64_regs.x[29];
            to->Lr   = from->integer.arm64_regs.x[30];
            to->Sp   = from->ctl.arm64_regs.sp;
            to->Pc   = from->ctl.arm64_regs.pc;
            to->Cpsr = from->ctl.arm64_regs.pstate;
        }
        if ((from->flags & SERVER_CTX_INTEGER) && (to_flags & CONTEXT_ARM64_INTEGER))
        {
            to->ContextFlags |= CONTEXT_ARM64_INTEGER;
            for (i = 0; i <= 28; i++) to->X[i] = from->integer.arm64_regs.x[i];
        }
        if ((from->flags & SERVER_CTX_FLOATING_POINT) && (to_flags & CONTEXT_ARM64_FLOATING_POINT))
        {
            to->ContextFlags |= CONTEXT_ARM64_FLOATING_POINT;
            for (i = 0; i < 32; i++)
            {
                to->V[i].Low = from->fp.arm64_regs.q[i].low;
                to->V[i].High = from->fp.arm64_regs.q[i].high;
            }
            to->Fpcr = from->fp.arm64_regs.fpcr;
            to->Fpsr = from->fp.arm64_regs.fpsr;
        }
        if ((from->flags & SERVER_CTX_DEBUG_REGISTERS) && (to_flags & CONTEXT_ARM64_DEBUG_REGISTERS))
        {
            to->ContextFlags |= CONTEXT_ARM64_DEBUG_REGISTERS;
            for (i = 0; i < ARM64_MAX_BREAKPOINTS; i++) to->Bcr[i] = from->debug.arm64_regs.bcr[i];
            for (i = 0; i < ARM64_MAX_BREAKPOINTS; i++) to->Bvr[i] = from->debug.arm64_regs.bvr[i];
            for (i = 0; i < ARM64_MAX_WATCHPOINTS; i++) to->Wcr[i] = from->debug.arm64_regs.wcr[i];
            for (i = 0; i < ARM64_MAX_WATCHPOINTS; i++) to->Wvr[i] = from->debug.arm64_regs.wvr[i];
        }
        exception_request_flags_from_server( &to->ContextFlags, from );
        return STATUS_SUCCESS;
    }

    case MAKELONG( IMAGE_FILE_MACHINE_ARM64, IMAGE_FILE_MACHINE_I386 ):
    case MAKELONG( IMAGE_FILE_MACHINE_I386, IMAGE_FILE_MACHINE_ARM64 ):
        return STATUS_SUCCESS;

    default:
        return STATUS_INVALID_PARAMETER;
    }
}


/***********************************************************************
 *           contexts_to_server
 */
static void contexts_to_server( struct context_data server_contexts[2], CONTEXT *context )
{
    unsigned int count = 0;
    void *native_context = get_native_context( context );
    void *wow_context = get_wow_context( context );
    /* Owner-aware (X3): context machine follows the calling pseudo-process. */
    extern const SECTION_IMAGE_INFORMATION *ios_cur_image_info(void);
    USHORT image_machine = ios_cur_image_info()->Machine;

    if (native_context)
    {
        context_to_server( &server_contexts[count++], native_machine, native_context, native_machine );
        if (wow_context) context_to_server( &server_contexts[count++], image_machine,
                                            wow_context, image_machine );
        else if (native_machine != image_machine)
            context_to_server( &server_contexts[count++], image_machine,
                               native_context, native_machine );
    }
    else
        context_to_server( &server_contexts[count++], native_machine,
                           wow_context, image_machine );

    if (count < 2) memset( &server_contexts[1], 0, sizeof(server_contexts[1]) );
}


/***********************************************************************
 *           contexts_from_server
 */
static void contexts_from_server( CONTEXT *context, struct context_data server_contexts[2] )
{
    void *native_context = get_native_context( context );
    void *wow_context = get_wow_context( context );
    /* Owner-aware (X3): context machine follows the calling pseudo-process. */
    extern const SECTION_IMAGE_INFORMATION *ios_cur_image_info(void);
    USHORT image_machine = ios_cur_image_info()->Machine;

    if (native_context)
    {
        context_from_server( native_context, &server_contexts[0], native_machine );
        if (wow_context)
            context_from_server( wow_context, &server_contexts[1], image_machine );
        else
            context_from_server( native_context, &server_contexts[1], native_machine );
    }
    else context_from_server( wow_context, &server_contexts[0], image_machine );
}


/***********************************************************************
 *           pthread_exit_wrapper
 */
static DECLSPEC_NORETURN void pthread_exit_wrapper( int status )
{
    /* iOS-Madeira ml558: a NATIVE (non-wine) thread can reach here.
     *
     * ml557 died exactly this way: a native thread faulted, the [fault-stuck]
     * breaker diverted it to abort_thread -> here, NtCurrentTeb() was NULL, and
     * `ntdll_get_thread_data()->alert_fd` faulted at 0x394. That fault storms,
     * the breaker diverts to abort_thread AGAIN, and we recurse until the stack
     * is gone -- 5,000+ iterations, sp walking down ~0x70 each time. A thread
     * with no wine TEB owns no wine fds, so there is simply nothing to close;
     * exiting quietly is both correct and the only way out of the loop. */
    if (!NtCurrentTeb())
    {
        static unsigned long noteb_n;
        if (++noteb_n <= 8)
            dprintf(2, "[pthread-exit] NO WINE TEB (native thread) — closing nothing, "
                       "exiting cleanly (n=%lu) rev=ml558\n", noteb_n);
        pthread_exit( UIntToPtr(status) );
    }
    close( ntdll_get_thread_data()->alert_fd );
    close( ntdll_get_thread_data()->wait_fd[0] );
    close( ntdll_get_thread_data()->wait_fd[1] );
    close( ntdll_get_thread_data()->reply_fd );
    close( ntdll_get_thread_data()->request_fd );
    /* iOS-Madeira (Steam S0): we write the TEB directly into TSD slot 275
     * (start_thread above) because FEX hardcodes offset 0x898 — but we
     * don't OWN dynamic key 275. If an Apple framework allocated that key
     * with an ObjC destructor, pthread's TSD cleanup calls
     * destructor(TEB) at thread exit → objc_release on a non-object →
     * crash (seen: every winhttp resolver-thread exit died in
     * objc_release+0x10 under pthread_exit). NULL values are skipped by
     * the cleanup loop, so clear the slot before exiting. */
    /* iOS-Madeira ml614: DETECT the leaked FEX hold, but DO NOT CALL INTO FEX.
     *
     * ⛔⛔ ml613 CALLED BTCpu64IosReleaseThreadHolds FROM HERE AND CRASHED EVERY
     * LAUNCH. That export is an **ARM64EC PE entry**, not a native Mach-O ARM64
     * function — its first bytes are the x64 entry thunk. Calling it from this
     * (native, Mach-O) code fetched those bytes as ARM64 instructions:
     *
     *   [xlate-exec]  pc=0x71f99c4040 -> 0x125528040       <- the resolved export
     *   [av-detail]   hostpc=0x125528040 hinsn=0x48c48b48  <- x64 `48 8b c4 48`
     *   [mach_exc]    lr=... pthread_exit_wrapper+0x10c    <- called from HERE
     *   0068: NtTerminateProcess(... c0000005)
     *
     * ⚠️ I originally read those [av-detail] lines as "the probe fired harmlessly"
     * because regs=0/carve=none. They were the probe photographing THIS bug.
     *
     * 🔑 RULE: never call a resolved ARM64EC PE export directly from native
     * unix/Mach-O code — that includes the exact-RIP callback. Any such call needs
     * either a genuinely native ARM64 C-ABI bridge on FEX's host side, or to run
     * from code already executing inside the ARM64EC environment.
     *
     * So the release itself is DEFERRED (see below for where it belongs). What
     * stays here is the detection, which costs nothing and is what named the ml611
     * freeze in the first place. A leaked hold still wedges the process — this
     * build reports it precisely instead of pretending to fix it.
     *
     * NEXT (not in this build): perform the release from the PE-side thread
     * teardown path (pThreadTerm/ThreadTerm), before it takes FEX teardown locks,
     * with a dedicated PE-side hook for abnormal exits that bypass it. The
     * callback/context must also be PEB-keyed — ios_resolve_fex_exports latches
     * the FIRST libarm64ecfex.dll mapping globally, but there are several
     * pseudo-process instances in this one Mach task. */
    if (NtCurrentTeb())
    {
        unsigned int tid = (unsigned int)(ULONG_PTR)NtCurrentTeb()->ClientId.UniqueThread;
        unsigned long long pre_stamp =
            *(volatile unsigned long long *)((char *)NtCurrentTeb() + 0x16f8);
        unsigned int pre_depth =
            *(volatile unsigned int *)((char *)NtCurrentTeb() + 0x16f0);
        unsigned int rwx_read =
            *(volatile unsigned char *)((char *)NtCurrentTeb() + 0x1700) ? 1u : 0u;

        /* ml614: gate on actually holding something. ml613 ran this block on EVERY
         * thread exit once the export resolved, even with pre_stamp == 0. */
        if (pre_stamp || rwx_read)
        {
            /* ml618: RELEASE IT. The callback is the arm64ec_redirect_ptr()-resolved
             * ARM64 alias registered by the PE side and self-tested there, so this
             * native call is legal — unlike ml613, which bound base+RVA (the raw x64
             * entry thunk) and died on every launch.
             *
             * PEB-keyed: pick the callback belonging to THIS pseudo-process, because
             * each has its own FEX context and its own CodeInvalidationMutex.
             * Runs while the TEB is still valid and before TSD 275 is cleared. */
            extern unsigned int (*ios_hold_release_lookup(void *peb))(void *, unsigned long long *,
                                                                      unsigned int *, unsigned int *);
            void *peb = NtCurrentTeb()->Peb;
            unsigned int (*cb)(void *, unsigned long long *, unsigned int *, unsigned int *) =
                ios_hold_release_lookup( peb );
            unsigned long long stamp = 0;
            unsigned int depth = 0, flags = 0, r = 0;

            if (cb) r = cb( NtCurrentTeb(), &stamp, &depth, &flags );

            dprintf(2, "[exit-hold] ml618 tid=%04x peb=%p stamp=0x%llx depth=%u rwx_read=%u -> %s"
                       "released=0x%x (%s%s%s%s)\n",
                    tid, peb, pre_stamp, pre_depth, rwx_read,
                    cb ? "" : "NO CALLBACK FOR THIS PEB — STILL LEAKED; ",
                    r,
                    (r & 1) ? "shared " : "",
                    (r & 2) ? "rwx-exclusive " : "",
                    (r & 4) ? "STAMP-FOREIGN-REFUSED " : "",
                    (r & 8) ? "no-ctx " : "");
        }
    }
    {
        /* Drop our own TEB reference through the key that owns the slot.
         * We used to poke raw slot 275 here, which we never owned. */
        extern pthread_key_t ios_teb_tls_key;
        pthread_setspecific( ios_teb_tls_key, NULL );
        /* iOS-Madeira ml413 (#60): xtajit64 stamps TEB->Instrumentation[8]
         * (+0x16f8) while this thread holds a FEX shared lock (compile-time
         * CodeInvalidationMutex read hold). A thread exiting with the stamp
         * still set is leaking that hold — every later invalidation writer
         * parks forever behind it. Log-only: names the leaker + the mutex. */
        {
            uint64_t held_lock = *(volatile uint64_t *)((char *)NtCurrentTeb() + 0x16f8);
            if (held_lock)
                dprintf(2, "[exit-hold] tid=%04x teb=%p EXITING while holding FEX shared lock @0x%llx — read hold LEAKED\n",
                        (unsigned int)(ULONG_PTR)NtCurrentTeb()->ClientId.UniqueThread,
                        NtCurrentTeb(), (unsigned long long)held_lock);
        }
        /* ml173: tell the VA layer this thread is gone so its leaked 512MB steered
         * reserves can be released (see ios_steer_reclaim_dead in virtual_ios.c).
         * A dead thread can never commit into them again, which is what makes
         * reclaiming them safe. */
        {
            extern void ios_thread_died( unsigned tid );
            ios_thread_died( (unsigned)(ULONG_PTR)NtCurrentTeb()->ClientId.UniqueThread );
        }
        {
            extern void ios_thread_qos_exit( unsigned tid );   /* MADEIRA_THREAD_QOS */
            ios_thread_qos_exit( (unsigned)(ULONG_PTR)NtCurrentTeb()->ClientId.UniqueThread );
        }
    }
    pthread_exit( UIntToPtr(status) );
}


/* madeira-bcd eco-native: env.MADEIRA_ECO_NATIVE = 1 (opt-in). The runtime's own
 * native helper threads -- the JIT-pool warmer (virtual_ios.c: page warming and
 * the periodic address-space walks, which ran on performance cores at ~2.8 GHz
 * in hzd486) and the stale-pointer healer (signal_arm64_ios.c) -- do no work a
 * frame waits for, yet they are created at the QoS of the thread that started
 * them. With the switch each moves itself to utility QoS when it starts, so it
 * runs on the efficiency cores at their lower clock, ECO on or off. Not moved:
 * the wineserver thread, the Mach exception thread (it services the faults
 * guest threads wait on), the samplers (already utility), audio, the UI. */
void ios_eco_native_self( const char *who )
{
    static int on = -1;
    int r;
    if (on < 0)
    {
        const char *e = getenv( "MADEIRA_ECO_NATIVE" );   /* 1: the runtime's native helper threads run at utility QoS */
        on = e && *e && strcmp( e, "0" ) != 0;
    }
    if (!on) return;
    r = pthread_set_qos_class_self_np( QOS_CLASS_UTILITY, 0 );
    dprintf( 2, "[eco-native] madeira-bcd %s thread at utility QoS%s (MADEIRA_ECO_NATIVE)\n", who, r ? ": refused" : "" );
}

/* eco-prio: env.MADEIRA_ECO_PRIO = 1 or 2 (opt-in). With eco on
 * (madeira.cfg eco = 1, the ECO pill, the power governor) every guest thread
 * runs at the eco QoS class, which keeps it on the efficiency cores. Horizon
 * Forbidden West on build 531 (2026-10-14) ran that way with 6-8 threads waiting
 * for a core on a full efficiency cluster while the performance cores did
 * 0.4-0.5 of a core of work ([xp] P= / E= / run=), and the threads a frame waits
 * on most directly -- madeira-d3d12's fence worker, which advances a fence once
 * the GPU is done, and its submission workers (async-submit = 1) -- queued for
 * the same cores as the game's job workers. With the switch, a thread that sets
 * ITS OWN priority (SetThreadPriority on itself) to THREAD_PRIORITY_TIME_CRITICAL
 * (1), or to THREAD_PRIORITY_HIGHEST and above (2), keeps the user-interactive
 * QoS while eco is on; setting a lower priority later returns it to the eco
 * class. madeira-d3d12's own worker threads ask for TIME_CRITICAL when the
 * switch is set. Another thread's priority is never touched (its pthread could
 * be gone by then), and a thread raised before eco came on is not moved. The
 * next ECO switch re-applies the eco class to every thread, these included.
 * Unset or 0: nothing changes. [eco-prio] names the first 32 threads moved. */
static int ios_eco_prio_level( void )
{
    static int lvl = -1;
    if (lvl < 0)
    {
        const char *e = getenv( "MADEIRA_ECO_PRIO" );   /* 1: under eco, a thread that raises itself to TIME_CRITICAL keeps user-interactive QoS; 2: HIGHEST and above; unset/0: off */
        int v = e && *e ? atoi( e ) : 0;
        lvl = v < 0 ? 0 : v > 2 ? 2 : v;
    }
    return lvl;
}

static __thread int ios_eco_prio_raised;   /* this thread holds user-interactive QoS through eco-prio */

static void ios_eco_prio_note( HANDLE handle, LONG priority )
{
    extern int madeira_get_eco( void );
    extern void ios_eco_apply_self( void );
    static int said;
    int lvl = ios_eco_prio_level(), raise, r;
    char name[64] = "";

    if (!lvl) return;
    raise = priority >= (lvl >= 2 ? THREAD_PRIORITY_HIGHEST : THREAD_PRIORITY_TIME_CRITICAL) && priority < 16;
    if (raise == ios_eco_prio_raised) return;   /* nothing to change for the calling thread */
    if (raise && !madeira_get_eco()) return;   /* eco off: every guest thread is user-interactive already */
    if (handle != GetCurrentThread())
    {
        THREAD_BASIC_INFORMATION tbi;
        if (NtQueryInformationThread( handle, ThreadBasicInformation, &tbi, sizeof(tbi), NULL ) ||
            HandleToULong( tbi.ClientId.UniqueThread ) != GetCurrentThreadId())
            return;   /* another thread: never touched */
    }
    if (raise) r = pthread_set_qos_class_self_np( QOS_CLASS_USER_INTERACTIVE, 0 );
    else { ios_eco_apply_self(); r = 0; }   /* back to whatever eco says now */
    ios_eco_prio_raised = raise && !r;
    pthread_getname_np( pthread_self(), name, sizeof(name) );
    if (__atomic_fetch_add( &said, 1, __ATOMIC_RELAXED ) < 32)
        dprintf( 2, "[eco-prio] thread %04x '%s' set itself to priority %d: %s (MADEIRA_ECO_PRIO=%d)\n",
                 (unsigned)GetCurrentThreadId(), name, (int)priority,
                 !raise ? "back to the eco QoS class" : r ? "user-interactive QoS REFUSED" : "user-interactive QoS while eco is on", lvl );
}

/* thread-qos: env.MADEIRA_THREAD_QOS = "GXWorker*=user-initiated;FD4JobWorker*=utility"
 * (opt-in). Every guest thread runs at USER_INTERACTIVE, so the scheduler cannot
 * tell a game's main thread from its worker pools: in Dark Souls III the five
 * GXWorker threads took more performance-core time than the main thread, which
 * spent 19 % of its time on the efficiency cores. With the switch, a thread whose
 * name (SetThreadDescription) matches a pattern runs at that class instead; first
 * match wins, '*' and '?' are wildcards, classes are user-interactive,
 * user-initiated (initiated), default, utility, background. Threads with no
 * name or no matching rule keep USER_INTERACTIVE, and ECO still overrides all.
 *
 * QoS can only be set by a thread on itself. A thread that names itself (also
 * through a real handle, as Dark Souls III does) applies its class at once; a
 * thread named by another one applies it at its next wait, sleep or yield: the
 * name is stored under its tid and ios_eco_gen is bumped, so every guest thread
 * re-runs ios_eco_apply_self (sync.c), whose pthread_set_qos_class_self_np is
 * renamed to madeira_guest_qos_self below (build.sh compiles sync.c with
 * -Dpthread_set_qos_class_self_np=madeira_guest_qos_self). Unset = nothing
 * changes: madeira_guest_qos_self passes the class through untouched. */
#define TQ_MAX_RULES   32
#define TQ_MAX_THREADS 512
struct tq_rule { char pat[64]; qos_class_t cls; };
struct tq_thread { unsigned tid; qos_class_t cls; char name[48]; };
static struct tq_rule tq_rules[TQ_MAX_RULES];
static int tq_nrules;
static int tq_on;
static pthread_once_t tq_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t tq_lock = PTHREAD_MUTEX_INITIALIZER;
static struct tq_thread tq_threads[TQ_MAX_THREADS];   /* tid 0 = free slot */
static __thread unsigned tq_self_tid;                 /* set once the TEB is known */
static __thread qos_class_t tq_self_applied;          /* class this thread set through the switch, 0 = none */

static const char *tq_class_name( qos_class_t c )
{
    switch (c)
    {
    case QOS_CLASS_USER_INTERACTIVE: return "user-interactive";
    case QOS_CLASS_USER_INITIATED:   return "user-initiated";
    case QOS_CLASS_DEFAULT:          return "default";
    case QOS_CLASS_UTILITY:          return "utility";
    case QOS_CLASS_BACKGROUND:       return "background";
    default:                         return "?";
    }
}

static qos_class_t tq_parse_class( const char *s )
{
    if (!strcmp( s, "user-interactive" ) || !strcmp( s, "interactive" )) return QOS_CLASS_USER_INTERACTIVE;
    if (!strcmp( s, "user-initiated" ) || !strcmp( s, "initiated" )) return QOS_CLASS_USER_INITIATED;
    if (!strcmp( s, "default" )) return QOS_CLASS_DEFAULT;
    if (!strcmp( s, "utility" )) return QOS_CLASS_UTILITY;
    if (!strcmp( s, "background" )) return QOS_CLASS_BACKGROUND;
    return QOS_CLASS_UNSPECIFIED;
}

static int tq_glob( const char *p, const char *s )
{
    for (;;)
    {
        if (*p == '*')
        {
            while (*p == '*') p++;
            if (!*p) return 1;
            for (; *s; s++) if (tq_glob( p, s )) return 1;
            return 0;
        }
        if (!*p) return !*s;
        if (!*s || (*p != '?' && *p != *s)) return 0;
        p++; s++;
    }
}

static char *tq_trim( char *s, char *end )   /* [s, end) without surrounding blanks, NUL-terminated */
{
    while (s < end && (*s == ' ' || *s == '\t')) s++;
    while (end > s && (end[-1] == ' ' || end[-1] == '\t' || end[-1] == '"')) end--;
    if (s < end && *s == '"') s++;
    *end = 0;
    return s;
}

static void tq_init_once(void)
{
    const char *e = getenv( "MADEIRA_THREAD_QOS" );
    char buf[1024], *p, *next;
    if (!e || !*e) return;
    snprintf( buf, sizeof(buf), "%s", e );
    for (p = buf; p && *p && tq_nrules < TQ_MAX_RULES; p = next)
    {
        char *semi = strchr( p, ';' ), *end = semi ? semi : p + strlen( p ), *eq, *pat, *cls;
        qos_class_t c;
        next = semi ? semi + 1 : NULL;
        *end = 0;
        if (!(eq = strrchr( p, '=' ))) continue;
        pat = tq_trim( p, eq );
        cls = tq_trim( eq + 1, end );
        if (!*pat || strlen( pat ) >= sizeof(tq_rules[0].pat)) continue;
        if ((c = tq_parse_class( cls )) == QOS_CLASS_UNSPECIFIED)
        {
            dprintf( 2, "[thread-qos] ignored rule \"%s=%s\": unknown class\n", pat, cls );
            continue;
        }
        strcpy( tq_rules[tq_nrules].pat, pat );
        tq_rules[tq_nrules++].cls = c;
    }
    tq_on = tq_nrules > 0;
    dprintf( 2, "[thread-qos] MADEIRA_THREAD_QOS: %d rule(s)%s\n", tq_nrules, tq_on ? "" : ", switch off" );
}

static int tq_enabled(void)
{
    pthread_once( &tq_once, tq_init_once );
    return tq_on;
}

/* the class stored for tid (0 = none); copies its name into name[48] */
static qos_class_t tq_lookup( unsigned tid, char *name )
{
    qos_class_t c = QOS_CLASS_UNSPECIFIED;
    int i;
    pthread_mutex_lock( &tq_lock );
    for (i = 0; i < TQ_MAX_THREADS; i++)
        if (tq_threads[i].tid == tid)
        {
            c = tq_threads[i].cls;
            if (name) memcpy( name, tq_threads[i].name, sizeof(tq_threads[i].name) );
            break;
        }
    pthread_mutex_unlock( &tq_lock );
    return c;
}

/* cls 0 removes the entry; returns 1 if the stored class changed */
static int tq_store( unsigned tid, qos_class_t cls, const char *name )
{
    int i, free_slot = -1, changed = 0;
    pthread_mutex_lock( &tq_lock );
    for (i = 0; i < TQ_MAX_THREADS; i++)
    {
        if (tq_threads[i].tid == tid) break;
        if (!tq_threads[i].tid && free_slot < 0) free_slot = i;
    }
    if (i < TQ_MAX_THREADS)
    {
        changed = tq_threads[i].cls != cls;
        if (cls)
        {
            tq_threads[i].cls = cls;
            snprintf( tq_threads[i].name, sizeof(tq_threads[i].name), "%s", name ? name : "" );
        }
        else tq_threads[i].tid = 0;
    }
    else if (cls && free_slot >= 0)
    {
        tq_threads[free_slot].cls = cls;
        snprintf( tq_threads[free_slot].name, sizeof(tq_threads[free_slot].name), "%s", name ? name : "" );
        __atomic_store_n( &tq_threads[free_slot].tid, tid, __ATOMIC_RELEASE );
        changed = 1;
    }
    pthread_mutex_unlock( &tq_lock );
    return changed;
}

/* sync.c's ios_eco_apply_self calls this in place of pthread_set_qos_class_self_np */
int madeira_guest_qos_self( qos_class_t cls, int rel )
{
    if (cls == QOS_CLASS_USER_INTERACTIVE && tq_self_tid && tq_enabled())
    {
        char name[48];
        qos_class_t want = tq_lookup( tq_self_tid, name );
        if (want)
        {
            int r = pthread_set_qos_class_self_np( want, 0 );
            if (want != tq_self_applied)
            {
                tq_self_applied = want;
                dprintf( 2, "[thread-qos] %04x %s -> %s%s\n", tq_self_tid, name,
                         tq_class_name( want ), r ? " REFUSED, stays user-interactive" : "" );
            }
            if (!r) return 0;
        }
        else if (tq_self_applied)
        {
            tq_self_applied = QOS_CLASS_UNSPECIFIED;
            dprintf( 2, "[thread-qos] %04x (no rule now) -> user-interactive\n", tq_self_tid );
        }
    }
    else if (cls != QOS_CLASS_USER_INTERACTIVE) tq_self_applied = QOS_CLASS_UNSPECIFIED;   /* ECO class */
    return pthread_set_qos_class_self_np( cls, rel );
}

/* start_thread, once the TEB is published: a thread named before it ran */
static void ios_thread_qos_start( unsigned tid )
{
    extern void ios_eco_apply_self(void);
    tq_self_tid = tid;
    if (tq_enabled() && tq_lookup( tid, NULL )) ios_eco_apply_self();
}

/* thread exit: a reused tid must not inherit the class */
void ios_thread_qos_exit( unsigned tid )
{
    if (tq_enabled()) tq_store( tid, QOS_CLASS_UNSPECIFIED, NULL );
}

/* set_native_thread_name */
static void ios_thread_qos_named( HANDLE handle, const char *name )
{
    extern void ios_eco_apply_self(void);
    extern volatile int ios_eco_gen;
    unsigned self, tid = 0;
    qos_class_t cls = QOS_CLASS_UNSPECIFIED;
    int i, changed;

    if (!tq_enabled()) return;
    self = (unsigned)(ULONG_PTR)NtCurrentTeb()->ClientId.UniqueThread;
    if (handle == GetCurrentThread() || handle == 0) tid = self;
    else
    {
        SERVER_START_REQ( get_thread_info )
        {
            req->handle = wine_server_obj_handle( handle );
            req->access = THREAD_QUERY_LIMITED_INFORMATION;
            if (!wine_server_call( req )) tid = reply->tid;
        }
        SERVER_END_REQ;
    }
    if (!tid) return;
    for (i = 0; i < tq_nrules; i++)
        if (tq_glob( tq_rules[i].pat, name )) { cls = tq_rules[i].cls; break; }
    changed = tq_store( tid, cls, name );
    if (tid == self)
    {
        tq_self_tid = self;
        if (changed) ios_eco_apply_self();
    }
    else if (changed) __atomic_add_fetch( &ios_eco_gen, 1, __ATOMIC_RELEASE );
}

/***********************************************************************
 *           start_thread
 *
 * Startup routine for a newly created thread.
 */
static void start_thread( TEB *teb )
{
    struct ntdll_thread_data *thread_data = (struct ntdll_thread_data *)&teb->GdiTebBatch;
    BOOL suspend;

    /* iOS-Madeira 2026-07-04 perf: promote guest threads to USER_INTERACTIVE
     * QoS. Default-QoS pthreads on iOS are E-core-eligible and get heavy
     * kernel timer coalescing (tens of ms of wakeup leeway on
     * select/nanosleep). [PROF] showed the game thread parked ~87% of each
     * 59ms frame in one system wait — if that's a frame-limiter sleep being
     * coalesced, this alone can collapse the wait to its requested length.
     * USER_INTERACTIVE = P-core scheduling + minimal timer leeway.
     * ml1133: through ios_eco_apply_self (sync.c), which picks the eco class
     * instead while the ECO switch is on. */
    {
        extern void ios_eco_apply_self(void);
        ios_eco_apply_self();
    }

    thread_data->syscall_table = KeServiceDescriptorTable;
    thread_data->syscall_trace = TRACE_ON(syscall);
    thread_data->pthread_id = pthread_self();
    pthread_setspecific( teb_key, teb );
    /* iOS: publish the TEB through our own pthread key so the x18
     * trampolines (mrs TPIDRRO_EL0; ldr TEB) work on this newly-created
     * thread. Without this, worker threads (DXMT command buffers,
     * NtCreateThreadEx threads) read TEB=0 and fault on the first guest x18
     * reference.
     *
     * This used to additionally write raw TSD slot 275, a dynamic pthread key
     * belonging to whoever created it first. Its real owner can reclaim and
     * reset it at any time -- observed on an M4 iPad, where the slot went to
     * NULL once the Metal stack came up and every trampoline then loaded
     * TEB=0. Only the slot backing ios_teb_tls_key is ours to write. */
    {
        extern pthread_key_t ios_teb_tls_key;
        extern int ios_teb_tls_slot_offset;
        uintptr_t tsd_base;
        void *raw;
        pthread_setspecific( ios_teb_tls_key, teb );
        __asm__ volatile("mrs %0, TPIDRRO_EL0" : "=r"(tsd_base));
        tsd_base &= ~7ULL;
        raw = ios_teb_tls_slot_offset ? *(void **)(tsd_base + ios_teb_tls_slot_offset) : NULL;
        dprintf(2, "[teb-tsd] thread tid=%04x raw=%p pthread=%p %s\n",
                (unsigned int)(ULONG_PTR)teb->ClientId.UniqueThread, raw, (void *)teb,
                raw == teb ? "MATCH" : "MISMATCH");
    }
    ios_thread_qos_start( (unsigned)(ULONG_PTR)teb->ClientId.UniqueThread );   /* MADEIRA_THREAD_QOS */
    server_init_thread( thread_data->start, &suspend );
    signal_start_thread( thread_data->start, thread_data->param, suspend, teb );
}


/***********************************************************************
 *           get_machine_context_size
 */
static SIZE_T get_machine_context_size( USHORT machine )
{
    switch (machine)
    {
    case IMAGE_FILE_MACHINE_I386:  return sizeof(I386_CONTEXT);
    case IMAGE_FILE_MACHINE_ARMNT: return sizeof(ARM_CONTEXT);
    case IMAGE_FILE_MACHINE_AMD64: return sizeof(AMD64_CONTEXT);
    case IMAGE_FILE_MACHINE_ARM64: return sizeof(ARM64_NT_CONTEXT);
    default: return 0;
    }
}


/***********************************************************************
 *           get_cpu_area
 *
 * cf. RtlWow64GetCurrentCpuArea
 */
void *get_cpu_area( USHORT machine )
{
    WOW64_CPURESERVED *cpu;
    ULONG align;

    if (!is_wow64()) return NULL;
#ifdef _WIN64
    cpu = NtCurrentTeb()->TlsSlots[WOW64_TLS_CPURESERVED];
#else
    cpu = ULongToPtr( NtCurrentTeb64()->TlsSlots[WOW64_TLS_CPURESERVED] );
#endif
    /* iOS-Madeira wow_peb is a SESSION
     * global while pseudo-processes share the address space, so once any
     * 32-bit child exists is_wow64() is true on 64-bit threads too — and those
     * threads have no CPU area.  Upstream can dereference unconditionally
     * because a process is WoW or it is not; here the NULL check is what keeps
     * a 64-bit thread from faulting on cpu->Machine. */
    if (!cpu) return NULL;
    if (cpu->Machine != machine) return NULL;
    switch (cpu->Machine)
    {
    case IMAGE_FILE_MACHINE_I386: align = TYPE_ALIGNMENT(I386_CONTEXT); break;
    case IMAGE_FILE_MACHINE_AMD64: align = TYPE_ALIGNMENT(AMD64_CONTEXT); break;
    case IMAGE_FILE_MACHINE_ARMNT: align = TYPE_ALIGNMENT(ARM_CONTEXT); break;
    case IMAGE_FILE_MACHINE_ARM64: align = TYPE_ALIGNMENT(ARM64_NT_CONTEXT); break;
    default: return NULL;
    }
    return (void *)(((ULONG_PTR)(cpu + 1) + align - 1) & ~((ULONG_PTR)align - 1));
}


/***********************************************************************
 *           set_thread_id
 */
void set_thread_id( TEB *teb, DWORD pid, DWORD tid )
{
    WOW_TEB *wow_teb = get_wow_teb( teb );

    teb->ClientId.UniqueProcess = ULongToHandle( pid );
    teb->ClientId.UniqueThread  = ULongToHandle( tid );
    teb->RealClientId = teb->ClientId;
    if (wow_teb)
    {
        wow_teb->ClientId.UniqueProcess = pid;
        wow_teb->ClientId.UniqueThread  = tid;
        wow_teb->RealClientId = wow_teb->ClientId;
    }
}


/***********************************************************************
 *           init_thread_stack
 */
/* madeira-bcd: which part of a new thread could not be allocated.
 * SocialClubHelper.exe's Chrome_IOThread created a thread and the helper died
 * at once with Chromium's out-of-memory exit and a size of 0 (logs 2026-10-08
 * 13:39:08, build 451, and 16:38:52, build 455; GTA V Enhanced then shows
 * "Failed to initialize. Error code: 17"): Chromium terminates with the stack
 * size it asked for (0 = default) when CreateThread fails with an
 * out-of-memory error. The server had made the thread; what failed after it
 * (the TEB, one of the stacks, pthread_create) was never logged.
 * init_thread_stack records the stack it is allocating; NtCreateThreadEx
 * reports a failure with that step, the status, the pthread error, the sizes
 * asked for and the task's thread count. At most 64 lines. */
static __thread const char *ios_its_step;

static void ios_note_thread_create_failure( const char *step, NTSTATUS status, int err,
                                            SIZE_T reserve, SIZE_T commit )
{
    static LONG lines;
    thread_act_array_t acts = NULL;
    mach_msg_type_number_t n = 0, i;
    int threads = -1;

    if (InterlockedIncrement( &lines ) > 64) return;
    if (task_threads( mach_task_self(), &acts, &n ) == KERN_SUCCESS)
    {
        threads = (int)n;
        for (i = 0; i < n; i++) mach_port_deallocate( mach_task_self(), acts[i] );
        vm_deallocate( mach_task_self(), (vm_address_t)acts, n * sizeof(*acts) );
    }
    dprintf( 2, "[thr-create] FAILED at %s: status=0x%x pthread=%d(%s) reserve=0x%lx commit=0x%lx "
                "creator pid=%04x tid=%04x peb=%p; task threads %d\n",
             step ? step : "?", (unsigned)status, err, err ? strerror( err ) : "-",
             (unsigned long)reserve, (unsigned long)commit,
             (unsigned)HandleToULong( NtCurrentTeb()->ClientId.UniqueProcess ),
             (unsigned)HandleToULong( NtCurrentTeb()->ClientId.UniqueThread ), NtCurrentTeb()->Peb, threads );
}

NTSTATUS init_thread_stack( TEB *teb, ULONG_PTR limit, SIZE_T reserve_size, SIZE_T commit_size )
{
    struct ntdll_thread_data *thread_data = (struct ntdll_thread_data *)&teb->GdiTebBatch;
    WOW_TEB *wow_teb = get_wow_teb( teb );
    INITIAL_TEB stack;
    NTSTATUS status;

    /* kernel stack */
    ios_its_step = "kernel stack";
    if ((status = virtual_alloc_thread_stack( &stack, limit_4g, 0, kernel_stack_size, kernel_stack_size, FALSE )))
        return status;
    thread_data->kernel_stack = stack.DeallocationStack;

    if (wow_teb)
    {
        WOW64_CPURESERVED *cpu;
        /* iOS-Madeira : size and tag the CPU area from the
         * OWNING pseudo-process's main image, not from the session global.
         * main_image_info is restored to the session's exe by
         * wine_ios_child_main (loader_ios.c, "main_image_info =
         * session_image_info") BEFORE init_thread_stack runs for the child, so
         * a 32-bit child used to get an ARM64-sized area tagged ARM64 here and
         * get_cpu_area( IMAGE_FILE_MACHINE_I386 ) then returned NULL — no
         * Eax/Ebx/Esp/Eip were ever written into the initial 32-bit context.
         * The ChpeV2 branch below (":Owner-aware (X3)") already keys off the
         * owning PEB; this is the same rule. */
        extern const SECTION_IMAGE_INFORMATION *ios_image_info_for_peb( void *peb_id );
        USHORT wow_machine = ios_image_info_for_peb( teb->Peb )->Machine;
        SIZE_T cpusize = sizeof(WOW64_CPURESERVED) +
            ((get_machine_context_size( wow_machine ) + 7) & ~7) + sizeof(ULONG64);

        /* 64-bit stack */
        ios_its_step = "WoW64 64-bit stack";
        if ((status = virtual_alloc_thread_stack( &stack, limit_4g, 0, 0x40000, 0x40000, TRUE ))) return status;
        cpu = (WOW64_CPURESERVED *)(((ULONG_PTR)stack.StackBase - cpusize) & ~15);
        cpu->Machine = wow_machine;

#ifdef _WIN64
        teb->Tib.StackBase = teb->TlsSlots[WOW64_TLS_CPURESERVED] = cpu;
        teb->Tib.StackLimit = stack.StackLimit;
        teb->DeallocationStack = stack.DeallocationStack;

        /* 32-bit stack.  `limit` is a GUEST ceiling;
         * virtual_alloc_thread_stack turns it into [B, B+limit] for a
         * windowed process, and the resulting addresses are host, so every
         * 32-bit TEB field below converts back to guest. */
        if (!limit || limit > user_space_wow_limit) limit = user_space_wow_limit;
#ifdef WINE_IOS
        /* user_space_wow_limit is published from the main image's
         * large-address-aware bit (virtual_set_large_address_space, and
         * ios_wow_image_ceiling when the image is mapped before init_peb), so
         * the line above is the normal path.  It can only still be 0 for a
         * thread created before that, and then the conservative 2 GB is the
         * safe answer for both LAA and non-LAA images — 4 GB would put a
         * non-LAA program's own stack above 0x80000000. */
        if (!limit && ios_wow_base()) limit = limit_2g - 1;
#endif
        ios_its_step = "WoW64 32-bit stack";
        if ((status = virtual_alloc_thread_stack( &stack, 0, limit, reserve_size, commit_size, TRUE )))
            return status;
        wow_teb->Tib.StackBase = ios_wow_guest_addr( stack.StackBase );
        wow_teb->Tib.StackLimit = ios_wow_guest_addr( stack.StackLimit );
        wow_teb->DeallocationStack = ios_wow_guest_addr( stack.DeallocationStack );
        return STATUS_SUCCESS;
#else
        wow_teb->Tib.StackBase = wow_teb->TlsSlots[WOW64_TLS_CPURESERVED] = PtrToUlong( cpu );
        wow_teb->Tib.StackLimit = PtrToUlong( stack.StackLimit );
        wow_teb->DeallocationStack = PtrToUlong( stack.DeallocationStack );
#endif
    }

#ifdef __aarch64__
    /* Owner-aware (X3): key the CHPE cpu_area on the process the TEB
     * belongs to, not the session's main exe — x64 children in an aarch64
     * desktop need it, aarch64 threads must not get it. */
    extern const SECTION_IMAGE_INFORMATION *ios_image_info_for_peb( void *peb_id );
    const SECTION_IMAGE_INFORMATION *ios_ii = ios_image_info_for_peb( teb->Peb );
    if (current_machine == IMAGE_FILE_MACHINE_ARM64 &&
        ios_ii->Machine == IMAGE_FILE_MACHINE_AMD64)
    {
        CHPE_V2_CPU_AREA_INFO *cpu_area;
        const SIZE_T chpev2_stack_size = 0x40000;

        /* emulator stack */
        ios_its_step = "emulator stack";
        if ((status = virtual_alloc_thread_stack( &stack, limit_4g, 0, chpev2_stack_size, chpev2_stack_size, FALSE )))
            return status;

        cpu_area = stack.DeallocationStack;
        cpu_area->ContextAmd64 = (ARM64EC_NT_CONTEXT *)&cpu_area->EmulatorDataInline;
        cpu_area->EmulatorStackBase  = (ULONG_PTR)stack.StackBase;
        cpu_area->EmulatorStackLimit = (ULONG_PTR)stack.StackLimit + page_size;
        teb->ChpeV2CpuAreaInfo = cpu_area;
        ERR("iOS arm64ec: TEB %p ChpeV2CpuAreaInfo=%p (stackBase=%p stackLimit=%p ContextAmd64=%p)\n",
            teb, cpu_area, (void*)cpu_area->EmulatorStackBase, (void*)cpu_area->EmulatorStackLimit,
            cpu_area->ContextAmd64);
    }
    else
    {
        ERR("iOS arm64ec: NOT setting cpu_area (owner machine=0x%x session is_arm64ec=%d)\n",
            ios_ii->Machine, is_arm64ec());
    }
#endif

    /* native stack */
    ios_its_step = "stack";
    if ((status = virtual_alloc_thread_stack( &stack, 0, limit, reserve_size, commit_size, TRUE )))
        return status;
    teb->Tib.StackBase = stack.StackBase;
    teb->Tib.StackLimit = stack.StackLimit;
    teb->DeallocationStack = stack.DeallocationStack;
    ERR("iOS native stack: TEB %p StackBase=%p StackLimit=%p DeallocStack=%p (reserve=0x%lx commit=0x%lx)\n",
        teb, stack.StackBase, stack.StackLimit, stack.DeallocationStack,
        (unsigned long)reserve_size, (unsigned long)commit_size);
    return STATUS_SUCCESS;
}


/***********************************************************************
 *           update_attr_list
 *
 * Update the output attributes.
 */
/* ml2210: wow64's PS_ATTRIBUTE_GROUP_AFFINITY thunk widens the pointer but keeps the
 * 32-bit caller's 12-byte GROUP_AFFINITY (a 32-bit mask). Read as the 16-byte native
 * struct, the group and reserved words were the next fields' bytes, NtCreateThreadEx
 * failed with c000000d and a 32-bit Chromium's thread pool threw. Each field is
 * decoded; the usual validation still applies. env.MADEIRA_WOW_AFFINITY32=0: as before. */
static int ios_wow_affinity32( const PS_ATTRIBUTE *attribute, GROUP_AFFINITY *out )
{
    static int on = -1;
    unsigned int mask;
    unsigned short tail[4];
    if (on < 0)
    {
        const char *e = getenv( "MADEIRA_WOW_AFFINITY32" );
        on = !(e && e[0] == '0');
    }
    if (!on || attribute->Size != 12 || !attribute->ValuePtr) return 0;
    memcpy( &mask, attribute->ValuePtr, 4 );
    memcpy( tail, (const char *)attribute->ValuePtr + 4, 8 );
    out->Mask = mask;
    out->Group = tail[0];
    memcpy( out->Reserved, tail + 1, 6 );
    return 1;
}

static NTSTATUS update_attr_list( PS_ATTRIBUTE_LIST *attr, HANDLE thread, const CLIENT_ID *id, TEB *teb )
{
    SIZE_T i, count = (attr->TotalLength - sizeof(attr->TotalLength)) / sizeof(PS_ATTRIBUTE);
    NTSTATUS status = STATUS_SUCCESS;

    for (i = 0; i < count; i++)
    {
        if (attr->Attributes[i].Attribute == PS_ATTRIBUTE_CLIENT_ID)
        {
            SIZE_T size = min( attr->Attributes[i].Size, sizeof(*id) );
            memcpy( attr->Attributes[i].ValuePtr, id, size );
            if (attr->Attributes[i].ReturnLength) *attr->Attributes[i].ReturnLength = size;
        }
        else if (attr->Attributes[i].Attribute == PS_ATTRIBUTE_TEB_ADDRESS)
        {
            SIZE_T size = min( attr->Attributes[i].Size, sizeof(teb) );
            memcpy( attr->Attributes[i].ValuePtr, &teb, size );
            if (attr->Attributes[i].ReturnLength) *attr->Attributes[i].ReturnLength = size;
        }
        else if (attr->Attributes[i].Attribute == PS_ATTRIBUTE_GROUP_AFFINITY)
        {
            GROUP_AFFINITY *aff = attr->Attributes[i].ValuePtr, converted;
            if (get_wow_teb( teb ) && ios_wow_affinity32( &attr->Attributes[i], &converted )) aff = &converted;
            status = NtSetInformationThread( thread, ThreadGroupInformation, aff, sizeof(*aff) );
            if (status) break;
        }
    }

    if (status)
    {
        NtTerminateThread( thread, status );
        NtClose( thread );
    }
    return status;
}

/***********************************************************************
 *              NtCreateThread   (NTDLL.@)
 */
NTSTATUS WINAPI NtCreateThread( HANDLE *handle, ACCESS_MASK access, OBJECT_ATTRIBUTES *attr,
                                HANDLE process, CLIENT_ID *id, CONTEXT *ctx, INITIAL_TEB *teb,
                                BOOLEAN suspended )
{
    FIXME( "%p %d %p %p %p %p %p %d, stub!\n",
           handle, access, attr, process, id, ctx, teb, suspended );
    return STATUS_NOT_IMPLEMENTED;
}

/***********************************************************************
 *              NtCreateThreadEx   (NTDLL.@)
 */
NTSTATUS WINAPI NtCreateThreadEx( HANDLE *handle, ACCESS_MASK access, OBJECT_ATTRIBUTES *attr,
                                  HANDLE process, PRTL_THREAD_START_ROUTINE start, void *param,
                                  ULONG flags, ULONG_PTR zero_bits, SIZE_T stack_commit,
                                  SIZE_T stack_reserve, PS_ATTRIBUTE_LIST *attr_list )
{
    static const ULONG supported_flags = THREAD_CREATE_FLAGS_CREATE_SUSPENDED | THREAD_CREATE_FLAGS_SKIP_THREAD_ATTACH |
                                         THREAD_CREATE_FLAGS_HIDE_FROM_DEBUGGER | THREAD_CREATE_FLAGS_SKIP_LOADER_INIT |
                                         THREAD_CREATE_FLAGS_BYPASS_PROCESS_FREEZE;
    sigset_t sigset;
    pthread_t pthread_id;
    pthread_attr_t pthread_attr;
    data_size_t len;
    struct object_attributes *objattr;
    struct ntdll_thread_data *thread_data;
    DWORD tid = 0;
    int request_pipe[2], pthread_err;
    TEB *teb;
    WOW_TEB *wow_teb;
    unsigned int status;

    if (flags & ~supported_flags)
        FIXME( "Unsupported flags %#x.\n", flags );

    /* [thr-create] pseudo-process forensics: services threadpool workers
     * were born with a SESSION-copy threadpool_worker_proc as their start
     * routine (2026-07-07 [exit-stk]) — log every creation with the start
     * address's copy attribution to catch the creator red-handed. */
    {
        extern void *ios_jit_pool_copy_owner(const void *addr, void **pe_base_out);
        extern void *ios_jit_current_peb(void);
        extern unsigned long long ios_jit_module_base_for_va(unsigned long long va, unsigned long long *size_out);
        void *cp = NULL;
        void *co = ios_jit_pool_copy_owner((void *)start, &cp);
        dprintf(2, "[thr-create] creator_teb=%p creator_peb=%p start=%p (copy pe=%p owner=%p) param=%p\n",
                (void *)NtCurrentTeb(), ios_jit_current_peb(), (void *)start, cp, co, param);
        /* [create-stk]: the creator's PE call chain, with per-frame copy
         * attribution — names the frame where a services thread crossed
         * into session-copy Tp code before spawning the doomed worker. */
        {
            extern uint64_t ios_jit_reverse_translate( uint64_t addr, uint64_t *module_base );
            static volatile int cs_count;
            if (__sync_add_and_fetch(&cs_count, 1) <= 20)
            {
                char *frame = (char *)get_syscall_frame();
                uint64_t pe_sp = frame ? *(uint64_t *)(frame + 0xf8) : 0;
                uint64_t pe_lr = frame ? *(uint64_t *)(frame + 0xf0) : 0;
                uint64_t pe_pc = frame ? *(uint64_t *)(frame + 0x100) : 0;
                int w, hits = 0;
                dprintf(2, "[create-stk] frame pc=%p lr=%p sp=%p\n",
                        (void *)(uintptr_t)pe_pc, (void *)(uintptr_t)pe_lr, (void *)(uintptr_t)pe_sp);
                for (w = 0; w < 384 && hits < 12 && pe_sp; w++)
                {
                    uint64_t val = 0, mod, va;
                    mach_vm_size_t got = 0;
                    if (mach_vm_read_overwrite(mach_task_self(),
                            (mach_vm_address_t)(pe_sp + 8ull * w), 8,
                            (mach_vm_address_t)&val, &got) != KERN_SUCCESS || got != 8)
                        break;
                    if ((va = ios_jit_reverse_translate(val, &mod)) && va != val)
                    {
                        void *fcp = NULL;
                        void *fco = ios_jit_pool_copy_owner((void *)(uintptr_t)val, &fcp);
                        dprintf(2, "[create-stk] sp+0x%x: 0x%llx pe=%p+0x%llx copy_owner=%p\n",
                                w * 8, (unsigned long long)val, (void *)(uintptr_t)mod,
                                (unsigned long long)(va - mod), fco);
                        hits++;
                    }
                }
            }
        }
    }

    if (zero_bits > 21 && zero_bits < 32) return STATUS_INVALID_PARAMETER_3;
#ifndef _WIN64
    if (!is_old_wow64() && zero_bits >= 32) return STATUS_INVALID_PARAMETER_3;
#endif

    if (process != NtCurrentProcess())
    {
        union apc_call call;
        union apc_result result;

        memset( &call, 0, sizeof(call) );

        call.create_thread.type      = APC_CREATE_THREAD;
        call.create_thread.flags     = flags;
        call.create_thread.func      = wine_server_client_ptr( start );
        call.create_thread.arg       = wine_server_client_ptr( param );
        call.create_thread.zero_bits = zero_bits;
        call.create_thread.reserve   = stack_reserve;
        call.create_thread.commit    = stack_commit;
        status = server_queue_process_apc( process, &call, &result );
        if (status != STATUS_SUCCESS) return status;

        if (!(status = result.create_thread.status))
        {
            CLIENT_ID client_id;
            TEB *teb = wine_server_get_ptr( result.create_thread.teb );
            *handle = wine_server_ptr_handle( result.create_thread.handle );
            client_id.UniqueProcess = ULongToHandle( result.create_thread.pid );
            client_id.UniqueThread  = ULongToHandle( result.create_thread.tid );
            if (attr_list) status = update_attr_list( attr_list, *handle, &client_id, teb );
        }
        return status;
    }

    if ((status = alloc_object_attributes( attr, &objattr, &len ))) return status;

    if (server_pipe( request_pipe ) == -1)
    {
        free( objattr );
        return STATUS_TOO_MANY_OPENED_FILES;
    }
    {
        /* ml586 fd-ownership trace (ledger lives in server_ios.c) */
        extern void ios_fdt_reg_request_pipe( int rd, int wr, void *peb );
        extern void *ios_jit_current_peb(void);
        ios_fdt_reg_request_pipe( request_pipe[0], request_pipe[1], ios_jit_current_peb() );
    }
    wine_server_send_fd( request_pipe[0] );

    if (!access) access = THREAD_ALL_ACCESS;

    SERVER_START_REQ( new_thread )
    {
        req->process    = wine_server_obj_handle( process );
        req->access     = access;
        req->flags      = flags;
        req->request_fd = request_pipe[0];
        wine_server_add_data( req, objattr, len );
        if (!(status = wine_server_call( req )))
        {
            *handle = wine_server_ptr_handle( reply->handle );
            tid = reply->tid;
        }
        {
            extern void ios_fdt_mark_closed( int fd );
            ios_fdt_mark_closed( request_pipe[0] );  /* expected handoff close */
        }
        close( request_pipe[0] );
    }
    SERVER_END_REQ;

    free( objattr );
    if (status)
    {
        {
            extern void ios_fdt_mark_closed( int fd );
            ios_fdt_mark_closed( request_pipe[1] );
        }
        close( request_pipe[1] );
        return status;
    }

    pthread_sigmask( SIG_BLOCK, &server_block_set, &sigset );

    if ((status = virtual_alloc_teb( &teb )))
    {
        ios_note_thread_create_failure( "TEB", status, 0, stack_reserve, stack_commit );
        goto done;
    }

    ios_its_step = NULL;
    if ((status = init_thread_stack( teb, get_zero_bits_limit( zero_bits ), stack_reserve, stack_commit )))
    {
        ios_note_thread_create_failure( ios_its_step, status, 0, stack_reserve, stack_commit );
        virtual_free_teb( teb );
        goto done;
    }

    set_thread_id( teb, GetCurrentProcessId(), tid );

    teb->SkipThreadAttach = !!(flags & THREAD_CREATE_FLAGS_SKIP_THREAD_ATTACH);
    teb->SkipLoaderInit = !!(flags & THREAD_CREATE_FLAGS_SKIP_LOADER_INIT);
    wow_teb = get_wow_teb( teb );
    if (wow_teb)
    {
        wow_teb->SkipThreadAttach = teb->SkipThreadAttach;
        wow_teb->SkipLoaderInit = teb->SkipLoaderInit;
    }

    thread_data = (struct ntdll_thread_data *)&teb->GdiTebBatch;
    thread_data->request_fd  = request_pipe[1];
    thread_data->start = start;
    thread_data->param = param;

    pthread_attr_init( &pthread_attr );
    pthread_attr_setstack( &pthread_attr, thread_data->kernel_stack, kernel_stack_size );
    pthread_attr_setguardsize( &pthread_attr, 0 );
    pthread_attr_setscope( &pthread_attr, PTHREAD_SCOPE_SYSTEM ); /* force creating a kernel thread */
    InterlockedIncrement( &nb_threads );
    if ((pthread_err = pthread_create( &pthread_id, &pthread_attr, (void * (*)(void *))start_thread, teb )))
    {
        InterlockedDecrement( &nb_threads );
        virtual_free_teb( teb );
        status = STATUS_NO_MEMORY;
        ios_note_thread_create_failure( "pthread_create", status, pthread_err, stack_reserve, stack_commit );
    }
    pthread_attr_destroy( &pthread_attr );

done:
    pthread_sigmask( SIG_SETMASK, &sigset, NULL );
    if (status)
    {
        NtClose( *handle );
        {
            extern void ios_fdt_mark_closed( int fd );
            ios_fdt_mark_closed( request_pipe[1] );
        }
        close( request_pipe[1] );
        return status;
    }
    if (attr_list) status = update_attr_list( attr_list, *handle, &teb->ClientId, teb );
    return status;
}


/***********************************************************************
 *           abort_thread
 */
void abort_thread( int status )
{
    pthread_sigmask( SIG_BLOCK, &server_block_set, NULL );
    if (InterlockedDecrement( &nb_threads ) <= 0) abort_process( status );
    pthread_exit_wrapper( status );
}


/***********************************************************************
 *           abort_process
 */
void abort_process( int status )
{
#ifdef WINE_IOS
    /* ml937: _exit() HERE KILLED THE WHOLE APP.
     *
     * On a normal Wine host one Windows process is one Unix process, so
     * `_exit()` is the correct immediate kill for TerminateProcess(). On iOS
     * every Windows process is a PSEUDO-process inside the single Mach task,
     * and `_exit()` is not shimmed the way exit() is (shims/wine_ios_exit.h) —
     * so any guest calling TerminateProcess(GetCurrentProcess(), code) took the
     * app, wineserver, and every other pseudo-process down with it, with no
     * crash report and no further log output because the exit is clean.
     *
     * Found by a game whose exe spawns its own bundled launcher and then
     * terminates itself with code 0: the child had a full PEB, private
     * ARM64EC ntdll, TEB and Mach handler and was one instruction from its PE
     * entry point when the parent's self-terminate erased the task. That is
     * ordinary Windows behaviour for a bootstrapper exe, and there were ZERO
     * exceptions in the run — nothing said "the app should have died here".
     *
     * Correct mapping: tear down THIS pseudo-process only, exactly as
     * exit_process() does. The two paths differ on Windows in that abort skips
     * LdrShutdownProcess (no DLL_PROCESS_DETACH, no atexit), which has already
     * happened by the time we get here — the unix-side teardown is the same
     * work either way: close this process's wineserver master socket (the EOF
     * is how the server learns the process died and wakes its waiters), drop
     * its fd cache and reclaim its JIT-pool allocations.
     *
     * Still owed: process_exit_wrapper's exit() only longjmps on a
     * pseudo-process's MAIN thread; a non-main thread calling it falls back to
     * pthread_exit and leaves that process's other threads running on a
     * reclaimed pool. That hole predates this change and is shared with
     * exit_process. */
    pthread_sigmask( SIG_BLOCK, &server_block_set, NULL );
    ERR( "abort_process: status=0x%x — tearing down this pseudo-process only (ml937; was _exit, which killed the app)\n",
         (unsigned int)status );
    process_exit_wrapper( get_unix_exit_code( status ));
    /* noreturn */
#endif
    _exit( get_unix_exit_code( status ));
}


/***********************************************************************
 *           exit_thread
 */
static DECLSPEC_NORETURN void exit_thread( int status )
{
    static void *prev_teb;
    TEB *teb;

    pthread_sigmask( SIG_BLOCK, &server_block_set, NULL );

    if (InterlockedDecrement( &nb_threads ) <= 0) exit_process( status );

    /* Opt-in, env.MADEIRA_EA_CEF = 1: 32-bit helper processes started one after
     * another can be given the same WoW window again, TEB addresses included.
     * prev_teb is a raw pointer, so it can then name the thread that is exiting
     * right now: joining itself fails and the old path frees the caller's own
     * stack. With the switch the hand-off goes through
     * ios_ea_reap_exited_thread (virtual_ios.c), which checks the identity of
     * the previous thread first. Unset: the upstream prev_teb hand-off.
     *
     * ml2290 (testers' log, 2026-10-31): the checked hand-off is the default.
     * A launcher installer ran its 32-bit VC++ redistributables one after the
     * other; the second got the first's window and TEB, its worker thread freed
     * its own kernel stack at exit (unregister_view+4, the fault waiting for the
     * virtual_mutex it held) and the installer waited on that thread forever.
     * env.MADEIRA_THREAD_REAP_CHECKED = 0 restores the upstream hand-off
     * (MADEIRA_EA_CEF = 1 still selects the checked one). */
    const char *ea_cef = getenv( "MADEIRA_EA_CEF" );
    const char *checked = getenv( "MADEIRA_THREAD_REAP_CHECKED" );
    if (!(checked && checked[0] == '0') || (ea_cef && !strcmp( ea_cef, "1" )))
    {
        extern void ios_ea_reap_exited_thread( TEB *current );
        ios_ea_reap_exited_thread( NtCurrentTeb() );
    }
    else if ((teb = InterlockedExchangePointer( &prev_teb, NtCurrentTeb() )))
    {
        struct ntdll_thread_data *thread_data = (struct ntdll_thread_data *)&teb->GdiTebBatch;

        if (thread_data->pthread_id)
        {
            pthread_join( thread_data->pthread_id, NULL );
            virtual_free_teb( teb );
        }
    }
    pthread_exit_wrapper( status );
}


/***********************************************************************
 *           exit_process
 */
void exit_process( int status )
{
#ifdef WINE_IOS
    ERR("exit_process: raw_status=0x%x unix_code=%d\n", (unsigned)status, get_unix_exit_code(status));
#endif
    pthread_sigmask( SIG_BLOCK, &server_block_set, NULL );
    process_exit_wrapper( get_unix_exit_code( status ));
}


/**********************************************************************
 *           wait_suspend
 *
 * Wait until the thread is no longer suspended.
 */
void wait_suspend( CONTEXT *context )
{
    int saved_errno = errno;
    struct context_data server_contexts[2];

    contexts_to_server( server_contexts, context );
    /* wait with 0 timeout, will only return once the thread is no longer suspended */
    server_select( NULL, 0, SELECT_INTERRUPTIBLE, 0, server_contexts, NULL );
    contexts_from_server( context, server_contexts );
    errno = saved_errno;
}


/**********************************************************************
 *           send_debug_event
 *
 * Send an EXCEPTION_DEBUG_EVENT event to the debugger.
 */
NTSTATUS send_debug_event( EXCEPTION_RECORD *rec, CONTEXT *context, BOOL first_chance, BOOL exception )
{
    unsigned int ret;
    DWORD i;
    obj_handle_t handle = 0;
    client_ptr_t params[EXCEPTION_MAXIMUM_PARAMETERS];
    union select_op select_op;
    sigset_t old_set;

    if (!peb->BeingDebugged) return 0;  /* no debugger present */

    pthread_sigmask( SIG_BLOCK, &server_block_set, &old_set );

    for (i = 0; i < min( rec->NumberParameters, EXCEPTION_MAXIMUM_PARAMETERS ); i++)
        params[i] = rec->ExceptionInformation[i];

    SERVER_START_REQ( queue_exception_event )
    {
        req->first   = first_chance;
        req->code    = rec->ExceptionCode;
        req->flags   = rec->ExceptionFlags;
        req->record  = wine_server_client_ptr( rec->ExceptionRecord );
        req->address = wine_server_client_ptr( rec->ExceptionAddress );
        req->len     = i * sizeof(params[0]);
        wine_server_add_data( req, params, req->len );
        if (!(ret = wine_server_call( req ))) handle = reply->handle;
    }
    SERVER_END_REQ;

    if (handle)
    {
        struct context_data server_contexts[2];

        select_op.wait.op = SELECT_WAIT;
        select_op.wait.handles[0] = handle;

        contexts_to_server( server_contexts, context );
        server_contexts[0].flags |= SERVER_CTX_EXEC_SPACE;
        server_contexts[0].exec_space.space.space = exception ? EXEC_SPACE_EXCEPTION : EXEC_SPACE_SYSCALL;
        server_select( &select_op, offsetof( union select_op, wait.handles[1] ), SELECT_INTERRUPTIBLE,
                       TIMEOUT_INFINITE, server_contexts, NULL );

        SERVER_START_REQ( get_exception_status )
        {
            req->handle = handle;
            ret = wine_server_call( req );
        }
        SERVER_END_REQ;
        if (NT_SUCCESS(ret)) contexts_from_server( context, server_contexts );
    }

    pthread_sigmask( SIG_SETMASK, &old_set, NULL );
    return ret;
}


#ifdef WINE_IOS
/* [steam-api], log only: what a process can see of the Steam client at the moment steam_api says none is running.
 *
 * A launcher or game that loads steam_api(64).dll and is told "SteamAPI_IsSteamRunning() did not locate a running
 * instance of Steam" stops, although the Dock host has published the client and started the program; in other sessions
 * the same call loads steamclient64.dll. A log cannot tell which of the values steam_api reads is missing, so the failing
 * process reports them itself, from NtRaiseException, when the text arrives as an OutputDebugString exception (the path
 * a 32-bit process takes; a 64-bit process handles OutputDebugString inside the PE ntdll and is not seen here). Reads only:
 *   HKCU\Software\Valve\Steam\ActiveProcess  pid, ActiveUser (only zero / not zero), SteamClientDll64
 *   HKCU\Software\Valve\Steam                SteamPath
 *   HKLM\Software\Valve\Steam (32- and 64-bit view)  SteamPID, InstallPath
 *   OpenProcess(pid) and its exit status (259 = still running); the named objects STEAM_DIPC_CONSUME / _PRODUCE.
 * At most twice per process; one checked read of the debug string, and only for strings of 80-200 bytes. Nothing is
 * written and nothing changes for any other debug string. */
#define SD_ERR( ... ) ERR_(seh)( __VA_ARGS__ )
static NTSTATUS ios_sd_key( const char *path, ACCESS_MASK wow, HANDLE *key )
{
    WCHAR wide[128];
    UNICODE_STRING name;
    OBJECT_ATTRIBUTES attr;
    size_t i;

    for (i = 0; path[i] && i < 127; i++) wide[i] = (unsigned char)path[i];
    wide[i] = 0;
    name.Buffer = wide;
    name.Length = name.MaximumLength = (USHORT)(i * sizeof(WCHAR));
    InitializeObjectAttributes( &attr, &name, OBJ_CASE_INSENSITIVE, NULL, NULL );
    return NtOpenKey( key, KEY_QUERY_VALUE | wow, &attr );
}

/* One value of an open key. dword: the value when it is a DWORD (else untouched); hide: report a DWORD only as zero or
 * not zero (the account id). */
static NTSTATUS ios_sd_value( const char *path, ACCESS_MASK wow, const char *vname, const char *label, int hide,
                              ULONG *dword )
{
    union { KEY_VALUE_PARTIAL_INFORMATION info; char raw[sizeof(KEY_VALUE_PARTIAL_INFORMATION) + 520]; } buf;
    WCHAR wide[64];
    UNICODE_STRING name;
    HANDLE key = 0;
    ULONG len = 0, i, n;
    NTSTATUS status = ios_sd_key( path, wow, &key );

    if (status)
    {
        SD_ERR( "[steam-api]   %s: key not opened, status %#x\n", label, (unsigned int)status );
        return status;
    }
    for (i = 0; vname[i] && i < 63; i++) wide[i] = (unsigned char)vname[i];
    wide[i] = 0;
    name.Buffer = wide;
    name.Length = name.MaximumLength = (USHORT)(i * sizeof(WCHAR));
    memset( &buf, 0, sizeof(buf) );
    status = NtQueryValueKey( key, &name, KeyValuePartialInformation, &buf, sizeof(buf), &len );
    NtClose( key );
    if (status)
        SD_ERR( "[steam-api]   %s: no value, status %#x\n", label, (unsigned int)status );
    else if (buf.info.Type == REG_DWORD && buf.info.DataLength == sizeof(ULONG))
    {
        ULONG v;
        memcpy( &v, buf.info.Data, sizeof(v) );
        if (dword) *dword = v;
        if (hide) SD_ERR( "[steam-api]   %s: DWORD, %s\n", label, v ? "not zero" : "zero" );
        else SD_ERR( "[steam-api]   %s: DWORD %u\n", label, (unsigned int)v );
    }
    else if (buf.info.Type == REG_SZ || buf.info.Type == REG_EXPAND_SZ)
    {
        char text[96];
        const WCHAR *w = (const WCHAR *)buf.info.Data;

        n = min( buf.info.DataLength / sizeof(WCHAR), (ULONG)(sizeof(text) - 1) );
        for (i = 0; i < n && w[i]; i++) text[i] = (w[i] >= 32 && w[i] < 127) ? (char)w[i] : '?';
        text[i] = 0;
        SD_ERR( "[steam-api]   %s: %s \"%s\"\n", label, buf.info.Type == REG_SZ ? "SZ" : "EXPAND_SZ", text );
    }
    else
        SD_ERR( "[steam-api]   %s: type %u, %u bytes\n", label, (unsigned int)buf.info.Type,
                   (unsigned int)buf.info.DataLength );
    return status;
}

static void ios_sd_object( const char *name )
{
    WCHAR wide[96];
    UNICODE_STRING us;
    OBJECT_ATTRIBUTES attr;
    HANDLE h = 0;
    NTSTATUS status;
    size_t i;

    for (i = 0; name[i] && i < 95; i++) wide[i] = (unsigned char)name[i];
    wide[i] = 0;
    us.Buffer = wide;
    us.Length = us.MaximumLength = (USHORT)(i * sizeof(WCHAR));
    InitializeObjectAttributes( &attr, &us, OBJ_CASE_INSENSITIVE, NULL, NULL );
    status = NtOpenSemaphore( &h, SYNCHRONIZE, &attr );
    if (status) status = NtOpenEvent( &h, SYNCHRONIZE, &attr );
    if (!status)
    {
        SD_ERR( "[steam-api]   %s: opens\n", name );
        NtClose( h );
    }
    else SD_ERR( "[steam-api]   %s: not opened, status %#x\n", name, (unsigned int)status );
}

static void ios_steam_api_diag( void )
{
    static LONG told;
    static const char active[] = "\\Registry\\User\\S-1-5-21-0-0-0-1000\\Software\\Valve\\Steam\\ActiveProcess";
    static const char user_steam[] = "\\Registry\\User\\S-1-5-21-0-0-0-1000\\Software\\Valve\\Steam";
    static const char machine_steam[] = "\\Registry\\Machine\\Software\\Valve\\Steam";
    ULONG pid = 0;

    if (InterlockedIncrement( &told ) > 2) return;
    SD_ERR( "[steam-api] steam_api found no running Steam; process %04x sees:\n",
               (unsigned int)HandleToULong( NtCurrentTeb()->ClientId.UniqueProcess ) );
    ios_sd_value( active, 0, "pid", "HKCU ActiveProcess pid", 0, &pid );
    ios_sd_value( active, 0, "ActiveUser", "HKCU ActiveProcess ActiveUser", 1, NULL );
    ios_sd_value( active, 0, "SteamClientDll64", "HKCU ActiveProcess SteamClientDll64", 0, NULL );
    ios_sd_value( user_steam, 0, "SteamPath", "HKCU Steam SteamPath", 0, NULL );
    ios_sd_value( machine_steam, KEY_WOW64_32KEY, "SteamPID", "HKLM(32) Steam SteamPID", 0, NULL );
    ios_sd_value( machine_steam, KEY_WOW64_32KEY, "InstallPath", "HKLM(32) Steam InstallPath", 0, NULL );
    ios_sd_value( machine_steam, KEY_WOW64_64KEY, "InstallPath", "HKLM(64) Steam InstallPath", 0, NULL );
    if (pid)
    {
        OBJECT_ATTRIBUTES attr;
        CLIENT_ID id;
        HANDLE process = 0;
        NTSTATUS status;

        InitializeObjectAttributes( &attr, NULL, 0, NULL, NULL );
        id.UniqueProcess = ULongToHandle( pid );
        id.UniqueThread = 0;
        status = NtOpenProcess( &process, PROCESS_QUERY_LIMITED_INFORMATION, &attr, &id );
        if (status)
            SD_ERR( "[steam-api]   OpenProcess(%u): status %#x\n", (unsigned int)pid, (unsigned int)status );
        else
        {
            PROCESS_BASIC_INFORMATION pbi;

            memset( &pbi, 0, sizeof(pbi) );
            status = NtQueryInformationProcess( process, ProcessBasicInformation, &pbi, sizeof(pbi), NULL );
            if (status)
                SD_ERR( "[steam-api]   OpenProcess(%u): opens, query status %#x\n", (unsigned int)pid,
                           (unsigned int)status );
            else
                SD_ERR( "[steam-api]   OpenProcess(%u): opens, exit status %u (259 = still running)\n",
                           (unsigned int)pid, (unsigned int)pbi.ExitStatus );
            NtClose( process );
        }
    }
    ios_sd_object( "\\BaseNamedObjects\\STEAM_DIPC_CONSUME" );
    ios_sd_object( "\\BaseNamedObjects\\STEAM_DIPC_PRODUCE" );
}

/* Whether this OutputDebugString exception carries steam_api's "no Steam running" text. */
static int ios_steam_api_message( const EXCEPTION_RECORD *rec )
{
    char text[208];
    SIZE_T got = 0, len;

    if (rec->ExceptionCode != DBG_PRINTEXCEPTION_C || rec->NumberParameters < 2 || !rec->ExceptionInformation[1])
        return 0;
    len = rec->ExceptionInformation[0];
    if (len < 80 || len > 200) return 0;
    if (NtReadVirtualMemory( NtCurrentProcess(), (const void *)rec->ExceptionInformation[1], text, len, &got ) || got != len)
        return 0;
    text[len - 1] = 0;
    if (text[0] != '[' || text[1] != 'S' || text[2] != '_') return 0;
    if (strstr( text, "SteamAPI_IsSteamRunning() did not locate a running instance" )) return 1;
    /* the older steam_api wording ("[S_API FAIL] SteamAPI_Init() failed; unable to locate a running instance of Steam, or a
     * local steamclient.dll."), still printed by older SteamStub-wrapped programs */
    return !strncmp( text, "[S_API FAIL]", 12 ) && strstr( text, "unable to locate a running instance of Steam" ) != NULL;
}

/* [cxx-type], log only: the type name of a C++ exception (code 0xE06D7363) as it is thrown.
 *
 * A program that ends in __fastfail after a C++ throw no handler frame accepts leaves a PE-side line with the code and the
 * parameters, but not WHAT was thrown, so nobody can say which catch should have taken it. The record's third parameter
 * is the _ThrowInfo; its CatchableTypeArray lists the thrown type first, then the types it converts to (base classes), each with a
 * type_info whose name is the decorated type (".?AVruntime_error@std@@"). Layouts:
 *   64-bit (4 parameters: magic, object, ThrowInfo, image base): ThrowInfo { attributes, pmfnUnwind, pForwardCompat, pCatchableTypeArray }
 *     as 32-bit RVAs from the image base; CatchableTypeArray { nCatchableTypes, RVA[] }; CatchableType { properties, pType RVA, ... };
 *     type_info { vtable (8), runtime data (8), name[] } = name at +16.
 *   32-bit (3 parameters: magic, object, ThrowInfo): the same with 32-bit pointers; name at +8. A WoW process's pointers are guest addresses.
 * Every read is NtReadVirtualMemory on this process, which reports an unreadable address instead of faulting. It reports at most 12 throws
 * (two lines each), each ThrowInfo once; nothing is written and the record is left as the fix-up above made it. */
static int ios_cxx_read( ULONG_PTR addr, void *buf, SIZE_T len, int guest32 )
{
    SIZE_T got = 0;

    if (guest32) addr = (ULONG_PTR)ios_wow_host_ptr( (ULONG)addr );
    if (addr < 0x10000) return 0;
    return !NtReadVirtualMemory( NtCurrentProcess(), (const void *)addr, buf, len, &got ) && got == len;
}

static void ios_cxx_type_name( ULONG_PTR type_info, int is64, int guest32, char *out, size_t outsz )
{
    char raw[72];
    size_t i;

    out[0] = '?'; out[1] = 0;
    memset( raw, 0, sizeof(raw) );
    if (!ios_cxx_read( type_info + (is64 ? 16 : 8), raw, sizeof(raw) - 1, guest32 )) return;
    for (i = 0; i < sizeof(raw) - 1 && raw[i] && i < outsz - 1; i++)
        out[i] = (raw[i] >= 0x20 && raw[i] < 0x7f) ? raw[i] : '?';
    out[i] = 0;
    if (!i) { out[0] = '?'; out[1] = 0; }
}

static void ios_cxx_throw_diag( const EXCEPTION_RECORD *rec )
{
    static LONG lines;
    static ULONG_PTR seen[12];
    static int nseen;
    int is64 = rec->NumberParameters >= 4, guest32 = !is64 && ios_wow_base() != 0, i;
    ULONG_PTR throw_info = rec->ExceptionInformation[2], base = is64 ? rec->ExceptionInformation[3] : 0;
    ULONG attrs = 0, count = 0, ti[4], refs[8], ct[7];
    char first[72] = "? (ThrowInfo or its type list not readable)", list[240];
    size_t len = 0;

    if (!throw_info) return;
    for (i = 0; i < nseen; i++) if (seen[i] == throw_info) return;
    if (nseen >= 12 || InterlockedIncrement( &lines ) > 12) return;
    seen[nseen++] = throw_info;

    list[0] = 0;
    if (ios_cxx_read( throw_info, ti, sizeof(ti), guest32 ))   /* { attributes, pmfnUnwind, pForwardCompat, pCatchableTypeArray } */
    {
        ULONG_PTR cta = is64 ? base + ti[3] : (ULONG_PTR)ti[3];

        attrs = ti[0];
        if (ti[3] && ios_cxx_read( cta, &count, 4, guest32 ))
        {
            ULONG k, want = count > 8 ? 8 : count;

            if (want && ios_cxx_read( cta + 4, refs, want * 4, guest32 ))
                for (k = 0; k < want; k++)
                {
                    ULONG_PTR ctp = is64 ? base + refs[k] : (ULONG_PTR)refs[k], type;
                    char name[72];

                    if (!refs[k] || !ios_cxx_read( ctp, ct, sizeof(ct), guest32 )) continue;   /* { properties, pType, PMD x3, size, copy } */
                    type = is64 ? base + ct[1] : (ULONG_PTR)ct[1];
                    ios_cxx_type_name( type, is64, guest32, name, sizeof(name) );
                    if (!k) strcpy( first, name );
                    else if (len < sizeof(list) - 80) len += snprintf( list + len, sizeof(list) - len, " %s", name );
                }
        }
    }
    ERR_(seh)( "[cxx-type] %d-bit throw at %p: thrown %s; also catchable as:%s (%u catchable type(s), ThrowInfo %p attributes %#x, "
               "object %p, magic %#lx)\n",
               is64 ? 64 : 32, rec->ExceptionAddress, first, list[0] ? list : " nothing", (unsigned)count, (void *)throw_info,
               (unsigned)attrs, (void *)rec->ExceptionInformation[1], (unsigned long)rec->ExceptionInformation[0] );
    ERR_(seh)( "[cxx-type]   exception parameters (%u): p0=%#lx p1=%#lx p2=%#lx p3=%#lx\n", (unsigned)rec->NumberParameters,
               (unsigned long)rec->ExceptionInformation[0], (unsigned long)rec->ExceptionInformation[1],
               (unsigned long)rec->ExceptionInformation[2], (unsigned long)(rec->NumberParameters > 3 ? rec->ExceptionInformation[3] : 0) );
    /* The HRESULT an ATL or COM exception carries, read from the thrown object: an installer that dies on an uncaught
     * ATL::CAtlException otherwise leaves no trace of which call failed. CAtlException is { HRESULT m_hr; }; _com_error is
     * { vtable; HRESULT m_hresult; ... }. Log only. */
    {
        ULONG hr = 0;
        ULONG_PTR obj = rec->ExceptionInformation[1];
        int ptr = is64 ? 8 : 4;

        if (strstr( first, "CAtlException@ATL" ) && ios_cxx_read( obj, &hr, 4, guest32 ))
            ERR_(seh)( "[cxx-type]   ATL::CAtlException hr=%#lx\n", (unsigned long)hr );
        else if (strstr( first, "_com_error@@" ) && ios_cxx_read( obj + ptr, &hr, 4, guest32 ))
            ERR_(seh)( "[cxx-type]   _com_error hr=%#lx\n", (unsigned long)hr );
    }
}

#endif

/*******************************************************************
 *		NtRaiseException (NTDLL.@)
 */
NTSTATUS WINAPI NtRaiseException( EXCEPTION_RECORD *rec, CONTEXT *context, BOOL first_chance )
{
    NTSTATUS status;
#ifdef WINE_IOS
    /* ml845: the engine's thread-naming exception is where a bogus "stack base"
     * reaches its per-thread state. Watch the slot across this dispatch. */
    if (rec && rec->ExceptionCode == 0x406D1388)
    {
        extern void ios_tlswatch_arm( const char * );
        ios_tlswatch_arm( "raise 0x406D1388" );
    }
    /* madeira-bcd: a 64-bit C++ throw carries the image base its ThrowInfo
     * RVAs are relative to (parameter 3, from RtlPcToFileHeader(ThrowInfo)).
     * When the ThrowInfo pointer is a JIT-pool alias of the image (native code
     * computing its own data address runs from the pool copy) no module owns
     * it, the base comes out 0 and __CxxFrameHandler4 faults reading 0+RVA
     * (Ghost of Tsushima: AV READ of 0x16694 in VCRUNTIME140_1 after a save).
     * Map the pointer back to the PE image and fill in the base. Upstream's
     * RtlPcToFileHeader patch (ios_patch_rtl_pc_to_file_header) fixes the base
     * where it is computed; this second layer catches a throw that still
     * arrives with base 0 or a pool-alias ThrowInfo. */
    if (rec && rec->ExceptionCode == 0xE06D7363 && rec->NumberParameters == 4 && rec->ExceptionInformation[2])
    {
        extern uint64_t ios_jit_reverse_translate( uint64_t addr, uint64_t *module_base );
        static LONG fixes, seen;
        ULONG_PTR info = rec->ExceptionInformation[2], base = rec->ExceptionInformation[3];
        uint64_t mod = 0, pe = ios_jit_reverse_translate( info, &mod );
        const char *how = NULL;

        if (pe && mod)
        {
            rec->ExceptionInformation[2] = pe;
            rec->ExceptionInformation[3] = mod;
            how = "pool alias -> PE image";
        }
        else if (!base)
        {
            MEMORY_BASIC_INFORMATION mbi;
            if (!NtQueryVirtualMemory( NtCurrentProcess(), (void *)info, MemoryBasicInformation,
                                       &mbi, sizeof(mbi), NULL ) && mbi.Type == MEM_IMAGE)
            {
                rec->ExceptionInformation[3] = (ULONG_PTR)mbi.AllocationBase;
                how = "base 0 -> owning image";
            }
            else how = "base 0, NO owning image (left as is)";
        }
        if (how && InterlockedIncrement( &fixes ) <= 32)
            ERR_(seh)( "[cxx-throw] #%d ThrowInfo %p base %p -> %p base %p: %s (addr %p)\n", (int)fixes,
                       (void *)info, (void *)base, (void *)rec->ExceptionInformation[2],
                       (void *)rec->ExceptionInformation[3], how, rec->ExceptionAddress );
        else if (!how && InterlockedIncrement( &seen ) <= 4)
            ERR_(seh)( "[cxx-throw] ok ThrowInfo %p base %p (addr %p)\n",
                       (void *)info, (void *)base, rec->ExceptionAddress );
    }
    /* [cxx-type], after the ThrowInfo above has been put right (log only) */
    if (rec && rec->ExceptionCode == 0xE06D7363 && (rec->NumberParameters == 4 || rec->NumberParameters == 3))
        ios_cxx_throw_diag( rec );
    /* madeira-bcd: Chromium's out-of-memory exit (SocialClubHelper.exe died of
     * it on the first launch of build 442, on four threads at once). The PE
     * [exc] line names the code only; PartitionAlloc passes { size of the
     * failed request, total page file, available page file } and base's own
     * OOM path passes the size alone, and the size is what tells a failed
     * reservation from a failed commit. */
    if (rec && rec->ExceptionCode == 0xE0000008 && rec->NumberParameters >= 1)
    {
        static LONG oom_lines;
        unsigned int tid = HandleToULong( NtCurrentTeb()->ClientId.UniqueThread );

        if (InterlockedIncrement( &oom_lines ) <= 16)
        {
            if (rec->NumberParameters >= 3)
                ERR_(seh)( "[chromium-oom] tid %04x: request %#lx bytes (%lu MB), page file total %lu MB, "
                           "available %lu MB, at %p\n", tid,
                           (unsigned long)rec->ExceptionInformation[0],
                           (unsigned long)(rec->ExceptionInformation[0] >> 20),
                           (unsigned long)(rec->ExceptionInformation[1] >> 20),
                           (unsigned long)(rec->ExceptionInformation[2] >> 20), rec->ExceptionAddress );
            else
                ERR_(seh)( "[chromium-oom] tid %04x: request %#lx bytes (%lu MB), at %p\n", tid,
                           (unsigned long)rec->ExceptionInformation[0],
                           (unsigned long)(rec->ExceptionInformation[0] >> 20), rec->ExceptionAddress );
        }
    }
#endif
#ifdef WINE_IOS
    /* [steam-api] (see ios_steam_api_diag): reads only, logs at most twice per process. */
    if (rec && first_chance && ios_steam_api_message( rec )) ios_steam_api_diag();
#endif
    status = send_debug_event( rec, context, first_chance, !(is_win64 || is_wow64() || is_old_wow64()) );

    if (status == DBG_CONTINUE || status == DBG_EXCEPTION_HANDLED)
        return NtContinue( context, FALSE );

    if (first_chance) return call_user_exception_dispatcher( rec, context );

    /* ml257: A DEBUG PRINT MUST NEVER KILL THE PROCESS.
     *
     * Steam called OutputDebugString; that raises DBG_PRINTEXCEPTION_C, which is
     * meant to be swallowed -- see rtl.c, where RtlRaiseException's own filter
     * returns EXCEPTION_EXECUTE_HANDLER for exactly this code. Here the dispatcher
     * could not reach that filter ("unwind stuck: steps=2 -- abandoning walk"), so
     * the raise fell through to second chance and we terminated the process with
     * exit_code=0x40010006 at unix_calls=13251 -- killing a Steam that was otherwise
     * healthy, over a printf. On Windows with no debugger attached this is a no-op.
     *
     * So swallow it and continue, exactly as the DBG_CONTINUE path above does. This
     * does not paper over the stuck unwind (task #38) -- it stops a benign event from
     * being fatal while that is fixed. Real faults still terminate.
     *
     * The thread-naming exception (MS_VC_EXCEPTION, 0x406D1388) is the same kind
     * of event: a hint for a debugger that a program raises inside its own
     * __try. When it reaches second chance anyway, a continuable one is
     * swallowed too. env.MADEIRA_THREADNAME_SWALLOW = 0 lets it end the process
     * as before. */
    static int threadname_swallow = -1;
    if (threadname_swallow < 0)
    {
        const char *e = getenv( "MADEIRA_THREADNAME_SWALLOW" );
        threadname_swallow = !(e && e[0] == '0');
    }
    if (rec->ExceptionCode == DBG_PRINTEXCEPTION_C ||
        rec->ExceptionCode == DBG_PRINTEXCEPTION_WIDE_C ||
        (threadname_swallow && rec->ExceptionCode == 0x406D1388 && !(rec->ExceptionFlags & EXCEPTION_NONCONTINUABLE)))
    {
        static int swallowed;
        if (swallowed++ < 8)
            ERR_(seh)("[dbgprint] swallowing %s that reached second chance "
                      "(flags=%x addr=%p) -- continuing instead of dying\n",
                      rec->ExceptionCode == 0x406D1388 ? "MS_VC_EXCEPTION (0x406D1388)"
                      : (rec->ExceptionCode == DBG_PRINTEXCEPTION_C ? "DBG_PRINTEXCEPTION_C"
                                                                    : "DBG_PRINTEXCEPTION_WIDE_C"),
                      rec->ExceptionFlags, rec->ExceptionAddress );
        return NtContinue( context, FALSE );
    }

    if (rec->ExceptionFlags & EXCEPTION_STACK_INVALID)
        ERR_(seh)("Exception frame is not in stack limits => unable to dispatch exception.\n");
    else if (rec->ExceptionCode == STATUS_NONCONTINUABLE_EXCEPTION)
        ERR_(seh)("Process attempted to continue execution after noncontinuable exception.\n");
    else
        ERR_(seh)("Unhandled exception code %x flags %x addr %p\n",
                  rec->ExceptionCode, rec->ExceptionFlags, rec->ExceptionAddress );

    NtTerminateProcess( NtCurrentProcess(), rec->ExceptionCode );
    return STATUS_SUCCESS;
}


/**********************************************************************
 *           NtCurrentTeb   (NTDLL.@)
 */
TEB * WINAPI NtCurrentTeb(void)
{
    return pthread_getspecific( teb_key );
}


/***********************************************************************
 *              NtOpenThread   (NTDLL.@)
 */
NTSTATUS WINAPI NtOpenThread( HANDLE *handle, ACCESS_MASK access,
                              const OBJECT_ATTRIBUTES *attr, const CLIENT_ID *id )
{
    unsigned int ret;

    *handle = 0;

    SERVER_START_REQ( open_thread )
    {
        req->tid        = HandleToULong(id->UniqueThread);
        req->access     = access;
        req->attributes = attr ? attr->Attributes : 0;
        ret = wine_server_call( req );
        *handle = wine_server_ptr_handle( reply->handle );
    }
    SERVER_END_REQ;
    return ret;
}


/******************************************************************************
 *              NtSuspendThread   (NTDLL.@)
 */
NTSTATUS WINAPI NtSuspendThread( HANDLE handle, ULONG *count )
{
    unsigned int ret;

    SERVER_START_REQ( suspend_thread )
    {
        req->handle = wine_server_obj_handle( handle );
        if (!(ret = wine_server_call( req )))
        {
            if (count) *count = reply->count;
        }
    }
    SERVER_END_REQ;
#ifdef WINE_IOS
    /* madeira-bcd: a thread that suspends itself must stop until it is resumed.
     * Elsewhere the server's SIGUSR1 makes usr1_handler wait in wait_suspend();
     * on iOS that signal never runs its handler (task #32), so SuspendThread on
     * oneself returned at once. Crysis's intro-video threads suspend themselves
     * once per frame and are resumed by the main thread: here they spun instead,
     * piling the count up to MAXIMUM_SUSPEND_COUNT, and when a video ended the
     * thread's exit (NtTerminateThread's select) waited on that count forever,
     * so the main thread sat out a 30 s join timeout between videos
     * (log 2026-09-30 12:25, build 244). Wait here the way wait_suspend does:
     * a zero-timeout select only returns once the thread is no longer suspended. */
    if (!ret)
    {
        BOOL self = handle == GetCurrentThread();
        if (!self)
        {
            THREAD_BASIC_INFORMATION tbi;
            self = !NtQueryInformationThread( handle, ThreadBasicInformation, &tbi, sizeof(tbi), NULL ) &&
                   HandleToULong( tbi.ClientId.UniqueThread ) == GetCurrentThreadId();
        }
        if (self)
        {
            static LONG self_suspends;
            LONG n = InterlockedIncrement( &self_suspends );
            if (n <= 4 || !(n & (n - 1)))
                dprintf( 2, "[self-suspend] madeira-bcd: tid=%04x suspended itself (#%d); waiting for the resume\n",
                         (int)GetCurrentThreadId(), (int)n );
            server_select( NULL, 0, SELECT_INTERRUPTIBLE, 0, NULL, NULL );
        }
    }
#endif
    return ret;
}


/******************************************************************************
 *              NtResumeThread   (NTDLL.@)
 */
NTSTATUS WINAPI NtResumeThread( HANDLE handle, ULONG *count )
{
    unsigned int ret;

    SERVER_START_REQ( resume_thread )
    {
        req->handle = wine_server_obj_handle( handle );
        if (!(ret = wine_server_call( req )))
        {
            if (count) *count = reply->count;
        }
    }
    SERVER_END_REQ;
    return ret;
}


/******************************************************************************
 *              NtAlertResumeThread   (NTDLL.@)
 */
NTSTATUS WINAPI NtAlertResumeThread( HANDLE handle, ULONG *count )
{
    FIXME( "stub: should alert thread %p\n", handle );
    return NtResumeThread( handle, count );
}


/******************************************************************************
 *              NtAlertThread   (NTDLL.@)
 */
NTSTATUS WINAPI NtAlertThread( HANDLE handle )
{
    FIXME( "stub: %p\n", handle );
    return STATUS_NOT_IMPLEMENTED;
}


#include <dlfcn.h>

extern int ios_thread_registry_count(void);
extern uintptr_t ios_thread_registry_teb(int i);
extern thread_t ios_thread_registry_mach(int i);

/* ml559 helpers for [xterm-where]: resolve a wine thread HANDLE to the Mach
 * thread we registered for it. The registry is keyed by mach_thread and stores
 * the TEB, and the TEB carries ClientId.UniqueThread — so handle -> tid (via the
 * server) -> registry scan -> mach_thread. Lock-free; read-only. */
static BOOL ios_terminate_is_self( HANDLE handle )
{
    return handle == GetCurrentThread() || handle == 0;
}

static thread_t ios_mach_thread_for_handle( HANDLE handle )
{
    DWORD tid = 0;
    int i, count;

    SERVER_START_REQ( get_thread_info )
    {
        req->handle = wine_server_obj_handle( handle );
        req->access = THREAD_QUERY_LIMITED_INFORMATION;
        if (!wine_server_call( req )) tid = reply->tid;
    }
    SERVER_END_REQ;
    if (!tid) return 0;

    count = ios_thread_registry_count();
    for (i = 0; i < count; i++)
    {
        uintptr_t teb = ios_thread_registry_teb( i );
        if (teb && (DWORD)(ULONG_PTR)((TEB *)teb)->ClientId.UniqueThread == tid)
            return ios_thread_registry_mach( i );
    }
    return 0;
}


/******************************************************************************
 *              NtTerminateThread  (NTDLL.@)
 */
NTSTATUS WINAPI NtTerminateThread( HANDLE handle, LONG exit_code )
{
    unsigned int ret;
    BOOL self;

    /* iOS-Madeira ml805: name every thread death and WHO caused it.
     *
     * A render thread exited while owning a critical section and eight threads
     * deadlocked behind it forever. The wineserver only reports `violent=0`,
     * which proves an orderly pipe closure and NOTHING about the cause: a
     * thread returning from its procedure, calling ExitThread, and being
     * terminated by a peer all produce it. Separating those is the whole point
     * -- "the wait timed out and it shut itself down" and "something else killed
     * it" call for opposite fixes. */
    {
        static unsigned long ios_term_n;
        if (++ios_term_n <= 128)
            ERR( "[thr-exit] ml805 target=%p self=%d exit_code=%d by_tid=%04x caller=%p\n",
                 handle, ios_terminate_is_self( handle ) ? 1 : 0, (int)exit_code,
                 (unsigned)(ULONG_PTR)NtCurrentTeb()->ClientId.UniqueThread,
                 __builtin_return_address(0) );
    }

    /* iOS-Madeira ml559 (#74 successor, DISCRIMINATOR — not a fix):
     *
     * ml558 died on a `BRK #1` (__builtin_trap) inside a system library, on a
     * thread we do not own, immediately after FEX logged "[thr-term] CROSS-TERM
     * tid=0x260 — victim heap not finalized". The tempting story is "we killed a
     * thread inside a libsystem critical section, so the next system call
     * trapped". That story is UNPROVEN, and asserting exactly this kind of
     * plausible chain has been wrong three times tonight, so this DECIDES it:
     *
     *   victim PC inside a SYSTEM image -> mechanism supported
     *   victim PC in guest/JIT code     -> mechanism refuted, look elsewhere
     *
     * Must sample BEFORE terminate_thread — afterwards the victim can already be
     * gone and thread_get_state would report nothing (or another thread's state).
     * Prints on every cross-thread kill including the boring ones, so "nothing
     * dangerous was killed" is a real observation rather than silence. */
    if (!ios_terminate_is_self( handle ))
    {
        static unsigned long xterm_n;
        thread_t vt = ios_mach_thread_for_handle( handle );
        if (++xterm_n <= 24 && vt)
        {
            arm_thread_state64_t vs;
            mach_msg_type_number_t vc = ARM_THREAD_STATE64_COUNT;
            if (thread_get_state( vt, ARM_THREAD_STATE64, (thread_state_t)&vs, &vc ) == KERN_SUCCESS)
            {
                uintptr_t vpc = (uintptr_t)arm_thread_state64_get_pc( vs );
                Dl_info di;
                int ok = dladdr( (void *)vpc, &di );
                dprintf( 2, "[xterm-where] #%lu victim pc=0x%llx %s`%s+0x%llx %s rev=ml559\n",
                         xterm_n, (unsigned long long)vpc,
                         ok && di.dli_fname ? di.dli_fname : "?",
                         ok && di.dli_sname ? di.dli_sname : "?",
                         ok && di.dli_saddr ? (unsigned long long)(vpc - (uintptr_t)di.dli_saddr) : 0ull,
                         ok ? "<== INSIDE A MACH-O IMAGE"
                            : "(no image — guest/JIT code; system-lock theory refuted for this kill)" );
            }
        }
    }

    SERVER_START_REQ( terminate_thread )
    {
        req->handle    = wine_server_obj_handle( handle );
        req->exit_code = exit_code;
        ret = wine_server_call( req );
        self = !ret && reply->self;
    }
    SERVER_END_REQ;

    if (self)
    {
        server_select( NULL, 0, SELECT_INTERRUPTIBLE, 0, NULL, NULL );
        exit_thread( exit_code );
    }
    return ret;
}


/******************************************************************************
 *              NtQueueApcThreadEx2  (NTDLL.@)
 */
NTSTATUS WINAPI NtQueueApcThreadEx2( HANDLE handle, HANDLE reserve_handle, ULONG flags,
                                     PNTAPCFUNC func, ULONG_PTR arg1, ULONG_PTR arg2, ULONG_PTR arg3 )
{
    unsigned int ret;
    union apc_call call;

    TRACE( "%p %p %#x %p %p %p %p.\n", handle, reserve_handle, flags, func, (void *)arg1, (void *)arg2, (void *)arg3 );

    SERVER_START_REQ( queue_apc )
    {
        req->handle = wine_server_obj_handle( handle );
        req->reserve_handle = wine_server_obj_handle( reserve_handle );
        if (func)
        {
            call.type         = APC_USER;
            call.user.func    = wine_server_client_ptr( func );
            call.user.flags = 0;
            if (flags & QUEUE_USER_APC_FLAGS_SPECIAL_USER_APC) call.user.flags |= SERVER_USER_APC_SPECIAL;
            if (flags & QUEUE_USER_APC_CALLBACK_DATA_CONTEXT) call.user.flags |= SERVER_USER_APC_CALLBACK_DATA_CONTEXT;
            call.user.args[0] = arg1;
            call.user.args[1] = arg2;
            call.user.args[2] = arg3;
            wine_server_add_data( req, &call, sizeof(call) );
        }
        ret = wine_server_call( req );
    }
    SERVER_END_REQ;
    return ret;
}


/******************************************************************************
 *              NtQueueApcThreadEx  (NTDLL.@)
 */
NTSTATUS WINAPI NtQueueApcThreadEx( HANDLE handle, HANDLE reserve_handle, PNTAPCFUNC func,
                                    ULONG_PTR arg1, ULONG_PTR arg2, ULONG_PTR arg3 )
{
    ULONG flags = 0;

    flags = (ULONG_PTR)reserve_handle & (ULONG_PTR)3;
    reserve_handle = (HANDLE)((ULONG_PTR)reserve_handle & ~(ULONG_PTR)3);
    return NtQueueApcThreadEx2( handle, reserve_handle, flags, func, arg1, arg2, arg3 );
}


/******************************************************************************
 *              NtQueueApcThread  (NTDLL.@)
 */
NTSTATUS WINAPI NtQueueApcThread( HANDLE handle, PNTAPCFUNC func, ULONG_PTR arg1,
                                  ULONG_PTR arg2, ULONG_PTR arg3 )
{
    return NtQueueApcThreadEx2( handle, NULL, QUEUE_USER_APC_FLAGS_NONE, func, arg1, arg2, arg3 );
}


/***********************************************************************
 *              set_thread_context
 */
NTSTATUS set_thread_context( HANDLE handle, const void *context, BOOL *self, USHORT machine )
{
    struct context_data server_contexts[2];
    unsigned int count = 0;
    unsigned int ret;

    context_to_server( &server_contexts[count++], native_machine, context, machine );
    if (machine != native_machine)
        context_to_server( &server_contexts[count++], machine, context, machine );

    SERVER_START_REQ( set_thread_context )
    {
        req->handle  = wine_server_obj_handle( handle );
        req->native_flags = server_contexts[0].flags & get_native_context_flags( native_machine, machine );
        wine_server_add_data( req, server_contexts, count * sizeof(server_contexts[0]) );
        ret = wine_server_call( req );
        *self = reply->self;
    }
    SERVER_END_REQ;

    return ret;
}


/***********************************************************************
 *              get_thread_context
 */
NTSTATUS get_thread_context( HANDLE handle, void *context, BOOL *self, USHORT machine )
{
    unsigned int ret;
    HANDLE context_handle;
    struct context_data server_contexts[2];
    unsigned int count;
    unsigned int flags = get_server_context_flags( context, machine );

    SERVER_START_REQ( get_thread_context )
    {
        req->handle  = wine_server_obj_handle( handle );
        req->flags   = flags;
        req->machine = machine;
        req->native_flags = flags & get_native_context_flags( native_machine, machine );
        wine_server_set_reply( req, server_contexts, sizeof(server_contexts) );
        ret = wine_server_call( req );
        *self = reply->self;
        context_handle = wine_server_ptr_handle( reply->handle );
        count = wine_server_reply_size( reply ) / sizeof(server_contexts[0]);
    }
    SERVER_END_REQ;

    if (ret == STATUS_PENDING)
    {
        sigset_t sigset;

        NtWaitForSingleObject( context_handle, FALSE, NULL );

        server_enter_uninterrupted_section( &fd_cache_mutex, &sigset );

        /* remove the handle from the cache, get_thread_context will close it for us */
        close_inproc_sync( context_handle );

        SERVER_START_REQ( get_thread_context )
        {
            req->context = wine_server_obj_handle( context_handle );
            req->flags   = flags;
            req->machine = machine;
            req->native_flags = flags & get_native_context_flags( native_machine, machine );
            wine_server_set_reply( req, server_contexts, sizeof(server_contexts) );
            ret = server_call_unlocked( req );
            count = wine_server_reply_size( reply ) / sizeof(server_contexts[0]);
        }
        SERVER_END_REQ;

        server_leave_uninterrupted_section( &fd_cache_mutex, &sigset );
    }
    if (!ret && count)
    {
        ret = context_from_server( context, &server_contexts[0], machine );
        if (!ret && count > 1) ret = context_from_server( context, &server_contexts[1], machine );
    }
    return ret;
}


/***********************************************************************
 *              ntdll_set_exception_jmp_buf
 */
void ntdll_set_exception_jmp_buf( jmp_buf jmp )
{
    assert( !jmp || !ntdll_get_thread_data()->jmp_buf );
    ntdll_get_thread_data()->jmp_buf = jmp;
}


BOOL get_thread_times(int unix_pid, int unix_tid, LARGE_INTEGER *kernel_time, LARGE_INTEGER *user_time)
{
#ifdef linux
    unsigned long clocks_per_sec = sysconf( _SC_CLK_TCK );
    unsigned long usr, sys;
    const char *pos;
    char buf[512];
    FILE *f;
    int i;

    if (unix_tid == -1)
        snprintf( buf, sizeof(buf), "/proc/%u/stat", unix_pid );
    else
        snprintf( buf, sizeof(buf), "/proc/%u/task/%u/stat", unix_pid, unix_tid );
    if (!(f = fopen( buf, "r" )))
    {
        WARN("Failed to open %s: %s\n", buf, strerror(errno));
        return FALSE;
    }

    pos = fgets( buf, sizeof(buf), f );
    fclose( f );

    /* the process name is printed unescaped, so we have to skip to the last ')'
     * to avoid misinterpreting the string */
    if (pos) pos = strrchr( pos, ')' );
    if (pos) pos = strchr( pos + 1, ' ' );
    if (pos) pos++;

    /* skip over the following fields: state, ppid, pgid, sid, tty_nr, tty_pgrp,
     * task->flags, min_flt, cmin_flt, maj_flt, cmaj_flt */
    for (i = 0; i < 11 && pos; i++)
    {
        pos = strchr( pos + 1, ' ' );
        if (pos) pos++;
    }

    /* the next two values are user and system time */
    if (pos && (sscanf( pos, "%lu %lu", &usr, &sys ) == 2))
    {
        kernel_time->QuadPart = (ULONGLONG)sys * 10000000 / clocks_per_sec;
        user_time->QuadPart = (ULONGLONG)usr * 10000000 / clocks_per_sec;
        return TRUE;
    }

    ERR("Failed to parse %s\n", debugstr_a(buf));
    return FALSE;
#elif defined(HAVE_LIBPROCSTAT)
    struct procstat *pstat;
    struct kinfo_proc *kip;
    unsigned int proc_count;
    BOOL ret = FALSE;

    pstat = procstat_open_sysctl();
    if (!pstat)
        return FALSE;
    if (unix_tid == -1)
        kip = procstat_getprocs(pstat, KERN_PROC_PID, unix_pid, &proc_count);
    else
        kip = procstat_getprocs(pstat, KERN_PROC_PID | KERN_PROC_INC_THREAD, unix_pid, &proc_count);
    if (kip)
    {
        unsigned int i;
        for (i = 0; i < proc_count; i++)
        {
            if (unix_tid == -1 || kip[i].ki_tid == unix_tid)
            {
                kernel_time->QuadPart = 10000000 * (ULONGLONG)kip[i].ki_rusage.ru_stime.tv_sec +
                    10 * (ULONGLONG)kip[i].ki_rusage.ru_stime.tv_usec;
                user_time->QuadPart = 10000000 * (ULONGLONG)kip[i].ki_rusage.ru_utime.tv_sec +
                    10 * (ULONGLONG)kip[i].ki_rusage.ru_utime.tv_usec;
                ret = TRUE;
                break;
            }
        }
        procstat_freeprocs(pstat, kip);
    }
    procstat_close(pstat);
    return ret;
#else
    static int once;
    if (!once++) FIXME("not implemented on this platform\n");
    return FALSE;
#endif
}

static void set_native_thread_name( HANDLE handle, const UNICODE_STRING *name )
{
    /* iOS-Madeira ml810: publish the thread name <-> TID <-> TEB mapping.
     *
     * Everything below is #ifdef linux, so on iOS this function did nothing and
     * the log carried thread NAMES (from [thread-stacks], keyed by mach port)
     * and Windows TIDs (from every other probe) with no way to join them. That
     * gap produced a wrong attribution: a deadlocked "00dc" was reported as
     * RenderThread 0 when it was actually PoolThread 1, and a whole causal
     * chain was built on it. One line here makes that mistake impossible.
     *
     * Self-naming is the common case (a thread names itself on entry), and it
     * is the only one that can be resolved without a server round trip -- so
     * say plainly which case this is rather than printing a bare handle. */
    {
        char nm[64];
        int nlen = ntdll_wcstoumbs( name->Buffer, name->Length / sizeof(WCHAR),
                                    nm, sizeof(nm) - 1, FALSE );
        if (nlen < 0) nlen = 0;
        nm[nlen] = 0;
        if (ios_terminate_is_self( handle ))
            ERR( "[thr-name] ml810 tid=%04x teb=%p name=\"%s\"\n",
                 (unsigned)(ULONG_PTR)NtCurrentTeb()->ClientId.UniqueThread,
                 NtCurrentTeb(), nm );
        else
            ERR( "[thr-name] ml810 handle=%p (named by tid=%04x, NOT self) name=\"%s\"\n",
                 handle, (unsigned)(ULONG_PTR)NtCurrentTeb()->ClientId.UniqueThread, nm );
        ios_thread_qos_named( handle, nm );   /* MADEIRA_THREAD_QOS */
    }
#ifdef linux
    unsigned int status;
    char path[64], nameA[64];
    int unix_pid, unix_tid, len, fd;

    SERVER_START_REQ( get_thread_times )
    {
        req->handle = wine_server_obj_handle( handle );
        status = wine_server_call( req );
        if (status == STATUS_SUCCESS)
        {
            unix_pid = reply->unix_pid;
            unix_tid = reply->unix_tid;
        }
    }
    SERVER_END_REQ;

    if (status != STATUS_SUCCESS || unix_pid == -1 || unix_tid == -1)
        return;

    if (unix_pid != getpid())
    {
        static int once;
        if (!once++) FIXME("cross-process native thread naming not supported\n");
        return;
    }

    len = ntdll_wcstoumbs( name->Buffer, name->Length / sizeof(WCHAR), nameA, sizeof(nameA), FALSE );
    snprintf(path, sizeof(path), "/proc/%u/task/%u/comm", unix_pid, unix_tid);
    if ((fd = open( path, O_WRONLY )) != -1)
    {
        write( fd, nameA, len );
        close( fd );
    }
#elif defined(__APPLE__)
    char nameA[MAXTHREADNAMESIZE];
    int len;
    THREAD_BASIC_INFORMATION info;

    if (NtQueryInformationThread( handle, ThreadBasicInformation, &info, sizeof(info), NULL ))
        return;

    if (HandleToULong( info.ClientId.UniqueProcess ) != GetCurrentProcessId())
    {
        static int once;
        if (!once++) FIXME("cross-process native thread naming not supported\n");
        return;
    }

    if (HandleToULong( info.ClientId.UniqueThread ) != GetCurrentThreadId())
    {
        static int once;
        if (!once++) FIXME("setting other thread name not supported\n");
        return;
    }

    len = ntdll_wcstoumbs( name->Buffer, name->Length / sizeof(WCHAR), nameA, sizeof(nameA) - 1, FALSE );
    nameA[len] = '\0';
    pthread_setname_np( nameA );
#elif defined(__FreeBSD__)
    unsigned int status;
    char nameA[64];
    int unix_pid, unix_tid, len;

    SERVER_START_REQ( get_thread_times )
    {
        req->handle = wine_server_obj_handle( handle );
        status = wine_server_call( req );
        if (status == STATUS_SUCCESS)
        {
            unix_pid = reply->unix_pid;
            unix_tid = reply->unix_tid;
        }
    }
    SERVER_END_REQ;

    if (status != STATUS_SUCCESS || unix_pid == -1 || unix_tid == -1)
        return;

    if (unix_pid != getpid())
    {
        static int once;
        if (!once++) FIXME("cross-process native thread naming not supported\n");
        return;
    }

    len = ntdll_wcstoumbs( name->Buffer, name->Length / sizeof(WCHAR), nameA, sizeof(nameA), FALSE );
    nameA[len] = '\0';
    thr_set_name( unix_tid, nameA );
#else
    static int once;
    if (!once++) FIXME("not implemented on this platform\n");
#endif
}

static BOOL is_process_wow64( const CLIENT_ID *id )
{
    HANDLE handle;
    ULONG_PTR info;
    BOOL ret = FALSE;

    if (id->UniqueProcess == ULongToHandle(GetCurrentProcessId())) return is_old_wow64();
    if (!NtOpenProcess( &handle, PROCESS_QUERY_LIMITED_INFORMATION, NULL, id ))
    {
        if (!NtQueryInformationProcess( handle, ProcessWow64Information, &info, sizeof(info), NULL ))
            ret = !!info;
        NtClose( handle );
    }
    return ret;
}

/******************************************************************************
 *              NtQueryInformationThread  (NTDLL.@)
 */
NTSTATUS WINAPI NtQueryInformationThread( HANDLE handle, THREADINFOCLASS class,
                                          void *data, ULONG length, ULONG *ret_len )
{
    unsigned int status;

    TRACE("(%p,%d,%p,%x,%p)\n", handle, class, data, length, ret_len);

    switch (class)
    {
    case ThreadBasicInformation:
    {
        THREAD_BASIC_INFORMATION info;
        const ULONG_PTR affinity_mask = get_system_affinity_mask();

        SERVER_START_REQ( get_thread_info )
        {
            req->handle = wine_server_obj_handle( handle );
            if (!(status = wine_server_call( req )))
            {
                info.ExitStatus             = reply->exit_code;
                info.TebBaseAddress         = wine_server_get_ptr( reply->teb );
                info.ClientId.UniqueProcess = ULongToHandle(reply->pid);
                info.ClientId.UniqueThread  = ULongToHandle(reply->tid);
                info.AffinityMask           = reply->affinity & affinity_mask;
                info.Priority               = reply->priority;
                info.BasePriority           = reply->base_priority;
            }
        }
        SERVER_END_REQ;
        if (status == STATUS_SUCCESS)
        {
            if (is_old_wow64())
            {
                if (info.TebBaseAddress && is_process_wow64( &info.ClientId ))
                    info.TebBaseAddress = (char *)info.TebBaseAddress + teb_offset;
                else
                    info.TebBaseAddress = NULL;
            }
            if (data) memcpy( data, &info, min( length, sizeof(info) ));
            if (ret_len) *ret_len = min( length, sizeof(info) );
        }
        return status;
    }

    case ThreadAffinityMask:
    {
        const ULONG_PTR affinity_mask = get_system_affinity_mask();
        ULONG_PTR affinity = 0;

        SERVER_START_REQ( get_thread_info )
        {
            req->handle = wine_server_obj_handle( handle );
            req->access = THREAD_QUERY_INFORMATION;
            if (!(status = wine_server_call( req ))) affinity = reply->affinity & affinity_mask;
        }
        SERVER_END_REQ;
        if (status == STATUS_SUCCESS)
        {
            if (data) memcpy( data, &affinity, min( length, sizeof(affinity) ));
            if (ret_len) *ret_len = min( length, sizeof(affinity) );
        }
        return status;
    }

    case ThreadTimes:
    {
        KERNEL_USER_TIMES kusrt;
        int unix_pid, unix_tid;

        SERVER_START_REQ( get_thread_times )
        {
            req->handle = wine_server_obj_handle( handle );
            status = wine_server_call( req );
            if (status == STATUS_SUCCESS)
            {
                kusrt.CreateTime.QuadPart = reply->creation_time;
                kusrt.ExitTime.QuadPart = reply->exit_time;
                unix_pid = reply->unix_pid;
                unix_tid = reply->unix_tid;
            }
        }
        SERVER_END_REQ;
        if (status == STATUS_SUCCESS)
        {
            BOOL ret = FALSE;

            kusrt.KernelTime.QuadPart = kusrt.UserTime.QuadPart = 0;
            if (unix_pid != -1 && unix_tid != -1)
                ret = get_thread_times( unix_pid, unix_tid, &kusrt.KernelTime, &kusrt.UserTime );
            if (!ret && handle == GetCurrentThread())
            {
                /* fall back to process times */
                struct tms time_buf;
                long clocks_per_sec = sysconf(_SC_CLK_TCK);

                times(&time_buf);
                kusrt.KernelTime.QuadPart = (ULONGLONG)time_buf.tms_stime * 10000000 / clocks_per_sec;
                kusrt.UserTime.QuadPart = (ULONGLONG)time_buf.tms_utime * 10000000 / clocks_per_sec;
            }
            if (data) memcpy( data, &kusrt, min( length, sizeof(kusrt) ));
            if (ret_len) *ret_len = min( length, sizeof(kusrt) );
        }
        return status;
    }

    case ThreadDescriptorTableEntry:
        status = get_thread_ldt_entry( handle, data, length );
        if (status == STATUS_SUCCESS && ret_len) *ret_len = sizeof(LDT_ENTRY);
        return status;

    case ThreadAmILastThread:
    {
        if (length != sizeof(ULONG)) return STATUS_INFO_LENGTH_MISMATCH;
        SERVER_START_REQ( get_thread_info )
        {
            req->handle = wine_server_obj_handle( handle );
            status = wine_server_call( req );
            if (status == STATUS_SUCCESS)
            {
                ULONG last = !!(reply->flags & GET_THREAD_INFO_FLAG_LAST);
                if (data) memcpy( data, &last, sizeof(last) );
                if (ret_len) *ret_len = sizeof(last);
            }
        }
        SERVER_END_REQ;
        return status;
    }

    case ThreadQuerySetWin32StartAddress:
    {
        SERVER_START_REQ( get_thread_info )
        {
            req->handle = wine_server_obj_handle( handle );
            req->access = THREAD_QUERY_INFORMATION;
            status = wine_server_call( req );
            if (status == STATUS_SUCCESS)
            {
                PRTL_THREAD_START_ROUTINE entry = wine_server_get_ptr( reply->entry_point );
                if (data) memcpy( data, &entry, min( length, sizeof(entry) ) );
                if (ret_len) *ret_len = min( length, sizeof(entry) );
            }
        }
        SERVER_END_REQ;
        return status;
    }

    case ThreadGroupInformation:
    {
        const ULONG_PTR affinity_mask = get_system_affinity_mask();
        GROUP_AFFINITY affinity;

        memset( &affinity, 0, sizeof(affinity) );
        affinity.Group = 0; /* Wine only supports max 64 processors */

        SERVER_START_REQ( get_thread_info )
        {
            req->handle = wine_server_obj_handle( handle );
            if (!(status = wine_server_call( req ))) affinity.Mask = reply->affinity & affinity_mask;
        }
        SERVER_END_REQ;
        if (status == STATUS_SUCCESS)
        {
            if (data) memcpy( data, &affinity, min( length, sizeof(affinity) ));
            if (ret_len) *ret_len = min( length, sizeof(affinity) );
        }
        return status;
    }

    case ThreadIsIoPending:
        FIXME( "ThreadIsIoPending info class not supported yet\n" );
        if (length != sizeof(BOOL)) return STATUS_INFO_LENGTH_MISMATCH;
        if (!data) return STATUS_ACCESS_DENIED;
        *(BOOL*)data = FALSE;
        if (ret_len) *ret_len = sizeof(BOOL);
        return STATUS_SUCCESS;

    case ThreadIsTerminated:
    {
        ULONG terminated;

        if (length != sizeof(ULONG)) return STATUS_INFO_LENGTH_MISMATCH;
        SERVER_START_REQ( get_thread_info )
        {
            req->handle = wine_server_obj_handle( handle );
            if (!(status = wine_server_call( req ))) terminated = !!(reply->flags & GET_THREAD_INFO_FLAG_TERMINATED);
        }
        SERVER_END_REQ;
        if (!status)
        {
            *(ULONG *)data = terminated;
            if (ret_len) *ret_len = sizeof(ULONG);
        }
        return status;
    }

    case ThreadSuspendCount:
        if (length != sizeof(ULONG)) return STATUS_INFO_LENGTH_MISMATCH;
        if (!data) return STATUS_ACCESS_VIOLATION;

        SERVER_START_REQ( get_thread_info )
        {
            req->handle = wine_server_obj_handle( handle );
            if (!(status = wine_server_call( req ))) *(ULONG *)data = reply->suspend_count;
        }
        SERVER_END_REQ;
        return status;

    case ThreadNameInformation:
    {
        THREAD_NAME_INFORMATION *info = data;
        data_size_t len, desc_len = 0;
        WCHAR *ptr;

        len = length >= sizeof(*info) ? length - sizeof(*info) : 0;
        ptr = info ? (WCHAR *)(info + 1) : NULL;

        SERVER_START_REQ( get_thread_info )
        {
            req->handle = wine_server_obj_handle( handle );
            if (ptr) wine_server_set_reply( req, ptr, len );
            status = wine_server_call( req );
            desc_len = reply->desc_len;
        }
        SERVER_END_REQ;

        if (!info) status = STATUS_BUFFER_TOO_SMALL;
        else if (status == STATUS_SUCCESS)
        {
            info->ThreadName.Length = info->ThreadName.MaximumLength = desc_len;
            info->ThreadName.Buffer = ptr;
        }

        if (ret_len && (status == STATUS_SUCCESS || status == STATUS_BUFFER_TOO_SMALL))
            *ret_len = sizeof(*info) + desc_len;
        return status;
    }

    case ThreadWow64Context:
        return get_thread_wow64_context( handle, data, length );

    case ThreadHideFromDebugger:
        /* TP Shell Service depends on ThreadHideFromDebugger returning
         * STATUS_ACCESS_VIOLATION if *ret_len is not writable, before
         * any other checks. Despite the status, the variable does not
         * actually seem to be written at that time. */
        if (ret_len) *(volatile ULONG *)ret_len |= 0;

        if (length != sizeof(BOOLEAN)) return STATUS_INFO_LENGTH_MISMATCH;
        if (!data) return STATUS_ACCESS_VIOLATION;
        SERVER_START_REQ( get_thread_info )
        {
            req->handle = wine_server_obj_handle( handle );
            req->access = THREAD_QUERY_INFORMATION;
            if ((status = wine_server_call( req ))) return status;
            *(BOOLEAN*)data = !!(reply->flags & GET_THREAD_INFO_FLAG_DBG_HIDDEN);
        }
        SERVER_END_REQ;
        if (ret_len) *ret_len = sizeof(BOOLEAN);
        return STATUS_SUCCESS;

    case ThreadPriorityBoost:
    {
        if (length != sizeof(ULONG)) return STATUS_INFO_LENGTH_MISMATCH;
        SERVER_START_REQ( get_thread_info )
        {
            req->handle = wine_server_obj_handle( handle );
            status = wine_server_call( req );
            if (status == STATUS_SUCCESS)
            {
                ULONG disable_boost = !!(reply->flags & GET_THREAD_INFO_FLAG_DISABLE_BOOST);
                if (data) memcpy( data, &disable_boost, sizeof(disable_boost) );
                if (ret_len) *ret_len = sizeof(disable_boost);
            }
        }
        SERVER_END_REQ;
        return status;
    }

    case ThreadIdealProcessorEx:
    {
        PROCESSOR_NUMBER *number = data;

        FIXME( "ThreadIdealProcessorEx info class - stub\n" );
        if (length != sizeof(*number)) return STATUS_INFO_LENGTH_MISMATCH;
        memset( number, 0, sizeof(*number) );
        if (ret_len) *ret_len = sizeof(*number);
        return STATUS_SUCCESS;
    }

    case ThreadIdealProcessor:
    case ThreadEnableAlignmentFaultFixup:
        return STATUS_INVALID_INFO_CLASS;

    case ThreadPriority:
    case ThreadBasePriority:
    case ThreadImpersonationToken:
    case ThreadEventPair_Reusable:
    case ThreadZeroTlsCell:
    case ThreadPerformanceCount:
    case ThreadSetTlsArrayAddress:
    default:
        FIXME( "info class %d not supported yet\n", class );
        return STATUS_NOT_IMPLEMENTED;
    }
}


/******************************************************************************
 *              NtSetInformationThread  (NTDLL.@)
 */
NTSTATUS WINAPI NtSetInformationThread( HANDLE handle, THREADINFOCLASS class,
                                        const void *data, ULONG length )
{
    unsigned int status;

    TRACE("(%p,%d,%p,%x)\n", handle, class, data, length);

    switch (class)
    {
    case ThreadZeroTlsCell:
        if (handle == GetCurrentThread())
        {
            if (length != sizeof(DWORD)) return STATUS_INVALID_PARAMETER;
            return virtual_clear_tls_index( *(const ULONG *)data );
        }
        FIXME( "ZeroTlsCell not supported on other threads\n" );
        return STATUS_NOT_IMPLEMENTED;

    case ThreadImpersonationToken:
    {
        const HANDLE *token = data;

        if (length != sizeof(HANDLE)) return STATUS_INVALID_PARAMETER;
        TRACE("Setting ThreadImpersonationToken handle to %p\n", *token );
        SERVER_START_REQ( set_thread_info )
        {
            req->handle   = wine_server_obj_handle( handle );
            req->token    = wine_server_obj_handle( *token );
            req->mask     = SET_THREAD_INFO_TOKEN;
            status = wine_server_call( req );
        }
        SERVER_END_REQ;
        return status;
    }

    case ThreadPriority:
    {
        const DWORD *priority = data;
        if (length != sizeof(DWORD)) return STATUS_INVALID_PARAMETER;
        SERVER_START_REQ( set_thread_info )
        {
            req->handle    = wine_server_obj_handle( handle );
            req->priority  = *priority;
            req->mask      = SET_THREAD_INFO_PRIORITY;
            status = wine_server_call( req );
        }
        SERVER_END_REQ;
        return status;
    }

    case ThreadBasePriority:
    {
        const DWORD *base_priority = data;
        if (length != sizeof(DWORD)) return STATUS_INVALID_PARAMETER;
        SERVER_START_REQ( set_thread_info )
        {
            req->handle         = wine_server_obj_handle( handle );
            req->base_priority  = *base_priority;
            req->mask           = SET_THREAD_INFO_BASE_PRIORITY;
            status = wine_server_call( req );
        }
        SERVER_END_REQ;
        if (!status) ios_eco_prio_note( handle, (LONG)*base_priority );   /* eco-prio (opt-in) */
        return status;
    }

    case ThreadAffinityMask:
    {
        const ULONG_PTR affinity_mask = get_system_affinity_mask();
        ULONG_PTR req_aff;

        if (length != sizeof(ULONG_PTR)) return STATUS_INVALID_PARAMETER;
        req_aff = *(const ULONG_PTR *)data & affinity_mask;
        if (!req_aff) return STATUS_INVALID_PARAMETER;
        { extern volatile long long ios_affinity_sets; __sync_fetch_and_add( &ios_affinity_sets, 1 ); }   /* ml1117 */

        SERVER_START_REQ( set_thread_info )
        {
            req->handle   = wine_server_obj_handle( handle );
            req->affinity = req_aff;
            req->mask     = SET_THREAD_INFO_AFFINITY;
            status = wine_server_call( req );
        }
        SERVER_END_REQ;
        return status;
    }

    case ThreadHideFromDebugger:
        if (length) return STATUS_INFO_LENGTH_MISMATCH;
        SERVER_START_REQ( set_thread_info )
        {
            req->handle = wine_server_obj_handle( handle );
            req->mask   = SET_THREAD_INFO_DBG_HIDDEN;
            status = wine_server_call( req );
        }
        SERVER_END_REQ;
        return status;

    case ThreadQuerySetWin32StartAddress:
    {
        const PRTL_THREAD_START_ROUTINE *entry = data;
        if (length != sizeof(PRTL_THREAD_START_ROUTINE)) return STATUS_INVALID_PARAMETER;
        SERVER_START_REQ( set_thread_info )
        {
            req->handle   = wine_server_obj_handle( handle );
            req->mask     = SET_THREAD_INFO_ENTRYPOINT;
            req->entry_point = wine_server_client_ptr( *entry );
            status = wine_server_call( req );
        }
        SERVER_END_REQ;
        return status;
    }

    case ThreadGroupInformation:
    {
        const ULONG_PTR affinity_mask = get_system_affinity_mask();
        const GROUP_AFFINITY *req_aff;

        if (length != sizeof(*req_aff)) return STATUS_INVALID_PARAMETER;
        if (!data) return STATUS_ACCESS_VIOLATION;
        req_aff = data;

        /* On Windows the request fails if the reserved fields are set */
        if (req_aff->Reserved[0] || req_aff->Reserved[1] || req_aff->Reserved[2])
            return STATUS_INVALID_PARAMETER;

        /* Wine only supports max 64 processors */
        if (req_aff->Group) return STATUS_INVALID_PARAMETER;
        if (req_aff->Mask & ~affinity_mask) return STATUS_INVALID_PARAMETER;
        if (!req_aff->Mask) return STATUS_INVALID_PARAMETER;
        SERVER_START_REQ( set_thread_info )
        {
            req->handle   = wine_server_obj_handle( handle );
            req->affinity = req_aff->Mask;
            req->mask     = SET_THREAD_INFO_AFFINITY;
            status = wine_server_call( req );
        }
        SERVER_END_REQ;
        return status;
    }

    case ThreadNameInformation:
    {
        const THREAD_NAME_INFORMATION *info = data;
        THREAD_BASIC_INFORMATION tbi;

        if (length != sizeof(*info)) return STATUS_INFO_LENGTH_MISMATCH;
        if (!info) return STATUS_ACCESS_VIOLATION;
        if (info->ThreadName.Length && !info->ThreadName.Buffer) return STATUS_ACCESS_VIOLATION;

        status = NtQueryInformationThread( handle, ThreadBasicInformation, &tbi, sizeof(tbi), NULL );
        if (handle == GetCurrentThread() || (!status && (HandleToULong(tbi.ClientId.UniqueThread) == GetCurrentThreadId())))
            WARN_(threadname)( "Thread renamed to %s\n", debugstr_us(&info->ThreadName) );
        else if (!status)
            WARN_(threadname)( "Thread ID %04x renamed to %s\n", HandleToULong( tbi.ClientId.UniqueThread ), debugstr_us(&info->ThreadName) );
        else
            WARN_(threadname)( "Thread handle %p renamed to %s\n", handle, debugstr_us(&info->ThreadName) );

        SERVER_START_REQ( set_thread_info )
        {
            req->handle = wine_server_obj_handle( handle );
            req->mask   = SET_THREAD_INFO_DESCRIPTION;
            wine_server_add_data( req, info->ThreadName.Buffer, info->ThreadName.Length );
            status = wine_server_call( req );
        }
        SERVER_END_REQ;

        set_native_thread_name( handle, &info->ThreadName );

        return status;
    }

    case ThreadWineNativeThreadName:
    {
        const THREAD_NAME_INFORMATION *info = data;

        if (length != sizeof(*info)) return STATUS_INFO_LENGTH_MISMATCH;

        set_native_thread_name( handle, &info->ThreadName );
        return STATUS_SUCCESS;
    }

    case ThreadWow64Context:
        return set_thread_wow64_context( handle, data, length );

    case ThreadEnableAlignmentFaultFixup:
        if (length != sizeof(BOOLEAN)) return STATUS_INFO_LENGTH_MISMATCH;
        if (!data) return STATUS_ACCESS_VIOLATION;
        FIXME( "ThreadEnableAlignmentFaultFixup stub!\n" );
        return STATUS_SUCCESS;

    case ThreadPowerThrottlingState:
        if (length != sizeof(THREAD_POWER_THROTTLING_STATE)) return STATUS_INFO_LENGTH_MISMATCH;
        if (!data) return STATUS_ACCESS_VIOLATION;
        FIXME( "ThreadPowerThrottling stub!\n" );
        return STATUS_SUCCESS;

    case ThreadIdealProcessor:
    {
        const ULONG *number = data;

        if (length != sizeof(*number)) return STATUS_INFO_LENGTH_MISMATCH;
        if (*number > MAXIMUM_PROCESSORS) return STATUS_INVALID_PARAMETER;
        FIXME( "ThreadIdealProcessor stub!\n" );
        return STATUS_SUCCESS;
    }

    case ThreadPriorityBoost:
    {
        const DWORD *disable_boost = data;
        if (length != sizeof(DWORD)) return STATUS_INVALID_PARAMETER;
        SERVER_START_REQ( set_thread_info )
        {
            req->handle         = wine_server_obj_handle( handle );
            req->disable_boost  = *disable_boost;
            req->mask           = SET_THREAD_INFO_DISABLE_BOOST;
            status = wine_server_call( req );
        }
        SERVER_END_REQ;
        return status;
    }

    case ThreadManageWritesToExecutableMemory:
    {
#ifdef __aarch64__
        const MANAGE_WRITES_TO_EXECUTABLE_MEMORY *mem = data;

        if (length != sizeof(*mem)) return STATUS_INFO_LENGTH_MISMATCH;
        if (handle != GetCurrentThread()) return STATUS_NOT_SUPPORTED;
        if (mem->Version != 2) return STATUS_REVISION_MISMATCH;
        if (mem->ProcessEnableWriteExceptions) return STATUS_INVALID_PARAMETER;
        ntdll_get_thread_data()->allow_writes = mem->ThreadAllowWrites;
        return STATUS_SUCCESS;
#else
        return STATUS_NOT_SUPPORTED;
#endif
    }

    case ThreadBasicInformation:
    case ThreadTimes:
    case ThreadDescriptorTableEntry:
    case ThreadEventPair_Reusable:
    case ThreadPerformanceCount:
    case ThreadAmILastThread:
    case ThreadSetTlsArrayAddress:
    case ThreadIsIoPending:
    default:
        FIXME( "info class %d not supported yet\n", class );
        return STATUS_NOT_IMPLEMENTED;
    }
}


/******************************************************************************
 *              NtGetCurrentProcessorNumber  (NTDLL.@)
 */
ULONG WINAPI NtGetCurrentProcessorNumber(void)
{
    ULONG processor;

#if defined(HAVE_SCHED_GETCPU)
    int res = sched_getcpu();
    if (res >= 0) return res;
#elif defined(__APPLE__) && defined(MAC_OS_VERSION_11_0)
    if (__builtin_available( macOS 11.0, * ))
    {
        size_t cpu_id;
        pthread_cpu_number_np( &cpu_id );
        return cpu_id;
    }
#endif
#if defined(__APPLE__) && (defined(__x86_64__) || defined(__i386__))
    {
        struct {
            unsigned long p1, p2;
        } p;
        __asm__ __volatile__("sidt %[p]" : [p] "=&m"(p));
        processor = (ULONG)(p.p1 & 0xfff);
        return processor;
    }
#endif

    if (peb->NumberOfProcessors > 1)
    {
        ULONG_PTR thread_mask, processor_mask;

        if (!NtQueryInformationThread( GetCurrentThread(), ThreadAffinityMask,
                                       &thread_mask, sizeof(thread_mask), NULL ))
        {
            for (processor = 0; processor < peb->NumberOfProcessors; processor++)
            {
                processor_mask = (1 << processor);
                if (thread_mask & processor_mask)
                {
                    if (thread_mask != processor_mask)
                        FIXME( "need multicore support (%d processors)\n",
                               peb->NumberOfProcessors );
                    return processor;
                }
            }
        }
    }
    /* fallback to the first processor */
    return 0;
}


/******************************************************************************
 *              NtGetNextThread  (NTDLL.@)
 */
NTSTATUS WINAPI NtGetNextThread( HANDLE process, HANDLE thread, ACCESS_MASK access, ULONG attributes,
                                 ULONG flags, HANDLE *handle )
{
    HANDLE ret_handle = 0;
    unsigned int ret;

    TRACE( "process %p, thread %p, access %#x, attributes %#x, flags %#x, handle %p.\n",
            process, thread, access, attributes, flags, handle );

    SERVER_START_REQ( get_next_thread )
    {
        req->process = wine_server_obj_handle( process );
        req->last = wine_server_obj_handle( thread );
        req->access = access;
        req->attributes = attributes;
        req->flags = flags;
        if (!(ret = wine_server_call( req ))) ret_handle = wine_server_ptr_handle( reply->handle );
    }
    SERVER_END_REQ;

    *handle = ret_handle;
    return ret;
}


/******************************************************************************
 *              NtWorkerFactoryWorkerReady  (NTDLL.@)
 */
NTSTATUS WINAPI NtWorkerFactoryWorkerReady( HANDLE handle )
{
    FIXME( "handle %p stub.\n", handle );

    return STATUS_NOT_IMPLEMENTED;
}
