#include <string.h>
#include "CLwIP.h"
#include "lwip/init.h"
#include "lwip/netif.h"
#include "lwip/pbuf.h"
#include "lwip/tcp.h"
#include "lwip/timeouts.h"
#include "lwip/ip.h"
#include "lwip/priv/tcp_priv.h"

static struct netif tun;
static struct tcp_pcb *listener;
static stack_output_fn output_fn;
static stack_accept_fn accept_fn;
static stack_received_fn received_fn;
static stack_sent_fn sent_fn;
static stack_failed_fn failed_fn;
static void *output_context;
static uint8_t packet_buffer[0xFFFF];

static void emit(struct pbuf *p, int version) {
    if (output_fn == NULL || p->tot_len > sizeof(packet_buffer)) {
        return;
    }
    if (p->len == p->tot_len) {
        output_fn(output_context, p->payload, p->len, version);
        return;
    }
    u16_t length = pbuf_copy_partial(p, packet_buffer, p->tot_len, 0);
    output_fn(output_context, packet_buffer, length, version);
}

static err_t output4(struct netif *netif, struct pbuf *p, const ip4_addr_t *address) {
    emit(p, 4);
    return ERR_OK;
}

static err_t output6(struct netif *netif, struct pbuf *p, const ip6_addr_t *address) {
    emit(p, 6);
    return ERR_OK;
}

static err_t tun_init(struct netif *netif) {
    netif->name[0] = 't';
    netif->name[1] = 'n';
    netif->mtu = 1500;
    netif->mtu6 = 1500;
    netif->output = output4;
    netif->output_ip6 = output6;
    return ERR_OK;
}

static err_t accepted(void *arg, struct tcp_pcb *pcb, err_t err) {
    if (err != ERR_OK || pcb == NULL) {
        return ERR_VAL;
    }
    if (accept_fn == NULL) {
        tcp_abort(pcb);
        return ERR_ABRT;
    }
    tcp_nagle_disable(pcb);
    accept_fn(output_context, pcb);
    return ERR_OK;
}

void stack_start(stack_output_fn output, stack_accept_fn accept, stack_received_fn received,
                 stack_sent_fn sent, stack_failed_fn failed, void *context) {
    output_fn = output;
    accept_fn = accept;
    received_fn = received;
    sent_fn = sent;
    failed_fn = failed;
    output_context = context;
    if (listener != NULL) {
        return;
    }
    lwip_init();
    ip4_addr_t address, netmask, gateway;
    IP4_ADDR(&address, 198, 18, 0, 1);
    IP4_ADDR(&netmask, 255, 254, 0, 0);
    ip4_addr_set_zero(&gateway);
    netif_add(&tun, &address, &netmask, &gateway, NULL, tun_init, ip_input);
    netif_set_default(&tun);
    netif_set_up(&tun);
    netif_set_link_up(&tun);

    struct tcp_pcb *pcb = tcp_new_ip_type(IPADDR_TYPE_ANY);
    tcp_bind(pcb, IP_ANY_TYPE, 0);
    listener = tcp_listen(pcb);
    tcp_accept(listener, accepted);
}

void stack_stop(void) {
    output_fn = NULL;
    accept_fn = NULL;
    output_context = NULL;
    while (tcp_active_pcbs != NULL) {
        tcp_abort(tcp_active_pcbs);
    }
}

void stack_check_timeouts(void) {
    sys_check_timeouts();
}

void stack_input(const uint8_t *packet, size_t length) {
    if (length == 0 || length > 0xFFFF) {
        return;
    }
    struct pbuf *p = pbuf_alloc(PBUF_RAW, (u16_t)length, PBUF_RAM);
    if (p == NULL) {
        return;
    }
    memcpy(p->payload, packet, length);
    if (tun.input(p, &tun) != ERR_OK) {
        pbuf_free(p);
    }
}

static void copy_address(const ip_addr_t *address, uint8_t *bytes) {
    memset(bytes, 0, 16);
    if (IP_IS_V4(address)) {
        memcpy(bytes, &ip_2_ip4(address)->addr, 4);
    } else {
        memcpy(bytes, ip_2_ip6(address)->addr, 16);
    }
}

int stack_tcp_endpoints(const struct tcp_pcb *pcb, uint8_t *local, uint16_t *local_port,
                        uint8_t *remote, uint16_t *remote_port) {
    copy_address(&pcb->local_ip, local);
    copy_address(&pcb->remote_ip, remote);
    *local_port = pcb->local_port;
    *remote_port = pcb->remote_port;
    return IP_IS_V4(&pcb->local_ip) ? 4 : 6;
}

static err_t tcp_received(void *arg, struct tcp_pcb *pcb, struct pbuf *p, err_t err) {
    if (p == NULL) {
        received_fn(arg, NULL, 0);
        return ERR_OK;
    }
    for (struct pbuf *q = p; q != NULL; q = q->next) {
        received_fn(arg, q->payload, q->len);
    }
    pbuf_free(p);
    return ERR_OK;
}

static err_t tcp_sent_more(void *arg, struct tcp_pcb *pcb, u16_t length) {
    sent_fn(arg);
    return ERR_OK;
}

static void tcp_failed(void *arg, err_t err) {
    failed_fn(arg);
}

void stack_tcp_attach(struct tcp_pcb *pcb, void *connection) {
    tcp_arg(pcb, connection);
    tcp_recv(pcb, tcp_received);
    tcp_sent(pcb, tcp_sent_more);
    tcp_err(pcb, tcp_failed);
}

void stack_tcp_received(struct tcp_pcb *pcb, size_t length) {
    while (length > 0) {
        u16_t part = length > 0xFFFF ? 0xFFFF : (u16_t)length;
        tcp_recved(pcb, part);
        length -= part;
    }
}

uint32_t stack_tcp_send_space(const struct tcp_pcb *pcb) {
    if (pcb->snd_queuelen >= TCP_SND_QUEUELEN) {
        return 0;
    }
    return tcp_sndbuf(pcb);
}

bool stack_tcp_write(struct tcp_pcb *pcb, const uint8_t *data, uint16_t length) {
    return tcp_write(pcb, data, length, TCP_WRITE_FLAG_COPY) == ERR_OK;
}

void stack_tcp_output(struct tcp_pcb *pcb) {
    tcp_output(pcb);
}

void stack_tcp_shutdown(struct tcp_pcb *pcb) {
    tcp_shutdown(pcb, 0, 1);
}

void stack_tcp_close(struct tcp_pcb *pcb) {
    tcp_arg(pcb, NULL);
    tcp_recv(pcb, NULL);
    tcp_sent(pcb, NULL);
    tcp_err(pcb, NULL);
    if (tcp_close(pcb) != ERR_OK) {
        tcp_abort(pcb);
    }
}
