/*
 * ml2101: Wine's HID report descriptor parser, for the wineserver.
 *
 * GPL-3.0-or-later WITH the Madeira Converter Exception, version 1; see
 * LICENSE-EXCEPTION.md. The parser itself is Wine's (LGPL-2.1-or-later,
 * dlls/hidparse.sys/main.c), compiled here unchanged.
 *
 * hid.dll answers HidP_GetCaps, HidP_GetUsageValue and the rest from the
 * "preparsed data" blob IOCTL_HID_GET_COLLECTION_DESCRIPTOR returns. That blob
 * is Wine's private struct hid_preparsed_data (include/wine/hid.h), which
 * hidclass.sys normally builds with hidparse.sys's HidP_GetCollectionDescription.
 * The virtual pad in build/wineserver/hidpad_ios.c has no hidclass under it,
 * so it calls the very same parser through this file: whatever layout the
 * pinned Wine's hid.dll expects is the layout it gets.
 *
 * Shims, all local to this translation unit:
 *  - ExAllocatePool/ExFreePool are ntoskrnl's; here they are malloc/free.
 *  - The parser's ERR/WARN/TRACE would reach ntdll's debug channel code, which
 *    needs a Wine thread (TEB). The wineserver thread has none, so every debug
 *    macro is compiled out.
 *  - Its exported names are prefixed, so nothing collides with a real
 *    hidparse.sys or any other symbol in the app.
 */

#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

#include "ntstatus.h"
#include "windef.h"
#include "winbase.h"
#include "winternl.h"
#include "winioctl.h"

#define HidP_GetCollectionDescription  madeira_hidparse_GetCollectionDescription
#define HidP_FreeCollectionDescription madeira_hidparse_FreeCollectionDescription
#define DriverEntry                    madeira_hidparse_DriverEntry
#define parse_descriptor               madeira_hidparse_parse_descriptor

#include <ddk/wdm.h>
#include <ddk/hidpddi.h>
#include "wine/hid.h"
#include "wine/list.h"
#include "wine/debug.h"

#undef ExAllocatePool
#undef ExFreePool
#define ExAllocatePool(type, size) malloc( size )
#define ExFreePool(ptr) free( ptr )

#undef ERR
#undef WARN
#undef FIXME
#undef TRACE
#undef TRACE_ON
#define ERR(...)   do { } while (0)
#define WARN(...)  do { } while (0)
#define FIXME(...) do { } while (0)
#define TRACE(...) do { } while (0)
#define TRACE_ON(ch) 0

/* The host check (tests/host/check-hidpad.py) points this at its Wine tree. */
#ifndef MADEIRA_HIDPARSE_MAIN
#define MADEIRA_HIDPARSE_MAIN "../../wine/dlls/hidparse.sys/main.c"
#endif
/* Its debugstr helpers print ULONG/LONG with %lx/%ld, right for the PE build
 * (LLP64) and a -Wformat warning here (LP64, where Wine's LONG is int). They
 * are never called -- TRACE is compiled out above -- so only the noise goes. */
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wformat"
#include MADEIRA_HIDPARSE_MAIN
#pragma GCC diagnostic pop

#include "hidparse_ios.h"

/* Parse `desc` and return its single top-level collection as hid.dll's
 * preparsed data (malloc'ed, *size bytes), and the byte length of every report
 * ID it declares, ID included, in input/output/feature (indexed by report ID,
 * 0 when the ID has no report of that type). NULL when the descriptor does not
 * parse or has more than one top-level collection. */
void *madeira_hidparse_preparse( const unsigned char *desc, unsigned int desc_len, unsigned int *size,
                                 unsigned short input[256], unsigned short output[256],
                                 unsigned short feature[256] )
{
    HIDP_DEVICE_DESC device_desc;
    void *data = NULL;
    ULONG i;

    memset( input, 0, 256 * sizeof(*input) );
    memset( output, 0, 256 * sizeof(*output) );
    memset( feature, 0, 256 * sizeof(*feature) );
    if (madeira_hidparse_GetCollectionDescription( (PHIDP_REPORT_DESCRIPTOR)desc, desc_len, NonPagedPool,
                                                   &device_desc ) != HIDP_STATUS_SUCCESS)
        return NULL;
    if (device_desc.CollectionDescLength == 1 &&
        (data = malloc( device_desc.CollectionDesc[0].PreparsedDataLength )))
    {
        memcpy( data, device_desc.CollectionDesc[0].PreparsedData,
                device_desc.CollectionDesc[0].PreparsedDataLength );
        *size = device_desc.CollectionDesc[0].PreparsedDataLength;
        for (i = 0; i < device_desc.ReportIDsLength; i++)
        {
            HIDP_REPORT_IDS *id = device_desc.ReportIDs + i;
            input[id->ReportID] = id->InputLength;
            output[id->ReportID] = id->OutputLength;
            feature[id->ReportID] = id->FeatureLength;
        }
    }
    madeira_hidparse_FreeCollectionDescription( &device_desc );
    return data;
}
