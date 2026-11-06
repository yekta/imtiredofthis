#ifndef ROUTEY_CLWIP_H
#define ROUTEY_CLWIP_H

/* What Swift sees of lwIP: lwIP's own headers clash with the system's, so they stay in port/. */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

struct tcp_pcb;

/* A packet lwIP sends, `version` 4 or 6. */
typedef void (*stack_output_fn)(void *context, const uint8_t *packet, size_t length, int version);
/* A new TCP connection from an app. */
typedef void (*stack_accept_fn)(void *context, struct tcp_pcb *pcb);
/* Data from the app on a connection, or NULL once it has finished sending. */
typedef void (*stack_received_fn)(void *connection, const uint8_t *data, size_t length);
/* lwIP has room to send more. */
typedef void (*stack_sent_fn)(void *connection);
/* The connection was reset; lwIP has already freed it. */
typedef void (*stack_failed_fn)(void *connection);

/* Brings the stack up (lwIP once per process) and sends what it does to these. */
void stack_start(stack_output_fn output, stack_accept_fn accept, stack_received_fn received,
                 stack_sent_fn sent, stack_failed_fn failed, void *context);
/* Aborts every connection and forgets the callbacks. */
void stack_stop(void);
/* One IP packet from the tun. */
void stack_input(const uint8_t *packet, size_t length);
void stack_check_timeouts(void);

/* A connection's ends: 16 bytes of address each (an IPv4 address in the first 4). Returns 4 or 6. */
int stack_tcp_endpoints(const struct tcp_pcb *pcb, uint8_t *local, uint16_t *local_port,
                        uint8_t *remote, uint16_t *remote_port);
/* Sends the connection's events, with `connection`, to the callbacks. */
void stack_tcp_attach(struct tcp_pcb *pcb, void *connection);
/* Opens the app's window again by `length` bytes the reader has taken. */
void stack_tcp_received(struct tcp_pcb *pcb, size_t length);
/* How much stack_tcp_write takes now. */
uint32_t stack_tcp_send_space(const struct tcp_pcb *pcb);
bool stack_tcp_write(struct tcp_pcb *pcb, const uint8_t *data, uint16_t length);
void stack_tcp_output(struct tcp_pcb *pcb);
/* Sends a FIN; the app can still send. */
void stack_tcp_shutdown(struct tcp_pcb *pcb);
/* Stops the events and closes the connection, or resets it if it can't. */
void stack_tcp_close(struct tcp_pcb *pcb);

#endif
