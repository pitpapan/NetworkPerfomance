#!/bin/bash
# Dump the FULL set of preprocessor macros exactly as the real build sees them,
# by re-running the same compiler/flags scons uses on a real lwIP TCP source
# file (tcp_out.c), with -E -dM instead of -c. This is compile-time ground
# truth, not a guess from reading rtconfig.h/lwipopts.h.
#
# Usage: dump_macros.sh            (dumps everything)
#        dump_macros.sh | grep ... (caller filters as needed)
set -euo pipefail

BSP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RTT_ROOT="$(cd "$BSP_DIR/../.." && pwd)"
cd "$BSP_DIR"

arm-none-eabi-gcc -E -dM \
  -march=armv7-a -mtune=cortex-a7 -ftree-vectorize -ffast-math -funwind-tables -fno-strict-aliasing -msoft-float \
  -Wall -Wno-cpp -std=gnu99 -D_POSIX_SOURCE -fdiagnostics-color=always -O0 -gdwarf-2 \
  -D__RTTHREAD__ -DRT_USING_NEWLIBC -DRT_USING_LIBC -D_POSIX_C_SOURCE=1 \
  -I. -Idrivers -Iapplications \
  -I"$RTT_ROOT/include" \
  -I"$RTT_ROOT/libcpu/arm/common" \
  -I"$RTT_ROOT/libcpu/arm/cortex-a" \
  -I"$RTT_ROOT/components/utilities/resource" \
  -I"$RTT_ROOT/components/utilities/libadt/ref" \
  -I"$RTT_ROOT/components/utilities/libadt/bitmap" \
  -I"$RTT_ROOT/components/utilities/libadt/hashmap" \
  -I"$RTT_ROOT/components/utilities/libadt/avl" \
  -I"$RTT_ROOT/components/utilities/libadt/uthash" \
  -I"$RTT_ROOT/components/finsh" \
  -I"$RTT_ROOT/components/libc/posix/ipc" \
  -I"$RTT_ROOT/components/libc/posix/delay" \
  -I"$RTT_ROOT/components/libc/posix/io/aio" \
  -I"$RTT_ROOT/components/libc/posix/io/eventfd" \
  -I"$RTT_ROOT/components/libc/posix/io/stdio" \
  -I"$RTT_ROOT/components/libc/posix/io/termios" \
  -I"$RTT_ROOT/components/libc/posix/io/epoll" \
  -I"$RTT_ROOT/components/libc/posix/io/poll" \
  -I"$RTT_ROOT/components/libc/compilers/newlib" \
  -I"$RTT_ROOT/components/libc/compilers/common/include" \
  -I"$RTT_ROOT/components/legacy" \
  -I"$RTT_ROOT/components/legacy/dfs" \
  -I"$RTT_ROOT/components/dfs/dfs_v2/include" \
  -I"$RTT_ROOT/components/dfs/dfs_v2/filesystems/tmpfs" \
  -I"$RTT_ROOT/components/dfs/dfs_v2/filesystems/devfs" \
  -I"$RTT_ROOT/components/dfs/dfs_v2/filesystems/romfs" \
  -I"$RTT_ROOT/components/dfs/dfs_v2/filesystems/mqueue" \
  -I"$RTT_ROOT/components/dfs/dfs_v2/filesystems/elmfat" \
  -I"$RTT_ROOT/components/net/lwip/port" \
  -I"$RTT_ROOT/components/net/lwip/lwip-2.0.3/src/include" \
  -I"$RTT_ROOT/components/net/lwip/lwip-2.0.3/src/include/ipv4" \
  -I"$RTT_ROOT/components/net/lwip/lwip-2.0.3/src/include/netif" \
  -I"$RTT_ROOT/components/net/sal/include" \
  -I"$RTT_ROOT/components/net/sal/include/socket" \
  -I"$RTT_ROOT/components/net/sal/impl" \
  -I"$RTT_ROOT/components/net/sal/include/dfs_net" \
  -I"$RTT_ROOT/components/net/sal/include/socket/sys_socket" \
  -I"$RTT_ROOT/components/net/utest" \
  -I"$RTT_ROOT/components/net/netdev/include" \
  -I"$RTT_ROOT/components/mm" \
  -I"$RTT_ROOT/components/drivers/include" \
  -I"$RTT_ROOT/components/drivers/phy" \
  -I"$RTT_ROOT/components/drivers/ktime" \
  -I"$RTT_ROOT/components/drivers/ktime/inc" \
  -I"$RTT_ROOT/components/drivers/smp_call" \
  -I"$RTT_ROOT/components/drivers/spi" \
  -I"$RTT_ROOT/components/drivers/spi/sfud/inc" \
  "$RTT_ROOT/components/net/lwip/lwip-2.0.3/src/core/tcp_out.c"
