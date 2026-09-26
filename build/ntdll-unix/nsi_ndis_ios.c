/* iOS SDK omits these optional BSD headers; the interface/address APIs
 * and routing sysctl ABI are available. Reuse Wine's provider unchanged. */
#include "config.h"
#undef HAVE_NET_IF_ARP_H
#undef HAVE_NETINET_IF_ETHER_H
#undef HAVE_NETINET_IP_VAR_H
#undef HAVE_NETINET_ICMP_VAR_H
#include "../../wine/dlls/nsiproxy.sys/ndis.c"
