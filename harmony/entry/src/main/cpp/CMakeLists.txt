cmake_minimum_required(VERSION 3.4.1)
project(dashbeam_engine)

set(DASHBEAM_ENGINE_ROOT ${CMAKE_CURRENT_SOURCE_DIR})
get_filename_component(DASHBEAM_REPO_ROOT "${DASHBEAM_ENGINE_ROOT}/../../../../.." ABSOLUTE)
set(DASHBEAM_RUST_ROOT "${DASHBEAM_REPO_ROOT}/engine")
set(DASHBEAM_OHOS_BUILD_SCRIPT "${DASHBEAM_REPO_ROOT}/scripts/build-ohos-engine.js")

if(OHOS_ARCH STREQUAL "arm64-v8a")
	set(DASHBEAM_RUST_TARGET "aarch64-unknown-linux-ohos")
elseif(OHOS_ARCH STREQUAL "x86_64")
	set(DASHBEAM_RUST_TARGET "x86_64-unknown-linux-ohos")
else()
	message(FATAL_ERROR "Unsupported OHOS_ARCH: ${OHOS_ARCH}")
endif()

if(NOT DEFINED OHOS_SDK_NATIVE OR NOT IS_DIRECTORY "${OHOS_SDK_NATIVE}")
	message(FATAL_ERROR "OHOS_SDK_NATIVE must point to the HarmonyOS native SDK")
endif()

find_program(DASHBEAM_NODE_EXECUTABLE NAMES node node.exe)
if(NOT DASHBEAM_NODE_EXECUTABLE)
	message(FATAL_ERROR "Node.js is required to build the DashBeam Rust engine")
endif()

set(DASHBEAM_RUST_ARCHIVE
	"${DASHBEAM_RUST_ROOT}/target/${DASHBEAM_RUST_TARGET}/release/libdashbeam_ohos_bridge.a")

file(GLOB_RECURSE DASHBEAM_RUST_SOURCES CONFIGURE_DEPENDS
	"${DASHBEAM_RUST_ROOT}/ohos-bridge/src/*.rs"
	"${DASHBEAM_RUST_ROOT}/native/src/*.rs"
	"${DASHBEAM_RUST_ROOT}/protocol/src/*.rs"
	"${DASHBEAM_RUST_ROOT}/vendor/iroh/src/*.rs"
	"${DASHBEAM_RUST_ROOT}/vendor/noq-udp/src/*.rs")

add_custom_command(
	OUTPUT "${DASHBEAM_RUST_ARCHIVE}"
	COMMAND "${DASHBEAM_NODE_EXECUTABLE}" "${DASHBEAM_OHOS_BUILD_SCRIPT}"
		--abi "${OHOS_ARCH}"
		--ndk "${OHOS_SDK_NATIVE}"
	DEPENDS
		"${DASHBEAM_OHOS_BUILD_SCRIPT}"
		"${DASHBEAM_RUST_ROOT}/Cargo.toml"
		"${DASHBEAM_RUST_ROOT}/Cargo.lock"
		"${DASHBEAM_RUST_ROOT}/ohos-bridge/Cargo.toml"
		"${DASHBEAM_RUST_ROOT}/native/Cargo.toml"
		"${DASHBEAM_RUST_ROOT}/protocol/Cargo.toml"
		"${DASHBEAM_RUST_ROOT}/vendor/iroh/Cargo.toml"
		"${DASHBEAM_RUST_ROOT}/vendor/noq-udp/Cargo.toml"
		"${DASHBEAM_RUST_ROOT}/vendor/iroh/build.rs"
		"${DASHBEAM_RUST_ROOT}/vendor/noq-udp/build.rs"
		${DASHBEAM_RUST_SOURCES}
	WORKING_DIRECTORY "${DASHBEAM_REPO_ROOT}"
	COMMENT "Building DashBeam Rust engine for ${OHOS_ARCH}"
	VERBATIM)

add_custom_target(dashbeam_ohos_rust DEPENDS "${DASHBEAM_RUST_ARCHIVE}")

add_library(dashbeam_engine SHARED napi_init.cpp)
add_dependencies(dashbeam_engine dashbeam_ohos_rust)

target_include_directories(dashbeam_engine PRIVATE
	"${DASHBEAM_ENGINE_ROOT}"
	"${DASHBEAM_RUST_ROOT}/ohos-bridge/include")

target_link_libraries(dashbeam_engine PRIVATE
	"${DASHBEAM_RUST_ARCHIVE}"
	libace_napi.z.so
	libohfileuri.so)