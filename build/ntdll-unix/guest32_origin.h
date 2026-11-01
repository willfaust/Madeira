/* SPDX-License-Identifier: LGPL-2.1-or-later
 * Fault-safe, bounded metadata-only guest diagnostics. The includer supplies
 * ios_g32_read(uint64_t, void *, size_t); no guest code or loader lock runs. */
#ifndef MADEIRA_GUEST32_ORIGIN_H
#define MADEIRA_GUEST32_ORIGIN_H
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

struct ios_g32_module { uint32_t base, size; char name[48]; };
struct ios_g32_origin {
    uint64_t window;
    uint32_t rip, esp, ebp, teb, low, high, seh;
    unsigned count;
    struct ios_g32_module modules[96];
};
static int ios_g32_guest( const struct ios_g32_origin *g, uint32_t p, void *out, size_t n )
{
    return p >= 0x10000 && n <= 0x100000000ULL - p && ios_g32_read(g->window + p, out, n);
}
static int ios_g32_capture( struct ios_g32_origin *g, uint64_t teb, uint64_t window, uint64_t frame )
{
    int32_t offset;
    uint64_t regs[10];
    uint32_t peb, ldr, head, link;
    memset(g, 0, sizeof(*g));
    g->window = window;
    if (!window || !frame || !ios_g32_read(frame, regs, sizeof(regs)) ||
        regs[3] > UINT32_MAX || regs[8] > UINT32_MAX || regs[9] > UINT32_MAX ||
        !ios_g32_read(teb + 0x180c, &offset, 4)) return 0;
    uint64_t t32 = teb + offset;
    if (t32 < window || t32 - window > UINT32_MAX) return 0;
    if (t32 - window > UINT32_MAX - 0x34) return 0;
    g->teb = t32 - window; g->rip = regs[3]; g->esp = regs[8]; g->ebp = regs[9];
    if (!ios_g32_guest(g, g->teb, &g->seh, 4) ||
        !ios_g32_guest(g, g->teb + 4, &g->high, 4) ||
        !ios_g32_guest(g, g->teb + 8, &g->low, 4) ||
        !ios_g32_guest(g, g->teb + 0x30, &peb, 4) ||
        peb > UINT32_MAX - 0x0c || !ios_g32_guest(g, peb + 0x0c, &ldr, 4) || !ldr || ldr > UINT32_MAX - 0x0c) return 0;
    head = ldr + 0x0c;
    if (!ios_g32_guest(g, head, &link, 4)) return 0;
    for (unsigned i = 0; link && link != head && i < 192 && g->count < 96; i++)
    {
        uint32_t next, base, size, name;
        uint16_t len;
        if (link > UINT32_MAX - 0x34 || !ios_g32_guest(g, link, &next, 4) ||
            !ios_g32_guest(g, link + 0x18, &base, 4) || !ios_g32_guest(g, link + 0x20, &size, 4) ||
            !ios_g32_guest(g, link + 0x2c, &len, 2) || !ios_g32_guest(g, link + 0x30, &name, 4)) break;
        if (base && size && size <= UINT32_MAX - base)
        {
            struct ios_g32_module *m = &g->modules[g->count++];
            m->base = base; m->size = size;
            for (unsigned j = 0; j < len / 2 && j < sizeof(m->name) - 1; j++)
            {
                uint16_t ch;
                if (name > UINT32_MAX - 2 * j || !ios_g32_guest(g, name + 2 * j, &ch, 2)) break;
                m->name[j] = ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
                             (ch >= '0' && ch <= '9') || ch == '.' || ch == '_' || ch == '-') ? ch : '?';
            }
        }
        if (next == link) break;
        link = next;
    }
    return g->count != 0;
}
static const struct ios_g32_module *ios_g32_find( const struct ios_g32_origin *g, uint32_t p )
{
    for (unsigned i = 0; i < g->count; i++)
        if (p >= g->modules[i].base && p - g->modules[i].base < g->modules[i].size) return &g->modules[i];
    return NULL;
}
static int ios_g32_rva( const struct ios_g32_origin *g, const struct ios_g32_module *m,
                       uint32_t rva, void *out, size_t n )
{
    return rva < m->size && n <= m->size - rva && ios_g32_guest(g, m->base + rva, out, n);
}
static void ios_g32_address( const struct ios_g32_origin *g, const char *tag, const char *kind,
                            unsigned index, uint32_t p )
{
    const struct ios_g32_module *m = ios_g32_find(g, p);
    if (m) dprintf(2, "[guest32-origin] tag=%s %s+%#x=%s+%#x\n", tag, kind, index, m->name, p - m->base);
}
/* PE identity enables matching symbols instead of guessing from a nearby
 * export. CodeView paths are reduced to a sanitized basename. */
