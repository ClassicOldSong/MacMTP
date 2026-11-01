cmake_minimum_required(VERSION 3.24)

if(NOT DEFINED CMAKE_OSX_DEPLOYMENT_TARGET OR CMAKE_OSX_DEPLOYMENT_TARGET STREQUAL "")
  set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0" CACHE STRING "Minimum supported macOS version" FORCE)
endif()

project(MacMTP VERSION 0.2.0 LANGUAGES C CXX OBJC OBJCXX)

if(NOT APPLE)
  message(FATAL_ERROR "MacMTP only supports macOS")
endif()

set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD_REQUIRED YES)

set(MACMTP_BUNDLE_ID "com.sudomaker.MacMTP" CACHE STRING "Host application bundle identifier")
set(MACMTP_APP_GROUP "group.com.sudomaker.MacMTP" CACHE STRING "File Provider document/app group")
set(MACMTP_TEAM_ID "" CACHE STRING "Expected Apple Developer team identifier")
set(MACMTP_CODE_SIGN_IDENTITY "-" CACHE STRING "codesign identity; '-' performs ad-hoc signing")
set(MACMTP_APP_PROVISIONING_PROFILE "" CACHE FILEPATH
  "Provisioning profile embedded in the host application")
set(MACMTP_EXTENSION_PROVISIONING_PROFILE "" CACHE FILEPATH
  "Provisioning profile embedded in the File Provider extension")
option(MACMTP_DISTRIBUTION_SIGNING
  "Sign with the hardened runtime and a secure timestamp for distribution" OFF)
set(MACMTP_NOTARY_PROFILE "" CACHE STRING
  "notarytool Keychain profile used by the Homebrew release target")
set(MACMTP_HOMEBREW_RELEASE_URL "" CACHE STRING
  "Published URL for the versioned Homebrew release archive")
set(MACMTP_HOMEBREW_HOMEPAGE "" CACHE STRING
  "Project homepage written to the generated Homebrew cask")

find_library(APPKIT_FRAMEWORK AppKit REQUIRED)
find_library(FILEPROVIDER_FRAMEWORK FileProvider REQUIRED)
find_library(FOUNDATION_FRAMEWORK Foundation REQUIRED)
find_library(IOKIT_FRAMEWORK IOKit REQUIRED)
find_library(SERVICEMANAGEMENT_FRAMEWORK ServiceManagement REQUIRED)
find_library(UNIFORMTYPEIDENTIFIERS_FRAMEWORK UniformTypeIdentifiers REQUIRED)
find_program(SIPS_EXECUTABLE sips REQUIRED)
find_program(ICONUTIL_EXECUTABLE iconutil REQUIRED)

include(cmake/BuildLibmtp.cmake)

configure_file(cmake/AppInfo.plist.in AppInfo.plist @ONLY)
configure_file(cmake/FileProviderInfo.plist.in FileProviderInfo.plist @ONLY)
configure_file(cmake/App.entitlements.in App.entitlements @ONLY)
configure_file(cmake/FileProvider.entitlements.in FileProvider.entitlements @ONLY)

