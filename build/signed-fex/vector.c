#include <stdint.h>
#if defined(_WIN32) && defined(__x86_64__)
#define ENTRY __declspec(dllexport) __attribute__((naked)) uint64_t
#define SHUFFLE(NAME, OP, H, L, ARGS) \
    ENTRY vector_##NAME##_##H##_##L(uint64_t seed) { __asm__(#OP " $(" #H "*16+" #L "), " ARGS "\n retq"); }
#define TEST(H, L) \
    SHUFFLE(pshuflw, pshuflw, H, L, "%xmm0, %xmm0") \
    SHUFFLE(pshufhw, pshufhw, H, L, "%xmm0, %xmm0") \
    SHUFFLE(pshufd, pshufd, H, L, "%xmm0, %xmm0") \
    SHUFFLE(shufps, shufps, H, L, "%xmm1, %xmm0") \
    SHUFFLE(pblendw, pblendw, H, L, "%xmm1, %xmm0") \
    SHUFFLE(dpps, dpps, H, L, "%xmm1, %xmm0") \
    SHUFFLE(dppd, dppd, H, L, "%xmm1, %xmm0")
#define ROW(H) TEST(H,0) TEST(H,1) TEST(H,2) TEST(H,3) TEST(H,4) TEST(H,5) TEST(H,6) TEST(H,7) \
               TEST(H,8) TEST(H,9) TEST(H,10) TEST(H,11) TEST(H,12) TEST(H,13) TEST(H,14) TEST(H,15)
ROW(0) ROW(1) ROW(2) ROW(3) ROW(4) ROW(5) ROW(6) ROW(7)
ROW(8) ROW(9) ROW(10) ROW(11) ROW(12) ROW(13) ROW(14) ROW(15)
#endif
uint64_t guest_workload(uint64_t seed) { return seed; }
