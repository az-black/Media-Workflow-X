cmake_minimum_required(VERSION 3.15)
project(pdf_compressor CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Path manual vcpkg untuk x64-windows
set(VCPKG_ROOT "C:/vcpkg/installed/x64-windows")

# Header OpenCV & QPDF
include_directories(
    "${VCPKG_ROOT}/include"
    "${VCPKG_ROOT}/include/opencv4"
)

# Path Library (.lib)
link_directories("${VCPKG_ROOT}/lib")

add_executable(pdf_compressor compress.cpp)

# Link library MSVC vcpkg secara langsung
target_link_libraries(pdf_compressor PRIVATE
    qpdf
    opencv_core4
    opencv_imgcodecs4
    opencv_imgproc4
)