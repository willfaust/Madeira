#include <FEXCore/Config/Config.h>
#include <FEXCore/Core/Context.h>
#include <FEXCore/Core/HostFeatures.h>
#include <FEXCore/Debug/InternalThreadState.h>
#include <FEXCore/Utils/AllocatorHooks.h>
#include <FEXCore/Utils/LogManager.h>
#include "Interface/Context/Context.h"
#include "Interface/Core/CPUBackend.h"
#include "Interface/Core/JIT/Relocations.h"
#include "Interface/Core/LookupCache.h"
#include "DummyHandlers.h"
#include <mach/mach.h>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

using Frame = FEXCore::Core::CpuStateFrame;
static constexpr uint64_t GuestBase = UINT64_C(0x130000000);

static void fail(const char *message) { std::fprintf(stderr, "%s\n", message); std::exit(1); }
static void assertion(const char *message) { fail(message); }
static void message(LogMan::DebugLevels, const char *text) { std::fprintf(stderr, "%s\n", text); }

static void *compile_memory(void *address, size_t size, int prot, int flags, int fd, off_t offset)
{
    // The exporter writes translations but never executes them.
    return ::mmap(address, size, prot & ~PROT_EXEC, flags, fd, offset);
}

static void write(const std::string& path, const void *data, size_t size)
{
    std::ofstream out(path, std::ios::binary);
    out.write(static_cast<const char *>(data), size);
    if (!out) fail("Cannot write export output");
}

