#ifndef __INSTR_H__
#define __INSTR_H__

/* Called by iperf.c right after a successful TCP connect(), with the
 * SAL-level socket fd (the same value iperf_client()'s own `sock` holds).
 * Resolves fd -> tcp_pcb internally and arms the tcp_poll sampler. */
void instr_attach_client_socket(int fd);

/* Called by iperf.c right before closesocket(), with the same fd. Restores
 * the pcb's original tcp_poll callback/interval and disarms the sampler. */
void instr_detach_client_socket(int fd);

#endif /* __INSTR_H__ */