set(MACMTP_ICON_SOURCE "${CMAKE_CURRENT_SOURCE_DIR}/assets/MacMTP.svg")
set(MACMTP_TRAY_ICON_SOURCE "${CMAKE_CURRENT_SOURCE_DIR}/assets/tray.svg")
set(MACMTP_ICONSET_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/MacMTP.iconset")
set(MACMTP_APP_ICON "${CMAKE_CURRENT_BINARY_DIR}/MacMTP.icns")
set(MACMTP_TRAY_ICON "${CMAKE_CURRENT_BINARY_DIR}/MacMTPTray.png")

add_custom_command(
  OUTPUT "${MACMTP_APP_ICON}" "${MACMTP_TRAY_ICON}"
  COMMAND ${CMAKE_COMMAND} -E make_directory "${MACMTP_ICONSET_DIRECTORY}"
  COMMAND ${SIPS_EXECUTABLE} -s format png -z 16 16 "${MACMTP_ICON_SOURCE}"
    --out "${MACMTP_ICONSET_DIRECTORY}/icon_16x16.png"
  COMMAND ${SIPS_EXECUTABLE} -s format png -z 32 32 "${MACMTP_ICON_SOURCE}"
    --out "${MACMTP_ICONSET_DIRECTORY}/icon_16x16@2x.png"
  COMMAND ${SIPS_EXECUTABLE} -s format png -z 32 32 "${MACMTP_ICON_SOURCE}"
    --out "${MACMTP_ICONSET_DIRECTORY}/icon_32x32.png"
  COMMAND ${SIPS_EXECUTABLE} -s format png -z 64 64 "${MACMTP_ICON_SOURCE}"
    --out "${MACMTP_ICONSET_DIRECTORY}/icon_32x32@2x.png"
  COMMAND ${SIPS_EXECUTABLE} -s format png -z 128 128 "${MACMTP_ICON_SOURCE}"
    --out "${MACMTP_ICONSET_DIRECTORY}/icon_128x128.png"
  COMMAND ${SIPS_EXECUTABLE} -s format png -z 256 256 "${MACMTP_ICON_SOURCE}"
    --out "${MACMTP_ICONSET_DIRECTORY}/icon_128x128@2x.png"
  COMMAND ${SIPS_EXECUTABLE} -s format png -z 256 256 "${MACMTP_ICON_SOURCE}"
    --out "${MACMTP_ICONSET_DIRECTORY}/icon_256x256.png"
  COMMAND ${SIPS_EXECUTABLE} -s format png -z 512 512 "${MACMTP_ICON_SOURCE}"
    --out "${MACMTP_ICONSET_DIRECTORY}/icon_256x256@2x.png"
  COMMAND ${SIPS_EXECUTABLE} -s format png -z 512 512 "${MACMTP_ICON_SOURCE}"
    --out "${MACMTP_ICONSET_DIRECTORY}/icon_512x512.png"
  COMMAND ${SIPS_EXECUTABLE} -s format png -z 1024 1024 "${MACMTP_ICON_SOURCE}"
    --out "${MACMTP_ICONSET_DIRECTORY}/icon_512x512@2x.png"
  COMMAND ${ICONUTIL_EXECUTABLE} -c icns "${MACMTP_ICONSET_DIRECTORY}"
    -o "${MACMTP_APP_ICON}"
  COMMAND ${SIPS_EXECUTABLE} -s format png -z 36 36 "${MACMTP_TRAY_ICON_SOURCE}"
    --out "${MACMTP_TRAY_ICON}"
  DEPENDS "${MACMTP_ICON_SOURCE}" "${MACMTP_TRAY_ICON_SOURCE}"
  COMMENT "Generating MacMTP application and menu bar icons"
  VERBATIM)

set_source_files_properties(LICENSE THIRD_PARTY_NOTICES.md PROPERTIES
  MACOSX_PACKAGE_LOCATION Resources)
set_source_files_properties("${MACMTP_APP_ICON}" "${MACMTP_TRAY_ICON}" PROPERTIES
  GENERATED TRUE
  MACOSX_PACKAGE_LOCATION Resources)

add_library(MacMTPCommon STATIC
  src/common/MTPDevice.h
  src/common/MTPDevice.mm)
target_include_directories(MacMTPCommon PUBLIC src/common)
target_compile_options(MacMTPCommon PRIVATE -fobjc-arc -Wall -Wextra)
target_link_libraries(MacMTPCommon
  PUBLIC
    libmtp::libmtp
    ${FOUNDATION_FRAMEWORK}
    ${IOKIT_FRAMEWORK})

add_executable(MacMTP MACOSX_BUNDLE
  LICENSE
  THIRD_PARTY_NOTICES.md
  "${MACMTP_APP_ICON}"
  "${MACMTP_TRAY_ICON}"
  src/app/main.mm
  src/app/AboutPanelController.h
  src/app/AboutPanelController.mm
  src/app/AppDelegate.h
  src/app/AppDelegate.mm
  src/app/MTPDomainSyncState.h
  src/app/MTPDomainSyncState.mm
  src/app/MTPUnmountController.h
  src/app/MTPUnmountController.mm
  src/app/MTPDeviceMonitor.h
  src/app/MTPDeviceMonitor.mm)
set_target_properties(MacMTP PROPERTIES
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_BINARY_DIR}/AppInfo.plist"
  INSTALL_RPATH "@executable_path/../Frameworks"
  BUILD_WITH_INSTALL_RPATH YES)
