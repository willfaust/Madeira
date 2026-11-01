/* SPDX-License-Identifier: LGPL-2.1-or-later
 * Read-only observation of the exact CEF build's AtExit registration failure.
 * Include after guest32_origin.h; ios_g32_read must be fault-safe. */
#ifndef MADEIRA_CEF_ATEXIT_CONTEXT_H
#define MADEIRA_CEF_ATEXIT_CONTEXT_H
struct ios_cef_atexit_state { uint32_t top_rva, top, lazy_rva, lazy, object, destructor; };
static int ios_cef_section( const struct ios_g32_origin *g, const struct ios_g32_module *m,
                            uint32_t rva, size_t size, uint32_t flag )
{
    uint32_t nt;uint16_t count,opt;
    if(!ios_g32_pe(g,m,&nt)||!ios_g32_rva(g,m,nt+6,&count,2)||count>96||
       !ios_g32_rva(g,m,nt+20,&opt,2)||opt>4096)return 0;
    for(unsigned i=0;i<count;i++)
    {
        uint32_t row[10];
        if(!ios_g32_rva(g,m,nt+24+opt+40*i,row,sizeof(row)))return 0;
        if((row[9]&flag)&&rva>=row[3]&&rva-row[3]<row[2]&&size<=row[2]-(rva-row[3]))return 1;
    }
    return 0;
}
static int ios_cef_exact_identity( const struct ios_g32_origin *g, const struct ios_g32_module *m )
{
    static const unsigned char guid[16]={0x5b,0x3c,0x13,0x4d,0xbe,0x4f,0x47,0x41,0x4c,0x4c,0x44,0x20,0x50,0x44,0x42,0x2e};
    uint32_t nt,debug[2];
    if(m->size!=0xb42a000||!ios_g32_pe(g,m,&nt)||!ios_g32_rva(g,m,nt+24+96+6*8,debug,8)||debug[1]/28>64)return 0;
    for(unsigned i=0;i<debug[1]/28;i++)
    {
        uint32_t row[7],cv[6];
        if(debug[0]>UINT32_MAX-i*28||!ios_g32_rva(g,m,debug[0]+i*28,row,sizeof(row)))return 0;
        if(row[3]==2&&row[4]>=24&&ios_g32_rva(g,m,row[5],cv,sizeof(cv))&&cv[0]==0x53445352&&cv[5]==1&&
           !memcmp(&cv[1],guid,16))return 1;
    }
    return 0;
}
static int ios_cef_atexit_capture( const struct ios_g32_origin *g, const struct ios_g32_module *m,
                                 struct ios_cef_atexit_state *out )
{
    /* CompleteLazyInstance's exact body, including its RegisterCallback call.
     * GUID guards offsets; opcodes independently guard the interpretation. */
    static const unsigned char prefix[33]={0x55,0x89,0xe5,0x8b,0x45,0x10,0x8b,0x4d,0x0c,0x8b,0x55,0x08,0x89,0x0a,0x85,0xc9,0x0f,0x94,0xc1,0x85,0xc0,0x0f,0x94,0xc2,0x08,0xca,0x75,0x0c,0xff,0x75,0x14,0x50,0xe8};
    static const unsigned char suffix[5]={0x83,0xc4,0x08,0x5d,0xc3};
    unsigned char helper[42],callback[240],caller[80];int32_t rel;uint32_t cb,top_va=0;unsigned hits=0;
    memset(out,0,sizeof(*out));
    if(!ios_cef_exact_identity(g,m)||!ios_cef_section(g,m,0xdf4990,sizeof(helper),0x20000000)||
       !ios_g32_rva(g,m,0xdf4990,helper,sizeof(helper))||memcmp(helper,prefix,sizeof(prefix))||memcmp(helper+37,suffix,5))return 0;
    memcpy(&rel,helper+33,4);if((int64_t)0xdf49b5+rel!=0xdfcd80)return 0;cb=0xdfcd80;
    if(!ios_cef_section(g,m,cb,sizeof(callback),0x20000000)||!ios_g32_rva(g,m,cb,callback,sizeof(callback)))return 0;
    /* Discover g_top_manager from the actual null-test branch. A matching
     * branch must call this build's TriggerNotReached, not another CHECK. */
    for(unsigned i=0;i+10<sizeof(callback);i++)
    {
        if(callback[i]!=0x8b||callback[i+1]!=0x35||callback[i+6]!=0x85||callback[i+7]!=0xf6||callback[i+8]!=0x74)continue;
        int target=(int)i+10+(int8_t)callback[i+9];
        if(target<0||target+5>(int)sizeof(callback)||callback[target]!=0xe8)continue;
        memcpy(&rel,callback+target+1,4);if((int64_t)cb+target+5+rel!=0x592f960)continue;
        memcpy(&top_va,callback+i+2,4);hits++;
    }
    if(hits!=1||top_va<m->base||!ios_cef_section(g,m,top_va-m->base,4,0x80000000)||
       !ios_g32_guest(g,top_va,&out->top,4))return 0;
    out->top_rva=top_va-m->base;
    /* At the recorded caller: published LazyInstance state, object pointer,
     * and destructor. Do not read object data or infer its template type. */
    if(!ios_cef_section(g,m,0x8e44e7,sizeof(caller),0x20000000)||!ios_g32_rva(g,m,0x8e44e7,caller,sizeof(caller))||
       caller[1]!=0xbf||caller[47]!=0x57||caller[48]!=0x68||caller[53]!=0x68||caller[58]!=0x57||caller[59]!=0xe8)return 0;
    uint32_t lazy_va;memcpy(&lazy_va,caller+2,4);memcpy(&out->destructor,caller+49,4);memcpy(&out->object,caller+54,4);
    memcpy(&rel,caller+60,4);if((int64_t)0x8e4527+rel!=0xdf4990||lazy_va<m->base||lazy_va>UINT32_MAX-4||
       out->object!=lazy_va+4||out->destructor<m->base||!ios_cef_section(g,m,out->destructor-m->base,1,0x20000000)||
       !ios_cef_section(g,m,lazy_va-m->base,4,0x80000000)||!ios_g32_guest(g,lazy_va,&out->lazy,4))return 0;
    out->lazy_rva=lazy_va-m->base;return 1;
}
static void ios_cef_atexit_report( const struct ios_g32_origin *g )
{
    for(unsigned i=0;i<g->count;i++)if(!strcmp(g->modules[i].name,"libcef.dll"))
    {
        struct ios_cef_atexit_state state;
        if(ios_cef_atexit_capture(g,&g->modules[i],&state))
            dprintf(2,"[cef-atexit-v1] top-global=libcef.dll+%#x top=%#x manager-null=%u lazy-state=libcef.dll+%#x value=%#x published=%u object=%#x destructor=%#x observation=read-only\n",
                    state.top_rva,state.top,state.top==0,state.lazy_rva,state.lazy,state.lazy==state.object,state.object,state.destructor);
        else dprintf(2,"[cef-atexit-v1] unavailable: build/opcode/section/read validation failed; no state inferred\n");
        return;
    }
}
#endif
