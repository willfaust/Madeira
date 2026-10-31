#ifndef MADEIRA_SIGNED_WINE_H
#define MADEIRA_SIGNED_WINE_H
#include <stdio.h>
int madeira_signed_wine_run(const char *fex, const char *image, const char *ntdll, FILE *report);
void madeira_signed_wine_if_requested(void);
#endif
