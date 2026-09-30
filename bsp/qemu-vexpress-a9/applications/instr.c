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
 *     app fd -> fd_get() -> dfs_file->vnode->data (SAL index) ->
 *     sal_get_socket() -> struct sal_socket.user_data (lwIP's OWN
 *     internal fd) -> lwip_get_tcp_pcb() (minimal lwIP accessor, see
 *     sockets.c).
 *   No public lwIP or SAL API returns a tcp_pcb* directly; this is the
 *   smallest bridge that exists across both layers as already installed
 *   in this tree.
 *
 * TASK 3 (sampler): an RT-Thread PERIODIC SOFT TIMER, independent of
 *   lwIP's own TCP timers.
 *
 *   Rationale: the previous design chained onto pcb->poll (tcp_poll).
 *   That is unusable as an active-transfer sampling clock, because
 *   pcb->polltmr is reset to 0 on every processed ACK
 *   (lwip-2.0.3/src/core/tcp_in.c:1203, inside tcp_receive()'s
 *   forward-progress handling). During a continuously-ACKed bulk
 *   transfer the poll countdown never reaches pollinterval, so the
 *   callback essentially never fires -- empirically sample_count=0 after
 *   a 30 s transfer. tcp_poll is an idle-connection callback by design.
 *   The pcb->poll chaining is therefore REMOVED ENTIRELY here: lwIP's own
 *   poll_tcp (installed by api_msg.c's setup_tcp() for ERR_MEM write
 *   retries and close-wait) is left completely untouched, which is a
 *   stronger "do not modify the data path" guarantee than chaining was.
 *
 *   Safety rules the timer callback obeys, in order:
 *     1. It runs on RT-Thread's soft-timer thread (RT_TIMER_FLAG_SOFT_TIMER),
 *        NOT in tick ISR context, so it is allowed to block on a mutex.
 *        That thread has a 4096-byte stack at priority 4
 *        (rtconfig.h:77-78) -- higher priority than tcpip_thread (10) and
 *        the iperf thread (20). RT-Thread mutexes implement priority
 *        inheritance (src/ipc.c), so a lower-priority lock holder is
 *        boosted rather than starved.
 *     2. It takes LOCK_TCPIP_CORE() before touching any lwIP state.
 *     3. Under the lock it VALIDATES the saved pcb pointer by searching
 *        lwIP's own tcp_active_pcbs list, and additionally checks the
 *        local/remote port pair still matches what was recorded at
 *        attach. The list check alone is not quite sufficient: a freed
 *        pcb's memp block can be recycled for a different connection at
 *        the same address. Ports make that case detectable.
 *     4. Under the lock it copies the wanted fields into plain locals
 *        (and, in the FULL tier, walks the unsent list -- which is a pcb
 *        dereference and so must happen here).
 *     5. It UNLOCKs, and only then does all accumulator arithmetic.
 *   No pcb memory is ever dereferenced outside the core lock, and no
 *   accumulator arithmetic is ever performed while holding it.
 *
 * TASK 4 (accumulators) and TASK 5 (msh commands) are the rest of this
 * file.
 */
#include <rtthread.h>
#include <string.h>
#include <stdlib.h>              /* atoi() for the msh interval command */

#include "lwip/opt.h"
#include "lwip/tcp.h"
#include "lwip/tcpip.h"
#include "lwip/priv/tcp_priv.h"   /* struct tcp_seg, tcp_active_pcbs */
#include "lwip/sockets.h"         /* lwip_get_tcp_pcb() */
#include "sal_low_lvl.h"          /* struct sal_socket, sal_get_socket() */
#include "dfs_file.h"             /* struct dfs_file / dfs_vnode */
#include "dfs.h"                  /* fd_get() */

#include "instr.h"

/* ---------------------------------------------------------------------
 * Compile-time switches.
 * ------------------------------------------------------------------- */
#ifndef INSTR_WALK_SEGMENT_LISTS
/* The FLOOR/FULL switch, unchanged in meaning from the previous design.
 *   1 = the unsent-list walk is compiled in; tiers OFF/FLOOR/FULL are all
 *       reachable at runtime via `instr_tier`.
 *   0 = the walk is not compiled at all; only OFF/FLOOR are reachable.
 * Building with 0 is the way to show that the walk's *code* -- not just
 * its execution -- is absent, for a perturbation argument that does not
 * depend on trusting a runtime flag. */