int main(int argc, char **argv)
{
    if (argc != 4) fail("Usage: export guest-image.bin instruction-rvas.txt output-directory");
    std::ifstream input(argv[1], std::ios::binary | std::ios::ate);
    if (!input || input.tellg() <= 0 || input.tellg() > 16 * 1024 * 1024) fail("Invalid guest image size");
    size_t image_size = input.tellg(); input.seekg(0);
    vm_address_t guest = GuestBase;
    auto allocation_status = vm_allocate(mach_task_self(), &guest, (image_size + 16383) & ~16383ULL, VM_FLAGS_FIXED);
    if (allocation_status != KERN_SUCCESS) {
        std::fprintf(stderr, "Guest allocation: %s at 0x%llx size=0x%zx\n", mach_error_string(allocation_status), guest, image_size);
        fail("Guest address is occupied; no mapping was replaced");
    }
    input.read(reinterpret_cast<char *>(guest), image_size);
    if (!input) fail("Cannot read guest image");
    std::ifstream offsets(argv[2]);
    std::vector<uint64_t> rvas;
    uint64_t rva;
    while (offsets >> std::hex >> rva) {
        if (rva >= image_size) fail("Instruction outside guest image");
        rvas.push_back(rva);
    }
    if (!offsets.eof() || rvas.empty() || rvas.size() > 100000) fail("Invalid instruction list");
    std::sort(rvas.begin(), rvas.end());
    rvas.erase(std::unique(rvas.begin(), rvas.end()), rvas.end());

    LogMan::Throw::InstallHandler(assertion);
    LogMan::Msg::InstallHandler(message);
    FEXCore::Allocator::mmap = compile_memory;
    FEXCore::Config::Initialize();
    FEXCore::Config::Load();
    FEXCore::Config::Set(FEXCore::Config::CONFIG_IS64BIT_MODE, "1");
    FEXCore::Config::Set(FEXCore::Config::CONFIG_MULTIBLOCK, "0");
    FEXCore::Config::Set(FEXCore::Config::CONFIG_MAXINST, "64");
    FEXCore::Config::Set(FEXCore::Config::CONFIG_TSOENABLED, "0");
    FEXCore::Config::Set(FEXCore::Config::CONFIG_DISABLETELEMETRY, "1");
    FEXCore::HostFeatures features {};
    features.DCacheLineSize = features.ICacheLineSize = 64;
    features.SupportsAtomics = true;
    features.CPUMIDRs.push_back(0x410fd070);
    auto ctx = FEXCore::Context::Context::CreateNewContext(features);
    auto signals = FEX::DummyHandlers::CreateSignalDelegator();
    auto syscalls = FEX::DummyHandlers::CreateSyscallHandler();
    ctx->SetSignalDelegator(signals.get());
    ctx->SetSyscallHandler(syscalls.get());
    if (!ctx->InitCore()) fail("FEX initialization failed");
    auto thread = ctx->CreateThread(0, 0);
    FEXCore::Core::CPUState::gdt_segment gdt[32] {};
    auto& state = thread->CurrentFrame->State;
    state.segment_arrays[0] = state.segment_arrays[1] = gdt;
    state.cs_idx = FEXCore::Core::CPUState::DEFAULT_USER_CS << 3;
    auto segment = FEXCore::Core::CPUState::GetSegmentFromIndex(state, state.cs_idx);
    segment->L = 1;
    segment->D = 0;
    ctx->GetCodeCache().InitiateCacheGeneration();
    auto impl = static_cast<FEXCore::Context::ContextImpl *>(ctx.get());
    auto buffer = impl->GetLatest();
    if (!buffer || buffer->Ptr == MAP_FAILED) fail("FEX compile buffer allocation failed");

    std::vector<std::pair<uint64_t, uint64_t>> ranges;
    for (auto offset : rvas) {
        size_t before = impl->LatestOffset;
        ctx->CompileRIPCount(thread, guest + offset, 64);
        if (buffer != impl->GetLatest()) fail("Code exceeds one FEX buffer");
        if (impl->LatestOffset != before) {
            size_t header = (before + 15) & ~15ULL;
            uint32_t tail;
            std::memcpy(&tail, buffer->Ptr + header, sizeof(tail));
            if (header + tail >= impl->LatestOffset || tail < 4) fail("Invalid FEX block extent");
            ranges.emplace_back(header + 4, header + tail);
        }
    }
    std::vector<uint8_t> code(buffer->Ptr, buffer->Ptr + impl->LatestOffset);
    auto relocations = thread->CPUBackend->TakeRelocations(0);
    std::vector<uint64_t> literals;
    unsigned rewritten = 0;
    for (const auto& reloc : relocations) {
        using Type = FEXCore::CPU::RelocationTypes;
        size_t slot = reloc.Header.Offset;
        if (slot > code.size() || code.size() - slot < 8) fail("FEX relocation outside code");
        if (reloc.Header.Type == Type::RELOC_GUEST_RIP_LITERAL) literals.push_back(slot);
        else if (reloc.Header.Type == Type::RELOC_NAMED_SYMBOL_LITERAL) {
            if (reloc.NamedSymbolLiteral.Symbol != FEXCore::CPU::RelocNamedSymbolLiteral::NamedSymbol::SYMBOL_LITERAL_EXITFUNCTION_LINKER)
                fail("Unsupported FEX runtime symbol");
            literals.push_back(slot);
            unsigned references = 0;
            for (const auto& range : ranges) for (size_t pos = range.first; pos + 4 <= range.second; pos += 4) {
                uint32_t word; std::memcpy(&word, code.data() + pos, 4);
                if ((word & 0xff000000u) != 0x58000000u) continue;
                int64_t immediate = int32_t(word << 8) >> 13;
                if (int64_t(pos) + immediate * 4 != int64_t(slot)) continue;
                constexpr size_t displacement = offsetof(Frame, Pointers.ExitFunctionLinker);
                static_assert(displacement % 8 == 0 && displacement / 8 < 4096);
                uint32_t load = 0xf9400000u | (uint32_t(displacement / 8) << 10) | (28u << 5) | (word & 31u);
                std::memcpy(code.data() + pos, &load, 4);
                ++references; ++rewritten;
            }
            // FEX also emits an unused linker literal for return-only blocks.
            (void)references;
            std::memset(code.data() + slot, 0, 8);
        } else if (reloc.Header.Type != Type::RELOC_GUEST_RIP_MOVE) fail("Named thunk needs an explicit AOT binding");
    }
    Frame frame {};
    std::memcpy(frame.Pointers.NamedVectorConstants, thread->CurrentFrame->Pointers.NamedVectorConstants,
                sizeof(frame.Pointers.NamedVectorConstants));
    std::string out = argv[3];
    write(out + "/translated.bin", code.data(), code.size());
    write(out + "/frame.bin", &frame, sizeof(frame));
    std::ofstream metadata(out + "/metadata.json");
    metadata << "{\"code_size\":" << code.size() << ",\"frame_size\":" << sizeof(Frame)
             << ",\"rewritten_exits\":" << rewritten << ",\"ranges\":[";
    for (size_t i = 0; i < ranges.size(); ++i)
        metadata << (i ? "," : "") << '[' << ranges[i].first << ',' << ranges[i].second << ']';
    metadata << "],\"literals\":[";
    for (size_t i = 0; i < literals.size(); ++i) metadata << (i ? "," : "") << literals[i];
    metadata << "],\"entries\":[";
    bool comma = false;
    for (const auto& [rip, block] : buffer->LookupCache->BlockList) {
        if (rip < guest || rip >= guest + image_size || block.HostCode < uintptr_t(buffer->Ptr) ||
            block.HostCode >= uintptr_t(buffer->Ptr) + code.size()) fail("Invalid FEX entry mapping");
        metadata << (comma ? "," : "") << '[' << rip << ',' << block.HostCode - uintptr_t(buffer->Ptr) << ']'; comma = true;
    }
    metadata << "]}\n";
    if (!metadata) fail("Cannot write FEX metadata");
    std::ofstream abi(out + "/abi.h");
    abi << "#pragma once\n";
#define OFFSET(name, field) abi << "#define FEX_" #name " " << offsetof(Frame, field) << "\n"
    OFFSET(GREGS, State.gregs); OFFSET(RIP, State.rip); OFFSET(PF, State.pf_raw); OFFSET(AF, State.af_raw);
    OFFSET(GS, State.gs_cached);
    OFFSET(NZCV, State.flags[24]); OFFSET(XMM, State.xmm.sse.data); OFFSET(L1, State.L1Pointer);
    OFFSET(L1MASK, State.L1Mask); OFFSET(STACK, ReturningStackLocation); OFFSET(PTRS, Pointers);
    OFFSET(LOOP, Pointers.DispatcherLoopTop); OFFSET(LINK, Pointers.ExitFunctionLinker);
    OFFSET(CONSTANTS, Pointers.NamedVectorConstants); OFFSET(CONSTANT_PTRS, Pointers.NamedVectorConstantPointers);
#undef OFFSET
    abi << "#define FEX_FRAME_SIZE " << sizeof(Frame) << "\n#define FEX_CONSTANT_COUNT "
        << std::size(frame.Pointers.NamedVectorConstants) << "\n";
    abi << "#define FEX_GUEST_BASE " << GuestBase << "\n#define FEX_GUEST_SIZE " << image_size << "\n";
    if (!abi) fail("Cannot write FEX ABI");
    metadata.close();
    abi.close();
    std::printf("Exported %zu instruction starts, %zu native entries, %zu bytes, %u immutable exits\n",
        rvas.size(), buffer->LookupCache->BlockList.size(), code.size(), rewritten);
    std::fflush(stdout);
    // The process owns all export-only allocations; no generated code ran.
    std::_Exit(0);
}