static int ios_g32_pe( const struct ios_g32_origin *g, const struct ios_g32_module *m, uint32_t *nt )
{
    uint16_t mz, magic;
    uint32_t sig;
    return ios_g32_rva(g,m,0,&mz,2) && mz == 0x5a4d && ios_g32_rva(g,m,0x3c,nt,4) &&
           *nt <= 0x100000 && ios_g32_rva(g,m,*nt,&sig,4) && sig == 0x4550 &&
           ios_g32_rva(g,m,*nt+24,&magic,2) && magic == 0x10b;
}
static void ios_g32_identity( const struct ios_g32_origin *g, const char *tag, uint32_t p )
{
    const struct ios_g32_module *m = ios_g32_find(g,p);
    uint32_t nt, stamp, check, debug[2];
    if (!m || !ios_g32_pe(g,m,&nt) || !ios_g32_rva(g,m,nt+8,&stamp,4) ||
        !ios_g32_rva(g,m,nt+24+64,&check,4)) return;
    dprintf(2,"[guest32-image] tag=%s module=%s size=%#x timestamp=%08x checksum=%08x\n",tag,m->name,m->size,stamp,check);
    if (!ios_g32_rva(g,m,nt+24+96+6*8,debug,8) || debug[1] / 28 > 64) return;
    for (unsigned i=0;i<debug[1]/28;i++)
    {
        uint32_t row[7], cv[6]; char pdb[64]={0}; unsigned n=0;
        if (debug[0] > UINT32_MAX-i*28 || !ios_g32_rva(g,m,debug[0]+i*28,row,sizeof(row))) break;
        if (row[3]!=2 || row[4]<24 || !ios_g32_rva(g,m,row[5],cv,sizeof(cv)) || cv[0]!=0x53445352) continue;
        unsigned count=row[4]-24; if(count>256)count=256;
        for(unsigned j=0;j<count;j++)
        {
            unsigned char c;
            if(row[5]>UINT32_MAX-24-j || !ios_g32_rva(g,m,row[5]+24+j,&c,1) || !c)break;
            if(c=='/' || c=='\\'){n=0;memset(pdb,0,sizeof(pdb));continue;}
            if(n<sizeof(pdb)-1)pdb[n++]=((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='.'||c=='_'||c=='-')?c:'?';
        }
        const unsigned char *b=(const unsigned char*)&cv[1];
        dprintf(2,"[guest32-symbols] module=%s pdb=%s guid=%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X age=%x\n",
                m->name,pdb,b[3],b[2],b[1],b[0],b[5],b[4],b[7],b[6],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15],cv[5]);
        break;
    }
}
/* A bounded nearest-export annotation is distinct from a private symbol or
 * an unwind. Exact entry-point hooks usually resolve without a PDB. */