#define INSTR_WALK_SEGMENT_LISTS   1
#endif

#ifndef INSTR_SNDBUF_LOW_THRESHOLD
/* LEGACY, RETAINED DELIBERATELY. Measured useless as a discriminator: it read
 * 318/319 at L0/50ms and 647/647 at L0/500ms, i.e. ~1.00 at every cell, because
 * snd_buf sits at 0 essentially always at L0. Kept unchanged so earlier runs
 * stay comparable; superseded for analysis by the mechanism classification
 * below. Its replacement (if any) is TBD FROM PILOT -- not set here. */
#define INSTR_SNDBUF_LOW_THRESHOLD 1024u   /* bytes; configurable at compile time */
#endif

#ifndef INSTR_APP_WRITE_BYTES
/* The application's fixed write size, IPERF_BUFSZ = 4*1024 (verified fact F14,
 * packages/netutils-latest/iperf/iperf.c). This is a WORKLOAD CONSTANT of the
 * benchmark, not a tunable threshold: "could the application have issued another
 * whole send() at this instant?" is a question with one correct denominator. */
#define INSTR_APP_WRITE_BYTES 4096u
#endif

#ifndef INSTR_DEFAULT_INTERVAL_MS
#define INSTR_DEFAULT_INTERVAL_MS  100u    /* msh-settable at runtime */
#endif

#ifndef INSTR_TRACE_SLOTS
/* Per-sample time-series ring buffer, for transient / steady-state work.
 * This is a CAPACITY, not an experimental parameter: it bounds how much
 * history `instr_trace` can print, and nothing else. Oldest samples are
 * overwritten once it is full; instr_dump's accumulators are unaffected
 * and always cover the whole run. 1024 slots x 16 bytes = 16 KiB of BSS
 * against a ~64 MB heap region. At a 100 ms interval that is 102.4 s of
 * history, which covers every run length used in Phase 0. */
#define INSTR_TRACE_SLOTS 1024u
#endif

#define INSTR_RUN_ID_MAX 32

/* Sampling tiers. OFF and FLOOR are always reachable; FULL requires
 * INSTR_WALK_SEGMENT_LISTS=1 at build time. */
#define INSTR_TIER_OFF    0
#define INSTR_TIER_FLOOR  1
#define INSTR_TIER_FULL   2

/* ---------------------------------------------------------------------
 * TASK 1: boot banner.
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
 * TASK 3 state: the sampler.
 * ------------------------------------------------------------------- */
static rt_timer_t     g_instr_timer       = RT_NULL;
static rt_uint32_t    g_instr_interval_ms = INSTR_DEFAULT_INTERVAL_MS;
static rt_uint8_t     g_instr_tier        = INSTR_TIER_FULL;

/* Written by the app thread (attach/detach), read by the soft-timer
 * thread. Both accesses happen while holding the lwIP core lock, so the
 * pointer and its identity fields are consistent as a group. */
static struct tcp_pcb *g_instr_pcb         = RT_NULL;
static rt_uint16_t     g_instr_local_port  = 0;
static rt_uint16_t     g_instr_remote_port = 0;

/* ---------------------------------------------------------------------
 * TASK 4: accumulators. Touched only by the soft-timer thread (sampling)
 * and by the msh thread (reset/dump), never by tcpip_thread.
 * ------------------------------------------------------------------- */
