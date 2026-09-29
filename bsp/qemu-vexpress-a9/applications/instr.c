/*
 * TCP sender-side instrumentation for the TFG iperf experiments.
 *
 * TASK 1 (boot banner): instr_boot_banner() prints the effective lwIP TCP
 *   config macros at boot, read straight from the macros -- not a
 *   hardcoded list -- so every run can confirm the firmware it is talking
 *   to actually matches its intended build.
 *
 * TASK 2 (pcb access): instr_attach_client_socket()/instr_detach_client_socket()
 *   take the plain SAL-level socket fd iperf_client() already has and
 *   resolve it to the underlying struct tcp_pcb * themselves:
 *     app fd -> sal_get_socket() -> struct sal_socket.user_data (lwIP's
 *     OWN internal fd, stored there by sal_socket()/inet_socket()) ->
 *     lwip_get_tcp_pcb() (new minimal lwIP accessor, see sockets.c).
 *   No public lwIP or SAL API returns a tcp_pcb* directly; this is the
 *   smallest bridge that exists across both layers as already installed
 *   in this tree (sal/impl/af_inet_lwip.c uses the exact same
 *   sal_socket->user_data -> lwip fd pattern internally).
 *
 * TASK 3 (sampler): chains onto the pcb's *existing* tcp_poll callback
 *   instead of replacing it with tcp_poll(). lwIP's own socket/netconn
 *   layer (api_msg.c) already occupies that single callback slot --
 *   tcp_poll(pcb, poll_tcp, NETCONN_TCP_POLL_INTERVAL) for ERR_MEM write
 *   retries, tightened to interval 1 while a close is pending. Replacing
 *   it via tcp_poll() would silently break that retry path, which counts
 *   as a data-path change. Instead we save pcb->poll/pcb->pollinterval,
 *   install our own function, and call the saved one after sampling.
 *
 * TASK 4 (accumulators) and TASK 5 (msh commands) are the rest of this
 * file.
 */
#include <rtthread.h>
#include <string.h>

#include "lwip/opt.h"
#include "lwip/tcp.h"
#include "lwip/tcpip.h"
#include "lwip/priv/tcp_priv.h"   /* struct tcp_seg, to walk unsent/unacked */
#include "lwip/sockets.h"         /* lwip_get_tcp_pcb() */
#include "sal_low_lvl.h"          /* struct sal_socket, sal_get_socket() */
#include "dfs_file.h"             /* struct dfs_file / dfs_vnode, for fd -> SAL index */
#include "dfs.h"                  /* fd_get() */

#include "instr.h"

/* ---------------------------------------------------------------------
 * Compile-time switches.
 * ------------------------------------------------------------------- */
#ifndef INSTR_WALK_SEGMENT_LISTS
/* 1 = also sum unsent/unacked payload bytes (O(list length) per sample).
 * 0 = only the cheap "unsent non-empty" boolean. Switchable so the cost
 * of the walk can be measured separately, per task instructions. */
#define INSTR_WALK_SEGMENT_LISTS   1
#endif

#ifndef INSTR_SNDBUF_LOW_THRESHOLD
#define INSTR_SNDBUF_LOW_THRESHOLD 1024u   /* bytes; configurable at compile time */
#endif

#define INSTR_RUN_ID_MAX 32

/* ---------------------------------------------------------------------
 * TASK 1: boot banner.
 *
 * Placed as an INIT_APP_EXPORT (component-init level, same mechanism the
 * project's earlier netio/workload modules used) so it runs once
 * automatically at boot, after the console device is up, without
 * touching applications/main.c. Every value below is the macro itself,
 * as seen by the compiler for this translation unit -- not re-typed
 * literals.
 * ------------------------------------------------------------------- */
static int instr_boot_banner(void)
{
    rt_kprintf("INSTR_CFG TCP_MSS=%d TCP_SND_BUF=%d TCP_SND_QUEUELEN=%d "
               "MEMP_NUM_TCP_SEG=%d TCP_WND=%d TCP_OVERSIZE=%d "
               "TCP_SNDLOWAT=%d TCP_SNDQUEUELOWAT=%d LWIP_WND_SCALE=%d\n",
               (int)TCP_MSS, (int)TCP_SND_BUF, (int)TCP_SND_QUEUELEN,
               (int)MEMP_NUM_TCP_SEG, (int)TCP_WND, (int)TCP_OVERSIZE,
               (int)TCP_SNDLOWAT, (int)TCP_SNDQUEUELOWAT, (int)LWIP_WND_SCALE);
    return 0;
}
INIT_APP_EXPORT(instr_boot_banner);

