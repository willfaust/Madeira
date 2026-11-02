// The extension memory experiment, Madeira's side (see MemoryHostProtocol.h).
//
// Run 2 (2026-09-29): memory OWNED by the MadeiraMemoryHost extension is billed
// to the extension even when Madeira writes it. Run 3: once the extension has
// exited, that memory is billed to nobody and keeps its data (3.5 GB, every word
// checked). Run 4, the pressure test with random data: clean to 8.5 GB, no
// disk swap, then the system ran out of pages and killed Madeira
// (memory-vmpage-shortage) at ~9 GB. Run 5, the same with data that compresses
// about 2:1: clean to 14.5 GB (the compressor held 15.1 GB in 8.5 GB), killed
// at ~15 GB.
//
// This run (6) measures reading such memory back once iOS has compressed it:
// the extension creates 22 x 512 MB (11 GB) of owned regions and exits; Madeira
// writes 4 GB (the cold set) and then 7 GB more, which in run 5 was past the
// point where the compressor took over. Then it reads the cold set back:
// regions 0-3 sequentially (throughput) and 1024 random pages in each of
// regions 4-7 (the cost of one page fault), with the kernel's decompression
// counter around each read to show how much really came out of the compressor.
// The last region written is read as the uncompressed baseline, and every
// region is verified at the end.

#import "MemoryHostTest.h"
#import "MemoryHostProtocol.h"
#import <mach/mach.h>
#import <os/proc.h>
#import <stdio.h>
#import <sys/sysctl.h>

@protocol MHExtensionClass
+ (id)extensionWithIdentifier:(NSString *)identifier error:(NSError **)error;
@end

@protocol MHExtension
- (void)beginExtensionRequestWithInputItems:(NSArray *)items completion:(void (^)(NSUUID *identifier))completion;
- (int)pidForRequestIdentifier:(NSUUID *)identifier;
- (void)cancelExtensionRequestWithIdentifier:(NSUUID *)identifier;
- (void)setRequestCancellationBlock:(void (^)(NSUUID *identifier, NSError *error))block;
- (void)setRequestInterruptionBlock:(void (^)(NSUUID *identifier))block;
@end

@interface MHListenerDelegate : NSObject <NSXPCListenerDelegate, MHMemoryClient>
@property (strong) NSXPCConnection *connection;
@property (strong) dispatch_semaphore_t connected;
@end

@implementation MHListenerDelegate
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection {
    connection.remoteObjectInterface = MHMemoryServerInterface();
    connection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(MHMemoryClient)];
    connection.exportedObject = self;
    [connection resume];
    self.connection = connection;
    dispatch_semaphore_signal(self.connected);
    return YES;
}
- (void)extensionReady:(int)pid available:(uint64_t)available {
    NSLog(@"[memhost] extension %d ready, %llu MB available", pid, available >> 20);
}
@end

static const int64_t MHTimeout = 20 * NSEC_PER_SEC;
static const uint64_t MB = 1 << 20;

static uint64_t mh_footprint(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
    return info.phys_footprint;
}

/// The whole system's free, compressed and swapped memory, and the lifetime
/// compression and swap counters.
static NSString *mh_system(void) {
    vm_statistics64_data_t vm;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &count) != KERN_SUCCESS) return @"system ?";
    uint64_t page = vm_kernel_page_size;
    struct xsw_usage swap = {0};
    size_t swapSize = sizeof swap;
    BOOL haveSwap = sysctlbyname("vm.swapusage", &swap, &swapSize, NULL, 0) == 0;
    return [NSString stringWithFormat:@"free %llu MB, compressor holds %llu MB in %llu MB, swap %@, compressions %llu, swapouts %llu, swapins %llu",
            (uint64_t)vm.free_count * page / MB, (uint64_t)vm.total_uncompressed_pages_in_compressor * page / MB,
            (uint64_t)vm.compressor_page_count * page / MB,
            haveSwap ? [NSString stringWithFormat:@"%llu/%llu MB", swap.xsu_used / MB, swap.xsu_total / MB] : @"n/a",
            vm.compressions, vm.swapouts, vm.swapins];
}

/// Lifetime count of pages the kernel has decompressed.
static uint64_t mh_decompressions(void) {
    vm_statistics64_data_t vm;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &count) != KERN_SUCCESS) return 0;
    return vm.decompressions;
}

typedef struct { BOOL ok; int pid; uint64_t footprint, available; } MHStatus;

