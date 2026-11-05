// SPDX-License-Identifier: MIT
// Hold real compiler completions briefly to observe overlap deterministically.
// The actual Metal library and error are forwarded unchanged to MoltenVK.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#include <atomic>
#include <mutex>
#include <condition_variable>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
extern "C" int vulkan_probe_main(int,char**);
static IMP original;
static std::atomic<unsigned> calls{0}, active{0}, peak{0};
static std::mutex mutex;
static std::condition_variable changed;
static void compile(id self, SEL sel, NSString* source, MTLCompileOptions* options,
                    void (^done)(id<MTLLibrary>, NSError*)) {
    unsigned ordinal=++calls, n=++active, old=peak.load();
    while(old<n && !peak.compare_exchange_weak(old,n)){}
    changed.notify_all();
    using Fn=void (*)(id,SEL,NSString*,MTLCompileOptions*,void (^)(id<MTLLibrary>,NSError*));
    ((Fn)original)(self,sel,source,options,^(id<MTLLibrary> lib,NSError* error){
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
            if(ordinal<=2){std::unique_lock<std::mutex> lock(mutex);
                changed.wait_for(lock,std::chrono::milliseconds(750),[]{return calls.load()>=2;});}
            --active;done(lib,error);
        });
    });
}
int main(int argc,char**argv){@autoreleasepool{
    id<MTLDevice> dev=MTLCreateSystemDefaultDevice();SEL sel=@selector(newLibraryWithSource:options:completionHandler:);
    Method method=class_getInstanceMethod(object_getClass(dev),sel);if(!method)return 2;
    original=method_setImplementation(method,(IMP)compile);
    int rc=vulkan_probe_main(argc,argv);method_setImplementation(method,original);
    const char* policy=getenv("MADEIRA_VK_PARALLEL_SHADER_CACHE");bool enabled=policy && !strcmp(policy,"1");
    printf("OVERLAP enabled=%d compiler-calls=%u peak=%u GPU-result=%d\n",enabled,calls.load(),peak.load(),rc);
    return rc || active || peak!=(enabled?2u:1u);
}}
