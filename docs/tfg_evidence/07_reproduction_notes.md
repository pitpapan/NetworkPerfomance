# 07 — Reproduction Notes

## Git state

- Repository: `~/NetworkPerfomance`
- Branch: `clean-benchmark` (default branch is `main`; the experiment work lives on `clean-benchmark`)

**This document does not record a HEAD commit hash, deliberately.** Two earlier
revisions each named one (`fc586d5`, then `1204b4b`) and both were stale within a
day — a hash written into prose is wrong as soon as the next commit lands, and a
stale hash is worse than none because it reads as authoritative. Obtain it instead:

```
cd ~/NetworkPerfomance
git log --oneline -5          # HEAD and recent ancestry
git status --short            # anything uncommitted
```

The same applies to file line counts and build-size figures: they were previously
written here and went stale for the same reason. Read them from the tree.

### What is and is not under version control

- **Tracked and committed:** the lwIP accessor
  (`components/net/lwip/lwip-2.0.3/src/api/sockets.c`,
  `.../src/include/lwip/sockets.h` — `lwip_get_tcp_pcb()`), and the instrumentation
  (`bsp/qemu-vexpress-a9/applications/instr.c`, `instr.h`).
- **NOT tracked, and the one artefact genuinely at risk:**
  `bsp/qemu-vexpress-a9/packages/netutils-latest/iperf/iperf.c`. It lives under the
  gitignored `packages/` path, so git does not see it at all. It carries three
  hand-applied edits — an `#include "instr.h"`, an `instr_attach_client_socket(sock)`
  immediately after the successful `connect()`, and an
  `instr_detach_client_socket(sock)` immediately before `closesocket()`. **These must
  be re-applied by hand if `packages/netutils-latest/` is ever re-cloned.** Verify
  with:

```
grep -n instr bsp/qemu-vexpress-a9/packages/netutils-latest/iperf/iperf.c
```

  Three hits is correct. Zero hits means the hooks are gone and the sampler will
  never arm, which presents as `sample_count=0` — indistinguishable at a glance from
  the old `tcp_poll` failure, so check this first if samples go missing.

## Build command
```
cd ~/NetworkPerfomance/bsp/qemu-vexpress-a9
scons -j2
```
Expected result: zero warnings, and `iperf` exported exactly once:

```
arm-none-eabi-nm rtthread.elf | grep -c '^[0-9a-f]* T iperf$'    # must print 1
arm-none-eabi-size rtthread.elf                                   # record, do not compare to a number in this file
```

No `text`/`data`/`bss` figures are quoted here. They move with every instrumentation
change, and earlier revisions of this document quoted figures that were stale within
a day. The per-configuration build logs under `raw_logs/` are the record; compare a
new build against the log for the *same* configuration and instrumentation revision,
not against prose.

## QEMU invocation
VERIFIED — used repeatedly and successfully this session:
```
qemu-system-arm -M vexpress-a9 -kernel rtthread.elf -nographic \
  -drive file=sd.bin,format=raw,if=sd -audio none \
  -net nic -net tap,ifname=tap0,script=no,downscript=no
```
Typically run inside a detached `tmux` session (e.g. `tmux new-session -d -s rtt_instr -x 220 -y 50 "<command above>"`) so it can be scripted from the host shell via `tmux send-keys`/`tmux capture-pane`.

## Network topology
- Host `tap0`: `192.168.10.1/24`
- RT-Thread: `192.168.10.2/24`, static, DHCP disabled
- `netem` location and direction: `tap0` **root** qdisc (replaces default entirely, never stacked with `fq_codel`), delays **host egress only** — i.e. packets leaving the host toward the VM. For RT-Thread→Ubuntu transfers this means the returning ACKs are delayed, not the outbound DATA.
- Apply/verify (requires `sudo`, interactive or piped password — **do not hardcode a password in any script or committed file**):
  ```
  sudo tc qdisc replace dev tap0 root netem delay <X>ms
  tc qdisc show dev tap0
  tc -s qdisc show dev tap0
  ```
  A helper exists: `bsp/qemu-vexpress-a9/experiment/scripts/set_netem.sh <delay_ms>` — VERIFIED working this session (tested at 50ms).

## iperf commands (VERIFIED, adopted direction)
```
# Ubuntu (receiver):
iperf -s -p 5001 -i 1

# RT-Thread msh (sender):
iperf -c 192.168.10.1 -p 5001
```
Stop cleanly with `iperf --stop` on the RT-Thread `msh` console. **Must be GNU `iperf` 2.x on the host, not `iperf3`** — the netutils implementation speaks a raw byte-stream, not iperf3's JSON control protocol; both are installed on the host (`iperf` 2.1.9 and `iperf3` 3.16 confirmed present), only `iperf` is protocol-relevant here.

## Instrumentation commands (VERIFIED)
```
msh> instr_reset <run_id>     # zero accumulators, store run_id
msh> instr_dump               # print one JSON line (split across 5 rt_kprintf calls internally)
```

## Expected boot banner

