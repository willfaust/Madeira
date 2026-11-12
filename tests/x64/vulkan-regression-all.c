/* Run the existing unmodified Vulkan tests in one Windows x64 process.
 * SPDX-License-Identifier: MIT
 */
#include <stdio.h>
int vulkan_clear_main(void);
int vulkan_vertex_cache_main(void);
int vulkan_present_main(void);
int vulkan_cache_export_main(void);
int vulkan_vertex_reuse_main(void);
int main(void)
{
    puts("[vk-regression-all] BEGIN real GPU enumeration and clear/readback");
    int result = vulkan_clear_main();
    if (result) { printf("[vk-regression-all] FAIL clear/readback result=%d\n", result); return result; }
    puts("[vk-regression-all] BEGIN vertex-layout cache isolation");
    result = vulkan_vertex_cache_main();
    if (result) { printf("[vk-regression-all] FAIL vertex cache result=%d\n", result); return result; }
    puts("[vk-regression-all] BEGIN complete vertex-input cache reuse");
    result = vulkan_vertex_reuse_main();
    if (result) { printf("[vk-regression-all] FAIL vertex reuse result=%d\n", result); return result; }
    puts("[vk-regression-all] BEGIN direct cache export");
    result = vulkan_cache_export_main();
    if (result) { printf("[vk-regression-all] FAIL cache export result=%d\n", result); return result; }
    puts("[vk-regression-all] BEGIN two visible RGB presentation rounds");
    result = vulkan_present_main();
    if (result) { printf("[vk-regression-all] FAIL presentation result=%d\n", result); return result; }
    puts("[vk-regression-all] PASS API/results/readback; visible RGB still requires user confirmation");
    return 0;
}
