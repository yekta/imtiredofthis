#ifndef ROUTEY_ARCH_CC_H
#define ROUTEY_ARCH_CC_H

#include <stdlib.h>
#include <sys/types.h>

#define LWIP_TIMEVAL_PRIVATE                    0
#define LWIP_ERRNO_INCLUDE                      <errno.h>
#define LWIP_DONT_PROVIDE_BYTEORDER_FUNCTIONS   1
#define LWIP_RAND()                             ((u32_t)arc4random())

/* Nothing is ever printed. */
#define LWIP_PLATFORM_DIAG(x)
#define LWIP_PLATFORM_ASSERT(x)                 abort()

#endif
