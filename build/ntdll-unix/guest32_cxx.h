/* SPDX-License-Identifier: LGPL-2.1-or-later
 * MSVC x86 throw metadata only. No exception object, what(), or guest calls. */
#ifndef MADEIRA_GUEST32_CXX_H
#define MADEIRA_GUEST32_CXX_H
#include "guest32_origin.h"
static int ios_g32_cxx_pointer(const struct ios_g32_origin *g, uint64_t p, uint32_t *guest)
{
    if (p >= g->window && p-g->window <= UINT32_MAX) p-=g->window;
    if (p < 0x10000 || p > UINT32_MAX) return 0;
    *guest=p;return 1;
}
static int ios_g32_cxx_metadata(const struct ios_g32_origin *g, uint32_t p, void *out, size_t n)
{
    const struct ios_g32_module *m=ios_g32_find(g,p);
    return m && n <= m->size-(p-m->base) && ios_g32_guest(g,p,out,n);
}
static void ios_g32_cxx_report(const struct ios_g32_origin *g, uint32_t flags, uint64_t address,
                               const uint64_t *params, unsigned count)
{
    uint32_t throwinfo, ti[4], array, total;
    dprintf(2,"[guest32-cxx-v1] flags=%#x address=%#llx count=%u magic=%#llx object=%#llx throwinfo=%#llx object-read=never\n",
            flags,(unsigned long long)address,count,
            (unsigned long long)(count>0?params[0]:0),(unsigned long long)(count>1?params[1]:0),
            (unsigned long long)(count>2?params[2]:0));
    if(count!=3 || params[0]<0x19930520 || params[0]>0x19930522 ||
       !ios_g32_cxx_pointer(g,params[2],&throwinfo) ||
       !ios_g32_cxx_metadata(g,throwinfo,ti,sizeof(ti))) return;
    ios_g32_address(g,"cpp-throw","throw-info",0,throwinfo);
    array=ti[3];
    if(!ios_g32_cxx_metadata(g,array,&total,4)||!total||total>64)return;
    for(unsigned i=0;i<total && i<4;i++)
    {
        uint32_t ct, desc;char name[96]={0};unsigned len=0;int terminated=0;
        if(array>UINT32_MAX-4-4*i||!ios_g32_cxx_metadata(g,array+4+4*i,&ct,4)||
           ct>UINT32_MAX-4||!ios_g32_cxx_metadata(g,ct+4,&desc,4)||desc>UINT32_MAX-8)break;
        for(;len<sizeof(name)-1;len++)
        {
            unsigned char ch;
            if(desc>UINT32_MAX-8-len||!ios_g32_cxx_metadata(g,desc+8+len,&ch,1))break;
            if(!ch){terminated=1;break;}
            /* Decorated RTTI identifiers, never arbitrary exception strings. */
            if(!((ch>='a'&&ch<='z')||(ch>='A'&&ch<='Z')||(ch>='0'&&ch<='9')||
                 ch=='.'||ch=='?'||ch=='@'||ch=='_'||ch=='$'))break;
            name[len]=ch;
        }
        if(terminated && len>3 && !memcmp(name,".?A",3))
            dprintf(2,"[guest32-cxx-type-v1] index=%u type=%s\n",i,name);
    }
}
#endif