typedef struct
{
    char         run_id[INSTR_RUN_ID_MAX];

    rt_uint32_t  sample_count;        /* samples where the pcb validated */
    rt_uint32_t  stale_count;         /* timer fired, pcb did NOT validate */

    rt_uint32_t  first_sample_tick;   /* rt_tick_get() at first valid sample */
    rt_uint32_t  last_sample_tick;    /* rt_tick_get() at last valid sample */

    /* Timing self-check: extrema of the gap between consecutive valid
     * samples, in ticks. With a nominal interval of N ticks a perfect
     * clock gives gap_min == gap_max == N. These are the instrument for
     * choosing a drift tolerance; no tolerance is applied here. */
    rt_uint32_t  gap_min_ticks;
    rt_uint32_t  gap_max_ticks;

    rt_uint32_t  snd_buf_min;
    rt_uint32_t  snd_buf_max;
    rt_uint64_t  snd_buf_sum;         /* -> mean free snd_buf */
    rt_uint32_t  snd_buf_low_count;   /* samples with snd_buf < threshold (legacy) */
    rt_uint32_t  snd_buf_zero_count;  /* samples with snd_buf EXACTLY 0 */
    rt_uint32_t  snd_buf_ge_write_count; /* samples with snd_buf >= one app write */

    /* Mechanism classification. Mutually exclusive and exhaustive: the three
     * counters sum to sample_count. They map one-to-one onto the three
     * alternatives the research question names (00_project_state.md row 1):
     *   app_limited    snd_buf > 0            -- buffer under-occupied; the
     *                                            application had room and had
     *                                            not filled it
     *   unsent_pending snd_buf == 0, unsent   -- buffer full AND data is queued
     *                                            but not yet transmitted
     *   ack_pending    snd_buf == 0, !unsent  -- buffer full and everything in
     *                                            it is transmitted, awaiting ACKs
     * Parameter-free: the only comparisons are against exact zero and against a
     * null pointer. Note these need the CHEAP unsent boolean only, so the
     * classification is available in the FLOOR tier; FULL adds the byte
     * magnitudes, not the category. */
    rt_uint32_t  mech_app_limited;
    rt_uint32_t  mech_unsent_pending;
    rt_uint32_t  mech_ack_pending;

    /* Retransmission activity, from pcb->nrtx (u8_t, "number of
     * retransmissions" for the segment currently being retried; it is
     * reset on forward progress, so this is an ACTIVITY INDICATOR, not a
     * cumulative retransmitted-segment count -- see 10's notes). */
    rt_uint32_t  nrtx_max;
    rt_uint32_t  nrtx_nonzero_count;

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
    rt_uint32_t  unacked_nonempty_count;
    rt_uint32_t  unacked_bytes_max;
} instr_accum_t;

/* One time-series slot. 16 bytes; deliberately narrow so the ring can be
 * long. tick is absolute rt_tick_get(); the reader differences it. */
typedef struct
{
    rt_uint32_t  tick;
    rt_uint16_t  snd_buf;
    rt_uint16_t  cwnd;
    rt_uint16_t  snd_wnd;
    rt_uint16_t  queuelen;
    rt_uint16_t  unsent_kb16;    /* unsent bytes, saturating at 65535 */
    rt_uint16_t  inflight_kb16;  /* inflight bytes, saturating at 65535 */
} instr_trace_slot_t;

static instr_trace_slot_t g_trace[INSTR_TRACE_SLOTS];
static rt_uint32_t        g_trace_written;   /* total ever written this run */

static instr_accum_t g_accum;

static void instr_accum_reset(const char *run_id)
{
    rt_memset(&g_accum, 0, sizeof(g_accum));
    if (run_id != RT_NULL)
    {
        rt_strncpy(g_accum.run_id, run_id, INSTR_RUN_ID_MAX - 1);
    }
    g_accum.snd_buf_min   = 0xFFFFFFFFu;
    g_accum.cwnd_min      = 0xFFFFu;
    g_accum.snd_wnd_min   = 0xFFFFu;
    g_accum.inflight_min  = 0xFFFFFFFFu;
    g_accum.gap_min_ticks = 0xFFFFFFFFu;
    g_trace_written = 0;
}

#if INSTR_WALK_SEGMENT_LISTS
/* Called with the lwIP core lock HELD -- it dereferences the pcb's
 * segment chain. O(list length); the list is bounded by
 * TCP_SND_QUEUELEN. */
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

/* ---------------------------------------------------------------------
 * The periodic soft-timer callback.
 * ------------------------------------------------------------------- */
