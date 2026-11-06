#ifndef ROUTEY_LWIPOPTS_H
#define ROUTEY_LWIPOPTS_H

/* The system's byte order macros, before lwIP defines its own. */
#include <sys/types.h>

/* No OS layer: everything runs on one queue, the stack's. */
#define NO_SYS                          1
#define SYS_LIGHTWEIGHT_PROT            0
#define LWIP_SINGLE_NETIF               1

/* Memory comes from malloc as it is used; there are no static pools. */
#define MEM_LIBC_MALLOC                 1
#define MEMP_MEM_MALLOC                 1
#define MEM_ALIGNMENT                   8

#define LWIP_IPV4                       1
#define LWIP_IPV6                       1
#define LWIP_TCP                        1
#define LWIP_UDP                        1
#define LWIP_ICMP                       0
#define LWIP_RAW                        0
#define LWIP_ARP                        0
#define LWIP_ETHERNET                   0
#define LWIP_DHCP                       0
#define LWIP_AUTOIP                     0
#define LWIP_ACD                        0
#define LWIP_IGMP                       0
#define LWIP_DNS                        0
#define LWIP_NETCONN                    0
#define LWIP_SOCKET                     0
#define LWIP_STATS                      0
#define LWIP_NETIF_LOOPBACK             0
#define LWIP_HAVE_LOOPIF                0
#define IP_FORWARD                      0

#define IP_REASSEMBLY                   1
#define IP_FRAG                         0
#define LWIP_IPV6_REASS                 1
#define LWIP_IPV6_FRAG                  0
#define IPV6_FRAG_COPYHEADER            1
#define LWIP_IPV6_MLD                   0
#define LWIP_IPV6_AUTOCONFIG            0
#define LWIP_IPV6_SEND_ROUTER_SOLICIT   0
#define LWIP_IPV6_DUP_DETECT_ATTEMPTS   0

#define TCP_MSS                         1460
#define LWIP_WND_SCALE                  1
#define TCP_RCV_SCALE                   2
#define TCP_WND                         (64 * 1024)
#define TCP_SND_BUF                     (64 * 1024)
#define TCP_SND_QUEUELEN                ((4 * TCP_SND_BUF + TCP_MSS - 1) / TCP_MSS)
#define MEMP_NUM_TCP_PCB                1024
#define LWIP_TCP_SACK_OUT               1
#define LWIP_TCP_KEEPALIVE              0
#define TCP_LISTEN_BACKLOG              0

/* The kernel made the packets from the tun; checking their checksums again is wasted work. */
#define CHECKSUM_CHECK_IP               0
#define CHECKSUM_CHECK_TCP              0
#define CHECKSUM_CHECK_UDP              0
#define CHECKSUM_CHECK_ICMP             0
#define CHECKSUM_CHECK_ICMP6            0

#endif