/* ---------------------------------------------------------------------
 * TASK 2 + TASK 3 state.
 * ------------------------------------------------------------------- */
static struct tcp_pcb  *g_instr_pcb = RT_NULL;
static tcp_poll_fn      g_orig_poll_fn = RT_NULL;
static rt_uint8_t       g_orig_poll_interval = 0;

/* ---------------------------------------------------------------------
 * TASK 4: accumulators.
 * ------------------------------------------------------------------- */
typedef struct
{
    char         run_id[INSTR_RUN_ID_MAX];

    rt_uint32_t  sample_count;

    rt_uint32_t  snd_buf_min;
    rt_uint32_t  snd_buf_low_count;    /* samples where snd_buf < INSTR_SNDBUF_LOW_THRESHOLD */

    rt_uint16_t  snd_queuelen_max;

    rt_uint16_t  cwnd_min;
    rt_uint16_t  cwnd_max;
    rt_uint64_t  cwnd_sum;

    rt_uint16_t  snd_wnd_min;
    rt_uint16_t  snd_wnd_max;
    rt_uint64_t  snd_wnd_sum;

    rt_uint32_t  inflight_min;
    rt_uint32_t  inflight_max;
    rt_uint64_t  inflight_sum;

    rt_uint32_t  unsent_nonempty_count;
    rt_uint32_t  unsent_bytes_max;
} instr_accum_t;

static instr_accum_t g_accum;

static void instr_accum_reset(const char *run_id)
{
    rt_memset(&g_accum, 0, sizeof(g_accum));
    if (run_id != RT_NULL)
    {
        rt_strncpy(g_accum.run_id, run_id, INSTR_RUN_ID_MAX - 1);
    }
    g_accum.snd_buf_min  = 0xFFFFFFFFu;
    g_accum.cwnd_min     = 0xFFFFu;
    g_accum.snd_wnd_min  = 0xFFFFu;
    g_accum.inflight_min = 0xFFFFFFFFu;
}

#if INSTR_WALK_SEGMENT_LISTS
static rt_uint32_t instr_sum_seg_len(struct tcp_seg *seg)
{
    rt_uint32_t total = 0;
    while (seg != RT_NULL)
    {
        total += seg->len;
        seg = seg->next;
    }
    return total;
}
#endif

/*
 * Runs on tcpip_thread's 1024-byte stack (TASK 3 critical constraint):
 * no printf, no allocation, only a handful of scalar locals.
 */
static err_t instr_poll_cb(void *arg, struct tcp_pcb *pcb)
{
    rt_uint32_t inflight;

    g_accum.sample_count++;

    if ((rt_uint32_t)pcb->snd_buf < g_accum.snd_buf_min)
    {
        g_accum.snd_buf_min = (rt_uint32_t)pcb->snd_buf;
    }
    if ((rt_uint32_t)pcb->snd_buf < INSTR_SNDBUF_LOW_THRESHOLD)
    {
        g_accum.snd_buf_low_count++;
    }

    if (pcb->snd_queuelen > g_accum.snd_queuelen_max)
    {
        g_accum.snd_queuelen_max = pcb->snd_queuelen;
    }

    if ((rt_uint16_t)pcb->cwnd < g_accum.cwnd_min) { g_accum.cwnd_min = (rt_uint16_t)pcb->cwnd; }
    if ((rt_uint16_t)pcb->cwnd > g_accum.cwnd_max) { g_accum.cwnd_max = (rt_uint16_t)pcb->cwnd; }
    g_accum.cwnd_sum += pcb->cwnd;

    if ((rt_uint16_t)pcb->snd_wnd < g_accum.snd_wnd_min) { g_accum.snd_wnd_min = (rt_uint16_t)pcb->snd_wnd; }
    if ((rt_uint16_t)pcb->snd_wnd > g_accum.snd_wnd_max) { g_accum.snd_wnd_max = (rt_uint16_t)pcb->snd_wnd; }
    g_accum.snd_wnd_sum += pcb->snd_wnd;

    /* in-flight = snd_nxt - lastack. Plain unsigned subtraction on u32_t
     * is correct across sequence-number wraparound as long as the true
     * distance is < 2^31 -- always true for a real send window -- the
     * same idiom lwIP itself uses for its TCP_SEQ_LT/GT comparisons. */
    inflight = (rt_uint32_t)(pcb->snd_nxt - pcb->lastack);
    if (inflight < g_accum.inflight_min) { g_accum.inflight_min = inflight; }
    if (inflight > g_accum.inflight_max) { g_accum.inflight_max = inflight; }
    g_accum.inflight_sum += inflight;

    if (pcb->unsent != RT_NULL)
    {
        g_accum.unsent_nonempty_count++;
#if INSTR_WALK_SEGMENT_LISTS
        {
            rt_uint32_t bytes = instr_sum_seg_len(pcb->unsent);
            if (bytes > g_accum.unsent_bytes_max) { g_accum.unsent_bytes_max = bytes; }
        }
#endif
    }

    /* Chain to whatever poll callback lwIP's own socket layer had
     * installed -- see file header comment. */
    if (g_orig_poll_fn != RT_NULL)
    {
        return g_orig_poll_fn(arg, pcb);
    }
    return ERR_OK;
}

