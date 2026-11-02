#import <Foundation/Foundation.h>

/// The extension memory experiment (MemoryHostProtocol.h): starts the
/// MadeiraMemoryHost extension, maps memory it creates, and reports whose
/// footprint pays for it. Runs on a background queue; `log` gets each result
/// line (on any thread) and `done` is called once at the end. The same lines go
/// to Documents/memhost-test.txt as they happen.
void MadeiraMemoryHostTest(void (^_Nonnull log)(NSString *_Nonnull line), void (^_Nonnull done)(void));
