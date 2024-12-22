#include <rtthread.h>
#include <rtdbg.h>

// Define a buffer for logging
#define LOG_BUFFER_SIZE 1024
static char log_buffer[LOG_BUFFER_SIZE];
static int log_index = 0;

void cpu_intensive_task(void *parameter)
{
    while (1)
    {
        volatile int counter = 0;
        for (int i = 0; i < 10000; i++)
        {
            counter += i;  // An CPU intensive workload
        }
        rt_thread_mdelay(10);  // Simulate periodic workload
    }
}

void custom_log_output(const char *fmt, ...)
{
    va_list args;
    va_start(args, fmt);

    log_index += vsnprintf(&log_buffer[log_index], LOG_BUFFER_SIZE - log_index, fmt, args);

    if (log_index >= LOG_BUFFER_SIZE - 1)
    {
        log_index = 0;  // Reset buffer
    }

    va_end(args);
}

void io_simulation_task(void *parameter)
{
    while (1)
    {
        custom_log_output("Performing I/O operation\n");
        rt_thread_mdelay(30);  // Simulate periodic I/O workload
    }
}

int workload_init(void)
{
    rt_thread_t cpu_task = rt_thread_create(
        "cpu_task",          // Thread name
        cpu_intensive_task,   // Entry function
        RT_NULL,              // Parameter
        1024,                 // Stack size
        8,                   // Priority
        10);                  // Time slice

    if (cpu_task != RT_NULL)
    {
        rt_thread_startup(cpu_task);
    }

    rt_thread_t io_task = rt_thread_create(
        "io_task",          // Thread name
        io_simulation_task,   // Entry function
        RT_NULL,              // Parameter
        1024,                 // Stack size
        9,                   // Priority
        10);                  // Time slice

    if (io_task != RT_NULL)
    {
        rt_thread_startup(io_task);
    }

    return 0;
}
INIT_APP_EXPORT(workload_init);