# lwIP

lwIP 2.2.1 (`STABLE-2_2_1_RELEASE`), BSD licence (`COPYING`): `src/core` (without `altcp`, and
only the IPv4 and IPv6 files a TCP stack needs) as `core`, and `src/include` as `include`. `port`,
`include/arch`, `include/lwipopts.h` and `include/CLwIP.h` are ours.

A VPN's stack has to take connections to every address and port, so four changes, each marked
`Routey:`:

- `core/ipv4/ip4.c`, `ip4_input_accept`: accept every destination while the netif is up.
- `core/ipv6/ip6.c`, `ip6_input_accept`: the same for IPv6.
- `core/tcp_in.c`, `tcp_input`: a listener bound to any address matches every port.
- `core/tcp_in.c`, `tcp_listen_input`: the new connection's local port is the one the app dialled.
