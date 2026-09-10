// security_cookie.c — отдельный файл для __security_cookie,
// чтобы избежать конфликта с vcruntime.h (который wdf.h тянет).
// /GS- отключает проверки, но WDF-стаб (fxdriverentry.lib) ссылается
// на __security_cookie и __security_init_cookie.
#include <ntddk.h>

// FIX-6 (Task 33): uintptr_t -> ULONG_PTR: uintptr_t приходит из <stdint.h>/<vcruntime.h>,
// которых нет в km-инклудах WDK (ntddk.h) — риск C2061. ULONG_PTR гарантирован basetsd.h
// и на x64/x86 бинарно идентичен uintptr_t. Функции — __cdecl для соответствия vcruntime-декларациям.
ULONG_PTR __security_cookie = 0x1B2F3A4C5D6E7F80ULL;

void __cdecl __security_init_cookie(void)
{
    LARGE_INTEGER perf;
    perf = KeQueryPerformanceCounter(NULL);
    ULONG_PTR new_cookie = (ULONG_PTR)perf.QuadPart;
    new_cookie ^= (ULONG_PTR)&__security_cookie;
    if (new_cookie == 0) new_cookie = 0x1B2F3A4C5D6E7F80ULL;
    InterlockedExchangePointer((void * volatile *)&__security_cookie, (void *)new_cookie);
}

void __cdecl __security_check_cookie(ULONG_PTR cookie)
{
    UNREFERENCED_PARAMETER(cookie);
}