static void instr_timer_cb(void *parameter)
{
    /* Locals filled under the core lock, consumed after it is released. */
    int          valid        = 0;
    rt_uint32_t  l_snd_buf    = 0;
    rt_uint16_t  l_queuelen   = 0;
    rt_uint16_t  l_cwnd       = 0;
    rt_uint16_t  l_snd_wnd    = 0;
    rt_uint32_t  l_snd_nxt    = 0;
    rt_uint32_t  l_lastack    = 0;
    int          l_unsent_set = 0;
    rt_uint32_t  l_unsent_len = 0;
    int          l_unacked_set = 0;
    rt_uint32_t  l_unacked_len = 0;
    rt_uint32_t  l_nrtx        = 0;
    rt_uint32_t  l_tick;

    (void)parameter;

    if (g_instr_tier == INSTR_TIER_OFF)
    {
        return;
    }

    LOCK_TCPIP_CORE();
    {
        struct tcp_pcb *target = g_instr_pcb;

        if (target != RT_NULL)
        {
            struct tcp_pcb *p;

            /* Validate against lwIP's own list of active pcbs. A pcb is
             * removed from this list (TCP_RMV_ACTIVE / tcp_pcb_remove)
             * before its memory is returned to the memp pool, so a
             * pointer found here is safe to dereference right now, while
             * we still hold the lock. */
            for (p = tcp_active_pcbs; p != RT_NULL; p = p->next)
            {
                if (p == target)
                {
                    /* Guard against memp recycling handing the same
                     * address to a different connection. */
                    if (p->local_port  == g_instr_local_port &&
                        p->remote_port == g_instr_remote_port)
                    {
                        valid = 1;
                    }
                    break;
                }
            }

            if (valid)
            {
                l_snd_buf  = (rt_uint32_t)target->snd_buf;
                l_queuelen = target->snd_queuelen;
                l_cwnd     = (rt_uint16_t)target->cwnd;
                l_snd_wnd  = (rt_uint16_t)target->snd_wnd;
                l_snd_nxt  = target->snd_nxt;
                l_lastack  = target->lastack;
                l_nrtx     = (rt_uint32_t)target->nrtx;

                l_unsent_set  = (target->unsent  != RT_NULL) ? 1 : 0;
                l_unacked_set = (target->unacked != RT_NULL) ? 1 : 0;
#if INSTR_WALK_SEGMENT_LISTS
                if (g_instr_tier == INSTR_TIER_FULL)
                {
                    if (l_unsent_set)  { l_unsent_len  = instr_sum_seg_len(target->unsent);  }
                    if (l_unacked_set) { l_unacked_len = instr_sum_seg_len(target->unacked); }
                }
#endif
            }
        }
    }
    UNLOCK_TCPIP_CORE();

    /* ---- everything below this line touches no lwIP memory ---- */

    l_tick = (rt_uint32_t)rt_tick_get();

    if (!valid)
    {
        g_accum.stale_count++;
        return;
    }

    if (g_accum.sample_count == 0)
    {
        g_accum.first_sample_tick = l_tick;
    }
    else
    {
        rt_uint32_t gap = l_tick - g_accum.last_sample_tick;
        if (gap < g_accum.gap_min_ticks) { g_accum.gap_min_ticks = gap; }
        if (gap > g_accum.gap_max_ticks) { g_accum.gap_max_ticks = gap; }
    }
    g_accum.last_sample_tick = l_tick;
    g_accum.sample_count++;

    if (l_snd_buf < g_accum.snd_buf_min) { g_accum.snd_buf_min = l_snd_buf; }
    if (l_snd_buf > g_accum.snd_buf_max) { g_accum.snd_buf_max = l_snd_buf; }
    g_accum.snd_buf_sum += l_snd_buf;
    if (l_snd_buf < INSTR_SNDBUF_LOW_THRESHOLD) { g_accum.snd_buf_low_count++; }
    if (l_snd_buf == 0) { g_accum.snd_buf_zero_count++; }
    if (l_snd_buf >= INSTR_APP_WRITE_BYTES) { g_accum.snd_buf_ge_write_count++; }

    if (l_snd_buf > 0)      { g_accum.mech_app_limited++;    }
    else if (l_unsent_set)  { g_accum.mech_unsent_pending++; }
    else                    { g_accum.mech_ack_pending++;    }

    if (l_nrtx > g_accum.nrtx_max) { g_accum.nrtx_max = l_nrtx; }
    if (l_nrtx > 0) { g_accum.nrtx_nonzero_count++; }

    if (l_queuelen > g_accum.snd_queuelen_max) { g_accum.snd_queuelen_max = l_queuelen; }

    if (l_cwnd < g_accum.cwnd_min) { g_accum.cwnd_min = l_cwnd; }
    if (l_cwnd > g_accum.cwnd_max) { g_accum.cwnd_max = l_cwnd; }
    g_accum.cwnd_sum += l_cwnd;

    if (l_snd_wnd < g_accum.snd_wnd_min) { g_accum.snd_wnd_min = l_snd_wnd; }
    if (l_snd_wnd > g_accum.snd_wnd_max) { g_accum.snd_wnd_max = l_snd_wnd; }
    g_accum.snd_wnd_sum += l_snd_wnd;

    /* in-flight = snd_nxt - lastack. Plain unsigned subtraction on u32_t
     * is correct across sequence-number wraparound as long as the true
     * distance is < 2^31 -- always true for a real send window -- the
     * same idiom lwIP itself uses for its TCP_SEQ_LT/GT comparisons. */
    {
        rt_uint32_t inflight = l_snd_nxt - l_lastack;
        if (inflight < g_accum.inflight_min) { g_accum.inflight_min = inflight; }
        if (inflight > g_accum.inflight_max) { g_accum.inflight_max = inflight; }
        g_accum.inflight_sum += inflight;
    }

    if (l_unsent_set)
    {
        g_accum.unsent_nonempty_count++;
        if (l_unsent_len > g_accum.unsent_bytes_max)
        {
            g_accum.unsent_bytes_max = l_unsent_len;
        }
    }
    if (l_unacked_set)
    {
        g_accum.unacked_nonempty_count++;
        if (l_unacked_len > g_accum.unacked_bytes_max)
        {
            g_accum.unacked_bytes_max = l_unacked_len;
        }
    }

    /* Time series. Ring, oldest overwritten; the accumulators above stay
     * complete regardless of how much history the ring holds. */
    {
        instr_trace_slot_t *t = &g_trace[g_trace_written % INSTR_TRACE_SLOTS];
        rt_uint32_t inflight = l_snd_nxt - l_lastack;
        t->tick         = l_tick;
        t->snd_buf      = (rt_uint16_t)l_snd_buf;
        t->cwnd         = l_cwnd;
        t->snd_wnd      = l_snd_wnd;
        t->queuelen     = l_queuelen;
        t->unsent_kb16   = (l_unsent_len > 0xFFFFu) ? 0xFFFFu : (rt_uint16_t)l_unsent_len;
        t->inflight_kb16 = (inflight     > 0xFFFFu) ? 0xFFFFu : (rt_uint16_t)inflight;
        g_trace_written++;
    }
}