/* fd (the POSIX/DFS-level fd iperf_client()'s own `sock` holds) ->
 * struct tcp_pcb *, or NULL. Three-level translation, all through public
 * RT-Thread/SAL/lwIP accessors:
 *   fd -> fd_get() -> struct dfs_file -> vnode->data (SAL socket index,
 *     the same lookup components/net/sal/src/sal_socket.c's own
 *     sal_poll() performs on a dfs_file)
 *   -> sal_get_socket() -> struct sal_socket.user_data (lwIP's own
 *     internal fd, stored there by sal_socket()/inet_socket())
 *   -> lwip_get_tcp_pcb() (new minimal lwIP accessor, see sockets.c) */
static struct tcp_pcb *instr_pcb_from_fd(int fd)
{
    struct dfs_file *file;
    struct sal_socket *sal_sock;
    int sal_index;
    int lwip_fd;

    file = fd_get(fd);
    if (file == RT_NULL || file->vnode == RT_NULL)
    {
        return RT_NULL;
    }
    sal_index = (int)(size_t)file->vnode->data;

    sal_sock = sal_get_socket(sal_index);
    if (sal_sock == RT_NULL)
    {
        return RT_NULL;
    }
    lwip_fd = (int)(size_t)sal_sock->user_data;
    return lwip_get_tcp_pcb(lwip_fd);
}

void instr_attach_client_socket(int fd)
{
    struct tcp_pcb *pcb = instr_pcb_from_fd(fd);
    if (pcb == RT_NULL)
    {
        rt_kprintf("instr: could not resolve fd %d to a tcp_pcb, sampler not armed\n", fd);
        return;
    }

    LOCK_TCPIP_CORE();
    g_orig_poll_fn       = pcb->poll;
    g_orig_poll_interval = pcb->pollinterval;
    pcb->poll = instr_poll_cb;
    /* pollinterval is intentionally left untouched -- it belongs to
     * lwIP's own retry logic, not to us; our sampling cadence is simply
     * whatever that interval already is (see instr_dump/report). */
    UNLOCK_TCPIP_CORE();

    g_instr_pcb = pcb;
    rt_kprintf("instr: sampler armed on fd=%d\n", fd);
}

void instr_detach_client_socket(int fd)
{
    struct tcp_pcb *pcb = instr_pcb_from_fd(fd);
    if (pcb == RT_NULL || pcb != g_instr_pcb)
    {
        return;
    }

    LOCK_TCPIP_CORE();
    pcb->poll = g_orig_poll_fn;
    pcb->pollinterval = g_orig_poll_interval;
    UNLOCK_TCPIP_CORE();

    g_instr_pcb = RT_NULL;
    g_orig_poll_fn = RT_NULL;
}

/* ---------------------------------------------------------------------
 * TASK 5: msh commands. These run on the msh thread, not the callback,
 * so rt_kprintf/formatting here is fine.
 * ------------------------------------------------------------------- */
