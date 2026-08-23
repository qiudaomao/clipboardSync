cmake_minimum_required(VERSION 3.24)

project(ClipboardSyncLinux VERSION 0.2.2 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTOUIC ON)
set(CMAKE_AUTORCC ON)

find_package(Qt6 6.7 REQUIRED COMPONENTS Core DBus Gui Widgets Network WebSockets)
find_package(OpenSSL 3.0 REQUIRED COMPONENTS Crypto)
find_package(X11 REQUIRED COMPONENTS Xi Xtst Xfixes)
find_package(PkgConfig REQUIRED)
pkg_check_modules(WAYLAND_CLIENT REQUIRED IMPORTED_TARGET wayland-client)
pkg_check_modules(XKBCOMMON REQUIRED IMPORTED_TARGET xkbcommon)
pkg_check_modules(LIBEI REQUIRED IMPORTED_TARGET libei-1.0)
find_program(WAYLAND_SCANNER wayland-scanner REQUIRED)

# Client glue for the wlroots virtual-input protocols, generated from the XMLs
# vendored under protocols/ (they ship with wlroots, not wayland-protocols).
set(WAYLAND_PROTOCOL_GEN_DIR ${CMAKE_CURRENT_BINARY_DIR}/wayland-protocols)
file(MAKE_DIRECTORY ${WAYLAND_PROTOCOL_GEN_DIR})
set(WAYLAND_PROTOCOL_SOURCES "")
foreach(proto wlr-virtual-pointer-unstable-v1 virtual-keyboard-unstable-v1 hyprland-input-capture-v1)
    set(proto_xml ${CMAKE_CURRENT_SOURCE_DIR}/protocols/${proto}.xml)
    set(proto_header ${WAYLAND_PROTOCOL_GEN_DIR}/${proto}-client-protocol.h)
    set(proto_source ${WAYLAND_PROTOCOL_GEN_DIR}/${proto}-protocol.c)
    add_custom_command(OUTPUT ${proto_header} ${proto_source}
        COMMAND ${WAYLAND_SCANNER} client-header ${proto_xml} ${proto_header}
        COMMAND ${WAYLAND_SCANNER} private-code ${proto_xml} ${proto_source}
        DEPENDS ${proto_xml} VERBATIM)
    list(APPEND WAYLAND_PROTOCOL_SOURCES ${proto_header} ${proto_source})
endforeach()

add_executable(clipboard-sync
    src/main.cpp
    src/AppController.cpp
    src/AppController.h
    src/AppConfig.cpp
    src/AppConfig.h
    src/ClipboardService.cpp
    src/ClipboardService.h
    src/BulkFrame.cpp
    src/BulkFrame.h
    src/CryptoBox.cpp
    src/CryptoBox.h
    src/EnvelopeRouting.cpp
    src/EnvelopeRouting.h
    src/FileTransferCoordinator.cpp
    src/FileTransferCoordinator.h
    src/InputBackend.h
    src/InputModels.cpp
    src/InputModels.h
    src/InputSharingCoordinator.cpp
    src/InputSharingCoordinator.h
    src/LinuxCapabilities.cpp
    src/LinuxCapabilities.h
    src/PortForwardCoordinator.cpp
    src/PortForwardCoordinator.h
    src/PortForwardDialog.cpp
    src/PortForwardDialog.h
    src/ScreenLayoutDialog.cpp
    src/ScreenLayoutDialog.h
    src/SleepPreventionController.cpp
    src/SleepPreventionController.h
    src/SyncTransport.cpp
    src/SyncTransport.h
    src/TimePlanDialog.cpp
    src/TimePlanDialog.h
    src/TunnelFrame.cpp
    src/TunnelFrame.h
    src/UpdateController.cpp
    src/UpdateController.h
    src/WaylandInputBackend.cpp
    src/WaylandInputBackend.h
    src/X11InputBackend.cpp
    src/X11InputBackend.h
    ${WAYLAND_PROTOCOL_SOURCES}
)
target_include_directories(clipboard-sync PRIVATE ${WAYLAND_PROTOCOL_GEN_DIR})

target_compile_definitions(clipboard-sync PRIVATE
    CLIPBOARD_SYNC_VERSION="${PROJECT_VERSION}"
    QT_NO_CAST_FROM_ASCII
    QT_NO_CAST_TO_ASCII
)

target_link_libraries(clipboard-sync PRIVATE
    Qt6::Core Qt6::DBus Qt6::Gui Qt6::Widgets Qt6::Network Qt6::WebSockets
    OpenSSL::Crypto
    X11::X11 X11::Xi X11::Xtst X11::Xfixes
    PkgConfig::WAYLAND_CLIENT PkgConfig::XKBCOMMON PkgConfig::LIBEI
)