/* ---------------------------------------------------------------------
 * TASK 2: fd -> tcp_pcb.
 * ------------------------------------------------------------------- */
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

/* ---------------------------------------------------------------------
 * Timer lifecycle. The timer object is created once, at boot, in the
 * deactivated state, so attach/detach never allocate.
 * ------------------------------------------------------------------- */
static rt_uint32_t instr_interval_ticks(void)
{
    rt_uint32_t ticks = (g_instr_interval_ms * RT_TICK_PER_SECOND) / 1000u;
    if (ticks == 0)
    {
        ticks = 1;   /* one tick = 10 ms at RT_TICK_PER_SECOND=100 */
    }
    return ticks;
}

static int instr_timer_init(void)
{
    rt_uint32_t ticks = instr_interval_ticks();

    g_instr_timer = rt_timer_create("instrsmp",
                                    instr_timer_cb,
                                    RT_NULL,
                                    ticks,
                                    RT_TIMER_FLAG_SOFT_TIMER | RT_TIMER_FLAG_PERIODIC);
    if (g_instr_timer == RT_NULL)
    {
        rt_kprintf("instr: FATAL rt_timer_create failed; sampler unavailable\n");
        return -RT_ENOMEM;
    }
    instr_accum_reset(RT_NULL);
    return 0;
}
INIT_APP_EXPORT(instr_timer_init);

void instr_attach_client_socket(int fd)
{
    struct tcp_pcb *pcb;

    if (g_instr_timer == RT_NULL)
    {
        rt_kprintf("instr: no timer object, sampler not armed\n");
        return;
    }

    /* Idempotent re-arm: a previous cycle may have left the timer
     * running (e.g. an abrupt teardown path that skipped detach). */
    rt_timer_stop(g_instr_timer);

    pcb = instr_pcb_from_fd(fd);
    if (pcb == RT_NULL)
    {
        rt_kprintf("instr: could not resolve fd %d to a tcp_pcb, sampler not armed\n", fd);
        return;
    }

    /* Record pointer and identity as one group, under the core lock, so
     * the timer thread never sees a half-updated target. */
    LOCK_TCPIP_CORE();
    g_instr_pcb         = pcb;
    g_instr_local_port  = pcb->local_port;
    g_instr_remote_port = pcb->remote_port;
    UNLOCK_TCPIP_CORE();

    /* Tier OFF means the timer is not started at all -- not "started but
     * returns early". Only then is the OFF arm a genuine no-instrument
     * baseline for the perturbation comparison: no soft-timer thread
     * wakeups, no core-lock acquisitions, no scheduler activity at all
     * attributable to sampling. */
    if (g_instr_tier == INSTR_TIER_OFF)
    {
        rt_kprintf("instr: tier=off, timer NOT started (fd=%d)\n", fd);
        return;
    }

    {
        rt_uint32_t ticks = instr_interval_ticks();
        rt_timer_control(g_instr_timer, RT_TIMER_CTRL_SET_TIME, &ticks);
        rt_timer_start(g_instr_timer);
        rt_kprintf("instr: sampler armed on fd=%d interval=%ums (%u ticks) tier=%d\n",
                   fd, g_instr_interval_ms, ticks, (int)g_instr_tier);
    }
}