The banner prints the macros directly, so it differs per configuration. Appears once at boot, after `[I/FileSystem] file system initialization done!` and before the `[W/kernel.service] rt_hw_us_delay()...` warnings (those warnings are pre-existing/harmless, unrelated to this project's changes).

**`STOCK` (OBSERVED — this is the one that was actually captured):**
```
INSTR_CFG TCP_MSS=1460 TCP_SND_BUF=8196 TCP_SND_QUEUELEN=22 MEMP_NUM_TCP_SEG=40 TCP_WND=2048 TCP_OVERSIZE=1460 TCP_SNDLOWAT=4098 TCP_SNDQUEUELOWAT=11 LWIP_WND_SCALE=0
```

**`L0` (PREDICTED from the archived `macro_dump_L0.txt`, not yet captured at boot):**
```
INSTR_CFG TCP_MSS=1460 TCP_SND_BUF=8196 TCP_SND_QUEUELEN=44 MEMP_NUM_TCP_SEG=44 TCP_WND=2048 TCP_OVERSIZE=1460 TCP_SNDLOWAT=4098 TCP_SNDQUEUELOWAT=22 LWIP_WND_SCALE=0
```
`L1` and `L2` differ only in `TCP_SND_BUF` (16384 / 32768) and `TCP_SNDLOWAT` (8192 / 16384).

> No boot-banner console output has ever been saved to a file — the `STOCK` line above is a transcription. Capture one per configuration on the first Phase 1 boot; it is the cheapest possible per-run proof that the firmware under test is the firmware intended.

## Current known-good baseline config
**`L0` = `TCP_SND_BUF=8196`, `TCP_SND_QUEUELEN=44`, `MEMP_NUM_TCP_SEG=44`, `TCP_WND=2048`** — the pinned anchor of the ladder. Set via `bsp/qemu-vexpress-a9/experiment/scripts/set_config.sh L0`, which edits `rtconfig.h` **and** `.config` together, rebuilds, verifies the effective values via the compiler's own preprocessor, checks `iperf` is linked exactly once, and archives the build log plus full macro dump under `docs/tfg_evidence/raw_logs/`. VERIFIED 2026-09-29.

> Note: `TCP_WND` is now pinned by the script in both files. A prior desync (`rtconfig.h` = 2048, `.config` = 8196) meant any `menuconfig` run would have silently regenerated `rtconfig.h` with a different receive window mid-sweep. Fixed.

Other named, build-verified configurations available the same way: `set_config.sh {L1|L2|STOCK|PINNED}`. `L1` = 16384/44/44, `L2` = 32768/44/44, `STOCK` = 8196/22/40 (the shipped, unpinned config, used only as the pinning-control arm), `PINNED` = alias of `L0`. All five were built 2026-09-29 with zero warnings; logs and macro dumps are in `raw_logs/`.

## Known invalid test configurations (do not attempt without changing the matrix)
- `TCP_SND_BUF=32768` **with `TCP_SND_QUEUELEN=22`** — build FAILS (`#error`, `01_verified_facts.md` F32). At the pinned `QUEUELEN=44`/`SEG=44` it builds cleanly; the value was never the problem, the fixed QUEUELEN was. (`L2` is exactly this point.)
- `TCP_SND_BUF=65536` (any QUEUELEN/SEG combination satisfying the other constraints) — builds but is wrong at runtime (truncates to 0), excluded from the ladder.
- `TCP_SND_QUEUELEN` set below `2*(TCP_SND_BUF/TCP_MSS)` for the active `TCP_SND_BUF` — build FAILS.
- `MEMP_NUM_TCP_SEG` set below the active `TCP_SND_QUEUELEN` — build FAILS.

## Locations of raw results/logs
- `docs/tfg_evidence/raw_logs/baseline_macro_dump_full.txt` — full baseline `-dM` preprocessor dump (archived this session).
- `docs/tfg_evidence/raw_logs/build_{L0,L1,L2,STOCK}.log` — full `scons -j2` build logs (182 compiled objects each, zero warnings, `size` output appended), one per configuration, 2026-09-29.
- `docs/tfg_evidence/raw_logs/macro_dump_{L0,L1,L2,STOCK}.txt` — full `-dM` preprocessor dumps, one per configuration, proving the effective compiled values.
- `docs/tfg_evidence/raw_logs/build_BASE.log` — **superseded and not evidence.** Contains only `scons: '.' is up to date` (a no-op invocation with zero compiler output); it cannot support any "builds cleanly" claim. Retained only so its earlier citations remain traceable.
- `docs/tfg_evidence/raw_logs/host_iperf_server_instr_verify.log` — a host-side `iperf -s` session log from the instrumentation-verification period; **UNKNOWN — NOT RECORDED** whether this corresponds byte-for-byte to any specific quoted Mbps figure in `04_historical_measurements.md` — treat as representative context, not as proof of a specific number.
- `bsp/qemu-vexpress-a9/experiment/manifest.yaml`, `run_matrix.csv` — formal Phase 1 design, all cells pending.
- `bsp/qemu-vexpress-a9/experiment/results.csv` — **does not exist yet.** This is where `collect_run_meta.sh` would append formal run data; it must be created by the first actual formal run.
- Per-configuration macro dumps are now archived for every Phase 1 configuration (`macro_dump_{L0,L1,L2,STOCK}.txt`). The old `B1/C1/C2/D1/D2` dumps were never saved and are moot — those configurations are superseded.
- Still `UNKNOWN — NOT RECORDED` as a saved file: the `-Woverflow` warning text for `TCP_SND_BUF=65536`, the `polltmr` debug trace output, and any boot-banner console capture. These exist only as conversation output, reconstructed in `01_verified_facts.md`/`02_experiment_history.md` with explicit `SESSION-DERIVED` labels. Re-capture the `-Woverflow` text before quoting it verbatim in the thesis.
