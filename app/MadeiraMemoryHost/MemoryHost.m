// MadeiraMemoryHost: an app extension on com.apple.ar.viewer, the extension
// point iOS 27's jetsam table gives no memory limit. It creates memory objects
// for Madeira on request (the extension memory experiment, see
// Madeira/MemoryHostProtocol.h). Started by Madeira through NSExtension the
// way LiveContainer starts its LiveProcess; Madeira passes an XPC endpoint in
// the request and the extension connects back to it.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach/mach.h>
#import <os/proc.h>
#import "../Madeira/MemoryHostProtocol.h"

static uint64_t mh_footprint(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
    return info.phys_footprint;
}

@interface MHServer : NSObject <MHMemoryServer>
@end

@implementation MHServer {
    NSMutableArray<NSNumber *> *_entries;   // keeps every entry (and so its object) alive
}

- (instancetype)init {
    if ((self = [super init])) _entries = [NSMutableArray array];
    return self;
}

- (void)statusWithReply:(void (^)(int, uint64_t, uint64_t))reply {
    reply(getpid(), mh_footprint(), os_proc_available_memory());
}

- (void)createRegion:(uint64_t)bytes kind:(int)kind touch:(BOOL)touch
               reply:(void (^)(xpc_object_t, int, uint64_t, uint64_t))reply {
    memory_object_size_t size = bytes;
    mach_port_t entry = MACH_PORT_NULL;
    vm_prot_t flags = VM_PROT_READ | VM_PROT_WRITE | MAP_MEM_NAMED_CREATE;
    if (kind == MHRegionLedgerTagged) flags |= MAP_MEM_LEDGER_TAGGED;
    if (kind == MHRegionPurgeable) flags |= MAP_MEM_PURGABLE;
    kern_return_t kr;
    if (kind == MHRegionPurgeableAlloc) {
        /* ml1152: the range is allocated purgeable (non-volatile) in this process and a
         * memory entry names it; the entry keeps the pages once this process has exited. */
        mach_vm_address_t range = 0;
        kr = mach_vm_allocate(mach_task_self(), &range, size, VM_FLAGS_ANYWHERE | VM_FLAGS_PURGABLE);
        if (kr == KERN_SUCCESS)
            kr = mach_make_memory_entry_64(mach_task_self(), &size, range, VM_PROT_READ | VM_PROT_WRITE, &entry, MACH_PORT_NULL);
    } else
        kr = mach_make_memory_entry_64(mach_task_self(), &size, 0, flags, &entry, MACH_PORT_NULL);
    if (kr == KERN_SUCCESS && touch) {
        mach_vm_address_t address = 0;
        kr = mach_vm_map(mach_task_self(), &address, size, 0, VM_FLAGS_ANYWHERE, entry, 0, FALSE,
                         VM_PROT_READ | VM_PROT_WRITE, VM_PROT_READ | VM_PROT_WRITE, VM_INHERIT_NONE);
        if (kr == KERN_SUCCESS) memset((void *)address, 0x5a, (size_t)size);   // stays mapped
    }
    xpc_object_t handle = xpc_dictionary_create(NULL, NULL, 0);
    if (kr == KERN_SUCCESS) {
        xpc_dictionary_set_mach_send(handle, "entry", entry);
        [_entries addObject:@(entry)];
    }
    NSLog(@"[memhost] region %llu MB kind=%d touch=%d kr=%d footprint=%llu MB", bytes >> 20, kind, touch, kr,
          mh_footprint() >> 20);
    reply(handle, kr, mh_footprint(), os_proc_available_memory());
}

- (void)exitWithReply:(void (^)(void))reply {
    NSLog(@"[memhost] exiting on request, footprint %llu MB", mh_footprint() >> 20);
    reply();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ exit(0); });
}

@end

@interface MadeiraMemoryHostHandler : NSObject <NSExtensionRequestHandling>
@end

static NSXPCConnection *mh_connection;
static MHServer *mh_server;

@implementation MadeiraMemoryHostHandler

- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context {
    NSXPCListenerEndpoint *endpoint = [context.inputItems.firstObject userInfo][@"endpoint"];
    if (![endpoint isKindOfClass:NSXPCListenerEndpoint.class]) {
        NSLog(@"[memhost] no endpoint in the request: %@", [context.inputItems.firstObject userInfo]);
        return;
    }
    mh_server = [MHServer new];
    mh_connection = [[NSXPCConnection alloc] initWithListenerEndpoint:endpoint];
    mh_connection.exportedInterface = MHMemoryServerInterface();
    mh_connection.exportedObject = mh_server;
    mh_connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(MHMemoryClient)];
    [mh_connection resume];
    [(id<MHMemoryClient>)mh_connection.remoteObjectProxy extensionReady:getpid() available:os_proc_available_memory()];
    NSLog(@"[memhost] connected, pid %d, available %zu MB", getpid(), os_proc_available_memory() >> 20);
}

@end

// An extension request's items are decoded with only property-list classes
// allowed, and the endpoint is not one; LiveContainer's LiveProcess lifts the
// check the same way before NSExtensionMain runs.
static BOOL mh_allow_class(id self, SEL _cmd, Class cls, id key, BOOL allowingInvocations) { return YES; }

__attribute__((constructor)) static void mh_allow_endpoint_decoding(void) {
    Method method = class_getInstanceMethod(NSClassFromString(@"NSXPCDecoder"),
                                            NSSelectorFromString(@"_validateAllowedClass:forKey:allowingInvocations:"));
    if (method) method_setImplementation(method, (IMP)mh_allow_class);
}