void instr_detach_client_socket(int fd)
{
    (void)fd;

    if (g_instr_timer == RT_NULL)
    {
        return;
    }

    /* Stop the clock FIRST. After rt_timer_stop() returns, the callback
     * is not pending; if it happens to be mid-flight it is already past
     * its validation step and working only on locals. Note this is
     * deliberately NOT conditional on re-resolving fd -> pcb: by the
     * time detach runs the socket may already be unusable (host killed
     * the server, connection reset), and the previous design's early
     * return in that case was what left a stale sampler installed. */
    rt_timer_stop(g_instr_timer);

    LOCK_TCPIP_CORE();
    g_instr_pcb         = RT_NULL;
    g_instr_local_port  = 0;
    g_instr_remote_port = 0;
    UNLOCK_TCPIP_CORE();
}

/* ---------------------------------------------------------------------
 * TASK 5: msh commands. These run on the msh thread, so rt_kprintf and
 * formatting here are fine.
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

static int instr_interval(int argc, char **argv)
{
    rt_uint32_t ms;

    if (argc < 2)
    {
        rt_kprintf("instr: interval=%ums (%u ticks, RT_TICK_PER_SECOND=%d)\n",
                   g_instr_interval_ms, instr_interval_ticks(), (int)RT_TICK_PER_SECOND);
        rt_kprintf("Usage: instr_interval <ms>\n");
        return 0;
    }

    ms = (rt_uint32_t)atoi(argv[1]);
    if (ms == 0)
    {
        rt_kprintf("instr: interval must be > 0 ms\n");
        return -1;
    }
    g_instr_interval_ms = ms;

    /* Apply immediately if the sampler is already running. */
    if (g_instr_timer != RT_NULL)
    {
        rt_uint32_t ticks = instr_interval_ticks();
        rt_timer_control(g_instr_timer, RT_TIMER_CTRL_SET_TIME, &ticks);
        rt_kprintf("instr: interval=%ums (%u ticks)\n", g_instr_interval_ms, ticks);
    }
    return 0;
}

static int instr_tier(int argc, char **argv)
{
    static const char *names[] = { "off", "floor", "full" };

    if (argc < 2)
    {
        rt_kprintf("instr: tier=%s (walk_segment_lists compiled=%d)\n",
                   names[g_instr_tier], (int)INSTR_WALK_SEGMENT_LISTS);
        rt_kprintf("Usage: instr_tier <off|floor|full>\n");
        return 0;
    }

    if (rt_strcmp(argv[1], "off") == 0)
    {
        g_instr_tier = INSTR_TIER_OFF;
    }
    else if (rt_strcmp(argv[1], "floor") == 0)
    {
        g_instr_tier = INSTR_TIER_FLOOR;
    }
    else if (rt_strcmp(argv[1], "full") == 0)
    {
#if INSTR_WALK_SEGMENT_LISTS
        g_instr_tier = INSTR_TIER_FULL;
#else
        rt_kprintf("instr: built with INSTR_WALK_SEGMENT_LISTS=0; full tier unavailable\n");
        return -1;
#endif
    }
    else
    {
        rt_kprintf("Usage: instr_tier <off|floor|full>\n");
        return -1;
    }

    rt_kprintf("instr: tier=%s\n", names[g_instr_tier]);
    return 0;
}

/* Print the per-sample time series as CSV, oldest retained first.
 * Usage: instr_trace [stride]   (stride defaults to 1)
 * One rt_kprintf per row, well under RT_CONSOLEBUF_SIZE. */
