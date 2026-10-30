/*
 * dcomp.dll for Madeira (arm64ec).
 *
 * Godot 4.5's Direct3D 12 driver (Slay the Spire 2) presents through
 * DirectComposition: it creates its swap chain with the DXGI factory's
 * CreateSwapChainForComposition, then DCompositionCreateDevice, a target for
 * its window, a visual whose content is the swap chain, and Commit. Wine's
 * dcomp answers E_NOTIMPL and DXMT's factory has no composition swap chains,
 * so swap_chain_resize failed on every frame and the window stayed black.
 *
 * Nothing here composes. A composition swap chain is made a window swap
 * chain instead: when this DLL loads, the CreateSwapChainForComposition entry
 * of the DXGI factory's vtable is pointed at composition_swap_chain(), which
 * picks the calling thread's largest visible top-level window (the one the
 * game renders to; Godot creates the swap chain on the thread that made its
 * window) and calls CreateSwapChainForHwnd. The DirectComposition objects
 * only accept their calls: the device, a target per window and visuals, with
 * Commit and the setters succeeding. A target whose window is not the one the
 * swap chain was given is logged.
 *
 * Log tag [dcomp]. Built by build/dcomp/build.sh.
 */
#define COBJMACROS
#include <windows.h>
#include <initguid.h>   /* IID_IDXGIFactory2 defined here, no import library */
#include <dxgi1_2.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

static void dcomp_log(const char *fmt, ...)
{
    typedef int (__cdecl *dbg_output_fn)(const char *);
    static dbg_output_fn dbg_output;
    static int looked;
    char buf[512];
    size_t len;
    va_list ap;

    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf - 1, fmt, ap);
    va_end(ap);
    len = strlen(buf);
    if (!len || buf[len - 1] != '\n') { buf[len] = '\n'; buf[len + 1] = 0; }
    if (!looked) {
        HMODULE nt = GetModuleHandleA("ntdll.dll");
        if (nt) dbg_output = (dbg_output_fn)(void *)GetProcAddress(nt, "__wine_dbg_output");
        looked = 1;
    }
    if (dbg_output) dbg_output(buf);
}

/* ---------------------------------------------------------------- DXGI */

typedef HRESULT (STDMETHODCALLTYPE *comp_fn)(IDXGIFactory2 *, IUnknown *, const DXGI_SWAP_CHAIN_DESC1 *,
                                              IDXGIOutput *, IDXGISwapChain1 **);
static comp_fn orig_composition;
static HWND last_hwnd;

struct pick { DWORD pid, tid; HWND best; LONGLONG area; int same_thread; };

static BOOL CALLBACK pick_window(HWND hwnd, LPARAM param)
{
    struct pick *p = (struct pick *)param;
    DWORD pid = 0, tid = GetWindowThreadProcessId(hwnd, &pid);
    RECT rc;
    LONGLONG area;
    int same;

    if (pid != p->pid || !IsWindowVisible(hwnd) || !GetClientRect(hwnd, &rc)) return TRUE;
    area = (LONGLONG)(rc.right - rc.left) * (rc.bottom - rc.top);
    same = tid == p->tid;
    if (!p->best || same > p->same_thread || (same == p->same_thread && area > p->area)) {
        p->best = hwnd; p->area = area; p->same_thread = same;
    }
    return TRUE;
}

static HRESULT STDMETHODCALLTYPE composition_swap_chain(IDXGIFactory2 *factory, IUnknown *device,
        const DXGI_SWAP_CHAIN_DESC1 *desc, IDXGIOutput *restrict_output, IDXGISwapChain1 **swap_chain)
{
    struct pick p = { GetCurrentProcessId(), GetCurrentThreadId(), NULL, 0, 0 };
    DXGI_SWAP_CHAIN_DESC1 d;
    HRESULT hr;

    if (!desc || !swap_chain) return DXGI_ERROR_INVALID_CALL;
    EnumWindows(pick_window, (LPARAM)&p);
    if (!p.best) p.best = GetForegroundWindow();
    if (!p.best) {
        dcomp_log("[dcomp] composition swap chain %ux%u: no window to present to\n", desc->Width, desc->Height);
        return orig_composition ? orig_composition(factory, device, desc, restrict_output, swap_chain) : E_NOTIMPL;
    }
    d = *desc;
    hr = IDXGIFactory2_CreateSwapChainForHwnd(factory, device, p.best, &d, NULL, restrict_output, swap_chain);
    if (FAILED(hr) && d.AlphaMode != DXGI_ALPHA_MODE_IGNORE && d.AlphaMode != DXGI_ALPHA_MODE_UNSPECIFIED) {
        d.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
        hr = IDXGIFactory2_CreateSwapChainForHwnd(factory, device, p.best, &d, NULL, restrict_output, swap_chain);
    }
    if (SUCCEEDED(hr)) last_hwnd = p.best;
    dcomp_log("[dcomp] composition swap chain %ux%u format %u buffers %u alpha %u -> window %p (%s thread) hr 0x%08lx\n",
              desc->Width, desc->Height, desc->Format, desc->BufferCount, desc->AlphaMode, p.best,
              p.same_thread ? "this" : "another", (unsigned long)hr);
    return hr;
}

