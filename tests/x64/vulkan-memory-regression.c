/* Real Vulkan cache memory/lifetime regression entry point. SPDX-License-Identifier: MIT */
#include <stdio.h>
int vulkan_cache_budget_main(int argc,char **argv);
int vulkan_cache_specialization_main(int argc,char **argv);
int main(void)
{
    puts("[vk-memory-regression] BEGIN bounded cache and retained GPU pipeline");
    int result=vulkan_cache_budget_main(0,NULL);
    if(result){printf("[vk-memory-regression] FAIL budget result=%d\n",result);return result;}
    puts("[vk-memory-regression] BEGIN merged specialization ownership");
    result=vulkan_cache_specialization_main(0,NULL);
    if(result){printf("[vk-memory-regression] FAIL specialization result=%d\n",result);return result;}
    puts("[vk-memory-regression] PASS real GPU dispatch/readback; no visible color screen is expected");
    return 0;
}
