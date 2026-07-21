<p align="center"><img width="50%" src="docs/images/ONNX_Runtime_logo_dark.png" /></p>

# ONNX Runtime — Custom Android Build Fork

This is a fork of [microsoft/onnxruntime](https://github.com/microsoft/onnxruntime) that adds
**custom Android runtime builds with statically linked custom operators**. The worked example
throughout this guide is the MMDeploy **`NMSRotated`** operator (rotated-box non-max suppression),
which is compiled directly into `libonnxruntime.so` so rotated-detection models run on a minimal
mobile runtime with no plugin loading.

> Upstream documentation still applies for everything else: [onnxruntime.ai/docs](https://onnxruntime.ai/docs).
> This README documents what is *different* in this fork and how to drive it end to end.

---

## Table of Contents

1. [What this fork adds](#what-this-fork-adds)
2. [How the build works (architecture)](#how-the-build-works-architecture)
3. [Prerequisites](#prerequisites)
4. [Quick start: build the custom AAR](#quick-start-build-the-custom-aar)
5. [The build settings file](#the-build-settings-file)
6. [How the custom operator is linked in](#how-the-custom-operator-is-linked-in)
7. [Adding your own custom operator](#adding-your-own-custom-operator)
8. [Shrinking the runtime (removing operators)](#shrinking-the-runtime-removing-operators)
9. [Converting a model to ORT format](#converting-a-model-to-ort-format)
10. [Verifying the built AAR](#verifying-the-built-aar)
11. [Publishing to GitHub Packages](#publishing-to-github-packages)
12. [Consuming the AAR in an Android app](#consuming-the-aar-in-an-android-app)
13. [Troubleshooting (real failures and their fixes)](#troubleshooting-real-failures-and-their-fixes)
14. [License](#license)

---

## What this fork adds

| Piece | Where | What it does |
|---|---|---|
| `NMSRotated` custom op source | [`onnxruntime_custom_operator/csrc/`](onnxruntime_custom_operator/csrc/) | The operator kernel, ported to the modern ORT C++ custom-op API |
| CMake static-link wiring | [`cmake/onnxruntime.cmake`](cmake/onnxruntime.cmake), [`cmake/CMakeLists.txt`](cmake/CMakeLists.txt) | Compiles the op into `libonnxruntime.so` and keeps the `RegisterCustomOps` export alive |
| Symbol export support | [`tools/ci_build/gen_def.py`](tools/ci_build/gen_def.py) | `--extra_symbols_file` so extra symbols survive `--gc-sections` + LTO |
| Build settings presets | `android-custom-*-settings.json` (repo root) | Ready-made minimal/XNNPACK/4-ABI configurations |
| Updated Docker environment | [`tools/android_custom_build/Dockerfile`](tools/android_custom_build/Dockerfile) | Ubuntu 22.04, NDK r28, Node 20, multi-arch CMake |
| Standalone Maven publisher | [`tools/android_custom_build/publish/`](tools/android_custom_build/publish/) | Publishes a built AAR to mavenLocal or GitHub Packages without rebuilding |
| Auto-publish after build | [`tools/android_custom_build/build_custom_android_package.py`](tools/android_custom_build/build_custom_android_package.py) | Optional `--publish` flags: build and push in one command |
| Model conversion script | [`onnxruntime_custom_operator/onnx_convert.py`](onnxruntime_custom_operator/onnx_convert.py) | ONNX → ORT-format conversion for the minimal runtime |

---

## How the build works (architecture)

The Android build is a 4-layer chain. You run the top layer; each layer drives the next:

```text
build_custom_android_package.py      (host)      builds the Docker image, runs the container,
        │                                        optionally publishes the AAR afterwards
        ▼
scripts/build.sh                     (container) thin entrypoint, passes your settings through
        │
        ▼
build_aar_package.py                 (container) loops over the 4 Android ABIs, then packages
        │                                        all of them into one .aar via Gradle
        ▼
build.py  →  CMake + Ninja           (container) the actual native build of libonnxruntime.so
                                                 — this is where the custom op gets compiled in
```

Key facts that follow from this design:

- **The container clones the repo from a URL** — it does *not* see your local working tree.
  Uncommitted changes never reach the build. Always build from a pushed branch
  (`--onnxruntime_repo_url` / `--onnxruntime_branch_or_tag`).
- **One full native build runs per ABI** (`armeabi-v7a`, `arm64-v8a`, `x86`, `x86_64`),
  then Gradle bundles the four `.so` files into a single AAR and lays it out as a local
  Maven repository under `output/aar_out/<config>/`.
- **Publishing runs on the host**, after the container exits, so registry credentials never
  enter the Docker build.

---

## Prerequisites

- **Docker Desktop** (running). On Apple Silicon, enable
  *Settings → General → Use Rosetta for x86/amd64 emulation* — the build must run as amd64
  (see [Troubleshooting](#troubleshooting-real-failures-and-their-fixes)).
- **Python 3.8+** on the host.
- Roughly **40 GB free disk** for the Docker image plus intermediates.
- No Android SDK/NDK needed on the host — the container provides NDK r28.

---

## Quick start: build the custom AAR

```bash
# 1. The Android NDK only ships an x86_64 host toolchain — force amd64 containers.
export DOCKER_DEFAULT_PLATFORM=linux/amd64

# 2. Make sure the container builds from FRESH source (the git clone is layer-cached).
docker rm -f ort-android-build 2>/dev/null
docker rmi -f onnxruntime-android-custom-build:latest 2>/dev/null
docker builder prune -f

# 3. Build all four ABIs with the NMSRotated op statically linked.
python3 tools/android_custom_build/build_custom_android_package.py \
  "$PWD/android-build-out" \
  --onnxruntime_repo_url  https://github.com/<your-fork>/onnxruntime.git \
  --onnxruntime_branch_or_tag nms-rotated-custom-op \
  --build_settings "$PWD/android-custom-minimal-xnnpack-4abi-static-nmsrotated-settings.json" \
  --config MinSizeRel \
  --docker_container_name ort-android-build
```

The result lands in a Maven-style layout:

```text
android-build-out/output/aar_out/MinSizeRel/
└── com/microsoft/onnxruntime/onnxruntime-android/<version>/
    ├── onnxruntime-android-<version>.aar        ← the runtime (all 4 ABIs inside)
    ├── onnxruntime-android-<version>.pom
    ├── onnxruntime-android-<version>-sources.jar
    └── onnxruntime-android-<version>-javadoc.jar
```

> `--docker_container_name` keeps the container after exit so build logs survive for
> debugging. Drop it once your configuration is stable and the container will be
> auto-removed (`--rm`).

---

## The build settings file

Everything about the native build is driven by one JSON file passed via `--build_settings`.
The preset used above, annotated:

```jsonc
{
  "build_abis": ["armeabi-v7a", "arm64-v8a", "x86", "x86_64"],
  "android_min_sdk_version": 24,
  "android_target_sdk_version": 34,
  "build_params": [
    "--enable_lto",                        // link-time optimization (smaller, faster)
    "--compile_no_warning_as_error",       // upstream warnings must not kill the build
    "--android",
    "--parallel", "4",
    "--cmake_generator=Ninja",

    "--cmake_extra_defines",
    "CMAKE_MAKE_PROGRAM=/usr/bin/ninja",
    // 16 KB page-size alignment (Android 15+ requirement; also NDK r28 default)
    "CMAKE_SHARED_LINKER_FLAGS=-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384",
    "CMAKE_MODULE_LINKER_FLAGS=-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384",
    // ── the custom operator switch ──
    "onnxruntime_ENABLE_STATIC_MMDEPLOY_NMS_ROTATED_OPS=ON",
    "onnxruntime_MMDEPLOY_NMS_ROTATED_OPS_DIR=/workspace/onnxruntime/onnxruntime_custom_operator/csrc",

    "--build_java",                        // required for the AAR
    "--build_shared_lib",
    "--use_xnnpack",                       // XNNPACK execution provider

    // ── minimal build: this is the size-reduction core ──
    "--minimal_build", "extended", "custom_ops",
    "--disable_exceptions",
    "--disable_ml_ops",
    "--disable_generation_ops",
    "--disable_types", "string", "optional", "sparsetensor", "float8", "float4",

    "--skip_tests",
    "--targets", "onnxruntime", "onnxruntime4j_jni"
  ]
}
```

The three `--minimal_build` related groups are what make this a *mobile* runtime rather than
the full desktop one; the two `onnxruntime_*NMS_ROTATED*` defines are what pull the custom
operator in. Everything else is standard Android build plumbing.

---

## How the custom operator is linked in

The operator is **compiled into `libonnxruntime.so`** — there is no separate plugin `.so` on
Android. Two CMake blocks in [`cmake/onnxruntime.cmake`](cmake/onnxruntime.cmake) do the work,
both gated on `onnxruntime_ENABLE_STATIC_MMDEPLOY_NMS_ROTATED_OPS`:

**Block 1 — compile the sources into the library target:**

```cmake
target_sources(onnxruntime PRIVATE
  "${onnxruntime_MMDEPLOY_NMS_ROTATED_OPS_DIR}/nms_rotated/nms_rotated.cpp"
  "${onnxruntime_MMDEPLOY_NMS_ROTATED_OPS_DIR}/common/ort_utils.cpp"
  "${onnxruntime_MMDEPLOY_NMS_ROTATED_OPS_DIR}/onnxruntime_register.cpp"
)
```

**Block 2 — keep the registration entrypoint alive.** The minimal build links with
`--gc-sections` and LTO, which strips anything not provably reachable. `RegisterCustomOps`
is only called *from the app at runtime*, so the linker would normally discard it — and the
whole operator with it. The fix: the symbol is written into an extra symbols file and fed to
`gen_def.py`, which places it in the linker version script *and* takes its address in
generated code:

```cmake
file(WRITE "${ORT_STATIC_CUSTOM_OPS_SYMBOL_FILE}" "RegisterCustomOps\n")
list(APPEND EXTRA_SYMBOL_ARGS --extra_symbols_file "${ORT_STATIC_CUSTOM_OPS_SYMBOL_FILE}")
```

Both halves are required. With only Block 1 the code compiles and then silently vanishes at
link time — the AAR builds "successfully" with no operator inside.

The operator itself is written against the **modern ORT C++ custom-op API**
(the legacy `Ort::CustomOpApi` was removed from ORT ≥ ~1.16):

```cpp
// onnxruntime_custom_operator/csrc/nms_rotated/nms_rotated.cpp
Ort::KernelContext ctx(context);
Ort::ConstValue boxes  = ctx.GetInput(0);
const float* boxes_data = boxes.GetTensorData<float>();
...
Ort::UnownedValue res = ctx.GetOutput(0, inds_dims.data(), inds_dims.size());
int64_t* res_data = res.GetTensorMutableData<int64_t>();
```

---

## Adding your own custom operator

To add another statically linked operator, follow the `NMSRotated` pattern:

1. **Write the kernel** against the modern C++ API (`Ort::CustomOpBase`,
   `Ort::KernelContext`) and register it in an `extern "C" RegisterCustomOps`
   (or extend the existing registration in
   [`onnxruntime_register.cpp`](onnxruntime_custom_operator/csrc/onnxruntime_register.cpp) —
   it iterates a domain→ops table, so adding an op is one `REGISTER_ONNXRUNTIME_OPS` line).
2. **Add the sources** to the `target_sources(onnxruntime PRIVATE ...)` block in
   `cmake/onnxruntime.cmake` (or add a parallel option like the NMSRotated one).
3. **Export the entrypoint** — if you add a *new* registration function name, append it to
   the same extra-symbols file so it survives dead-code stripping.
4. **Keep `--minimal_build ... custom_ops`** in the settings file — that flag compiles ORT's
   custom-op infrastructure into the minimal build; without it registration fails at runtime.
5. Commit, push to your fork, rebuild (remember the Docker cache bust), and
   [verify](#verifying-the-built-aar).

---

## Shrinking the runtime (removing operators)

Three independent levers, from coarsest to finest:

**1. Minimal build + disables (already in the preset).**
`--minimal_build extended` drops the ONNX-format loader and most graph optimizers
(the runtime then only loads `.ort` models). `--disable_ml_ops`,
`--disable_generation_ops`, and `--disable_types ...` remove whole op/type families.

**2. Reduced-ops build — keep only what your models use.**
Converting a model ([next section](#converting-a-model-to-ort-format)) emits a
`*.required_operators.config` listing exactly the kernels the model needs, e.g.:

```text
ai.onnx;11;Concat,Conv,Equal,Flatten,Gather,MaxPool,Range,ReduceMax,Resize,Slice,...
com.microsoft;1;FusedConv,QuickGelu
mmdeploy;1;NMSRotated
```

Feed that file back into the build and every kernel *not* listed is excluded:

```bash
python3 tools/android_custom_build/build_custom_android_package.py \
  "$PWD/android-build-out" \
  --include_ops_by_config "$PWD/security_zone.required_operators.config" \
  --build_settings ... # rest as in Quick start
```

You can pass several models' configs merged into one file; the union of ops is kept.
For an extra size step, add `--enable_reduced_operator_type_support` to `build_params`
so kernels also drop unused *type* specializations.

**3. Drop execution providers you don't use** — e.g. remove `--use_xnnpack` if CPU-only EP
is acceptable. Each EP adds native code to every ABI.

> Measure before/after with the [verification](#verifying-the-built-aar) unzip — the
> per-ABI `.so` sizes are the honest metric, not the AAR size.

---

## Converting a model to ORT format

The minimal runtime only loads **`.ort`** models. Conversion runs the model through a
desktop Python ORT session — which must also know the custom op, via a host-native build of
the same operator:

```bash
cd onnxruntime_custom_operator

# one-time: build the desktop copy of the op against an ORT SDK release
cmake -S csrc -B csrc/build-desktop -DCMAKE_BUILD_TYPE=Release \
      -DONNXRUNTIME_DIR=/path/to/onnxruntime-osx-arm64-<ver> \
      -DCMAKE_DISABLE_FIND_PACKAGE_onnxruntime=ON
cmake --build csrc/build-desktop

# convert (also emits the required_operators.config used for reduced builds)
python onnx_convert.py \
  --onnx-model security_zone.onnx \
  --custom-op-library csrc/build-desktop/libnms_rotated_ort.dylib \
  --conversion-dir out/converted-models \
  --android-raw-dir out/raw \
  --skip-test
```

Match the SDK you compile against to the `onnxruntime` version installed in your Python
environment. If loading fails with `Library not loaded: @rpath/libonnxruntime.1.dylib`,
the pip wheel is missing a versioned alias — add a symlink next to the wheel's dylib:

```bash
CAPI=$(python -c "import onnxruntime,os;print(os.path.dirname(onnxruntime.__file__)+'/capi')")
ln -sf libonnxruntime.<ver>.dylib "$CAPI/libonnxruntime.1.dylib"
```

---

## Verifying the built AAR

Never trust a green build — check the binary. An AAR is a zip:

```bash
unzip -o onnxruntime-android-<ver>.aar -d /tmp/aar_check

# 1. the registration entrypoint must be a dynamic export in EVERY ABI
NM=/opt/homebrew/opt/llvm/bin/llvm-nm    # brew install llvm
for abi in arm64-v8a armeabi-v7a x86_64 x86; do
  echo -n "$abi RegisterCustomOps: "
  $NM -D --defined-only /tmp/aar_check/jni/$abi/libonnxruntime.so | grep -c RegisterCustomOps
done
# expected: 1 for each ABI

# 2. the op name and domain must be baked into the binary
strings /tmp/aar_check/jni/arm64-v8a/libonnxruntime.so | grep -iE "nmsrotated|mmdeploy"
# expected: NMSRotated / mmdeploy

# 3. 16 KB page alignment (Android 15+ devices)
/opt/homebrew/opt/llvm/bin/llvm-readelf -l /tmp/aar_check/jni/arm64-v8a/libonnxruntime.so | grep LOAD
# expected: Align column reads 0x4000
```

If check 1 or 2 returns nothing, the operator is not in the build — see the
[silent-missing-operator entry](#troubleshooting-real-failures-and-their-fixes) below.

---

## Publishing to GitHub Packages

### One command: build + publish

```bash
export GITHUB_ACTOR=<github-username>
export GITHUB_TOKEN=<PAT with write:packages>
export DOCKER_DEFAULT_PLATFORM=linux/amd64

python3 tools/android_custom_build/build_custom_android_package.py \
  "$PWD/android-build-out" \
  --onnxruntime_repo_url https://github.com/<your-fork>/onnxruntime.git \
  --onnxruntime_branch_or_tag nms-rotated-custom-op \
  --build_settings "$PWD/android-custom-minimal-xnnpack-4abi-static-nmsrotated-settings.json" \
  --config MinSizeRel \
  --publish \
  --publish_github_url https://maven.pkg.github.com/<owner>/<repo> \
  --publish_group com.<yourorg>.ml \
  --publish_artifact_id onnxruntime-android-nmsrotated \
  --publish_version 1.27.0-nmsrotated.1
```

Credentials are validated *before* the multi-hour build starts. Published versions are
immutable on GitHub Packages — bump `--publish_version` for every release
(`...-nmsrotated.2`, `...-nmsrotated.3`, …).

### Publish an already-built AAR (no rebuild)

```bash
java/gradlew -p tools/android_custom_build/publish publishToMavenLocal \
  -PaarDir="$PWD/android-build-out/output/aar_out/MinSizeRel/com/microsoft/onnxruntime/onnxruntime-android/1.27.0" \
  -PaarVersion=1.27.0-nmsrotated.1 \
  -PaarFileVersion=1.27.0 \
  -PaarGroup=com.<yourorg>.ml \
  -PaarArtifactId=onnxruntime-android-nmsrotated
```

Swap `publishToMavenLocal` for `publish` plus `-PgithubUrl=...` to target GitHub Packages.
Use distinct coordinates (never `com.microsoft.onnxruntime:onnxruntime-android`) so the
custom build can never be confused with the official package.

---

## Consuming the AAR in an Android app

```kotlin
// settings.gradle.kts
dependencyResolutionManagement {
    repositories {
        maven {
            url = uri("https://maven.pkg.github.com/<owner>/<repo>")
            credentials {
                username = providers.gradleProperty("gpr.user").orNull ?: System.getenv("GITHUB_ACTOR")
                password = providers.gradleProperty("gpr.key").orNull  ?: System.getenv("GITHUB_TOKEN")
            }
        }
    }
}

// build.gradle.kts
dependencies {
    implementation("com.<yourorg>.ml:onnxruntime-android-nmsrotated:1.27.0-nmsrotated.1")
}
```

Consumers need a token with `read:packages`. Because the operator is statically linked,
the app does **not** call `registerCustomOpsLibrary` — models using `mmdeploy:NMSRotated`
load directly. Ship `.ort` models (e.g. in `res/raw/`); the minimal runtime does not load
`.onnx`.

---

## Troubleshooting (real failures and their fixes)

Every entry below was hit for real while developing this fork.

| Symptom | Cause | Fix |
|---|---|---|
| `vcpkg was unable to detect the active compiler` + `CMAKE_C_COMPILER not set` at the very first CMake step | Container running as `aarch64` (Apple Silicon default) but the Android NDK only ships a `linux-x86_64` host toolchain, so the compiler path doesn't exist | `export DOCKER_DEFAULT_PLATFORM=linux/amd64`, rebuild the image; verify with `docker run --rm <image> uname -m` → `x86_64` |
| Build fails on a warning in *upstream* ORT code (e.g. `unused variable ... [-Werror]`) | Minimal-build configurations compile out code paths, leaving unused symbols that `-Werror` promotes to errors | Add `--compile_no_warning_as_error` to `build_params` — don't patch upstream |
| Build **succeeds** but the AAR has **no custom operator** (verification returns 0) | The container clones from the remote URL — local uncommitted changes and untracked source never reached it; unknown `-D` flags are silently ignored by CMake | Commit everything (including the op source), push to a fork, build with `--onnxruntime_repo_url`/`--onnxruntime_branch_or_tag` |
| Rebuilt after pushing new commits, but the old error is still there | Docker layer-caches the `git clone`, so the container still has the previous source | `docker rmi -f onnxruntime-android-custom-build:latest && docker builder prune -f` before rebuilding |
| `error: no type named 'CustomOpApi' in namespace 'Ort'` | Operator written against the legacy custom-op wrapper that was removed from modern ORT headers | Port to the modern API: `Ort::KernelContext` / `Ort::ConstValue` / `Ort::UnownedValue`, attributes via `OrtApi::KernelInfoGetAttribute_float` (done in this fork — use it as the reference) |
| Converter: `Failed to load library ... Library not loaded: @rpath/libonnxruntime.1.dylib` | pip wheel ships only the fully-versioned dylib name | Symlink `libonnxruntime.1.dylib → libonnxruntime.<ver>.dylib` in the wheel's `capi/` dir |
| Converter: `Fail: [ONNXRuntimeError] ... NMSRotated is not a registered function/op` | Conversion session doesn't know the custom op | Pass `--custom-op-library` with a host-native build of the operator matching the Python ORT version |
| `docker: ... name is already in use` | Previous run used `--docker_container_name` and the container persists | `docker rm -f <name>` |

---

## Data/Telemetry

Windows distributions of this project may collect usage data and send it to Microsoft to
help improve products and services. See the [privacy statement](docs/Privacy.md).

## License

This project is licensed under the [MIT License](LICENSE), same as upstream ONNX Runtime.
