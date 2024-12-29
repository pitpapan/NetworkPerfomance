#include <rthw.h>
#include <rtthread.h>

void show_cpu_count(void)
{
    rt_kprintf("CPU cores: %d\n", RT_CPUS_NR);
}
MSH_CMD_EXPORT(show_cpu_count, Show CPU core count);