/* Madeira runs an ARM64EC DLL from a JIT-pool copy of its image, so the vtable
 * a factory points at is the pool copy's, at another address than the PE view
 * the loader mapped. VirtualProtect on a pool address changes the PE page's
 * protection and then copies that PE page over the pool copy (the "IAT sync"
 * in virtual_ios.c), once when the page becomes writable and once when its
 * protection is restored. A slot written only in the pool copy is put back by
 * the second copy: Slay the Spire 2's log has the patch line and then DXMT's
 * own "Not implemented" from CreateSwapChainForComposition on every frame.
 * pe_view() finds the PE view's address of a pool-copy address in `module`,
 * so the slot can be written in both. It returns the address itself when it
 * already lies in the PE view (no pool copy), or NULL when no copy of the
 * module's headers is found below it within the image's size. */
static void *pe_view(HMODULE module, void *address)
{
    const IMAGE_DOS_HEADER *dos = (const IMAGE_DOS_HEADER *)module;
    const IMAGE_NT_HEADERS *nt = (const IMAGE_NT_HEADERS *)((const char *)module + dos->e_lfanew);
    uintptr_t base = (uintptr_t)module, at = (uintptr_t)address, size = nt->OptionalHeader.SizeOfImage, page;
    /* the DOS header, the PE signature and the file header: the loader may
     * rewrite OptionalHeader.ImageBase in one view, never these */
    const size_t nt_part = sizeof(DWORD) + sizeof(IMAGE_FILE_HEADER);

    if (at - base < size) return address;
    for (page = at & ~(uintptr_t)0xfff; at - page < size; page -= 0x1000) {
        const IMAGE_NT_HEADERS *copy = (const IMAGE_NT_HEADERS *)(page + dos->e_lfanew);
        if (IsBadReadPtr((const void *)page, sizeof *dos)) return NULL;
        if (memcmp((const void *)page, dos, sizeof *dos)) continue;
        if (IsBadReadPtr(copy, sizeof *copy)) return NULL;
        if (!memcmp(copy, nt, nt_part) && copy->OptionalHeader.SizeOfImage == size)
            return (void *)(base + (at - page));
    }
    return NULL;
}

/* Points the factory vtable's CreateSwapChainForComposition at
 * composition_swap_chain. Every factory of a dxgi.dll shares the vtable, so
 * one patch covers the game's factory, made before this DLL was loaded. The
 * slot is written in the PE view as well as in the pool copy (pe_view), then
 * read back after the protection is restored. */
static void patch_factory(void)
{
    typedef HRESULT (WINAPI *create_fn)(REFIID, void **);
    HMODULE dxgi = GetModuleHandleA("dxgi.dll");
    create_fn create;
    IDXGIFactory2 *factory = NULL;
    void **slot, **pe_slot;
    DWORD old;

    if (!dxgi) { dcomp_log("[dcomp] dxgi.dll not loaded: composition swap chains stay unsupported\n"); return; }
    create = (create_fn)(void *)GetProcAddress(dxgi, "CreateDXGIFactory1");
    if (!create || FAILED(create(&IID_IDXGIFactory2, (void **)&factory)) || !factory) {
        dcomp_log("[dcomp] no IDXGIFactory2: composition swap chains stay unsupported\n");
        return;
    }
    slot = (void **)&factory->lpVtbl->CreateSwapChainForComposition;
    if (*slot != (void *)composition_swap_chain) {
        pe_slot = (void **)pe_view(dxgi, slot);
        if (VirtualProtect(slot, sizeof *slot, PAGE_READWRITE, &old)) {
            orig_composition = (comp_fn)*slot;
            if (pe_slot && pe_slot != slot) *pe_slot = (void *)composition_swap_chain;
            *slot = (void *)composition_swap_chain;
            VirtualProtect(slot, sizeof *slot, old, &old);
            FlushInstructionCache(GetCurrentProcess(), slot, sizeof *slot);
            if (*slot == (void *)composition_swap_chain)
                dcomp_log("[dcomp] DXGI factory: composition swap chains become window swap chains "
                          "(slot %p, PE view %p)\n", slot, pe_slot);
            else
                dcomp_log("[dcomp] DXGI factory: the patch did not stay (slot %p holds %p, PE view %p): "
                          "composition swap chains stay unsupported\n", slot, *slot, pe_slot);
        } else {
            dcomp_log("[dcomp] DXGI factory vtable not writable (error %lu)\n", GetLastError());
        }
    }
    IDXGIFactory2_Release(factory);
}

/* ------------------------------------------------- DirectComposition objects
 * One layout for the three kinds: a vtable of generic entries with the
 * methods that matter set by index (Wine's dcomp.idl gives the order). */

