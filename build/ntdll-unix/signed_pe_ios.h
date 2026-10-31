/* SPDX-License-Identifier: LGPL-2.1-or-later */
#ifndef MADEIRA_SIGNED_PE_H
#define MADEIRA_SIGNED_PE_H
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

struct madeira_signed_pe;
typedef void *(*madeira_pe_resolver)(void *context, const char *dll, const char *name, uint16_t ordinal);
struct madeira_signed_pe *madeira_pe_open(const char *framework, FILE *report);
void madeira_pe_close(struct madeira_signed_pe *module);
void *madeira_pe_image(struct madeira_signed_pe *module);
void *madeira_pe_export(struct madeira_signed_pe *module, const char *name, uint16_t ordinal);
int madeira_pe_bind(struct madeira_signed_pe *module, madeira_pe_resolver resolver, void *context);
int madeira_pe_check(struct madeira_signed_pe *module);
int madeira_pe_wine_enabled(void);
int madeira_pe_wine_configure(void);
int madeira_pe_wine_attach(void *image, size_t size);
int madeira_pe_wine_sync(void *address, size_t size);
void *madeira_pe_wine_translate(const void *address, int reverse);
void madeira_pe_wine_detach(void *image);
int madeira_pe_wine_code_overlap(const void *address, size_t size);
#endif
