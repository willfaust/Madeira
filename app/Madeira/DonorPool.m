// ml1150: fills the swap tier's donor pool (virtual_ios.c) before Wine starts.
//
// The MadeiraMemoryHost extension creates owned memory regions without touching
// them, hands their memory entries over and exits. Memory owned by an exited
// task is billed to no process's footprint (runs 2-6 of MemoryHostTest.m), so
// the tier can map guest data from it at RAM speed. A dispatch memory-pressure
// source feeds the tier's guard, which stops taking pool memory under pressure.

#import <Foundation/Foundation.h>
#import "MemoryHostProtocol.h"
#import <signal.h>

int madeira_donor_pool_add(unsigned int entry, unsigned long long size);
void madeira_donor_pool_set_pressure(int level);

@protocol MPExtensionClass
+ (id)extensionWithIdentifier:(NSString *)identifier error:(NSError **)error;
@end
@protocol MPExtension
- (void)beginExtensionRequestWithInputItems:(NSArray *)items completion:(void (^)(NSUUID *identifier))completion;
- (void)cancelExtensionRequestWithIdentifier:(NSUUID *)identifier;
- (void)setRequestInterruptionBlock:(void (^)(NSUUID *identifier))block;
- (int)pidForRequestIdentifier:(NSUUID *)identifier;
- (void)_kill:(int)signal;   // ml1153: NSExtension private; sends the signal to the extension process
@end

@interface MPListener : NSObject <NSXPCListenerDelegate, MHMemoryClient>
@property (strong) NSXPCConnection *connection;
@property (strong) dispatch_semaphore_t connected;
@end
@implementation MPListener
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection {
    connection.remoteObjectInterface = MHMemoryServerInterface();
    connection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(MHMemoryClient)];
    connection.exportedObject = self;
    [connection resume];
    self.connection = connection;
    dispatch_semaphore_signal(self.connected);
    return YES;
}
- (void)extensionReady:(int)pid available:(uint64_t)available {}
@end

static void MPStartPressureSource(void) {
    static dispatch_source_t source;
    source = dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
                                    DISPATCH_MEMORYPRESSURE_NORMAL | DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL,
                                    dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    dispatch_source_set_event_handler(source, ^{
        unsigned long level = dispatch_source_get_data(source);
        madeira_donor_pool_set_pressure(level & DISPATCH_MEMORYPRESSURE_CRITICAL ? 2 : level & DISPATCH_MEMORYPRESSURE_WARN ? 1 : 0);
    });
    dispatch_resume(source);
}

/// Blocks for at most ~15 s. Returns the MB registered with the tier. `purgeable` picks
/// madeira.cfg donor-pool-kind = purgeable (ml1152) over the ledger-tagged default.
long MadeiraDonorPoolStart(long megabytes, int purgeable) {
    const uint64_t region = 512ull << 20;
    const int64_t timeout = 10 * NSEC_PER_SEC;
    long regions = megabytes / 512, added = 0;
    if (regions <= 0) return 0;
    NSString *identifier = [NSBundle.mainBundle.bundleIdentifier stringByAppendingString:@".MemoryHost"];
    Class<MPExtensionClass> cls = (Class<MPExtensionClass>)NSClassFromString(@"NSExtension");
    id<MPExtension> extension = [cls extensionWithIdentifier:identifier error:nil];
    if (!extension) { fprintf(stderr, "[swap] ml1150 donor pool: no extension %s\n", identifier.UTF8String); return 0; }
    dispatch_semaphore_t exited = dispatch_semaphore_create(0);
    [extension setRequestInterruptionBlock:^(NSUUID *uuid) { dispatch_semaphore_signal(exited); }];

    static NSXPCListener *listener;
    static MPListener *delegate;
    delegate = [MPListener new];
    delegate.connected = dispatch_semaphore_create(0);
    listener = [NSXPCListener anonymousListener];
    listener.delegate = delegate;
    [listener resume];
    NSExtensionItem *item = [NSExtensionItem new];
    item.userInfo = @{ @"endpoint": listener.endpoint };
    dispatch_semaphore_t started = dispatch_semaphore_create(0);
    __block NSUUID *request = nil;
    [extension beginExtensionRequestWithInputItems:@[item] completion:^(NSUUID *uuid) { request = uuid; dispatch_semaphore_signal(started); }];
    if (dispatch_semaphore_wait(started, dispatch_time(DISPATCH_TIME_NOW, timeout)) || !request ||
        dispatch_semaphore_wait(delegate.connected, dispatch_time(DISPATCH_TIME_NOW, timeout))) {
        fprintf(stderr, "[swap] ml1150 donor pool: the extension did not start or connect; no pool\n");
        if (request) [extension cancelExtensionRequestWithIdentifier:request];
        return 0;
    }
    NSXPCConnection *connection = delegate.connection;
    for (long i = 0; i < regions; i++) {
        dispatch_semaphore_t reply = dispatch_semaphore_create(0);
        __block mach_port_t entry = MACH_PORT_NULL;
        id<MHMemoryServer> proxy = [connection remoteObjectProxyWithErrorHandler:^(NSError *e) { dispatch_semaphore_signal(reply); }];
        [proxy createRegion:region kind:(purgeable ? MHRegionPurgeableAlloc : MHRegionLedgerTagged) touch:NO reply:^(xpc_object_t handle, int kr, uint64_t fp, uint64_t av) {
            if (kr == KERN_SUCCESS && handle) entry = xpc_dictionary_copy_mach_send(handle, "entry");
            dispatch_semaphore_signal(reply);
        }];
        if (dispatch_semaphore_wait(reply, dispatch_time(DISPATCH_TIME_NOW, timeout)) || entry == MACH_PORT_NULL) break;
        if (madeira_donor_pool_add(entry, region) != 0) { mach_port_deallocate(mach_task_self(), entry); break; }
        added++;
    }
    // The extension exits; from then on its regions are billed to nobody.
    [(id<MHMemoryServer>)[connection remoteObjectProxyWithErrorHandler:^(NSError *e) {}] exitWithReply:^{}];
    BOOL gone = dispatch_semaphore_wait(exited, dispatch_time(DISPATCH_TIME_NOW, timeout)) == 0;
    if (!gone) {
        /* ml1153: a live extension would keep owning its regions and their footprint. Kill it
         * the way MeloNX's RAM donor does; the memory then belongs to nobody. */
        NSObject *object = (NSObject *)extension;
        int pid = [object respondsToSelector:@selector(pidForRequestIdentifier:)] ? [extension pidForRequestIdentifier:request] : 0;
        if ([object respondsToSelector:@selector(_kill:)]) {
            [extension _kill:SIGKILL];
            gone = dispatch_semaphore_wait(exited, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0;
            fprintf(stderr, "[swap] ml1150 donor pool: the extension (pid %d) did not exit on request; sent SIGKILL (%s)\n",
                    pid, gone ? "exited" : "no exit report");
        } else
            fprintf(stderr, "[swap] ml1150 donor pool: the extension (pid %d) did not exit and NSExtension has no _kill:\n", pid);
    }
    [connection invalidate];
    fprintf(stderr, "[swap] ml1150 donor pool: %ld x 512 MB registered, extension %s\n", added, gone ? "exited" : "did NOT report exiting");
    if (added) MPStartPressureSource();
    return added * 512;
}