target_compile_options(MacMTP PRIVATE -fobjc-arc -Wall -Wextra)
target_link_libraries(MacMTP PRIVATE
  MacMTPCommon
  ${APPKIT_FRAMEWORK}
  ${FILEPROVIDER_FRAMEWORK}
  ${SERVICEMANAGEMENT_FRAMEWORK})

add_executable(MacMTPFileProvider MACOSX_BUNDLE
  LICENSE
  THIRD_PARTY_NOTICES.md
  "${MACMTP_APP_ICON}"
  src/extension/main.mm
  src/extension/FileProviderExtension.h
  src/extension/FileProviderExtension.mm
  src/extension/MTPConnection.h
  src/extension/MTPConnection.mm
  src/extension/MTPEnumerator.h
  src/extension/MTPEnumerator.mm
  src/extension/MTPItem.h
  src/extension/MTPItem.mm)
set_target_properties(MacMTPFileProvider PROPERTIES
  BUNDLE_EXTENSION appex
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_BINARY_DIR}/FileProviderInfo.plist"
  INSTALL_RPATH "@executable_path/../Frameworks"
  BUILD_WITH_INSTALL_RPATH YES)
target_include_directories(MacMTPFileProvider PRIVATE src/extension)
target_compile_options(MacMTPFileProvider PRIVATE -fobjc-arc -Wall -Wextra)
target_link_libraries(MacMTPFileProvider PRIVATE
  MacMTPCommon
  ${FILEPROVIDER_FRAMEWORK}
  ${UNIFORMTYPEIDENTIFIERS_FRAMEWORK})

function(embed_mtp_libraries target)
  add_custom_command(TARGET ${target} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory "$<TARGET_BUNDLE_DIR:${target}>/Contents/Frameworks"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "$<TARGET_FILE:MacMTPLibmtp>"
      "$<TARGET_BUNDLE_DIR:${target}>/Contents/Frameworks/${MACMTP_LIBMTP_DYLIB_NAME}"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "$<TARGET_FILE:usb-1.0>"
      "$<TARGET_BUNDLE_DIR:${target}>/Contents/Frameworks/${MACMTP_LIBUSB_DYLIB_NAME}"
    VERBATIM)
endfunction()

embed_mtp_libraries(MacMTP)
embed_mtp_libraries(MacMTPFileProvider)

add_custom_target(MacMTPBundle ALL
  COMMAND ${CMAKE_COMMAND}
    "-DAPP_BUNDLE=$<TARGET_BUNDLE_DIR:MacMTP>"
    "-DEXTENSION_BUNDLE=$<TARGET_BUNDLE_DIR:MacMTPFileProvider>"
    "-DAPP_ENTITLEMENTS=${CMAKE_CURRENT_BINARY_DIR}/App.entitlements"
    "-DEXTENSION_ENTITLEMENTS=${CMAKE_CURRENT_BINARY_DIR}/FileProvider.entitlements"
    "-DCODE_SIGN_IDENTITY=${MACMTP_CODE_SIGN_IDENTITY}"
    "-DAPP_PROVISIONING_PROFILE=${MACMTP_APP_PROVISIONING_PROFILE}"
    "-DEXTENSION_PROVISIONING_PROFILE=${MACMTP_EXTENSION_PROVISIONING_PROFILE}"
    "-DDISTRIBUTION_SIGNING=${MACMTP_DISTRIBUTION_SIGNING}"
    "-DEXPECTED_TEAM_ID=${MACMTP_TEAM_ID}"
    -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/PackageBundle.cmake"
  DEPENDS MacMTP MacMTPFileProvider
  VERBATIM)

