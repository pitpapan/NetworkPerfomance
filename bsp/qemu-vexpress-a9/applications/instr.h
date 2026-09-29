#ifndef __INSTR_H__
#define __INSTR_H__

/* Called by iperf.c right after a successful TCP connect(), with the
 * SAL-level socket fd (the same value iperf_client()'s own `sock` holds).
 * Resolves fd -> tcp_pcb internally, records the pcb pointer plus its
 * local/remote port pair as the sampling target, and starts the periodic
 * soft-timer sampler. Safe to call when a previous cycle left the timer
 * running: it stops the timer before re-arming. */
void instr_attach_client_socket(int fd);

/* Called by iperf.c right before closesocket(), with the same fd (the fd
 * is not used -- kept for symmetry with attach). Stops the sampler and
 * clears the target. Deliberately does NOT re-resolve fd -> pcb: at this
 * point the socket may already be unusable (peer reset, server killed),
 * and stopping the clock must not be conditional on that succeeding. */
void instr_detach_client_socket(int fd);

#endif /* __INSTR_H__ */