static MHStatus mh_status(NSXPCConnection *connection) {
    __block MHStatus status = {0};
    dispatch_semaphore_t reply = dispatch_semaphore_create(0);
    id<MHMemoryServer> proxy = [connection remoteObjectProxyWithErrorHandler:^(NSError *error) { dispatch_semaphore_signal(reply); }];
    [proxy statusWithReply:^(int pid, uint64_t footprint, uint64_t available) {
        status = (MHStatus){YES, pid, footprint, available};
        dispatch_semaphore_signal(reply);
    }];
    if (dispatch_semaphore_wait(reply, dispatch_time(DISPATCH_TIME_NOW, MHTimeout))) return (MHStatus){0};
    return status;
}

typedef struct { BOOL answered; int kr; mach_port_t entry; uint64_t footprint, available; } MHRegion;

static MHRegion mh_create(NSXPCConnection *connection, uint64_t bytes, int kind, BOOL touch) {
    __block MHRegion region = {NO, 0, MACH_PORT_NULL, 0, 0};
    dispatch_semaphore_t reply = dispatch_semaphore_create(0);
    id<MHMemoryServer> proxy = [connection remoteObjectProxyWithErrorHandler:^(NSError *error) { dispatch_semaphore_signal(reply); }];
    [proxy createRegion:bytes kind:kind touch:touch reply:^(xpc_object_t handle, int kr, uint64_t footprint, uint64_t available) {
        mach_port_t entry = (kr == KERN_SUCCESS && handle) ? xpc_dictionary_copy_mach_send(handle, "entry") : MACH_PORT_NULL;
        region = (MHRegion){YES, kr, entry, footprint, available};
        dispatch_semaphore_signal(reply);
    }];
    if (dispatch_semaphore_wait(reply, dispatch_time(DISPATCH_TIME_NOW, MHTimeout))) return (MHRegion){NO, 0, MACH_PORT_NULL, 0, 0};
    return region;
}

/// Every 64-bit word gets a value unique to its region and position. Run 5
/// keeps only the low 32 bits: half of every page's 32-bit words are zero,
/// which iOS's memory compressor stores in a couple of bits each, so the data
/// compresses to about half (run 4 used the full 64 bits: random, ~10%).
static inline uint64_t mh_word(uint64_t tag, uint64_t index) { return (tag ^ (index * 0x9E3779B97F4A7C15ull)) & 0xFFFFFFFFull; }

static void mh_fill(uint64_t *words, uint64_t bytes, uint64_t tag) {
    for (uint64_t i = 0, n = bytes / 8; i < n; i++) words[i] = mh_word(tag, i);
}

/// The number of words that do not hold their pattern.
static uint64_t mh_verify(const uint64_t *words, uint64_t bytes, uint64_t tag) {
    uint64_t bad = 0;
    for (uint64_t i = 0, n = bytes / 8; i < n; i++) bad += words[i] != mh_word(tag, i);
    return bad;
}

static long long mh_mb(uint64_t after, uint64_t before) { return ((long long)after - (long long)before) / (long long)MB; }

