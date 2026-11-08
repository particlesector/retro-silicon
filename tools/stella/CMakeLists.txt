# SPDX-License-Identifier: Apache-2.0
# stella-frames: the Atari 2600's golden frames from Stella's libretro core. Built when RS_STELLA_DIR
# (or the environment's RS_STELLA_DIR) names a folder with lib/stella_libretro.so and include/libretro.h
# (see README.md).
set(RS_STELLA_DIR "$ENV{RS_STELLA_DIR}" CACHE PATH "Stella's libretro core: lib/stella_libretro.so, include/libretro.h")
if(RS_STELLA_DIR AND EXISTS ${RS_STELLA_DIR}/include/libretro.h)
    find_package(ZLIB REQUIRED)
    add_executable(stella-frames stella_frames.cpp)
    target_include_directories(stella-frames PRIVATE ${RS_STELLA_DIR}/include)
    target_compile_definitions(stella-frames PRIVATE RS_STELLA_CORE="${RS_STELLA_DIR}/lib/stella_libretro.so")
    target_link_libraries(stella-frames PRIVATE ZLIB::ZLIB ${CMAKE_DL_LIBS})
endif()
