#ifndef MACMTP_LIBMTP_GPHOTO2_ENDIAN_H
#define MACMTP_LIBMTP_GPHOTO2_ENDIAN_H

#include <libkern/OSByteOrder.h>
#include <stdint.h>

#define htole16(x) OSSwapHostToLittleInt16((uint16_t)(x))
#define htole32(x) OSSwapHostToLittleInt32((uint32_t)(x))
#define htole64(x) OSSwapHostToLittleInt64((uint64_t)(x))
#define htobe16(x) OSSwapHostToBigInt16((uint16_t)(x))
#define htobe32(x) OSSwapHostToBigInt32((uint32_t)(x))
#define htobe64(x) OSSwapHostToBigInt64((uint64_t)(x))

#define le16toh(x) OSSwapLittleToHostInt16((uint16_t)(x))
#define le32toh(x) OSSwapLittleToHostInt32((uint32_t)(x))
#define le64toh(x) OSSwapLittleToHostInt64((uint64_t)(x))
#define be16toh(x) OSSwapBigToHostInt16((uint16_t)(x))
#define be32toh(x) OSSwapBigToHostInt32((uint32_t)(x))
#define be64toh(x) OSSwapBigToHostInt64((uint64_t)(x))

#define htole16a(a, x) OSWriteLittleInt16((a), 0, (x))
#define htole32a(a, x) OSWriteLittleInt32((a), 0, (x))
#define htole64a(a, x) OSWriteLittleInt64((a), 0, (x))
#define htobe16a(a, x) OSWriteBigInt16((a), 0, (x))
#define htobe32a(a, x) OSWriteBigInt32((a), 0, (x))
#define htobe64a(a, x) OSWriteBigInt64((a), 0, (x))

#define le16atoh(a) OSReadLittleInt16((a), 0)
#define le32atoh(a) OSReadLittleInt32((a), 0)
#define le64atoh(a) OSReadLittleInt64((a), 0)
#define be16atoh(a) OSReadBigInt16((a), 0)
#define be32atoh(a) OSReadBigInt32((a), 0)
#define be64atoh(a) OSReadBigInt64((a), 0)

#endif
