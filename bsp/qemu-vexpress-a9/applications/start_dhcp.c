#include <lwip/netifapi.h>
#include <lwip/dhcp.h>
#include <netif/ethernetif.h>

void start_dhcp(void)
{
    struct netif *netif = netif_list;  /* 获取默认网络接口 */

    if (netif)
    {
        rt_kprintf("Starting DHCP on e0...\n");
        dhcp_start(netif);
        rt_kprintf("DHCP started.\n");
    }
    else
    {
        rt_kprintf("Network interface not found!\n");
    }
}
MSH_CMD_EXPORT(start_dhcp, Start DHCP client);
