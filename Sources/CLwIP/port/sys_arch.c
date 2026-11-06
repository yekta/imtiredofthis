#include <time.h>
#include "lwip/sys.h"

u32_t sys_now(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (u32_t)(now.tv_sec * 1000 + now.tv_nsec / 1000000);
}
