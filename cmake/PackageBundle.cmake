if(NOT DEFINED APP_BUNDLE OR NOT DEFINED EXTENSION_BUNDLE)
  message(FATAL_ERROR "APP_BUNDLE and EXTENSION_BUNDLE are required")
endif()

if(DISTRIBUTION_SIGNING)
  if(CODE_SIGN_IDENTITY STREQUAL "" OR CODE_SIGN_IDENTITY STREQUAL "-")
    message(FATAL_ERROR
      "Distribution signing requires a Developer ID Application identity")
  endif()
endif()

set(plugin_directory "${APP_BUNDLE}/Contents/PlugIns")
set(embedded_extension "${plugin_directory}/MacMTPFileProvider.appex")

file(MAKE_DIRECTORY "${plugin_directory}")
file(REMOVE_RECURSE "${embedded_extension}")
file(COPY "${EXTENSION_BUNDLE}" DESTINATION "${plugin_directory}")

set(embedded_app_profile "${APP_BUNDLE}/Contents/embedded.provisionprofile")
if(DEFINED APP_PROVISIONING_PROFILE
    AND NOT APP_PROVISIONING_PROFILE STREQUAL "")
  if(NOT EXISTS "${APP_PROVISIONING_PROFILE}")
    message(FATAL_ERROR
      "Host provisioning profile does not exist: ${APP_PROVISIONING_PROFILE}")
  endif()
  file(COPY_FILE "${APP_PROVISIONING_PROFILE}"
    "${embedded_app_profile}" ONLY_IF_DIFFERENT)
else()
  file(REMOVE "${embedded_app_profile}")
endif()

set(embedded_extension_profile
  "${embedded_extension}/Contents/embedded.provisionprofile")
if(DEFINED EXTENSION_PROVISIONING_PROFILE
    AND NOT EXTENSION_PROVISIONING_PROFILE STREQUAL "")
  if(NOT EXISTS "${EXTENSION_PROVISIONING_PROFILE}")
    message(FATAL_ERROR
      "Extension provisioning profile does not exist: ${EXTENSION_PROVISIONING_PROFILE}")
  endif()
  file(COPY_FILE "${EXTENSION_PROVISIONING_PROFILE}"
    "${embedded_extension_profile}" ONLY_IF_DIFFERENT)
else()
  file(REMOVE "${embedded_extension_profile}")
endif()

if(CODE_SIGN_IDENTITY STREQUAL "")
  message(STATUS "Skipping code signing")
else()
  set(signing_arguments --force --sign "${CODE_SIGN_IDENTITY}")
  if(DISTRIBUTION_SIGNING)
    list(APPEND signing_arguments --options runtime --timestamp)
  endif()

  file(GLOB extension_libraries "${embedded_extension}/Contents/Frameworks/*.dylib")
  foreach(library IN LISTS extension_libraries)
    execute_process(
      COMMAND /usr/bin/codesign ${signing_arguments} "${library}"
      COMMAND_ERROR_IS_FATAL ANY)
  endforeach()

  execute_process(
    COMMAND /usr/bin/codesign ${signing_arguments}
      --entitlements "${EXTENSION_ENTITLEMENTS}" "${embedded_extension}"
    COMMAND_ERROR_IS_FATAL ANY)

  file(GLOB app_libraries "${APP_BUNDLE}/Contents/Frameworks/*.dylib")
  foreach(library IN LISTS app_libraries)
    execute_process(
      COMMAND /usr/bin/codesign ${signing_arguments} "${library}"
      COMMAND_ERROR_IS_FATAL ANY)
  endforeach()

  execute_process(
    COMMAND /usr/bin/codesign ${signing_arguments}
      --entitlements "${APP_ENTITLEMENTS}" "${APP_BUNDLE}"
    COMMAND_ERROR_IS_FATAL ANY)

  if(DEFINED EXPECTED_TEAM_ID AND NOT EXPECTED_TEAM_ID STREQUAL ""
      AND NOT CODE_SIGN_IDENTITY STREQUAL "-")
    execute_process(
      COMMAND /usr/bin/codesign -d --verbose=4 "${APP_BUNDLE}"
      RESULT_VARIABLE signature_result
      OUTPUT_VARIABLE signature_details
      ERROR_VARIABLE signature_details)
    if(NOT signature_result EQUAL 0)
      message(FATAL_ERROR "Unable to inspect the app signature:\n${signature_details}")
    endif()
    string(FIND "${signature_details}"
      "TeamIdentifier=${EXPECTED_TEAM_ID}" team_identifier_index)
    if(team_identifier_index EQUAL -1)
      message(FATAL_ERROR
        "The app signature does not belong to team ${EXPECTED_TEAM_ID}")
    endif()
  endif()
endif()

# The inputs inside an existing bundle can all be replaced without changing the
# outer directory's timestamp. Mark the finished bundle itself as updated so
# Finder and other bundle consumers do not keep presenting stale file metadata.
execute_process(
  COMMAND /usr/bin/touch "${APP_BUNDLE}"
  COMMAND_ERROR_IS_FATAL ANY)
