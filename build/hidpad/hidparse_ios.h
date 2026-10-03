/* ml2101: Wine's HID descriptor parser for the wineserver (hidparse_ios.c).
 * GPL-3.0-or-later WITH the Madeira Converter Exception, version 1; see
 * LICENSE-EXCEPTION.md. Plain C types only: the wineserver includes this next
 * to its own headers, which do not mix with the DDK's. */
#ifndef MADEIRA_HIDPARSE_IOS_H
#define MADEIRA_HIDPARSE_IOS_H

void *madeira_hidparse_preparse( const unsigned char *desc, unsigned int desc_len, unsigned int *size,
                                 unsigned short input[256], unsigned short output[256],
                                 unsigned short feature[256] );

#endif
