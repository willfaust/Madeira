/*
 * nsiproxy.sys tcp module
 *
 * Copyright 2003, 2006, 2011 Juan Lang
 * Copyright 2007 TransGaming Technologies Inc.
 * Copyright 2021 Huw Davies
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public
 * License as published by the Free Software Foundation; either
 * version 3 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * General Public License for more details.
 *
 * You should have received a copy of the GNU General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301, USA
 */
/* iOS SDK omits these optional BSD headers; the interface/address APIs
 * and routing sysctl ABI are available. Reuse Wine's provider unchanged. */
#include "config.h"
#undef HAVE_NET_IF_ARP_H
#undef HAVE_NETINET_IF_ETHER_H
#undef HAVE_NETINET_IP_VAR_H
#undef HAVE_NETINET_ICMP_VAR_H
#undef HAVE_STRUCT_IPSTAT_IPS_TOTAL
#undef HAVE_STRUCT_IP_STATS_IPS_TOTAL
/* sockaddr_inarp's routing-message ABI from Apple's bsd/netinet/if_ether.h.
 * This public structure is omitted from the iPhoneOS SDK. */
#include <sys/socket.h>
#include <netinet/in.h>
struct sockaddr_inarp
{
    unsigned char sin_len;
    unsigned char sin_family;
    unsigned short sin_port;
    struct in_addr sin_addr;
    struct in_addr sin_srcaddr;
    unsigned short sin_tos;
    unsigned short sin_other;
};
#include "../../wine/dlls/nsiproxy.sys/ip.c"

/* Shared address-scope helpers from nsiproxy.sys/tcp.c. The TCP connection
 * provider remains the existing server-backed iOS implementation. */
struct ipv6_addr_scope *get_ipv6_addr_scope_table( unsigned int *size )
{
    struct ipv6_addr_scope *table = NULL, *new_table;
    unsigned int table_size = 0, num = 0;
    *size = 0;

#ifdef __linux__
    {
        char buf[512], *ptr;
        FILE *fp;

        if (!(fp = fopen( "/proc/net/if_inet6", "r" ))) goto failed;

        while ((ptr = fgets( buf, sizeof(buf), fp )))
        {
            WORD a[8];
            UINT scope;
            struct ipv6_addr_scope *entry;
            unsigned int i;

            if (sscanf( ptr, "%4hx%4hx%4hx%4hx%4hx%4hx%4hx%4hx %*s %*s %x",
                        a, a + 1, a + 2, a + 3, a + 4, a + 5, a + 6, a + 7, &scope ) != 9)
                continue;

            if (++num > table_size)
            {
                if (!table_size) table_size = 4;
                else table_size *= 2;
                if (!(new_table = realloc( table, table_size * sizeof(table[0]) )))
                {
                    fclose( fp );
                    goto failed;
                }
                table = new_table;
            }

            entry = table + num - 1;
            for (i = 0; i < 8; i++)
                entry->addr.u.Word[i] = htons( a[i] );
            entry->scope = htons( scope );
        }

        fclose( fp );
    }
#elif defined(HAVE_GETIFADDRS)
    {
        struct ifaddrs *addrs, *cur;

        if (getifaddrs( &addrs ) == -1)  goto failed;

        for (cur = addrs; cur; cur = cur->ifa_next)
        {
            struct sockaddr_in6 *sin6;
            struct ipv6_addr_scope *entry;

            if (!cur->ifa_addr || cur->ifa_addr->sa_family != AF_INET6) continue;

            if (++num > table_size)
            {
                if (!table_size) table_size = 4;
                else table_size *= 2;
                if (!(new_table = realloc( table, table_size * sizeof(table[0]) )))
                {
                    freeifaddrs( addrs );
                    goto failed;
                }
                table = new_table;
            }

            sin6 = (struct sockaddr_in6 *)cur->ifa_addr;
            entry = table + num - 1;
            memcpy( &entry->addr, &sin6->sin6_addr, sizeof(entry->addr) );
            entry->scope = sin6->sin6_scope_id;
        }

        freeifaddrs( addrs );
    }
#else
    FIXME( "not implemented\n" );
    goto failed;
#endif

    *size = num;
    return table;

failed:
    free( table );
    return NULL;
}

UINT find_ipv6_addr_scope( const IN6_ADDR *addr, const struct ipv6_addr_scope *table, unsigned int size )
{
    const BYTE multicast_scope_mask = 0x0F;
    const BYTE multicast_scope_shift = 0;
    unsigned int i;

    if (WS_IN6_IS_ADDR_UNSPECIFIED( addr )) return 0;

    if (WS_IN6_IS_ADDR_MULTICAST( addr ))
        return htons( (addr->u.Byte[1] & multicast_scope_mask) >> multicast_scope_shift );

    if (!table) return -1;

    for (i = 0; i < size; i++)
        if (!memcmp( &table[i].addr, addr, sizeof(table[i].addr) ))
            return table[i].scope;

    return -1;
}

