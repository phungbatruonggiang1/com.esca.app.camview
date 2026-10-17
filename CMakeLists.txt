cmake_minimum_required(VERSION 3.16)
# C as well as C++: wayland-scanner emits the protocol marshalling as C.
project(esca-camview VERSION 0.1.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(GNUInstallDirs)
find_package(PkgConfig REQUIRED)

pkg_check_modules(WAYLAND_CLIENT REQUIRED IMPORTED_TARGET wayland-client)

# --- xdg-shell -------------------------------------------------------------
# The protocol is XML that ships with wayland-protocols; wayland-scanner turns
# it into a header and a C file. The scanner has to be the build host's, not
# the target's, which is why the recipe depends on wayland-native.
pkg_get_variable(WAYLAND_PROTOCOLS_DIR wayland-protocols pkgdatadir)
find_program(WAYLAND_SCANNER NAMES wayland-scanner REQUIRED)

set(XDG_SHELL_XML "${WAYLAND_PROTOCOLS_DIR}/stable/xdg-shell/xdg-shell.xml")
set(XDG_SHELL_HEADER "${CMAKE_CURRENT_BINARY_DIR}/xdg-shell-client-protocol.h")
set(XDG_SHELL_SOURCE "${CMAKE_CURRENT_BINARY_DIR}/xdg-shell-protocol.c")

add_custom_command(
    OUTPUT "${XDG_SHELL_HEADER}"
    COMMAND "${WAYLAND_SCANNER}" client-header "${XDG_SHELL_XML}" "${XDG_SHELL_HEADER}"
    DEPENDS "${XDG_SHELL_XML}"
    VERBATIM)
add_custom_command(
    OUTPUT "${XDG_SHELL_SOURCE}"
    COMMAND "${WAYLAND_SCANNER}" private-code "${XDG_SHELL_XML}" "${XDG_SHELL_SOURCE}"
    DEPENDS "${XDG_SHELL_XML}"
    VERBATIM)

# --- the services this is a client of --------------------------------------
find_library(ESCA_CAMCLIENT_LIB NAMES esca-camclient REQUIRED)
find_path(ESCA_CAM_INCLUDE_DIR esca/camera/client.hpp REQUIRED)
find_library(ESCA_VISIONCLIENT_LIB NAMES esca-visionclient REQUIRED)
find_path(ESCA_VISION_INCLUDE_DIR esca/vision/client.hpp REQUIRED)

add_executable(esca-camview
    src/main.cpp
    src/render.cpp
    src/window.cpp
    "${XDG_SHELL_SOURCE}"
    "${XDG_SHELL_HEADER}")
target_include_directories(esca-camview PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/src"
    "${CMAKE_CURRENT_BINARY_DIR}"
    "${ESCA_CAM_INCLUDE_DIR}"
    "${ESCA_VISION_INCLUDE_DIR}")
target_link_libraries(esca-camview PRIVATE
    PkgConfig::WAYLAND_CLIENT
    "${ESCA_CAMCLIENT_LIB}"
    "${ESCA_VISIONCLIENT_LIB}")

install(TARGETS esca-camview RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(FILES data/appinfo.json
        DESTINATION ${CMAKE_INSTALL_DATADIR}/esca/applications/vn.sparc.esca.camview)