struct obj { void **vtbl; LONG refs; HWND hwnd; };

static HRESULT STDMETHODCALLTYPE obj_ok(void *self) { (void)self; return S_OK; }
static HRESULT STDMETHODCALLTYPE obj_notimpl(void *self) { (void)self; return E_NOTIMPL; }

static HRESULT STDMETHODCALLTYPE obj_query(struct obj *self, REFIID iid, void **out)
{
    (void)iid;
    if (!out) return E_POINTER;
    *out = self;
    InterlockedIncrement(&self->refs);
    return S_OK;
}
static ULONG STDMETHODCALLTYPE obj_addref(struct obj *self) { return InterlockedIncrement(&self->refs); }
static ULONG STDMETHODCALLTYPE obj_release(struct obj *self)
{
    LONG n = InterlockedDecrement(&self->refs);
    if (!n) HeapFree(GetProcessHeap(), 0, self);
    return n;
}

enum { DEVICE_METHODS = 27, VISUAL_METHODS = 20, TARGET_METHODS = 4 };
static void *device_vtbl[DEVICE_METHODS], *visual_vtbl[VISUAL_METHODS], *target_vtbl[TARGET_METHODS];

static struct obj *obj_new(void **vtbl, HWND hwnd)
{
    struct obj *o = HeapAlloc(GetProcessHeap(), 0, sizeof *o);
    if (o) { o->vtbl = vtbl; o->refs = 1; o->hwnd = hwnd; }
    return o;
}

/* IDCompositionDevice::CreateTargetForHwnd (6) */
static HRESULT STDMETHODCALLTYPE device_target(struct obj *self, HWND hwnd, BOOL topmost, void **target)
{
    (void)self; (void)topmost;
    if (!target) return E_POINTER;
    if (!(*target = obj_new(target_vtbl, hwnd))) return E_OUTOFMEMORY;
    dcomp_log("[dcomp] target for window %p%s\n", hwnd,
              last_hwnd && hwnd != last_hwnd ? " -- NOT the window the swap chain presents to" : "");
    return S_OK;
}

/* IDCompositionDevice::CreateVisual (7) */
static HRESULT STDMETHODCALLTYPE device_visual(struct obj *self, void **visual)
{
    (void)self;
    if (!visual) return E_POINTER;
    return (*visual = obj_new(visual_vtbl, NULL)) ? S_OK : E_OUTOFMEMORY;
}

/* IDCompositionDevice::CheckDeviceState (26) */
static HRESULT STDMETHODCALLTYPE device_state(struct obj *self, BOOL *valid)
{
    (void)self;
    if (!valid) return E_POINTER;
    *valid = TRUE;
    return S_OK;
}

static void init_vtables(void)
{
    int i;
    for (i = 0; i < DEVICE_METHODS; i++) device_vtbl[i] = (void *)obj_notimpl;
    for (i = 0; i < VISUAL_METHODS; i++) visual_vtbl[i] = (void *)obj_ok;     /* setters */
    for (i = 0; i < TARGET_METHODS; i++) target_vtbl[i] = (void *)obj_ok;     /* SetRoot */
    device_vtbl[0] = visual_vtbl[0] = target_vtbl[0] = (void *)obj_query;
    device_vtbl[1] = visual_vtbl[1] = target_vtbl[1] = (void *)obj_addref;
    device_vtbl[2] = visual_vtbl[2] = target_vtbl[2] = (void *)obj_release;
    device_vtbl[3] = (void *)obj_ok;            /* Commit */
    device_vtbl[4] = (void *)obj_ok;            /* WaitForCommitCompletion */
    device_vtbl[6] = (void *)device_target;
    device_vtbl[7] = (void *)device_visual;
    device_vtbl[26] = (void *)device_state;
}

static HRESULT create_device(REFIID iid, void **device)
{
    (void)iid;
    if (!device) return E_POINTER;
    if (!(*device = obj_new(device_vtbl, NULL))) return E_OUTOFMEMORY;
    dcomp_log("[dcomp] DirectComposition device (presents through the window swap chain)\n");
    return S_OK;
}

HRESULT WINAPI DCompositionCreateDevice(IDXGIDevice *dxgi_device, REFIID iid, void **device)
{
    (void)dxgi_device;
    return create_device(iid, device);
}

HRESULT WINAPI DCompositionCreateDevice2(IUnknown *rendering_device, REFIID iid, void **device)
{
    (void)rendering_device;
    return create_device(iid, device);
}

HRESULT WINAPI DCompositionCreateDevice3(IUnknown *rendering_device, REFIID iid, void **device)
{
    (void)rendering_device;
    return create_device(iid, device);
}

HRESULT WINAPI DllCanUnloadNow(void) { return S_FALSE; }

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved)
{
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(inst);
        init_vtables();
        patch_factory();
    }
    return TRUE;
}