static void ios_g32_export( const struct ios_g32_origin *g, const char *tag, uint32_t p )
{
    const struct ios_g32_module *m=ios_g32_find(g,p);
    uint32_t nt,dir[2],e[10],best=0,index=0;
    if(!m||!ios_g32_pe(g,m,&nt)||!ios_g32_rva(g,m,nt+24+96,dir,8)||!dir[0]||
       !ios_g32_rva(g,m,dir[0],e,sizeof(e))||e[5]>16384||e[6]>16384)return;
    for(unsigned start=0;start<e[5];start+=64)
    {
        uint32_t rvas[64];unsigned n=e[5]-start;if(n>64)n=64;
        if(e[7]>UINT32_MAX-start*4||!ios_g32_rva(g,m,e[7]+start*4,rvas,n*4))return;
        for(unsigned j=0;j<n;j++)
            if(rvas[j] && rvas[j]<=p-m->base && rvas[j]>=best &&
               !(rvas[j]>=dir[0] && rvas[j]-dir[0]<dir[1])){best=rvas[j];index=start+j;}
    }
    if(!best||p-m->base-best>0x400)return;
    for(unsigned start=0;start<e[6];start+=64)
    {
        uint16_t ord[64];unsigned n=e[6]-start;if(n>64)n=64;
        if(e[9]>UINT32_MAX-start*2||!ios_g32_rva(g,m,e[9]+start*2,ord,n*2))return;
        for(unsigned j=0;j<n;j++)if(ord[j]==index)
        {
            uint32_t rva;char name[80]={0};
            if(e[8]>UINT32_MAX-(start+j)*4||!ios_g32_rva(g,m,e[8]+(start+j)*4,&rva,4))return;
            for(unsigned k=0;k<sizeof(name)-1;k++)
            {
                unsigned char ch;
                if(rva>UINT32_MAX-k||!ios_g32_rva(g,m,rva+k,&ch,1)||!ch)break;
                name[k]=((ch>='a'&&ch<='z')||(ch>='A'&&ch<='Z')||(ch>='0'&&ch<='9')||ch=='_'||ch=='@'||ch=='?')?ch:'?';
            }
            dprintf(2,"[guest32-export] tag=%s %s+%#x nearest-export=%s+%#x\n",tag,m->name,p-m->base,name,p-m->base-best);return;
        }
    }
}
static void ios_g32_code( const struct ios_g32_origin *g, const char *tag, uint32_t p )
{
    const struct ios_g32_module *m=ios_g32_find(g,p);
    uint32_t nt; uint16_t sections,opt;
    if(!m||!ios_g32_pe(g,m,&nt)||!ios_g32_rva(g,m,nt+6,&sections,2)||sections>96||
       !ios_g32_rva(g,m,nt+20,&opt,2)||opt>4096)return;
    for(unsigned i=0;i<sections;i++)
    {
        uint32_t row[10]; unsigned char code[16];char hex[49]={0};
        if(!ios_g32_rva(g,m,nt+24+opt+40*i,row,sizeof(row)))break;
        if(!(row[9]&0x20000000)||p-m->base<row[3]||p-m->base-row[3]>=row[2])continue;
        size_t n=row[2]-(p-m->base-row[3]);if(n>16)n=16;
        if(!ios_g32_rva(g,m,p-m->base,code,n))return;
        for(unsigned j=0;j<n;j++)snprintf(hex+3*j,4,"%02x ",code[j]);
        dprintf(2,"[guest32-code] tag=%s %s+%#x bytes=%s\n",tag,m->name,p-m->base,hex);return;
    }
}
/* Exact symbols may be unavailable for Valve's CEF build. Capture a small
 * executable-only window around real EBP returns so an offline disassembler
 * can inspect the call/branch and nearby API arguments. Never scan strings,
 * data, arbitrary stack contents or guessed function boundaries. */