set(MACMTP_RELEASE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/release")
set(MACMTP_RELEASE_ARCHIVE
  "${MACMTP_RELEASE_DIRECTORY}/MacMTP-${PROJECT_VERSION}-macOS-universal.zip")
set(MACMTP_HOMEBREW_CASK "${MACMTP_RELEASE_DIRECTORY}/Casks/macmtp.rb")

add_custom_target(MacMTPHomebrewRelease
  COMMAND ${CMAKE_COMMAND}
    "-DAPP_BUNDLE=$<TARGET_BUNDLE_DIR:MacMTP>"
    "-DDISTRIBUTION_SIGNING=${MACMTP_DISTRIBUTION_SIGNING}"
    "-DNOTARY_PROFILE=${MACMTP_NOTARY_PROFILE}"
    "-DRELEASE_ARCHIVE=${MACMTP_RELEASE_ARCHIVE}"
    "-DRELEASE_URL=${MACMTP_HOMEBREW_RELEASE_URL}"
    "-DHOMEPAGE=${MACMTP_HOMEBREW_HOMEPAGE}"
    "-DBUNDLE_ID=${MACMTP_BUNDLE_ID}"
    "-DVERSION=${PROJECT_VERSION}"
    "-DBUILD_TYPE=${CMAKE_BUILD_TYPE}"
    "-DDEPLOYMENT_TARGET=${CMAKE_OSX_DEPLOYMENT_TARGET}"
    "-DCASK_TEMPLATE=${CMAKE_CURRENT_SOURCE_DIR}/packaging/homebrew/macmtp.rb.in"
    "-DCASK_OUTPUT=${MACMTP_HOMEBREW_CASK}"
    "-DCASK_GENERATOR=${CMAKE_CURRENT_SOURCE_DIR}/cmake/GenerateHomebrewCask.cmake"
    -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/PackageHomebrewRelease.cmake"
  DEPENDS MacMTPBundle
  COMMENT "Notarizing MacMTP and preparing its Homebrew cask"
  USES_TERMINAL
  VERBATIM)

message(STATUS "MacMTP bundle identifier: ${MACMTP_BUNDLE_ID}")
message(STATUS "MacMTP app group: ${MACMTP_APP_GROUP}")
message(STATUS "MacMTP team identifier: ${MACMTP_TEAM_ID}")
message(STATUS "MacMTP signing identity: ${MACMTP_CODE_SIGN_IDENTITY}")

include(CTest)
if(BUILD_TESTING)
  add_executable(MacMTPIdentifierTests
    tests/IdentifierTests.mm
    src/extension/FileProviderExtension.mm
    src/extension/MTPConnection.mm
    src/extension/MTPEnumerator.mm
    src/extension/MTPItem.mm)
  target_include_directories(MacMTPIdentifierTests PRIVATE src/extension)
  target_compile_options(MacMTPIdentifierTests PRIVATE -fobjc-arc -Wall -Wextra)
  target_link_libraries(MacMTPIdentifierTests PRIVATE
    MacMTPCommon
    ${FILEPROVIDER_FRAMEWORK}
    ${UNIFORMTYPEIDENTIFIERS_FRAMEWORK})
  add_test(NAME MacMTPIdentifierTests COMMAND MacMTPIdentifierTests)

  add_executable(MacMTPSyncTests
    tests/SyncTests.mm
    src/app/MTPDomainSyncState.mm
    src/app/MTPUnmountController.mm)
  target_include_directories(MacMTPSyncTests PRIVATE src/app)
  target_compile_options(MacMTPSyncTests PRIVATE -fobjc-arc -Wall -Wextra)
  target_link_libraries(MacMTPSyncTests PRIVATE ${APPKIT_FRAMEWORK} ${FILEPROVIDER_FRAMEWORK})
  add_test(NAME MacMTPSyncTests COMMAND MacMTPSyncTests)

  add_custom_target(MacMTPHomebrewReleaseTests
    COMMAND ${CMAKE_CTEST_COMMAND} --test-dir "${CMAKE_CURRENT_BINARY_DIR}"
      --output-on-failure
    DEPENDS MacMTPIdentifierTests MacMTPSyncTests
    USES_TERMINAL
    VERBATIM)
  add_dependencies(MacMTPHomebrewRelease MacMTPHomebrewReleaseTests)
endif()
