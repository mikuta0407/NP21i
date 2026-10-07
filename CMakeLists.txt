cmake_minimum_required(VERSION 3.24)

# iOS / iPadOS port of Neko Project II kai (np21/w based).
# Configure with:
#   cmake -S . -B build/ios -G Xcode -DCMAKE_SYSTEM_NAME=iOS
project(NP21iOS LANGUAGES C CXX OBJC)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_OSX_DEPLOYMENT_TARGET "15.0" CACHE STRING "")

set(NP2_DIR "${CMAKE_CURRENT_SOURCE_DIR}/vendor/NP2kai")
set(SDL_DIR "${CMAKE_CURRENT_SOURCE_DIR}/vendor/SDL")
set(IOS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/ios")

# ---- SDL2 (zlib license) -------------------------------------------------
set(SDL_SHARED OFF CACHE BOOL "" FORCE)
set(SDL_STATIC ON CACHE BOOL "" FORCE)
set(SDL_TEST OFF CACHE BOOL "" FORCE)
add_subdirectory("${SDL_DIR}" "${CMAKE_BINARY_DIR}/SDL" EXCLUDE_FROM_ALL)
# NP2kai includes <SDL2/SDL.h>; expose the SDL headers under that prefix.
set(SDL2_COMPAT_INCLUDE "${CMAKE_BINARY_DIR}/sdl2-include")
file(MAKE_DIRECTORY "${SDL2_COMPAT_INCLUDE}")
file(CREATE_LINK "${SDL_DIR}/include" "${SDL2_COMPAT_INCLUDE}/SDL2" SYMBOLIC)

# ---- NP2kai sources ------------------------------------------------------
# License policy: only modified-BSD / MIT / zlib code is built.
# Excluded on purpose (see .notes/PLAN.md):
#   sound/fmgen/*            : cisc license (no commercial use without consent)
#   sound/mame/*             : GPLv2  (replaced by sound/mamebsd)
#   fpemul_dosbox*.c         : GPLv2
#   fpemul_softfloat.c, fpu/softfloat/* : old SoftFloat (replaced by softfloat3)
#   wab/tgui9680*            : GPLv2
#   i386hax/*                : HAXM, not available on iOS
set(NP2_SOURCES
	${NP2_DIR}/calendar.c
	${NP2_DIR}/debugsnapshot.c
	${NP2_DIR}/keystat.c
	${NP2_DIR}/nevent.c
	${NP2_DIR}/pccore.c
	${NP2_DIR}/statsave.c
	${NP2_DIR}/timing.c
	${NP2_DIR}/debugsub386.c
	${NP2_DIR}/np2_thread.c
	${NP2_DIR}/np2_tickcount.c
	${NP2_DIR}/codecnv/eucsjis.c
	${NP2_DIR}/codecnv/eucucs2.c
	${NP2_DIR}/codecnv/jisucs2.c
	${NP2_DIR}/codecnv/sjiseuc.c
	${NP2_DIR}/codecnv/sjisucs2.c
	${NP2_DIR}/codecnv/tcswap16.c
	${NP2_DIR}/codecnv/tcswap32.c
	${NP2_DIR}/codecnv/textcnv.c
	${NP2_DIR}/codecnv/ucs2sjis.c
	${NP2_DIR}/codecnv/ucs2ucs4.c
	${NP2_DIR}/codecnv/ucs2utf8.c
	${NP2_DIR}/codecnv/ucs4ucs2.c
	${NP2_DIR}/codecnv/ucs4utf8.c
	${NP2_DIR}/codecnv/utf8ucs2.c
	${NP2_DIR}/codecnv/utf8ucs4.c
	${NP2_DIR}/diskimage/cd/cdd_ccd.c
	${NP2_DIR}/diskimage/cd/cdd_cue.c
	${NP2_DIR}/diskimage/cd/cdd_iso.c
	${NP2_DIR}/diskimage/cd/cdd_mds.c
	${NP2_DIR}/diskimage/cd/cdd_nrg.c
	${NP2_DIR}/generic/cmjasts.c
	${NP2_DIR}/generic/cmndraw.c
	${NP2_DIR}/generic/cmver.c
	${NP2_DIR}/generic/dipswbmp.c
	${NP2_DIR}/generic/hostdrv.c
	${NP2_DIR}/generic/hostdrvs.c
	${NP2_DIR}/generic/hostdrv9x.c
	${NP2_DIR}/generic/hostdrvnt.c
	${NP2_DIR}/generic/hostdrvwincompat.c
	${NP2_DIR}/generic/keydisp.c
	${NP2_DIR}/generic/memdbg32.c
	${NP2_DIR}/generic/np2info.c
	${NP2_DIR}/generic/softkbd.c
	${NP2_DIR}/generic/unasm.c
	${NP2_DIR}/sound/adpcmc.c
	${NP2_DIR}/sound/adpcmg.c
	${NP2_DIR}/sound/beepc.c
	${NP2_DIR}/sound/beepg.c
	${NP2_DIR}/sound/cs4231c.c
	${NP2_DIR}/sound/cs4231g.c
	${NP2_DIR}/sound/ct1741c.c
	${NP2_DIR}/sound/ct1741g.c
	${NP2_DIR}/sound/fmboard.c
	${NP2_DIR}/sound/opl3.c
	${NP2_DIR}/sound/oplgenc.c
	${NP2_DIR}/sound/oplgeng.c
	${NP2_DIR}/sound/opna.c
	${NP2_DIR}/sound/opngenc.c
	${NP2_DIR}/sound/opngeng.c
	${NP2_DIR}/sound/opntimer.c
	${NP2_DIR}/sound/pcm86c.c
	${NP2_DIR}/sound/pcm86g.c
	${NP2_DIR}/sound/pcmmix.c
	${NP2_DIR}/sound/psggenc.c
	${NP2_DIR}/sound/psggeng.c
	${NP2_DIR}/sound/rhythmc.c
	${NP2_DIR}/sound/s98.c
	${NP2_DIR}/sound/sndcsec.c
	${NP2_DIR}/sound/sound.c
	${NP2_DIR}/sound/soundrom.c
	${NP2_DIR}/sound/tms3631c.c
	${NP2_DIR}/sound/tms3631g.c
	${NP2_DIR}/sound/ymzadpcmc.c
	${NP2_DIR}/sound/ymzadpcmg.c
	${NP2_DIR}/i386c/ia32/instructions/fpu/fpdummy.c
	${NP2_DIR}/i386c/ia32/instructions/fpu/fpemul_softfloat3.cpp
	${NP2_DIR}/i386c/ia32/instructions/mmx/3dnow.c
	${NP2_DIR}/i386c/ia32/instructions/mmx/mmx.c
	${NP2_DIR}/i386c/ia32/instructions/sse/sse.c
	${NP2_DIR}/i386c/ia32/instructions/sse2/sse2.c
	${NP2_DIR}/i386c/ia32/instructions/sse3/sse3.c
	${NP2_DIR}/i386c/ia32/instructions/ssse3/ssse3.c
	${NP2_DIR}/i386c/ia32/instructions/sse4/sse4_1.c
	${NP2_DIR}/i386c/ia32/instructions/sse4/sse4_2.c
	${NP2_DIR}/i386c/ia32/instructions/sse4a/sse4a.c
)
file(GLOB_RECURSE _np2_glob
	${NP2_DIR}/bios/*.c
	${NP2_DIR}/cbus/*.c
	${NP2_DIR}/common/*.c
	${NP2_DIR}/diskimage/fd/*.c
	${NP2_DIR}/embed/*.c
	${NP2_DIR}/fdd/*.c
	${NP2_DIR}/font/*.c
	${NP2_DIR}/io/*.c
	${NP2_DIR}/lio/*.c
	${NP2_DIR}/mem/*.c
	${NP2_DIR}/sound/getsnd/*.c
	${NP2_DIR}/sound/mamebsd/*.cpp
	${NP2_DIR}/sound/vermouth/*.c
	${NP2_DIR}/trap/*.c
	${NP2_DIR}/vram/*.c
	${NP2_DIR}/wab/*.c
	${NP2_DIR}/wab/*.cpp
	${NP2_DIR}/i386c/ia32/instructions/fpu/softfloat3/*.c
)
file(GLOB _np2_glob_flat
	${NP2_DIR}/diskimage/*.c
	${NP2_DIR}/i386c/*.c
	${NP2_DIR}/i386c/ia32/*.c
	${NP2_DIR}/i386c/ia32/instructions/*.c
	${NP2_DIR}/sdl/*.c
)
list(APPEND NP2_SOURCES ${_np2_glob} ${_np2_glob_flat})
list(FILTER NP2_SOURCES EXCLUDE REGEX "/wab/tgui9680")
# Replaced by the iOS layer (CoreMIDI).
list(FILTER NP2_SOURCES EXCLUDE REGEX "/sdl/cmmidi\\.c$")
# fontmng.c is compiled as-is; SDL_ttf is satisfied by a stub header (ios/shim)
# until a CoreText based font manager replaces it.

# ---- iOS platform layer --------------------------------------------------
set(IOS_SOURCES
	${IOS_DIR}/src/main.m
	${IOS_DIR}/src/debugkeys.m
	${IOS_DIR}/src/debugmidi.m
	${IOS_DIR}/src/debugscreen.m
	${IOS_DIR}/src/cmmidi.c
	${IOS_DIR}/src/midiport.m
	${IOS_DIR}/src/settings.m
)

add_executable(NP21iOS MACOSX_BUNDLE ${NP2_SOURCES} ${IOS_SOURCES})

target_include_directories(NP21iOS PRIVATE
	${IOS_DIR}/src
	${IOS_DIR}/shim
	${SDL2_COMPAT_INCLUDE}
	${NP2_DIR}
	${NP2_DIR}/sdl
	${NP2_DIR}/i386c
	${NP2_DIR}/i386c/ia32
)

target_compile_definitions(NP21iOS PRIVATE
	# common (upstream NP2kai_common_definitions minus SUPPORT_FMGEN / SUPPORT_PNG)
	BIOS_IO_EMULATION OSLANG_UTF8 SUPPORT_8BPP SUPPORT_16BPP SUPPORT_24BPP SUPPORT_32BPP
	SUPPORT_CL_GD5430 SUPPORT_CRT15KHZ SUPPORT_FAST_MEMORYCHECK SUPPORT_GPIB SUPPORT_HRTIMER
	SUPPORT_KAI_IMAGES SUPPORT_LARGE_HDD SUPPORT_NORMALDISP SUPPORT_PC9861K SUPPORT_PX
	SUPPORT_RESUME SUPPORT_RS232C_FIFO SUPPORT_S98 SUPPORT_EMU_SOUNDBIOS SUPPORT_SCSI
	SUPPORT_HOSTDRV SUPPORT_FDDSNDDEV SUPPORT_SMPU98 SUPPORT_SOFTKBD=0 SUPPORT_SOUND_SB16
	SUPPORT_STATSAVE=10 SUPPORT_UTF8 SUPPORT_V30EXT SUPPORT_V30ORIGINAL SUPPORT_VIDEOFILTER
	SUPPORT_VPCVHD SUPPORT_WAB USE_MAME USE_MAME_BSD VAEG_FIX VERMOUTH_LIB
	# ia32
	CPUCORE_IA32 IA32_PAGING_EACHSIZE IA32_REBOOT_ON_PANIC SUPPORT_CRT31KHZ SUPPORT_PC9801_119
	SUPPORT_PC9821 SUPPORT_IDEIO SUPPORT_LARGE_MEMORY SUPPORT_PEGC SUPPORT_VGA_MODEX
	SUPPORT_GAMEPORT SUPPORT_IDEIO_48BIT SUPPORT_FPU_SOFTFLOAT3 SUPPORT_PCI USE_FPU USE_MMX
	USE_3DNOW USE_SSE USE_SSE2 USE_SSE3 USE_SSSE3 USE_SSE4_1 USE_SSE4_2 USE_SSE4A USE_TSC
	USE_FASTPAGING USE_VME SUPPORT_MEMDBG32
	# SDL port
	# patch 0002: poll MIDI-IN on every MPU tick
	SUPPORT_MPU98_TICK_MIDIIN
	NP2_SDL SUPPORT_BMS USE_SDL=2 OSLINEBREAK_LF SUPPORT_SDL_AUDIO
	SUPPORT_NP2_TICKCOUNT SUPPORT_NP2_THREAD SUPPORT_PTHREAD
	NP2KAI_GIT_TAG="ios" NP2KAI_GIT_HASH="dev"
)

target_compile_options(NP21iOS PRIVATE
	$<$<COMPILE_LANGUAGE:C>:-include compiler.h>
)
# Upstream code is noisy; keep warnings for the iOS layer only.
# The emulator core is always optimized: at -O0 it cannot keep real time,
# which makes the main loop run frames in bursts and ruins MIDI timing.
set_source_files_properties(${NP2_SOURCES} PROPERTIES COMPILE_OPTIONS "-Wno-everything;-O2")

target_link_libraries(NP21iOS PRIVATE SDL2::SDL2main SDL2::SDL2-static "-framework CoreMIDI")

# Settings app entries (copied as a folder; CodeSign runs after this step).
add_custom_command(TARGET NP21iOS POST_BUILD
	COMMAND ${CMAKE_COMMAND} -E copy_directory
		"${IOS_DIR}/Settings.bundle" "$<TARGET_BUNDLE_DIR:NP21iOS>/Settings.bundle"
)

set_target_properties(NP21iOS PROPERTIES
	MACOSX_BUNDLE_INFO_PLIST "${IOS_DIR}/Info.plist"
	XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "net.mikuta0407.np21ios"
	XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2"
	XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "NO"
	XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS "iphonesimulator iphoneos"
)