static void ios_g32_callsite( const struct ios_g32_origin *g, const char *tag, unsigned frame, uint32_t p )
{
    const struct ios_g32_module *m=ios_g32_find(g,p);
    uint32_t nt;uint16_t sections,opt;
    if(!m||(strcmp(m->name,"libcef.dll")&&strcmp(m->name,"vk_swiftshader.dll")&&
            strcmp(m->name,"vcruntime140.dll")&&strcmp(m->name,"msvcp140.dll"))||!ios_g32_pe(g,m,&nt)||
       !ios_g32_rva(g,m,nt+6,&sections,2)||sections>96||
       !ios_g32_rva(g,m,nt+20,&opt,2)||opt>4096)return;
    for(unsigned i=0;i<sections;i++)
    {
        uint32_t row[10],rva=p-m->base;unsigned char bytes[80];char hex[241]={0};
        if(!ios_g32_rva(g,m,nt+24+opt+40*i,row,sizeof(row)))return;
        if(!(row[9]&0x20000000)||rva<row[3]||rva-row[3]>=row[2])continue;
        unsigned prefix=rva-row[3];if(prefix>64)prefix=64;
        uint32_t start=rva-prefix;size_t size=(uint64_t)row[3]+row[2]-start;
        if(size>sizeof(bytes))size=sizeof(bytes);
        if(!ios_g32_rva(g,m,start,bytes,size))return;
        for(unsigned j=0;j<size;j++)snprintf(hex+3*j,4,"%02x ",bytes[j]);
        dprintf(2,"[guest32-callsite-v1] tag=%s frame=%u return=%s+%#x code=%s+%#x bytes=%s\n",
                tag,frame,m->name,rva,m->name,start,hex);
        return;
    }
}
static void ios_g32_report( const struct ios_g32_origin *g, const char *tag, uint32_t target )
{
    dprintf(2,"[guest32-state] tag=%s window=%p rip=%#x esp=%#x ebp=%#x stack=[%#x,%#x) seh=%#x\n",
            tag,(void*)(uintptr_t)g->window,g->rip,g->esp,g->ebp,g->low,g->high,g->seh);
    ios_g32_address(g,tag,"rip",0,g->rip);ios_g32_export(g,tag,g->rip);ios_g32_identity(g,tag,g->rip);ios_g32_code(g,tag,g->rip?g->rip-1:0);
    const struct ios_g32_module *at = ios_g32_find(g,g->rip);
    if(!at || strcmp(at->name,"libcef.dll"))
        for(unsigned i=0;i<g->count;i++)
            if(!strcmp(g->modules[i].name,"libcef.dll")){ios_g32_identity(g,tag,g->modules[i].base);break;}
    if(target){ios_g32_address(g,tag,"target",0,target);ios_g32_export(g,tag,target);ios_g32_identity(g,tag,target);ios_g32_code(g,tag,target);}
    if(g->low>=g->high || g->esp<g->low || g->esp>=g->high)return;
    for(unsigned i=0,emitted=0;i<128&&emitted<20;i++)
    {
        uint32_t value;uint64_t a=(uint64_t)g->esp+4*i;
        if(a+4>g->high || !ios_g32_guest(g,a,&value,4))break;
        if(ios_g32_find(g,value)){ios_g32_address(g,tag,"stack-candidate",4*i,value);emitted++;}
    }
    uint32_t bp=g->ebp;
    for(unsigned i=0;i<8;i++)
    {
        uint32_t row[2];
        if((bp&3)||bp<g->esp||(uint64_t)bp+8>g->high||!ios_g32_guest(g,bp,row,8))break;
        ios_g32_address(g,tag,"ebp-return",i,row[1]);
        if(!strcmp(tag,"cef-assert")||!strcmp(tag,"breakpoint")||!strcmp(tag,"breakpoint-terminate")||!strcmp(tag,"cpp-throw"))
            ios_g32_callsite(g,tag,i,row[1]);
        if(row[0]<=bp||row[0]-bp>0x100000)break;bp=row[0];
    }
    uint32_t seh=g->seh;
    for(unsigned i=0;i<8&&seh!=UINT32_MAX;i++)
    {
        uint32_t row[2];
        if((seh&3)||seh<g->low||(uint64_t)seh+8>g->high||!ios_g32_guest(g,seh,row,8))break;
        ios_g32_address(g,tag,"seh-handler",i,row[1]);
        if(row[0]<=seh)break;seh=row[0];
    }
}
#endif