static int instr_trace(int argc, char **argv)
{
    rt_uint32_t stride = 1;
    rt_uint32_t total, start, i;

    if (argc >= 2)
    {
        stride = (rt_uint32_t)atoi(argv[1]);
        if (stride == 0) { stride = 1; }
    }

    total = g_trace_written;
    if (total == 0)
    {
        rt_kprintf("INSTR_TRACE run_id=%s rows=0 (no samples)\n", g_accum.run_id);
        return 0;
    }

    /* If the ring wrapped, the oldest retained sample is total-SLOTS. */
    start = (total > INSTR_TRACE_SLOTS) ? (total - INSTR_TRACE_SLOTS) : 0u;

    rt_kprintf("INSTR_TRACE_BEGIN run_id=%s written=%u retained_from=%u stride=%u\n",
               g_accum.run_id, total, start, stride);
    rt_kprintf("n,tick,snd_buf,cwnd,snd_wnd,queuelen,unsent,inflight\n");

    for (i = start; i < total; i += stride)
    {
        instr_trace_slot_t *t = &g_trace[i % INSTR_TRACE_SLOTS];
        rt_kprintf("%u,%u,%u,%u,%u,%u,%u,%u\n",
                   i, t->tick, (rt_uint32_t)t->snd_buf, (rt_uint32_t)t->cwnd,
                   (rt_uint32_t)t->snd_wnd, (rt_uint32_t)t->queuelen,
                   (rt_uint32_t)t->unsent_kb16, (rt_uint32_t)t->inflight_kb16);
    }
    rt_kprintf("INSTR_TRACE_END run_id=%s\n", g_accum.run_id);
    return 0;
}

