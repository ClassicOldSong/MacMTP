foreach(required_variable IN ITEMS
    APP_BUNDLE NOTARY_PROFILE RELEASE_ARCHIVE RELEASE_URL HOMEPAGE BUNDLE_ID
    VERSION BUILD_TYPE DEPLOYMENT_TARGET CASK_TEMPLATE CASK_OUTPUT CASK_GENERATOR)
  if(NOT DEFINED ${required_variable} OR "${${required_variable}}" STREQUAL "")
    message(FATAL_ERROR "${required_variable} is required")
  endif()
endforeach()

if(NOT DISTRIBUTION_SIGNING)
  message(FATAL_ERROR
    "MacMTPHomebrewRelease requires -DMACMTP_DISTRIBUTION_SIGNING=ON")
endif()
if(NOT BUILD_TYPE STREQUAL "Release")
  message(FATAL_ERROR
    "MacMTPHomebrewRelease requires a Release build, not '${BUILD_TYPE}'")
endif()
if(NOT DEPLOYMENT_TARGET STREQUAL "13.0")
  message(FATAL_ERROR
    "The generated cask declares macOS 13, but this build targets ${DEPLOYMENT_TARGET}")
endif()
if(NOT IS_DIRECTORY "${APP_BUNDLE}")
  message(FATAL_ERROR "Application bundle does not exist: ${APP_BUNDLE}")
endif()
if(NOT EXISTS "${CASK_GENERATOR}")
  message(FATAL_ERROR "Homebrew cask generator does not exist: ${CASK_GENERATOR}")
endif()

set(extension_bundle
  "${APP_BUNDLE}/Contents/PlugIns/MacMTPFileProvider.appex")
set(mach_o_files
  "${APP_BUNDLE}/Contents/MacOS/MacMTP"
  "${extension_bundle}/Contents/MacOS/MacMTPFileProvider")
file(GLOB app_libraries "${APP_BUNDLE}/Contents/Frameworks/*.dylib")
file(GLOB extension_libraries "${extension_bundle}/Contents/Frameworks/*.dylib")
list(APPEND mach_o_files ${app_libraries} ${extension_libraries})

foreach(mach_o_file IN LISTS mach_o_files)
  if(NOT EXISTS "${mach_o_file}")
    message(FATAL_ERROR "Expected bundle executable is missing: ${mach_o_file}")
  endif()
  execute_process(
    COMMAND /usr/bin/lipo "${mach_o_file}" -verify_arch arm64 x86_64
    RESULT_VARIABLE architecture_result
    ERROR_VARIABLE architecture_error)
  if(NOT architecture_result EQUAL 0)
    message(FATAL_ERROR
      "Homebrew release is not universal: ${mach_o_file}\n${architecture_error}")
  endif()
endforeach()

execute_process(
  COMMAND /usr/bin/codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"
  COMMAND_ERROR_IS_FATAL ANY)
execute_process(
  COMMAND /usr/bin/codesign -d --verbose=4 "${APP_BUNDLE}"
  RESULT_VARIABLE signature_result
  OUTPUT_VARIABLE signature_output
  ERROR_VARIABLE signature_output)
if(NOT signature_result EQUAL 0)
  message(FATAL_ERROR "Unable to inspect the app signature:\n${signature_output}")
endif()

string(FIND "${signature_output}" "Authority=Developer ID Application:" authority_index)
if(authority_index EQUAL -1)
  message(FATAL_ERROR
    "Homebrew release must be signed with a Developer ID Application identity")
endif()
string(REGEX MATCH "flags=[^\n]*\\(runtime\\)" runtime_signature "${signature_output}")
if(runtime_signature STREQUAL "")
  message(FATAL_ERROR "Homebrew release must enable the hardened runtime")
endif()

get_filename_component(release_directory "${RELEASE_ARCHIVE}" DIRECTORY)
file(MAKE_DIRECTORY "${release_directory}")
set(notary_archive "${release_directory}/MacMTP-${VERSION}-notary.zip")
file(REMOVE "${notary_archive}" "${RELEASE_ARCHIVE}")

execute_process(
  COMMAND /usr/bin/ditto -c -k --sequesterRsrc --keepParent
    "${APP_BUNDLE}" "${notary_archive}"
  COMMAND_ERROR_IS_FATAL ANY)
execute_process(
  COMMAND /usr/bin/xcrun notarytool submit "${notary_archive}"
    --keychain-profile "${NOTARY_PROFILE}" --wait
  COMMAND_ERROR_IS_FATAL ANY)
execute_process(
  COMMAND /usr/bin/xcrun stapler staple "${APP_BUNDLE}"
  COMMAND_ERROR_IS_FATAL ANY)
execute_process(
  COMMAND /usr/bin/xcrun stapler validate "${APP_BUNDLE}"
  COMMAND_ERROR_IS_FATAL ANY)
execute_process(
  COMMAND /usr/bin/codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"
  COMMAND_ERROR_IS_FATAL ANY)
execute_process(
  COMMAND /usr/sbin/spctl --assess --type execute --verbose=4 "${APP_BUNDLE}"
  COMMAND_ERROR_IS_FATAL ANY)

execute_process(
  COMMAND /usr/bin/ditto -c -k --sequesterRsrc --keepParent
    "${APP_BUNDLE}" "${RELEASE_ARCHIVE}"
  COMMAND_ERROR_IS_FATAL ANY)
file(REMOVE "${notary_archive}")

include("${CASK_GENERATOR}")

message(STATUS "Created notarized Homebrew archive: ${RELEASE_ARCHIVE}")
