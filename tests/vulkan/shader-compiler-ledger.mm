#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#define MVK_XCODE_16 1
#include "MVKShaderCompilerDiagnostics.h"
#include <cassert>
int main() { @autoreleasepool {
    setenv("MADEIRA_VK_SHADER_COMPILE_DIAGNOSTICS", "1", 1);
    MTLCompileOptions* o = [MTLCompileOptions new];
    id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    auto record = [&](NSString* s, unsigned expected) {
        auto t = madeiraCompilerDiagnostics::begin(s, o, d);
        assert(t.enabled && t.category == expected);
        madeiraCompilerDiagnostics::end(t, true);
    };
    record(@"source-a", 0); record(@"source-a", 1);
    o.preprocessorMacros = @{@"COUNT": @6}; record(@"source-a", 0); record(@"source-a", 1);
    o.preprocessorMacros = @{@"COUNT": @7}; record(@"source-a", 0);
    o.preserveInvariance = YES; record(@"source-a", 0);
    o.preprocessorMacros = @{@"COUNT": @7, @"OTHER": @3}; record(@"source-a", 0);
    o.preprocessorMacros = @{@"OTHER": @3, @"COUNT": @7}; record(@"source-a", 1);
    bool sawOverflow = false;
    for (unsigned i = 0; i < 34000; ++i) {
        auto t = madeiraCompilerDiagnostics::begin([NSString stringWithFormat:@"source-%u", i], o, d);
        assert(t.category != 1); sawOverflow |= t.category == 2;
        madeiraCompilerDiagnostics::end(t, true);
    }
    assert(sawOverflow);
    record(@"source-a", 1); // Existing fingerprints survive table saturation.
    auto& l = madeiraCompilerDiagnostics::ledger();
    assert(l.counts[0] <= 32768 && l.counts[0] + l.counts[1] + l.counts[2] == l.completed);
    printf("PASS bounded-ledger macro-values option-differences canonical-macro-order saturation; bytes=%zu\n", sizeof(l));
    [o release]; [d release];
} }
