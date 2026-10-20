cmake_minimum_required(VERSION 3.16)
project(esca-camview-bridge VERSION 0.2.0 LANGUAGES CXX)

# The native half of the camera viewer: libesca-camclient behind a C ABI that
# dart:ffi can call. Built by its own recipe; the Flutter bundle is the other.

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(GNUInstallDirs)

find_library(ESCA_CAMCLIENT_LIB NAMES esca-camclient REQUIRED)
find_path(ESCA_CAM_INCLUDE_DIR esca/camera/client.hpp REQUIRED)

add_library(esca-camview-bridge SHARED esca_camview_bridge.cpp)
target_include_directories(esca-camview-bridge PRIVATE "${ESCA_CAM_INCLUDE_DIR}")
target_link_libraries(esca-camview-bridge PRIVATE "${ESCA_CAMCLIENT_LIB}")
# -O2 at least: the conversion loop runs on every pixel of every frame.
target_compile_options(esca-camview-bridge PRIVATE -O2)

# Unversioned on purpose: dart:ffi opens it by this exact name, and nothing
# links against it at build time for a soname to protect.
install(TARGETS esca-camview-bridge LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR})