static int instr_dump(int argc, char **argv)
{
    rt_uint32_t cwnd_mean_x1000 = 0, snd_wnd_mean_x1000 = 0, inflight_mean_x1000 = 0;
    rt_uint32_t snd_buf_mean_x1000 = 0;
    rt_uint32_t span_ticks = 0;
    rt_uint32_t gap_min = 0;

    (void)argc;
    (void)argv;

    if (g_accum.sample_count > 0)
    {
        cwnd_mean_x1000     = (rt_uint32_t)((g_accum.cwnd_sum     * 1000u) / g_accum.sample_count);
        snd_wnd_mean_x1000  = (rt_uint32_t)((g_accum.snd_wnd_sum  * 1000u) / g_accum.sample_count);
        inflight_mean_x1000 = (rt_uint32_t)((g_accum.inflight_sum * 1000u) / g_accum.sample_count);
        snd_buf_mean_x1000  = (rt_uint32_t)((g_accum.snd_buf_sum  * 1000u) / g_accum.sample_count);
        span_ticks          = g_accum.last_sample_tick - g_accum.first_sample_tick;
        gap_min = (g_accum.gap_min_ticks == 0xFFFFFFFFu) ? 0u : g_accum.gap_min_ticks;
    }

    /* RT_CONSOLEBUF_SIZE is 256 bytes in this build (src/kservice.c:
     * static char rt_log_buf[RT_CONSOLEBUF_SIZE]; anything longer is
     * silently truncated by rt_kprintf itself). The full JSON line is
     * longer than that, so it is assembled from several rt_kprintf
     * calls, none containing a newline except the last -- the console
     * still shows one continuous JSON line, just not built by one call. */
    rt_kprintf("{\"run_id\":\"%s\",\"cfg\":{\"TCP_MSS\":%d,\"TCP_SND_BUF\":%d,"
               "\"TCP_SND_QUEUELEN\":%d,\"MEMP_NUM_TCP_SEG\":%d,",
        g_accum.run_id,
        (int)TCP_MSS, (int)TCP_SND_BUF, (int)TCP_SND_QUEUELEN, (int)MEMP_NUM_TCP_SEG);

    rt_kprintf("\"TCP_WND\":%d,\"TCP_OVERSIZE\":%d,\"TCP_SNDLOWAT\":%d,"
               "\"TCP_SNDQUEUELOWAT\":%d,\"LWIP_WND_SCALE\":%d},",
        (int)TCP_WND, (int)TCP_OVERSIZE, (int)TCP_SNDLOWAT,
        (int)TCP_SNDQUEUELOWAT, (int)LWIP_WND_SCALE);

    rt_kprintf("\"sampler\":{\"kind\":\"soft_timer_periodic\",\"interval_ms\":%u,"
               "\"tier\":%d,\"walk_compiled\":%d,\"tick_per_second\":%d},",
        g_instr_interval_ms, (int)g_instr_tier, (int)INSTR_WALK_SEGMENT_LISTS,
        (int)RT_TICK_PER_SECOND);

    rt_kprintf("\"sample_count\":%u,\"stale_count\":%u,\"first_sample_tick\":%u,"
               "\"last_sample_tick\":%u,\"sample_span_ticks\":%u,",
        g_accum.sample_count, g_accum.stale_count,
        g_accum.first_sample_tick, g_accum.last_sample_tick, span_ticks);

    rt_kprintf("\"gap_min_ticks\":%u,\"gap_max_ticks\":%u,\"trace_written\":%u,"
               "\"trace_slots\":%u,\"nrtx_max\":%u,\"nrtx_nonzero_count\":%u,",
        gap_min, g_accum.gap_max_ticks, g_trace_written,
        (rt_uint32_t)INSTR_TRACE_SLOTS, g_accum.nrtx_max, g_accum.nrtx_nonzero_count);

    rt_kprintf("\"snd_buf_min\":%u,\"snd_buf_max\":%u,\"snd_buf_mean_x1000\":%u,"
               "\"snd_buf_low_count\":%u,\"snd_buf_low_threshold\":%u,\"snd_queuelen_max\":%u,",
        g_accum.sample_count ? g_accum.snd_buf_min : 0u, g_accum.snd_buf_max,
        snd_buf_mean_x1000, g_accum.snd_buf_low_count,
        (rt_uint32_t)INSTR_SNDBUF_LOW_THRESHOLD, (rt_uint32_t)g_accum.snd_queuelen_max);

    rt_kprintf("\"cwnd_min\":%u,\"cwnd_max\":%u,\"cwnd_mean_x1000\":%u,"
               "\"snd_wnd_min\":%u,\"snd_wnd_max\":%u,\"snd_wnd_mean_x1000\":%u,",
        g_accum.sample_count ? (rt_uint32_t)g_accum.cwnd_min : 0u,
        (rt_uint32_t)g_accum.cwnd_max, cwnd_mean_x1000,
        g_accum.sample_count ? (rt_uint32_t)g_accum.snd_wnd_min : 0u,
        (rt_uint32_t)g_accum.snd_wnd_max, snd_wnd_mean_x1000);

    rt_kprintf("\"inflight_min\":%u,\"inflight_max\":%u,\"inflight_mean_x1000\":%u,",
        g_accum.sample_count ? g_accum.inflight_min : 0u, g_accum.inflight_max,
        inflight_mean_x1000);

    rt_kprintf("\"snd_buf_zero_count\":%u,\"snd_buf_ge_write_count\":%u,"
               "\"app_write_bytes\":%u,\"mech_app_limited\":%u,"
               "\"mech_unsent_pending\":%u,\"mech_ack_pending\":%u,",
        g_accum.snd_buf_zero_count, g_accum.snd_buf_ge_write_count,
        (rt_uint32_t)INSTR_APP_WRITE_BYTES, g_accum.mech_app_limited,
        g_accum.mech_unsent_pending, g_accum.mech_ack_pending);

    rt_kprintf("\"unsent_nonempty_count\":%u,\"unsent_bytes_max\":%u,"
               "\"unacked_nonempty_count\":%u,\"unacked_bytes_max\":%u,"
               "\"walk_segment_lists\":%d}\n",
        g_accum.unsent_nonempty_count, g_accum.unsent_bytes_max,
        g_accum.unacked_nonempty_count, g_accum.unacked_bytes_max,
        (int)INSTR_WALK_SEGMENT_LISTS);

    return 0;
}

#ifdef FINSH_USING_MSH
#include <finsh.h>
MSH_CMD_EXPORT(instr_reset, zero instrumentation accumulators and store a run id);
MSH_CMD_EXPORT(instr_dump, print one JSON line with run config and accumulators);
MSH_CMD_EXPORT(instr_interval, get or set the periodic sampler interval in ms);
MSH_CMD_EXPORT(instr_tier, get or set the sampling tier off floor or full);
MSH_CMD_EXPORT(instr_trace, print the per-sample time series as CSV with optional stride);
#endif /* FINSH_USING_MSH */
