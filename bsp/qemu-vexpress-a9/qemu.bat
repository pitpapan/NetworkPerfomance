@echo off
if exist sd.bin goto run
qemu-img create -f raw sd.bin 64M

:run
qemu-system-arm --version
qemu-system-arm -M vexpress-a9 -smp cpus=1 -m 128M -kernel rtthread.bin -serial stdio -sd sd.bin -net nic -net tap,ifname=tap
