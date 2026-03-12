if [ ! -f "sd.bin" ]; then
dd if=/dev/zero of=sd.bin bs=1024 count=65536
fi

qemu-system-arm --version
qemu-system-arm -M vexpress-a9 -kernel rtthread.elf -nographic -sd sd.bin -net nic -net tap,ifname=tap0,script=no,downscript=no