static int instr_reset(int argc, char **argv)
{
    if (argc < 2)
    {
        rt_kprintf("Usage: instr_reset <run_id>\n");
        return -1;
    }
    instr_accum_reset(argv[1]);
    rt_kprintf("instr: accumulators reset, run_id=%s\n", g_accum.run_id);
    return 0;
}

static int instr_dump(int argc, char **argv)
{
    rt_uint32_t cwnd_mean_x1000 = 0, snd_wnd_mean_x1000 = 0, inflight_mean_x1000 = 0;

    (void)argc;
    (void)argv;

    if (g_accum.sample_count > 0)
    {
        cwnd_mean_x1000     = (rt_uint32_t)((g_accum.cwnd_sum     * 1000u) / g_accum.sample_count);
        snd_wnd_mean_x1000  = (rt_uint32_t)((g_accum.snd_wnd_sum  * 1000u) / g_accum.sample_count);
        inflight_mean_x1000 = (rt_uint32_t)((g_accum.inflight_sum * 1000u) / g_accum.sample_count);
    }

    /* RT_CONSOLEBUF_SIZE is 256 bytes in this build (src/kservice.c: static
     * char rt_log_buf[RT_CONSOLEBUF_SIZE]; anything longer is silently
     * truncated by rt_kprintf itself). The full JSON line is longer than
     * that, so it is assembled from several rt_kprintf calls, none
     * containing a newline except the last -- the console still shows one
     * continuous JSON line, just not built by one call. */
    rt_kprintf("{\"run_id\":\"%s\",\"cfg\":{\"TCP_MSS\":%d,\"TCP_SND_BUF\":%d,"
               "\"TCP_SND_QUEUELEN\":%d,\"MEMP_NUM_TCP_SEG\":%d,",
        g_accum.run_id,
        (int)TCP_MSS, (int)TCP_SND_BUF, (int)TCP_SND_QUEUELEN, (int)MEMP_NUM_TCP_SEG);

    rt_kprintf("\"TCP_WND\":%d,\"TCP_OVERSIZE\":%d,\"TCP_SNDLOWAT\":%d,"
               "\"TCP_SNDQUEUELOWAT\":%d,\"LWIP_WND_SCALE\":%d},",
        (int)TCP_WND, (int)TCP_OVERSIZE, (int)TCP_SNDLOWAT,
        (int)TCP_SNDQUEUELOWAT, (int)LWIP_WND_SCALE);

    rt_kprintf("\"sample_count\":%u,\"snd_buf_min\":%u,\"snd_buf_low_count\":%u,"
               "\"snd_buf_low_threshold\":%u,\"snd_queuelen_max\":%u,",
        g_accum.sample_count,
        g_accum.sample_count ? g_accum.snd_buf_min : 0u, g_accum.snd_buf_low_count,
        (rt_uint32_t)INSTR_SNDBUF_LOW_THRESHOLD, g_accum.snd_queuelen_max);

    rt_kprintf("\"cwnd_min\":%u,\"cwnd_max\":%u,\"cwnd_mean_x1000\":%u,"
               "\"snd_wnd_min\":%u,\"snd_wnd_max\":%u,\"snd_wnd_mean_x1000\":%u,",
        g_accum.sample_count ? (rt_uint32_t)g_accum.cwnd_min : 0u, (rt_uint32_t)g_accum.cwnd_max, cwnd_mean_x1000,
        g_accum.sample_count ? (rt_uint32_t)g_accum.snd_wnd_min : 0u, (rt_uint32_t)g_accum.snd_wnd_max, snd_wnd_mean_x1000);

    rt_kprintf("\"inflight_min\":%u,\"inflight_max\":%u,\"inflight_mean_x1000\":%u,"
               "\"unsent_nonempty_count\":%u,\"unsent_bytes_max\":%u,\"walk_segment_lists\":%d}\n",
        g_accum.sample_count ? g_accum.inflight_min : 0u, g_accum.inflight_max, inflight_mean_x1000,
        g_accum.unsent_nonempty_count, g_accum.unsent_bytes_max, (int)INSTR_WALK_SEGMENT_LISTS);

    return 0;
}

#ifdef FINSH_USING_MSH
#include <finsh.h>
MSH_CMD_EXPORT(instr_reset, zero instrumentation accumulators and store a run id);
MSH_CMD_EXPORT(instr_dump, print one JSON line with run config and accumulators);
#endif /* FINSH_USING_MSH */