include(GNUInstallDirs)
install(TARGETS clipboard-sync RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(FILES packaging/io.github.qiudaomao.clipboardsync.desktop
    DESTINATION ${CMAKE_INSTALL_DATADIR}/applications)
install(FILES packaging/io.github.qiudaomao.clipboardsync.metainfo.xml
    DESTINATION ${CMAKE_INSTALL_DATADIR}/metainfo)
install(FILES packaging/io.github.qiudaomao.clipboardsync.svg
    DESTINATION ${CMAKE_INSTALL_DATADIR}/icons/hicolor/scalable/apps)

enable_testing()
add_executable(protocol-tests tests/CryptoBoxTests.cpp src/CryptoBox.cpp src/CryptoBox.h)
target_link_libraries(protocol-tests PRIVATE Qt6::Core OpenSSL::Crypto)
target_include_directories(protocol-tests PRIVATE src)
add_test(NAME protocol-tests COMMAND protocol-tests)

add_executable(envelope-routing-tests
    tests/EnvelopeRoutingTests.cpp
    src/EnvelopeRouting.cpp
    src/EnvelopeRouting.h
)
target_link_libraries(envelope-routing-tests PRIVATE Qt6::Core)
target_include_directories(envelope-routing-tests PRIVATE src)
add_test(NAME envelope-routing-tests COMMAND envelope-routing-tests)

add_executable(tunnel-frame-tests
    tests/TunnelFrameTests.cpp
    src/TunnelFrame.cpp
    src/TunnelFrame.h
    src/CryptoBox.cpp
    src/CryptoBox.h
)
target_link_libraries(tunnel-frame-tests PRIVATE Qt6::Core OpenSSL::Crypto)
target_include_directories(tunnel-frame-tests PRIVATE src)
add_test(NAME tunnel-frame-tests COMMAND tunnel-frame-tests)

add_executable(bulk-frame-tests
    tests/BulkFrameTests.cpp
    src/BulkFrame.cpp
    src/BulkFrame.h
    src/TunnelFrame.cpp
    src/TunnelFrame.h
    src/CryptoBox.cpp
    src/CryptoBox.h
)
target_link_libraries(bulk-frame-tests PRIVATE Qt6::Core OpenSSL::Crypto)
target_include_directories(bulk-frame-tests PRIVATE src)
add_test(NAME bulk-frame-tests COMMAND bulk-frame-tests)

add_executable(file-transfer-tests
    tests/FileTransferTests.cpp
    src/FileTransferCoordinator.cpp
    src/FileTransferCoordinator.h
)
target_link_libraries(file-transfer-tests PRIVATE Qt6::Core)
target_include_directories(file-transfer-tests PRIVATE src)
add_test(NAME file-transfer-tests COMMAND file-transfer-tests)

add_executable(port-forward-tests
    tests/PortForwardTests.cpp
    src/PortForwardCoordinator.cpp
    src/PortForwardCoordinator.h
)
target_link_libraries(port-forward-tests PRIVATE Qt6::Core Qt6::Network)
target_include_directories(port-forward-tests PRIVATE src)
add_test(NAME port-forward-tests COMMAND port-forward-tests)

add_executable(update-controller-tests
    tests/UpdateControllerTests.cpp
    src/UpdateController.cpp
    src/UpdateController.h
)
target_compile_definitions(update-controller-tests PRIVATE CLIPBOARD_SYNC_VERSION="${PROJECT_VERSION}")
target_link_libraries(update-controller-tests PRIVATE Qt6::Core Qt6::Gui Qt6::Network)
target_include_directories(update-controller-tests PRIVATE src)
add_test(NAME update-controller-tests COMMAND update-controller-tests)

add_executable(input-sharing-tests
    tests/InputSharingTests.cpp
    src/InputModels.cpp
    src/InputModels.h
    src/InputSharingCoordinator.cpp
    src/InputSharingCoordinator.h
    src/InputBackend.h
)
target_link_libraries(input-sharing-tests PRIVATE Qt6::Core Qt6::Gui)
target_include_directories(input-sharing-tests PRIVATE src)
add_test(NAME input-sharing-tests COMMAND input-sharing-tests)
set_tests_properties(input-sharing-tests PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")

add_executable(screen-layout-tests
    tests/ScreenLayoutDialogTests.cpp
    src/InputModels.cpp
    src/InputModels.h
    src/ScreenLayoutDialog.cpp
    src/ScreenLayoutDialog.h
)
target_link_libraries(screen-layout-tests PRIVATE Qt6::Core Qt6::Gui Qt6::Widgets)
target_include_directories(screen-layout-tests PRIVATE src)
add_test(NAME screen-layout-tests COMMAND screen-layout-tests)
set_tests_properties(screen-layout-tests PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")

add_executable(clipboard-service-tests
    tests/ClipboardServiceTests.cpp
    src/ClipboardService.cpp
    src/ClipboardService.h
)
target_link_libraries(clipboard-service-tests PRIVATE Qt6::Core Qt6::Gui Qt6::Widgets)
target_include_directories(clipboard-service-tests PRIVATE src)
add_test(NAME clipboard-service-tests COMMAND clipboard-service-tests)
set_tests_properties(clipboard-service-tests PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")

add_executable(time-plan-tests
    tests/TimePlanTests.cpp
    src/AppConfig.cpp
    src/AppConfig.h
    src/TimePlanDialog.cpp
    src/TimePlanDialog.h
)
target_link_libraries(time-plan-tests PRIVATE Qt6::Core Qt6::Gui Qt6::Widgets)
target_include_directories(time-plan-tests PRIVATE src)
add_test(NAME time-plan-tests COMMAND time-plan-tests)
set_tests_properties(time-plan-tests PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")

add_executable(sleep-prevention-tests
    tests/SleepPreventionTests.cpp
    src/AppConfig.cpp
    src/AppConfig.h
    src/SleepPreventionController.cpp
    src/SleepPreventionController.h
)
target_link_libraries(sleep-prevention-tests PRIVATE Qt6::Core Qt6::DBus)
target_include_directories(sleep-prevention-tests PRIVATE src)
add_test(NAME sleep-prevention-tests COMMAND sleep-prevention-tests)
