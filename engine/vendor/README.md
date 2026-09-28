# Network dependency overrides

This workspace pins local copies of `iroh` 1.0.3 and `noq-udp` 1.1.0 through
`[patch.crates-io]` in `engine/Cargo.toml`. Keep their versions aligned with
the corresponding entries in `engine/Cargo.lock`.

- `iroh/src/socket/transports.rs` passes only the active receive-batch slice
  to each transport. The original fixed-size slice caused an assertion panic
  when a caller supplied fewer than `BATCH_SIZE` buffers.
- `noq-udp/build.rs` selects its existing `posix_minimal` backend for
  `target_env = "ohos"`. The default batched Unix receive path panicked in the
  HarmonyOS emulator. The portable backend uses a single UDP receive instead.

HarmonyOS Rust targets use `target_os = "linux"` and `target_env = "ohos"`.
The CMake native target tracks these vendored sources and build scripts so a
dependency change rebuilds the packaged HAP.