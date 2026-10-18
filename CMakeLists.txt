cmake_minimum_required(VERSION 3.16)
project(esca-camview VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(GNUInstallDirs)
find_package(PkgConfig REQUIRED)

# The shared toolkit: windowing, drawing and input, which this application
# used to carry itself until a second one needed the same code.
find_library(ESCA_UI_LIB NAMES esca-ui REQUIRED)
find_path(ESCA_UI_INCLUDE_DIR esca/ui/window.hpp REQUIRED)

# --- the services this is a client of --------------------------------------
find_library(ESCA_CAMCLIENT_LIB NAMES esca-camclient REQUIRED)
find_path(ESCA_CAM_INCLUDE_DIR esca/camera/client.hpp REQUIRED)
find_library(ESCA_VISIONCLIENT_LIB NAMES esca-visionclient REQUIRED)
find_path(ESCA_VISION_INCLUDE_DIR esca/vision/client.hpp REQUIRED)

add_executable(esca-camview src/main.cpp)
target_include_directories(esca-camview PRIVATE
    "${ESCA_UI_INCLUDE_DIR}"
    "${ESCA_CAM_INCLUDE_DIR}"
    "${ESCA_VISION_INCLUDE_DIR}")
target_link_libraries(esca-camview PRIVATE
    "${ESCA_UI_LIB}"
    "${ESCA_CAMCLIENT_LIB}"
    "${ESCA_VISIONCLIENT_LIB}")

install(TARGETS esca-camview RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(FILES data/appinfo.json
        DESTINATION ${CMAKE_INSTALL_DATADIR}/esca/applications/vn.sparc.esca.camview)
