# 07 — Reproduction Notes

## Git state
- Repository: `~/NetworkPerfomance`
- Branch: `clean-benchmark`
- HEAD commit: `fc586d5` ("adding new shit before P0C")
- Uncommitted changes currently present (must be applied on top of HEAD to reach the state described in this archive):
  - `components/net/lwip/lwip-2.0.3/src/api/sockets.c` (+21 lines: `lwip_get_tcp_pcb()`)
  - `components/net/lwip/lwip-2.0.3/src/include/lwip/sockets.h` (+2 lines: forward decl + prototype)
  - `bsp/qemu-vexpress-a9/applications/instr.c` (new, 350 lines, untracked)
  - `bsp/qemu-vexpress-a9/applications/instr.h` (new, 13 lines, untracked)
  - `bsp/qemu-vexpress-a9/packages/netutils-latest/iperf/iperf.c` (+4 lines: `#include "instr.h"` + two hook calls) — **this file lives under a gitignored path (`packages/`) and is NOT tracked by git at all.** The diff is only preserved in `02_experiment_history.md`/prior session reports and must be manually re-applied if `packages/netutils-latest/` is ever re-cloned.

## Build command
```
cd ~/NetworkPerfomance/bsp/qemu-vexpress-a9
scons -j2
```
Expected clean-baseline result (VERIFIED, this session): `text=762015 data=34248 bss=114284`, zero warnings, `arm-none-eabi-nm rtthread.elf | grep -c '^[0-9a-f]* T iperf$'` → `1`.

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

## Expected boot banner (VERIFIED, current baseline)
```
INSTR_CFG TCP_MSS=1460 TCP_SND_BUF=8196 TCP_SND_QUEUELEN=22 MEMP_NUM_TCP_SEG=40 TCP_WND=2048 TCP_OVERSIZE=1460 TCP_SNDLOWAT=4098 TCP_SNDQUEUELOWAT=11 LWIP_WND_SCALE=0
```
Appears once at boot, after `[I/FileSystem] file system initialization done!` and before the `[W/kernel.service] rt_hw_us_delay()...` warnings (those warnings are pre-existing/harmless, unrelated to this project's changes).

## Current known-good baseline config
`TCP_SND_BUF=8196`, `TCP_SND_QUEUELEN=22`, `MEMP_NUM_TCP_SEG=40` — set via `bsp/qemu-vexpress-a9/rtconfig.h:305-307` (`RT_LWIP_TCP_SEG_NUM`, `RT_LWIP_TCP_SND_BUF`, `RT_LWIP_TCP_SND_QUEUELEN`). A helper reproduces this exactly: `bsp/qemu-vexpress-a9/experiment/scripts/set_config.sh BASE` (VERIFIED — this exact invocation was used to restore baseline in a prior session and rebuilds/verifies via macro dump automatically).

Other named, build-tested configurations available the same way: `set_config.sh {B1|C1|C2|D1|D2}` (values in `00_project_state.md`).

## Known invalid test configurations (do not attempt without changing the matrix)
- `TCP_SND_BUF=32768` with `TCP_SND_QUEUELEN=22` fixed — build FAILS (`#error`, see `01_verified_facts.md` F32).
- `TCP_SND_BUF=65536` (any QUEUELEN/SEG combination satisfying the other constraints) — builds but is wrong at runtime (truncates to 0), excluded from the ladder.
- `TCP_SND_QUEUELEN` set below `2*(TCP_SND_BUF/TCP_MSS)` for the active `TCP_SND_BUF` — build FAILS.
- `MEMP_NUM_TCP_SEG` set below the active `TCP_SND_QUEUELEN` — build FAILS.

## Locations of raw results/logs
- `docs/tfg_evidence/raw_logs/baseline_macro_dump_full.txt` — full baseline `-dM` preprocessor dump (archived this session).
- `docs/tfg_evidence/raw_logs/build_BASE.log` — short baseline build log excerpt.
- `docs/tfg_evidence/raw_logs/host_iperf_server_instr_verify.log` — a host-side `iperf -s` session log from the instrumentation-verification period; **UNKNOWN — NOT RECORDED** whether this corresponds byte-for-byte to any specific quoted Mbps figure in `04_historical_measurements.md` — treat as representative context, not as proof of a specific number.
- `bsp/qemu-vexpress-a9/experiment/manifest.yaml`, `run_matrix.csv` — formal Phase 1 design, all cells pending.
- `bsp/qemu-vexpress-a9/experiment/results.csv` — **does not exist yet.** This is where `collect_run_meta.sh` would append formal run data; it must be created by the first actual formal run.
- Everything else referenced during this session (individual macro dumps for B1/C1/C2/D1/D2, `-Woverflow` warning text, `polltmr` debug trace output) — `UNKNOWN — NOT RECORDED` as a saved file; exists only as conversation output, reconstructed in `01_verified_facts.md`/`02_experiment_history.md` with explicit `SESSION-DERIVED` labels where applicable.
