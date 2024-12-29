#include <rthw.h>
#include <rtthread.h>

#define CLK_CTRL_ADDR 0x10000000  // 示例地址，具体请查阅文档

void show_cpu_freq(void)
{
    rt_tick_t start_tick, end_tick;
    uint32_t delay_ms = 1000; // 延迟 1000ms

    start_tick = rt_tick_get();
    rt_thread_mdelay(delay_ms); // 延迟一秒
    end_tick = rt_tick_get();

    uint32_t ticks = end_tick - start_tick;
    uint32_t tick_freq = RT_TICK_PER_SECOND; // 系统每秒的 Tick 数
    uint32_t clock_freq = tick_freq * delay_ms;

    rt_kprintf("Measured Clock Frequency: %u Hz\n", clock_freq);
}
MSH_CMD_EXPORT(show_cpu_freq, Show CPU frequency);
