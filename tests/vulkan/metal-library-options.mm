// SPDX-License-Identifier: MIT
// Observe the real Metal compiler boundary; never replace the compiler/output.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <atomic>
#include <cstdio>
#include <cstdlib>
extern "C" int vulkan_probe_main(int, char**);
static IMP original;
static std::atomic<unsigned> observed{0}, wrong{0};
static MTLLibraryOptimizationLevel expected;
static void compile(id self, SEL sel, NSString* source, MTLCompileOptions* options,
                    void (^done)(id<MTLLibrary>, NSError*)) {
    observed++;
    if (options.optimizationLevel != expected) wrong++;
    using Fn = void (*)(id, SEL, NSString*, MTLCompileOptions*, void (^)(id<MTLLibrary>, NSError*));
    ((Fn)original)(self, sel, source, options, done);
}
int main(int argc, char** argv) { @autoreleasepool {
    const char* policy = getenv("MADEIRA_VK_METAL_LIBRARY_OPTIMIZATION");
    expected = policy && !strcmp(policy, "size") ? MTLLibraryOptimizationLevelSize : MTLLibraryOptimizationLevelDefault;
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    SEL sel = @selector(newLibraryWithSource:options:completionHandler:);
    Method method = class_getInstanceMethod(object_getClass(dev), sel);
    if (!dev || !method) return 2;
    original = method_setImplementation(method, (IMP)compile);
    int result = vulkan_probe_main(argc, argv);
    method_setImplementation(method, original);
    printf("OPTIONS expected=%lu observed=%u wrong=%u GPU-result=%d\n", (unsigned long)expected, observed.load(), wrong.load(), result);
    return result || !observed || wrong ? 1 : 0;
}}