void MadeiraMemoryHostTest(void (^log)(NSString *line), void (^done)(void)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        // The extension's interruption and cancellation callbacks can arrive after
        // the test has closed the file, on another queue.
        __block FILE *out = fopen([[docs stringByAppendingPathComponent:@"memhost-test.txt"] fileSystemRepresentation], "w");
        NSObject *fileLock = [NSObject new];
        void (^say)(NSString *) = ^(NSString *line) {
            @synchronized (fileLock) {
                if (out) { fprintf(out, "%s\n", line.UTF8String); fflush(out); }
            }
            log(line);
        };
        void (^finish)(void) = ^{
            @synchronized (fileLock) {
                if (out) fclose(out);
                out = NULL;
            }
            done();
        };

        uint64_t ram = 0;
        size_t ramSize = sizeof ram;
        sysctlbyname("hw.memsize", &ram, &ramSize, NULL, 0);
        const uint64_t baseline = mh_footprint();
        say([NSString stringWithFormat:@"Run 6 (read-back from the compressor). Device RAM %llu MB. Madeira pid %d: footprint %llu MB, available %zu MB; %@",
             ram / MB, getpid(), baseline / MB, os_proc_available_memory() / MB, mh_system()]);

        NSString *identifier = [NSBundle.mainBundle.bundleIdentifier stringByAppendingString:@".MemoryHost"];
        Class<MHExtensionClass> extensionClass = (Class<MHExtensionClass>)NSClassFromString(@"NSExtension");
        NSError *error = nil;
        id<MHExtension> extension = [extensionClass extensionWithIdentifier:identifier error:&error];
        if (!extension) {
            say([NSString stringWithFormat:@"No extension %@: %@", identifier, error]);
            finish();
            return;
        }
        dispatch_semaphore_t exited = dispatch_semaphore_create(0);
        [extension setRequestInterruptionBlock:^(NSUUID *uuid) {
            say(@"Extension request INTERRUPTED (the extension exited)");
            dispatch_semaphore_signal(exited);
        }];
        [extension setRequestCancellationBlock:^(NSUUID *uuid, NSError *cancelError) {
            say([NSString stringWithFormat:@"Extension request CANCELLED: %@", cancelError.localizedDescription]);
        }];

        static NSXPCListener *listener;
        static MHListenerDelegate *delegate;
        delegate = [MHListenerDelegate new];
        delegate.connected = dispatch_semaphore_create(0);
        listener = [NSXPCListener anonymousListener];
        listener.delegate = delegate;
        [listener resume];

        NSExtensionItem *item = [NSExtensionItem new];
        item.userInfo = @{ @"endpoint": listener.endpoint };
        dispatch_semaphore_t started = dispatch_semaphore_create(0);
        __block NSUUID *request = nil;
        [extension beginExtensionRequestWithInputItems:@[item] completion:^(NSUUID *uuid) {
            request = uuid;
            dispatch_semaphore_signal(started);
        }];
        if (dispatch_semaphore_wait(started, dispatch_time(DISPATCH_TIME_NOW, MHTimeout)) || !request) {
            say(@"The extension did not start (no request identifier)");
            finish();
            return;
        }
        if (dispatch_semaphore_wait(delegate.connected, dispatch_time(DISPATCH_TIME_NOW, MHTimeout))) {
            say(@"The extension started but never connected back");
            [extension cancelExtensionRequestWithIdentifier:request];
            finish();
            return;
        }
        NSXPCConnection *connection = delegate.connection;
        MHStatus first = mh_status(connection);
        say([NSString stringWithFormat:@"Extension pid %d: footprint %llu MB, available %llu MB", first.pid,
             first.footprint / MB, first.available / MB]);

        // 11 GB of owned regions, created and mapped but not touched.
        enum { Regions = 22, Cold = 8 };
        const uint64_t chunk = 512 * MB;
        const uint64_t page = vm_kernel_page_size;
        mach_vm_address_t address[Regions] = {0};
        mach_port_t entry[Regions] = {0};
        int mapped = 0;
        for (int i = 0; i < Regions; i++) {
            MHRegion region = mh_create(connection, chunk, MHRegionLedgerTagged, NO);
            if (!region.answered || region.kr != KERN_SUCCESS) {
                say([NSString stringWithFormat:@"Region %d: create failed (answered %d, kr %d)", i, region.answered, region.kr]);
                break;
            }
            entry[i] = region.entry;
            kern_return_t kr = mach_vm_map(mach_task_self(), &address[i], chunk, 0, VM_FLAGS_ANYWHERE, region.entry, 0, FALSE,
                                           VM_PROT_READ | VM_PROT_WRITE, VM_PROT_READ | VM_PROT_WRITE, VM_INHERIT_NONE);
            if (kr != KERN_SUCCESS) {
                address[i] = 0;
                say([NSString stringWithFormat:@"Region %d: map kr %d", i, kr]);
                break;
            }
            mapped++;
        }
        id<MHMemoryServer> proxy = [connection remoteObjectProxyWithErrorHandler:^(NSError *e) {}];
        [proxy exitWithReply:^{}];
        BOOL gone = dispatch_semaphore_wait(exited, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0;
        say([NSString stringWithFormat:@"Mapped %d x 512 MB; extension %@. %@", mapped, gone ? @"exited" : @"did NOT report exiting", mh_system()]);

        if (mapped == Regions) {
            CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
            for (int i = 0; i < Cold; i++) mh_fill((uint64_t *)address[i], chunk, 0xD000 + i);
            say([NSString stringWithFormat:@"Cold set: wrote %d x 512 MB in %.2f s. %@", Cold, CFAbsoluteTimeGetCurrent() - t0, mh_system()]);
            t0 = CFAbsoluteTimeGetCurrent();
            for (int i = Cold; i < Regions; i++) mh_fill((uint64_t *)address[i], chunk, 0xD000 + i);
            say([NSString stringWithFormat:@"Filler: wrote %d x 512 MB in %.2f s. Madeira %+lld MB. %@", Regions - Cold,
                 CFAbsoluteTimeGetCurrent() - t0, mh_mb(mh_footprint(), baseline), mh_system()]);
            [NSThread sleepForTimeInterval:3];
            say([NSString stringWithFormat:@"After 3 s: %@", mh_system()]);

            // Uncompressed baseline: the region written last.
            uint64_t d0 = mh_decompressions();
            t0 = CFAbsoluteTimeGetCurrent();
            uint64_t bad = mh_verify((const uint64_t *)address[Regions - 1], chunk, 0xD000 + Regions - 1);
            double seconds = CFAbsoluteTimeGetCurrent() - t0;
            say([NSString stringWithFormat:@"Baseline (last region written): 512 MB read in %.3f s = %.2f GB/s, %llu MB decompressed, %llu bad words",
                 seconds, 0.5 / seconds, (mh_decompressions() - d0) * page / MB, bad]);

            // Sequential read-back of cold regions 0-3.
            for (int i = 0; i < 4; i++) {
                d0 = mh_decompressions();
                t0 = CFAbsoluteTimeGetCurrent();
                bad = mh_verify((const uint64_t *)address[i], chunk, 0xD000 + i);
                seconds = CFAbsoluteTimeGetCurrent() - t0;
                uint64_t decompressedMB = (mh_decompressions() - d0) * page / MB;
                say([NSString stringWithFormat:@"Cold region %d, sequential: 512 MB in %.3f s = %.2f GB/s; %llu MB decompressed (%.2f GB/s of it); %llu bad words",
                     i, seconds, 0.5 / seconds, decompressedMB, decompressedMB / 1024.0 / seconds, bad]);
            }

            // Random single pages in cold regions 4-7: the cost of one fault.
            mach_timebase_info_data_t timebase;
            mach_timebase_info(&timebase);
            for (int i = 4; i < Cold; i++) {
                const uint64_t pages = chunk / page, samples = 1024;
                volatile uint64_t sink = 0;
                uint64_t wrong = 0;
                d0 = mh_decompressions();
                uint64_t start = mach_absolute_time();
                for (uint64_t k = 0; k < samples; k++) {
                    uint64_t p = arc4random_uniform((uint32_t)pages);
                    uint64_t index = p * page / 8;
                    uint64_t value = ((const volatile uint64_t *)address[i])[index];
                    sink += value;
                    wrong += value != mh_word(0xD000 + i, index);
                }
                double us = (double)(mach_absolute_time() - start) * timebase.numer / timebase.denom / 1000.0;
                uint64_t faults = mh_decompressions() - d0;
                say([NSString stringWithFormat:@"Cold region %d, %llu random pages: %.0f us total, %.1f us per page; %llu pages decompressed (%.1f us each if all the time went there); %llu wrong",
                     i, samples, us, us / samples, faults, faults ? us / faults : 0.0, wrong]);
            }

            // Everything, once more.
            uint64_t badAll = 0;
            d0 = mh_decompressions();
            t0 = CFAbsoluteTimeGetCurrent();
            for (int i = 0; i < Regions; i++) badAll += mh_verify((const uint64_t *)address[i], chunk, 0xD000 + i);
            seconds = CFAbsoluteTimeGetCurrent() - t0;
            say([NSString stringWithFormat:@"All 11 GB verified in %.1f s (%.2f GB/s): %llu bad words, %llu MB decompressed. Madeira %+lld MB. %@",
                 seconds, 11.0 / seconds, badAll, (mh_decompressions() - d0) * page / MB, mh_mb(mh_footprint(), baseline), mh_system()]);
        }

        for (int i = 0; i < Regions; i++) {
            if (address[i]) mach_vm_deallocate(mach_task_self(), address[i], chunk);
            if (entry[i]) mach_port_deallocate(mach_task_self(), entry[i]);
        }
        [extension cancelExtensionRequestWithIdentifier:request];
        [connection invalidate];
        say([NSString stringWithFormat:@"Done; mappings released. Madeira %+lld MB; %@", mh_mb(mh_footprint(), baseline), mh_system()]);
        finish();
    });
}
