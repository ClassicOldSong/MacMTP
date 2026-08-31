foreach(required_variable IN ITEMS
    RELEASE_ARCHIVE RELEASE_URL HOMEPAGE BUNDLE_ID VERSION CASK_TEMPLATE CASK_OUTPUT)
  if(NOT DEFINED ${required_variable} OR "${${required_variable}}" STREQUAL "")
    message(FATAL_ERROR "${required_variable} is required")
  endif()
endforeach()

if(NOT EXISTS "${RELEASE_ARCHIVE}")
  message(FATAL_ERROR "Release archive does not exist: ${RELEASE_ARCHIVE}")
endif()
if(NOT EXISTS "${CASK_TEMPLATE}")
  message(FATAL_ERROR "Homebrew cask template does not exist: ${CASK_TEMPLATE}")
endif()

file(SHA256 "${RELEASE_ARCHIVE}" MACMTP_RELEASE_SHA256)
set(MACMTP_RELEASE_URL "${RELEASE_URL}")
set(MACMTP_HOMEPAGE "${HOMEPAGE}")
set(MACMTP_BUNDLE_ID "${BUNDLE_ID}")
set(MACMTP_VERSION "${VERSION}")

get_filename_component(cask_directory "${CASK_OUTPUT}" DIRECTORY)
file(MAKE_DIRECTORY "${cask_directory}")
configure_file("${CASK_TEMPLATE}" "${CASK_OUTPUT}" @ONLY)

message(STATUS "Generated Homebrew cask: ${CASK_OUTPUT}")
message(STATUS "Release SHA-256: ${MACMTP_RELEASE_SHA256}")
