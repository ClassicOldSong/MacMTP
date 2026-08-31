# libmtp only provides an Autotools build. MacMTP is macOS-only and must be
# buildable with CMake and Ninja alone, so this adapter mirrors the library
# source list from libmtp's src/Makefile.am and supplies the headers that its
# configure script generates for Darwin.

set(MACMTP_LIBMTP_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party/libmtp")
set(MACMTP_LIBUSB_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party/libusb-cmake")

if(NOT EXISTS "${MACMTP_LIBMTP_SOURCE_DIR}/src/Makefile.am" OR
   NOT EXISTS "${MACMTP_LIBUSB_SOURCE_DIR}/CMakeLists.txt")
  message(FATAL_ERROR
    "Third-party sources are missing. Run: git submodule update --init --recursive")
endif()

set(LIBUSB_BUILD_SHARED_LIBS ON CACHE BOOL "Build bundled libusb as a shared library" FORCE)
set(LIBUSB_BUILD_TESTING OFF CACHE BOOL "Build libusb tests" FORCE)
set(LIBUSB_BUILD_EXAMPLES OFF CACHE BOOL "Build libusb examples" FORCE)
set(LIBUSB_INSTALL_TARGETS OFF CACHE BOOL "Install libusb targets" FORCE)

# SDK 27 declares pipe2(), but the function is unavailable on older systems.
# Prevent a configure-time link check against a new SDK from raising the actual
# runtime requirement above the selected deployment target.
if(CMAKE_OSX_DEPLOYMENT_TARGET VERSION_LESS "27.0")
  set(HAVE_PIPE2 OFF CACHE INTERNAL "pipe2 is unavailable before macOS 27" FORCE)
else()
  unset(HAVE_PIPE2 CACHE)
endif()

add_subdirectory(
  "${MACMTP_LIBUSB_SOURCE_DIR}"
  "${CMAKE_CURRENT_BINARY_DIR}/third_party/libusb"
  EXCLUDE_FROM_ALL)

set_target_properties(usb-1.0 PROPERTIES
  OUTPUT_NAME "usb-1.0.0"
  LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/third_party/runtime/$<CONFIG>"
  MACHO_COMPATIBILITY_VERSION "6.0.0"
  MACHO_CURRENT_VERSION "6.0.0"
  INSTALL_NAME_DIR "@rpath"
  BUILD_WITH_INSTALL_NAME_DIR YES)
if(HAVE_VISIBILITY)
  target_compile_options(usb-1.0 PRIVATE -fvisibility=hidden)
endif()

set(MACMTP_LIBMTP_GENERATED_DIR "${CMAKE_CURRENT_BINARY_DIR}/third_party/libmtp/include")
file(MAKE_DIRECTORY "${MACMTP_LIBMTP_GENERATED_DIR}")

set(LIBMTP_SOURCE_VERSION "1.1.23")
set(VERSION "${LIBMTP_SOURCE_VERSION}")
configure_file(
  "${MACMTP_LIBMTP_SOURCE_DIR}/src/libmtp.h.in"
  "${MACMTP_LIBMTP_GENERATED_DIR}/libmtp.h"
  @ONLY)
unset(VERSION)
configure_file(
  "${CMAKE_CURRENT_SOURCE_DIR}/cmake/libmtp-config.h.in"
  "${MACMTP_LIBMTP_GENERATED_DIR}/config.h"
  @ONLY)
configure_file(
  "${CMAKE_CURRENT_SOURCE_DIR}/cmake/libmtp-gphoto2-endian.h"
  "${MACMTP_LIBMTP_GENERATED_DIR}/gphoto2-endian.h"
  COPYONLY)
configure_file(
  "${CMAKE_CURRENT_SOURCE_DIR}/cmake/libmtp-stdint.h"
  "${MACMTP_LIBMTP_GENERATED_DIR}/_stdint.h"
  COPYONLY)

# libmtp.sym is the upstream source of truth for the public ABI. Darwin's
# exported-symbols list uses the Mach-O underscore prefix.
file(STRINGS "${MACMTP_LIBMTP_SOURCE_DIR}/src/libmtp.sym" LIBMTP_PUBLIC_SYMBOLS)
list(TRANSFORM LIBMTP_PUBLIC_SYMBOLS PREPEND "_")
list(JOIN LIBMTP_PUBLIC_SYMBOLS "\n" LIBMTP_DARWIN_EXPORTS)
set(MACMTP_LIBMTP_EXPORT_LIST "${MACMTP_LIBMTP_GENERATED_DIR}/libmtp.exports")
file(CONFIGURE
  OUTPUT "${MACMTP_LIBMTP_EXPORT_LIST}"
  CONTENT "${LIBMTP_DARWIN_EXPORTS}\n"
  @ONLY)

add_library(MacMTPLibmtp SHARED
  "${MACMTP_LIBMTP_SOURCE_DIR}/src/libmtp.c"
  "${MACMTP_LIBMTP_SOURCE_DIR}/src/unicode.c"
  "${MACMTP_LIBMTP_SOURCE_DIR}/src/util.c"
  "${MACMTP_LIBMTP_SOURCE_DIR}/src/playlist-spl.c"
  "${MACMTP_LIBMTP_SOURCE_DIR}/src/ptp.c"
  "${MACMTP_LIBMTP_SOURCE_DIR}/src/libusb1-glue.c")
add_library(libmtp::libmtp ALIAS MacMTPLibmtp)

target_include_directories(MacMTPLibmtp
  PUBLIC "${MACMTP_LIBMTP_GENERATED_DIR}"
  PRIVATE "${MACMTP_LIBMTP_SOURCE_DIR}/src")
target_compile_options(MacMTPLibmtp PRIVATE -Wall -Wmissing-prototypes)
target_link_options(MacMTPLibmtp PRIVATE
  "LINKER:-exported_symbols_list,${MACMTP_LIBMTP_EXPORT_LIST}")
find_library(MACMTP_ICONV_LIBRARY iconv REQUIRED)
target_link_libraries(MacMTPLibmtp PRIVATE usb-1.0 "${MACMTP_ICONV_LIBRARY}")
set_target_properties(MacMTPLibmtp PROPERTIES
  OUTPUT_NAME "mtp.9"
  LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/third_party/runtime/$<CONFIG>"
  MACHO_COMPATIBILITY_VERSION "14.0.0"
  MACHO_CURRENT_VERSION "14.0.0"
  INSTALL_NAME_DIR "@rpath"
  BUILD_WITH_INSTALL_NAME_DIR YES
  INSTALL_RPATH "@loader_path"
  BUILD_WITH_INSTALL_RPATH YES)

set(MACMTP_LIBMTP_DYLIB_NAME "libmtp.9.dylib")
set(MACMTP_LIBUSB_DYLIB_NAME "libusb-1.0.0.dylib")
