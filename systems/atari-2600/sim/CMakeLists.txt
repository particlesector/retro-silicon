# SPDX-License-Identifier: Apache-2.0
find_package(ZLIB REQUIRED)
rs_sim_test(a2600_frames_test SOURCES a2600_frames_test.cpp)
rs_verilate(a2600_frames_test COMPONENT atari2600 PREFIX Va2600)
target_link_libraries(a2600_frames_test PRIVATE ZLIB::ZLIB)
target_compile_definitions(a2600_frames_test PRIVATE RS_TESTROMS="${RS_TESTROMS}"
    RS_A2600_GOLDEN="${PROJECT_SOURCE_DIR}/harness/golden/a2600_frames_crc32.txt"
    RS_A2600_AUDIO_GOLDEN="${PROJECT_SOURCE_DIR}/harness/golden/a2600_audio_crc32.txt"
    RS_A2600_PADDLES="${PROJECT_SOURCE_DIR}/harness/golden/a2600_paddles.txt")

# The same test with the TIA's score-mode glitch on, against harness/golden/a2600_score_glitch_crc32.txt.
rs_sim_test(a2600_score_glitch_test SOURCES a2600_frames_test.cpp PREFIX "score glitch: ")
rs_verilate(a2600_score_glitch_test COMPONENT atari2600 PREFIX Va2600 PARAMS TIA_SCORE_GLITCH=1)
target_link_libraries(a2600_score_glitch_test PRIVATE ZLIB::ZLIB)
target_compile_definitions(a2600_score_glitch_test PRIVATE RS_TESTROMS="${RS_TESTROMS}"
    RS_A2600_GOLDEN="${PROJECT_SOURCE_DIR}/harness/golden/a2600_score_glitch_crc32.txt"
    RS_A2600_AUDIO_GOLDEN="${PROJECT_SOURCE_DIR}/harness/golden/a2600_audio_crc32.txt"
    RS_A2600_PADDLES="${PROJECT_SOURCE_DIR}/harness/golden/a2600_paddles.txt")
