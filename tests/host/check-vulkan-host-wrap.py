#!/usr/bin/env python3
"""Run vulkan_ios.c's wrapped host entry points against a fake Vulkan library.

Checks that vulkan.c's dlsym hands out the wrapped vkGet*ProcAddr, that a
successful present is counted and a failed one is not, that an acquire's
VK_SUBOPTIMAL_KHR follows ignore_host_suboptimal, and that a submit waits while
Madeira is inactive. VULKAN_INCLUDE points at Vulkan headers, as for
check-vulkan-static.py. Not a GPU or MoltenVK test.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
adapter = (root / 'build/win32u-unix/vulkan_ios.c').read_text()
assert '#define dlsym madeira_vulkan_host_sym' in adapter
start = adapter.index('extern int madeira_app_active( void );')
wrappers = adapter[start:adapter.index('#include "vulkan_surface_ios.c"')]
headers = os.environ.get('VULKAN_INCLUDE', str(root / 'toolchains/moltenvk/MoltenVK/include'))
prelude = r'''
#include <vulkan/vulkan.h>
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
static int active = 1, presents, ignore = 1, submits;
static VkResult present_result, acquire_result;
int madeira_app_active(void) { return __atomic_load_n(&active, __ATOMIC_SEQ_CST); }
void madeira_note_vulkan_present(void) { presents++; }
static int ignore_host_suboptimal(void) { return ignore; }
static VKAPI_ATTR VkResult VKAPI_CALL submit(VkQueue q, uint32_t n, const VkSubmitInfo *s, VkFence f)
{ __atomic_add_fetch(&submits, 1, __ATOMIC_SEQ_CST); return VK_SUCCESS; }
static VKAPI_ATTR VkResult VKAPI_CALL present(VkQueue q, const VkPresentInfoKHR *p) { return present_result; }
static VKAPI_ATTR VkResult VKAPI_CALL acquire(VkDevice d, VkSwapchainKHR s, uint64_t t, VkSemaphore m, VkFence f, uint32_t *i)
{ *i = 1; return acquire_result; }
static VKAPI_ATTR VkResult VKAPI_CALL acquire2(VkDevice d, const VkAcquireNextImageInfoKHR *a, uint32_t *i)
{ *i = 2; return acquire_result; }
static void other(void) {}
static PFN_vkVoidFunction lookup(const char *n)
{
    if (!strcmp(n, "vkQueueSubmit")) return (PFN_vkVoidFunction)submit;
    if (!strcmp(n, "vkQueuePresentKHR")) return (PFN_vkVoidFunction)present;
    if (!strcmp(n, "vkAcquireNextImageKHR")) return (PFN_vkVoidFunction)acquire;
    if (!strcmp(n, "vkAcquireNextImage2KHR")) return (PFN_vkVoidFunction)acquire2;
    if (!strcmp(n, "vkCmdDraw")) return other;
    return NULL;
}
static VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL gipa(VkInstance i, const char *n) { return lookup(n); }
static VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL gdpa(VkDevice d, const char *n) { return lookup(n); }
static char library;
static void *ios_vulkan_sym(void *handle, const char *name)
{
    assert(handle == &library);
    if (!strcmp(name, "vkGetInstanceProcAddr")) return (void *)gipa;
    if (!strcmp(name, "vkGetDeviceProcAddr")) return (void *)gdpa;
    return NULL;
}
'''
tests = r'''
static void *background_submit(void *arg)
{
    PFN_vkQueueSubmit s = (PFN_vkQueueSubmit)arg;
    assert(s(0, 0, 0, 0) == VK_SUCCESS);
    return NULL;
}
int main(void)
{
    PFN_vkGetInstanceProcAddr gi = (PFN_vkGetInstanceProcAddr)madeira_vulkan_host_sym(&library, "vkGetInstanceProcAddr");
    PFN_vkGetDeviceProcAddr gd = (PFN_vkGetDeviceProcAddr)madeira_vulkan_host_sym(&library, "vkGetDeviceProcAddr");
    assert(gi && gi != (PFN_vkGetInstanceProcAddr)gipa && gd && gd != (PFN_vkGetDeviceProcAddr)gdpa);
    assert(!madeira_vulkan_host_sym(&library, "vkCreateInstance"));
    assert(gd(0, "vkCmdDraw") == other && !gd(0, "vkQueueSubmit2"));
    PFN_vkQueuePresentKHR p = (PFN_vkQueuePresentKHR)gd(0, "vkQueuePresentKHR");
    assert(p && p != present && (PFN_vkQueuePresentKHR)gi(0, "vkQueuePresentKHR") == p);
    VkPresentInfoKHR info = {.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR};
    present_result = VK_SUCCESS; assert(p(0, &info) == VK_SUCCESS && presents == 1);
    present_result = VK_SUBOPTIMAL_KHR; assert(p(0, &info) == VK_SUBOPTIMAL_KHR && presents == 2);
    present_result = VK_ERROR_OUT_OF_DATE_KHR; assert(p(0, &info) == VK_ERROR_OUT_OF_DATE_KHR && presents == 2);
    PFN_vkAcquireNextImageKHR a = (PFN_vkAcquireNextImageKHR)gd(0, "vkAcquireNextImageKHR");
    PFN_vkAcquireNextImage2KHR a2 = (PFN_vkAcquireNextImage2KHR)gd(0, "vkAcquireNextImage2KHR");
    VkAcquireNextImageInfoKHR ai = {.sType = VK_STRUCTURE_TYPE_ACQUIRE_NEXT_IMAGE_INFO_KHR};
    uint32_t index = 0;
    acquire_result = VK_SUBOPTIMAL_KHR;
    assert(a(0, 0, 0, 0, 0, &index) == VK_SUCCESS && index == 1);
    assert(a2(0, &ai, &index) == VK_SUCCESS && index == 2);
    ignore = 0;
    assert(a(0, 0, 0, 0, 0, &index) == VK_SUBOPTIMAL_KHR && a2(0, &ai, &index) == VK_SUBOPTIMAL_KHR);
    ignore = 1;
    acquire_result = VK_ERROR_OUT_OF_DATE_KHR; assert(a(0, 0, 0, 0, 0, &index) == VK_ERROR_OUT_OF_DATE_KHR);
    acquire_result = VK_TIMEOUT; assert(a2(0, &ai, &index) == VK_TIMEOUT);
    PFN_vkQueueSubmit s = (PFN_vkQueueSubmit)gd(0, "vkQueueSubmit");
    pthread_t thread;
    active = 0;
    assert(!pthread_create(&thread, NULL, background_submit, (void *)s));
    usleep(100000);
    assert(__atomic_load_n(&submits, __ATOMIC_SEQ_CST) == 0);
    __atomic_store_n(&active, 1, __ATOMIC_SEQ_CST);
    assert(!pthread_join(thread, NULL) && submits == 1);
    return 0;
}
'''
with tempfile.TemporaryDirectory(prefix='madeira-vk-wrap-') as tmp:
    c = Path(tmp) / 'check.c'
    exe = Path(tmp) / 'check'
    c.write_text(prelude + wrappers + tests)
    subprocess.run([os.environ.get('CC', 'cc'), '-std=gnu11', '-Wall', '-Werror', '-Wno-unused-function',
                    '-fsanitize=address,undefined', '-pthread', '-I' + headers, str(c), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
print('PASS: wrapped vkGet*ProcAddr, present counting, acquire VK_SUBOPTIMAL_KHR handling and the '
      'inactive-app wait (not a GPU test)')
