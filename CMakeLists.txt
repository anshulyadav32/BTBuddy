cmake_minimum_required(VERSION 3.21)
project(BTBuddy VERSION 1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTOUIC ON)
set(CMAKE_AUTORCC ON)

find_package(Qt6 REQUIRED COMPONENTS Widgets)

qt_add_executable(BTBuddy
    src/main.cpp
    src/mainwindow.cpp
    src/mainwindow.hpp
    src/serial_port.cpp
    src/serial_port.hpp
    src/kechaoda.cpp
    src/kechaoda.hpp
)

target_link_libraries(BTBuddy PRIVATE Qt6::Widgets)

set_target_properties(BTBuddy PROPERTIES
    MACOSX_BUNDLE TRUE
    MACOSX_BUNDLE_GUI_IDENTIFIER com.btbuddy.app
    MACOSX_BUNDLE_BUNDLE_NAME BTBuddy
)
