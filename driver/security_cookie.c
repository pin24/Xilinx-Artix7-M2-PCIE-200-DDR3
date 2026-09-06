// security_cookie.c — отдельный файл для __security_cookie,
// чтобы избежать конфликта с vcruntime.h (который wdf.h тянет).
// /GS- отключает проверки, но WDF-стаб (fxdriverentry.lib) ссылается
// на __security_cookie и __security_init_cookie.
#include <ntddk.h>

uintptr_t __security_cookie = 0x1B2F3A4C5D6E7F80ULL;

void __security_init_cookie(void)
{
    LARGE_INTEGER perf;
    perf = KeQueryPerformanceCounter(NULL);
    uintptr_t new_cookie = (uintptr_t)perf.QuadPart;
    new_cookie ^= (uintptr_t)&__security_cookie;
    if (new_cookie == 0) new_cookie = 0x1B2F3A4C5D6E7F80ULL;
    InterlockedExchangePointer((void * volatile *)&__security_cookie, (void *)new_cookie);
}

void __security_check_cookie(uintptr_t cookie)
{
    UNREFERENCED_PARAMETER(cookie);
}