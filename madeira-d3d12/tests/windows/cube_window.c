/*  Visible rotating D3D12 cube: an x86-64 Windows program drawing through our
 *  D3D12 interfaces and presenting into the host window.
 *
 *  Every draw goes through the same device, command list, fence and submission
 *  path the offscreen tests exercise. Presentation uses the explicitly named
 *  test bridge rather than DXGI, because a swapchain brings format negotiation,
 *  buffer counts, resize and fullscreen with it, none of which is needed to show
 *  that the runtime draws.
 *
 *  Shaders are still matched fixtures, not runtime-converted DXIL. The window
 *  title says so, so nobody can watch this and conclude shader handling is done.
 */

#define COBJMACROS
#define INITGUID
#include <initguid.h>
#include <windows.h>
#include <d3d12.h>
#include <math.h>
#include <stdio.h>

#include "tri_dxil.h"
#include "cube_geom.h"
#include "root_sig.h"
#include "checker_tex.h"

typedef HRESULT (WINAPI *pfn_create)(IUnknown *, D3D_FEATURE_LEVEL, REFIID, void **);
typedef void *(*pfn_pcreate)(ID3D12Device *, intptr_t, UINT, UINT);
typedef ID3D12Resource *(*pfn_pacquire)(void *);
typedef void (*pfn_ppresent)(void *, ID3D12CommandQueue *);
typedef void (*pfn_pdestroy)(void *);

