// Extension memory experiment (2026-09-29), shared by Madeira and its
// MadeiraMemoryHost extension.
//
// iOS 27's jetsam table gives the com.apple.ar.viewer extension point no
// memory limit (LiveContainer runs guest apps in such an extension). The
// question: memory objects created in that extension and mapped into Madeira,
// whose phys_footprint pays for them? Madeira asks the extension for regions
// of each kind below, writes every page itself, and compares both processes'
// footprints before and after.

#import <Foundation/Foundation.h>
#import <xpc/xpc.h>
#import <mach/mach.h>

// <mach/mach_vm.h> is "unsupported" on the iOS SDK, but libsystem_kernel
// exports these (JITAllocator.c declares its own the same way).
extern kern_return_t mach_vm_map(vm_map_t target, mach_vm_address_t *address, mach_vm_size_t size,
                                 mach_vm_offset_t mask, int flags, mem_entry_name_port_t object,
                                 memory_object_offset_t offset, boolean_t copy, vm_prot_t cur_protection,
                                 vm_prot_t max_protection, vm_inherit_t inheritance);
extern kern_return_t mach_vm_deallocate(vm_map_t target, mach_vm_address_t address, mach_vm_size_t size);
extern kern_return_t mach_vm_allocate(vm_map_t target, mach_vm_address_t *address, mach_vm_size_t size, int flags);

typedef NS_ENUM(int, MHRegionKind) {
    MHRegionPlain = 0,        // MAP_MEM_NAMED_CREATE: an object with no owner
    MHRegionLedgerTagged = 1, // + MAP_MEM_LEDGER_TAGGED: owned by the extension
    MHRegionPurgeable = 2,    // + MAP_MEM_PURGABLE (non-volatile): owned by the extension
    MHRegionPurgeableAlloc = 3, // ml1152: mach_vm_allocate(VM_FLAGS_PURGABLE) in the extension, then a memory entry on that range (the way MeloNX donates RAM)
};

@protocol MHMemoryServer
/// The extension's pid, phys_footprint and os_proc_available_memory().
- (void)statusWithReply:(void (^)(int pid, uint64_t footprint, uint64_t available))reply;
/// Creates a region of `bytes`; with `touch`, the extension maps it and writes
/// every page first (and keeps it mapped). The reply's XPC dictionary holds the
/// memory entry's send right under "entry".
- (void)createRegion:(uint64_t)bytes kind:(int)kind touch:(BOOL)touch
               reply:(void (^)(xpc_object_t handle, int kr, uint64_t footprint, uint64_t available))reply;
/// Replies, then exits the extension process (exit(0)) shortly after.
- (void)exitWithReply:(void (^)(void))reply;
@end

/// Madeira's side of the connection. The extension calls this first: an
/// NSXPCConnection made from an endpoint reaches the listener only with its
/// first message, so without it Madeira never sees the connection.
@protocol MHMemoryClient
- (void)extensionReady:(int)pid available:(uint64_t)available;
@end

static inline NSXPCInterface *MHMemoryServerInterface(void) {
    NSXPCInterface *interface = [NSXPCInterface interfaceWithProtocol:@protocol(MHMemoryServer)];
    [interface setXPCType:XPC_TYPE_DICTIONARY forSelector:@selector(createRegion:kind:touch:reply:)
                 argumentIndex:0 ofReply:YES];
    return interface;
}
