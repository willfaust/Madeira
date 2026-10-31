/* Cache/GPU handoff on one device, then existing real Windows WSI regression
 * on its own instance/device. No game data, address patches or fake frames.
 * SPDX-License-Identifier: MIT */
#include <stdio.h>
int cache_handoff_main(void);
int vulkan_present_main(void);
int main(void) {
 setvbuf(stdout,NULL,_IONBF,0);
 if(cache_handoff_main())return 2;
 puts("[vk-postcompile] handoff complete; BEGIN separate-device RGB presentation");
 if(vulkan_present_main())return 2;
 puts("[vk-postcompile] PASS cache + Windows handoff + GPU readback + present");return 0;
}