static LRESULT CALLBACK wndproc(HWND h, UINT m, WPARAM w, LPARAM l) {
    if (m == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcA(h, m, w, l);
}

int WINAPI WinMain(HINSTANCE inst, HINSTANCE prev, LPSTR cmd, int show) {
    (void)prev; (void)cmd;
    const UINT W = 640, H = 480;

    HMODULE dll = LoadLibraryA("madeira_d3d12.dll");
    if (!dll) { printf("cube: madeira_d3d12.dll not found (%lu)\n", GetLastError()); return 1; }
    pfn_create   create   = (pfn_create)GetProcAddress(dll, "MadeiraD3D12CreateDevice");
    pfn_serialize serialize = (pfn_serialize)GetProcAddress(dll, "MadeiraD3D12SerializeRootSignature");
    pfn_pcreate  pcreate  = (pfn_pcreate)GetProcAddress(dll, "MadeiraD3D12PresenterCreate");
    pfn_pacquire pacquire = (pfn_pacquire)GetProcAddress(dll, "MadeiraD3D12PresenterAcquire");
    pfn_ppresent ppresent = (pfn_ppresent)GetProcAddress(dll, "MadeiraD3D12PresenterPresent");
    pfn_pdestroy pdestroy = (pfn_pdestroy)GetProcAddress(dll, "MadeiraD3D12PresenterDestroy");
    if (!create || !serialize || !pcreate || !pacquire || !ppresent) {
        printf("cube: exports missing\n"); return 1;
    }

    WNDCLASSA wc; ZeroMemory(&wc, sizeof wc);
    wc.lpfnWndProc = wndproc; wc.hInstance = inst; wc.lpszClassName = "MadeiraD3D12Cube";
    wc.hCursor = LoadCursorA(NULL, (LPCSTR)IDC_ARROW);
    RegisterClassA(&wc);
    RECT r = { 0, 0, (LONG)W, (LONG)H };
    AdjustWindowRect(&r, WS_OVERLAPPEDWINDOW, FALSE);
    HWND hwnd = CreateWindowExA(0, wc.lpszClassName,
                                "Madeira D3D12 textured cube  [DXIL converted at runtime]",
                                WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT,
                                r.right - r.left, r.bottom - r.top, NULL, NULL, inst, NULL);
    if (!hwnd) { printf("cube: no window\n"); return 1; }
    ShowWindow(hwnd, show ? show : SW_SHOW);
    UpdateWindow(hwnd);

    ID3D12Device *dev = NULL;
    HRESULT hr = create(NULL, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&dev);
    if (FAILED(hr) || !dev) { printf("cube: no device %#lx\n", hr); return 1; }

    D3D12_COMMAND_QUEUE_DESC qd; ZeroMemory(&qd, sizeof qd);
    qd.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
    ID3D12CommandQueue *queue = NULL;
    ID3D12Device_CreateCommandQueue(dev, &qd, &IID_ID3D12CommandQueue, (void **)&queue);
    ID3D12CommandAllocator *alloc = NULL;
    ID3D12Device_CreateCommandAllocator(dev, D3D12_COMMAND_LIST_TYPE_DIRECT,
                                        &IID_ID3D12CommandAllocator, (void **)&alloc);
    ID3D12GraphicsCommandList *list = NULL;
    ID3D12Device_CreateCommandList(dev, 0, D3D12_COMMAND_LIST_TYPE_DIRECT, alloc, NULL,
                                   &IID_ID3D12GraphicsCommandList, (void **)&list);
    ID3D12GraphicsCommandList_Close(list);
    ID3D12Fence *fence = NULL;
    ID3D12Device_CreateFence(dev, 0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, (void **)&fence);
    HANDLE ev = CreateEventA(NULL, FALSE, FALSE, NULL);

    /* A real serialized root signature, parsed by the runtime and handed to the
     * converter. The shaders are compiled against THIS layout at pipeline
     * creation, so the binding the shader sees comes from what the application
     * declared rather than from anything built into the runtime. */
    static unsigned char rs_blob[512];
    ID3D12RootSignature *rootsig = make_textured_root_sig(dev, serialize, rs_blob, sizeof rs_blob);
    if (!rootsig) { printf("cube: no root signature\n"); return 1; }

    D3D12_GRAPHICS_PIPELINE_STATE_DESC pd; ZeroMemory(&pd, sizeof pd);
    pd.pRootSignature = rootsig;
    pd.VS.pShaderBytecode = texcube_vs_dxil; pd.VS.BytecodeLength = sizeof texcube_vs_dxil;
    pd.PS.pShaderBytecode = texcube_ps_dxil; pd.PS.BytecodeLength = sizeof texcube_ps_dxil;
    pd.NumRenderTargets = 1;
    pd.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;
    pd.DSVFormat = DXGI_FORMAT_D32_FLOAT;
    pd.SampleDesc.Count = 1;
    pd.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    /* A zeroed description leaves RenderTargetWriteMask at 0, "write no
     * channel": a runtime that honours the mask, as D3D12 does, draws the cube
     * every frame without writing a pixel (only the clear colour shows). Set the
     * write mask, and turn on the depth test texcube.hlsl is written for ("the
     * face towards the viewer wins the depth test"): with it off, as the zeroed
     * state had it, faces are drawn in index order and back faces cover front
     * ones as the cube turns. The depth buffer below already exists and is
     * cleared to 1.0 every frame. */
    pd.BlendState.RenderTarget[0].RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
    pd.SampleMask = 0xffffffffu;
    pd.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
    pd.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
    pd.RasterizerState.DepthClipEnable = TRUE;
    pd.DepthStencilState.DepthEnable = TRUE;
    pd.DepthStencilState.DepthWriteMask = D3D12_DEPTH_WRITE_MASK_ALL;
    pd.DepthStencilState.DepthFunc = D3D12_COMPARISON_FUNC_LESS;
    ID3D12PipelineState *pso = NULL;
    hr = ID3D12Device_CreateGraphicsPipelineState(dev, &pd, &IID_ID3D12PipelineState, (void **)&pso);
    if (FAILED(hr) || !pso) { printf("cube: no pipeline %#lx\n", hr); return 1; }

    D3D12_HEAP_PROPERTIES hp; ZeroMemory(&hp, sizeof hp);
    D3D12_RESOURCE_DESC td; ZeroMemory(&td, sizeof td);
    td.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    td.Width = W; td.Height = H; td.DepthOrArraySize = 1; td.MipLevels = 1;
    td.SampleDesc.Count = 1;
    td.Format = DXGI_FORMAT_D32_FLOAT;
    td.Flags = D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL;
    hp.Type = D3D12_HEAP_TYPE_DEFAULT;
    ID3D12Resource *depth = NULL;
    ID3D12Device_CreateCommittedResource(dev, &hp, D3D12_HEAP_FLAG_NONE, &td,
            D3D12_RESOURCE_STATE_DEPTH_WRITE, NULL, &IID_ID3D12Resource, (void **)&depth);

    D3D12_DESCRIPTOR_HEAP_DESC hd; ZeroMemory(&hd, sizeof hd);
    hd.NumDescriptors = 1;
    hd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
    ID3D12DescriptorHeap *rtvh = NULL;
    ID3D12Device_CreateDescriptorHeap(dev, &hd, &IID_ID3D12DescriptorHeap, (void **)&rtvh);
    hd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_DSV;
    ID3D12DescriptorHeap *dsvh = NULL;
    ID3D12Device_CreateDescriptorHeap(dev, &hd, &IID_ID3D12DescriptorHeap, (void **)&dsvh);

    D3D12_RESOURCE_DESC bd; ZeroMemory(&bd, sizeof bd);
    bd.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    bd.Height = 1; bd.DepthOrArraySize = 1; bd.MipLevels = 1;
    bd.Format = DXGI_FORMAT_UNKNOWN; bd.SampleDesc.Count = 1;
    bd.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    hp.Type = D3D12_HEAP_TYPE_UPLOAD;
    bd.Width = 1024;          /* rot + 24 positions + 24 colours */
    ID3D12Resource *cb = NULL;
    ID3D12Device_CreateCommittedResource(dev, &hp, D3D12_HEAP_FLAG_NONE, &bd,
            D3D12_RESOURCE_STATE_GENERIC_READ, NULL, &IID_ID3D12Resource, (void **)&cb);
    bd.Width = 128;
    ID3D12Resource *ib = NULL;
    ID3D12Device_CreateCommittedResource(dev, &hp, D3D12_HEAP_FLAG_NONE, &bd,
            D3D12_RESOURCE_STATE_GENERIC_READ, NULL, &IID_ID3D12Resource, (void **)&ib);
    /* The sampled texture, its staging buffer, and the shader-visible heaps the
     * descriptor tables point into. Same path the offscreen suite checks. */
    const UINT TEXW = CHECKER_DIM, TEXH = CHECKER_DIM;
    const UINT64 TEXBYTES = (UINT64)TEXW * TEXH * 4;
    D3D12_RESOURCE_DESC ctd; ZeroMemory(&ctd, sizeof ctd);
    ctd.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    ctd.Width = TEXW; ctd.Height = TEXH; ctd.DepthOrArraySize = 1; ctd.MipLevels = 1;
    ctd.Format = DXGI_FORMAT_R8G8B8A8_UNORM; ctd.SampleDesc.Count = 1;
    D3D12_HEAP_PROPERTIES dhp; ZeroMemory(&dhp, sizeof dhp);
    dhp.Type = D3D12_HEAP_TYPE_DEFAULT;
    ID3D12Resource *tex = NULL;
    ID3D12Device_CreateCommittedResource(dev, &dhp, D3D12_HEAP_FLAG_NONE, &ctd,
            D3D12_RESOURCE_STATE_COMMON, NULL, &IID_ID3D12Resource, (void **)&tex);

    bd.Width = TEXBYTES;
    ID3D12Resource *texup = NULL;
    ID3D12Device_CreateCommittedResource(dev, &hp, D3D12_HEAP_FLAG_NONE, &bd,
            D3D12_RESOURCE_STATE_GENERIC_READ, NULL, &IID_ID3D12Resource, (void **)&texup);

    D3D12_DESCRIPTOR_HEAP_DESC shd; ZeroMemory(&shd, sizeof shd);
    shd.NumDescriptors = 4;
    shd.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
    shd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
    ID3D12DescriptorHeap *srvh = NULL;
    ID3D12Device_CreateDescriptorHeap(dev, &shd, &IID_ID3D12DescriptorHeap, (void **)&srvh);
    shd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER;
    ID3D12DescriptorHeap *smph = NULL;
    ID3D12Device_CreateDescriptorHeap(dev, &shd, &IID_ID3D12DescriptorHeap, (void **)&smph);

    if (!depth || !rtvh || !dsvh || !cb || !ib) { printf("cube: resources failed\n"); return 1; }
    if (!tex || !texup || !srvh || !smph) { printf("cube: texture resources failed\n"); return 1; }

    BYTE *texels = NULL;
    ID3D12Resource_Map(texup, 0, NULL, (void **)&texels);
    if (texels) checker_fill(texels, TEXW, TEXW * 4);
    ID3D12Resource_Unmap(texup, 0, NULL);

    D3D12_CPU_DESCRIPTOR_HANDLE srv_cpu, smp_cpu;
    D3D12_GPU_DESCRIPTOR_HANDLE srv_gpu, smp_gpu;
    srvh->lpVtbl->GetCPUDescriptorHandleForHeapStart(srvh, &srv_cpu);
    smph->lpVtbl->GetCPUDescriptorHandleForHeapStart(smph, &smp_cpu);
    srvh->lpVtbl->GetGPUDescriptorHandleForHeapStart(srvh, &srv_gpu);
    smph->lpVtbl->GetGPUDescriptorHandleForHeapStart(smph, &smp_gpu);

    D3D12_SHADER_RESOURCE_VIEW_DESC svd; ZeroMemory(&svd, sizeof svd);
    svd.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    svd.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D;
    svd.Texture2D.MipLevels = 1;
    ID3D12Device_CreateShaderResourceView(dev, tex, &svd, srv_cpu);

    /* Point sampling, so a stretched or misaligned checker reads as hard edges
     * in the wrong place rather than as a blur that is easy to excuse. */
    D3D12_SAMPLER_DESC smd; ZeroMemory(&smd, sizeof smd);
    smd.Filter = D3D12_FILTER_MIN_MAG_MIP_POINT;
    smd.AddressU = smd.AddressV = smd.AddressW = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
    smd.MaxLOD = 0.0f;
    ID3D12Device_CreateSampler(dev, &smd, smp_cpu);

    /* Upload once, before the loop, on its own submission. */
    {
        ID3D12CommandAllocator_Reset(alloc);
        ID3D12GraphicsCommandList_Reset(list, alloc, NULL);
        D3D12_TEXTURE_COPY_LOCATION ud, us;
        ZeroMemory(&ud, sizeof ud); ZeroMemory(&us, sizeof us);
        ud.pResource = tex; us.pResource = texup;
        us.PlacedFootprint.Footprint.RowPitch = TEXW * 4;
        ID3D12GraphicsCommandList_CopyTextureRegion(list, &ud, 0, 0, 0, &us, NULL);
        ID3D12GraphicsCommandList_Close(list);
        ID3D12CommandList *ul[1]; ul[0] = (ID3D12CommandList *)list;
        UINT64 uv = ID3D12Fence_GetCompletedValue(fence) + 1;
        ID3D12CommandQueue_ExecuteCommandLists(queue, 1, ul);
        ID3D12Fence_SetEventOnCompletion(fence, uv, ev);
        ID3D12CommandQueue_Signal(queue, fence, uv);
        WaitForSingleObject(ev, 5000);
        /* Flushed explicitly: stdout is block-buffered and this demo no longer
         * exits, so buffered output never reached the log. Earlier runs only
         * showed their frame counts because the process terminated. */
        printf("cube: texture uploaded (%ux%u)\n", TEXW, TEXH);
        fflush(stdout);
    }

    unsigned short *ibp = NULL;
    ID3D12Resource_Map(ib, 0, NULL, (void **)&ibp);
    if (ibp) memcpy(ibp, cube_idx, sizeof cube_idx);
    ID3D12Resource_Unmap(ib, 0, NULL);

    D3D12_INDEX_BUFFER_VIEW ibv;
    ibv.BufferLocation = ID3D12Resource_GetGPUVirtualAddress(ib);
    ibv.SizeInBytes = (UINT)sizeof cube_idx;
    ibv.Format = DXGI_FORMAT_R16_UINT;

    void *pres = pcreate(dev, (intptr_t)hwnd, W, H);
    if (!pres) { printf("cube: presenter failed\n"); return 1; }

    D3D12_CPU_DESCRIPTOR_HANDLE rtv, dsv;
    rtvh->lpVtbl->GetCPUDescriptorHandleForHeapStart(rtvh, &rtv);
    dsvh->lpVtbl->GetCPUDescriptorHandleForHeapStart(dsvh, &dsv);
    ID3D12Device_CreateDepthStencilView(dev, depth, NULL, dsv);

    printf("cube: entering the frame loop\n");
    UINT64 fv = 0;
    float yaw = 0.0f, pitch = 0.0f;
    int running = 1, frames = 0;
    while (running) {
        MSG msg;
        while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) {
            if (msg.message == WM_QUIT) { running = 0; break; }
            TranslateMessage(&msg); DispatchMessageA(&msg);
        }
        if (!running) break;

        ID3D12Resource *back = pacquire(pres);
        if (!back) { Sleep(16); continue; }
        ID3D12Device_CreateRenderTargetView(dev, back, NULL, rtv);

        float *p = NULL;
        ID3D12Resource_Map(cb, 0, NULL, (void **)&p);
        if (p) {
            /* Yaw and pitch advance at different, non-commensurate rates, so the
             * cube tumbles through orientations instead of repeating a path that
             * leaves two faces permanently edge-on. */
            p[0] = (float)cos((double)yaw);   p[1] = (float)sin((double)yaw);
            p[2] = (float)cos((double)pitch); p[3] = (float)sin((double)pitch);
            memcpy(p + 4, cube_pos, sizeof cube_pos);
            memcpy(p + 4 + 24 * 4, cube_col, sizeof cube_col);
        }
        ID3D12Resource_Unmap(cb, 0, NULL);
        yaw   += 0.013f;
        pitch += 0.0079f;

        const FLOAT clear[4] = { 0.06f, 0.07f, 0.10f, 1.0f };
        D3D12_VIEWPORT vp; vp.TopLeftX = 0; vp.TopLeftY = 0;
        vp.Width = (FLOAT)W; vp.Height = (FLOAT)H; vp.MinDepth = 0; vp.MaxDepth = 1;

        ID3D12GraphicsCommandList_Reset(list, alloc, NULL);
        ID3D12GraphicsCommandList_OMSetRenderTargets(list, 1, &rtv, FALSE, &dsv);
        ID3D12GraphicsCommandList_ClearRenderTargetView(list, rtv, clear, 0, NULL);
        ID3D12GraphicsCommandList_ClearDepthStencilView(list, dsv, D3D12_CLEAR_FLAG_DEPTH, 1.0f, 0, 0, NULL);
        ID3D12GraphicsCommandList_SetPipelineState(list, pso);
        ID3D12GraphicsCommandList_SetGraphicsRootSignature(list, rootsig);
        ID3D12DescriptorHeap *bound[2]; bound[0] = srvh; bound[1] = smph;
        ID3D12GraphicsCommandList_SetDescriptorHeaps(list, 2, bound);
        ID3D12GraphicsCommandList_SetGraphicsRootDescriptorTable(list, 1, srv_gpu);
        ID3D12GraphicsCommandList_SetGraphicsRootDescriptorTable(list, 2, smp_gpu);
        ID3D12GraphicsCommandList_SetGraphicsRootConstantBufferView(list, 0,
                ID3D12Resource_GetGPUVirtualAddress(cb));
        ID3D12GraphicsCommandList_RSSetViewports(list, 1, &vp);
        ID3D12GraphicsCommandList_IASetPrimitiveTopology(list, D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        ID3D12GraphicsCommandList_IASetIndexBuffer(list, &ibv);
        ID3D12GraphicsCommandList_DrawIndexedInstanced(list,
                (UINT)(sizeof cube_idx / sizeof cube_idx[0]), 1, 0, 0, 0);
        ID3D12GraphicsCommandList_Close(list);

        ID3D12CommandList *ls[1] = { (ID3D12CommandList *)list };
        ID3D12CommandQueue_ExecuteCommandLists(queue, 1, ls);
        ppresent(pres, queue);

        /* One frame in flight: the allocator cannot be reused until the GPU has
         * finished with what was recorded into it. */
        ID3D12Fence_SetEventOnCompletion(fence, ++fv, ev);
        ID3D12CommandQueue_Signal(queue, fence, fv);
        WaitForSingleObject(ev, 5000);
        ID3D12CommandAllocator_Reset(alloc);

        /* Runs until the window is closed. An earlier build stopped at a fixed
         * frame count, which from the outside looked exactly like a crash or a
         * hang: the cube simply stopped and the process was gone. A visible demo
         * should end when the user ends it. */
        if (++frames % 600 == 0) printf("cube: %d frames\n", frames);
    }

    printf("cube: %d frames drawn\n", frames);
    if (pdestroy) pdestroy(pres);
    CloseHandle(ev);
    if (ib) ID3D12Resource_Release(ib);
    if (cb) ID3D12Resource_Release(cb);
    if (dsvh) ID3D12DescriptorHeap_Release(dsvh);
    if (rtvh) ID3D12DescriptorHeap_Release(rtvh);
    if (depth) ID3D12Resource_Release(depth);
    if (pso) ID3D12PipelineState_Release(pso);
    if (fence) ID3D12Fence_Release(fence);
    if (list) ID3D12GraphicsCommandList_Release(list);
    if (alloc) ID3D12CommandAllocator_Release(alloc);
    if (queue) ID3D12CommandQueue_Release(queue);
    ID3D12Device_Release(dev);
    return 0;
}
