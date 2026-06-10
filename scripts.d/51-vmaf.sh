#!/bin/bash

SCRIPT_REPO="https://github.com/Netflix/vmaf.git"
SCRIPT_COMMIT="32780bd9b635532f3dd63a7eb202b8cc54574fc6"

ffbuild_enabled() {
    return 0
}

# Each scripts.d/*.sh runs in an ISOLATED stage container that starts
# from `base` plus whatever's listed here. With CUDA enabled the
# libvmaf build needs nv-codec-headers (ffnvcodec.pc + headers)
# available in $FFBUILD_PREFIX -- those come from the 50-ffnvcodec.sh
# stage, which doesn't propagate automatically. Without this depends
# declaration, meson setup fails with:
#   "ffnvcodec/dynlink_cuda.h not found. Please install
#    nv-codec-headers ..."
# even though 50-ffnvcodec.sh ran successfully earlier.
#
# The dependency is conceptually optional on non-linux64 targets (no
# CUDA -> no ffnvcodec need), but declaring it unconditionally is
# fine: ffnvcodec.pc is small and is needed by ffmpeg's nvenc/nvdec
# config on all targets that ship those encoders anyway.
ffbuild_depends() {
    echo base
    echo ffnvcodec
}

ffbuild_dockerbuild() {
    # Kill build of unused and broken tools
    echo > libvmaf/tools/meson.build

    # IMPORTANT: build dir MUST live INSIDE libvmaf/, not as a sibling.
    # The libvmaf meson generates .cu custom_commands with -I paths
    # like `-I ../src -I ../include` that resolve relative to the
    # SOURCE root. With the historic `cd build && meson ../libvmaf`
    # pattern (build dir sibling to libvmaf/), those `../src` paths
    # point at <vmaf-repo>/src which doesn't exist (the actual source
    # is <vmaf-repo>/libvmaf/src). Using the in-tree pattern below
    # makes ../src resolve correctly. This only matters with
    # -Denable_cuda=true (the CPU build doesn't have those custom
    # commands), so the original out-of-tree pattern silently worked
    # until we enabled CUDA.
    cd libvmaf
    mkdir build && cd build

    local myconf=(
        --prefix="$FFBUILD_PREFIX"
        --buildtype=release
        --default-library=static
        -Dbuilt_in_models=true
        -Denable_tests=false
        -Denable_docs=false
        -Denable_float=true
    )

    if [[ $TARGET == *32 ]]; then
        myconf+=(
            -Denable_avx512=false
            -Denable_asm=false
        )
    else
        myconf+=(
            -Denable_avx512=true
            -Denable_asm=true
        )
    fi

    # CUDA backend for libvmaf -- enabled ONLY on linux64 because:
    #   1. only that target's base image installs the CUDA toolkit
    #      (cuda-nvcc + cudart-static + driver-dev stub);
    #   2. nvcc supports linux x86_64 native; cross-compiling CUDA
    #      kernels for win/arm/etc is either unsupported (winarm64,
    #      *mips64*, *ppc64*, *riscv64*) or pointless (no consumer
    #      NVIDIA GPUs on those targets).
    # When enabled, libvmaf builds .cu kernels into libvmaf.a and
    # ffmpeg's `configure --enable-libvmaf` picks them up via the
    # libvmaf.pc Cflags/Libs and auto-enables the libvmaf_cuda
    # filter -- no separate ffmpeg flag needed.
    if [[ $TARGET == linux64 ]]; then
        myconf+=(
            -Denable_cuda=true
        )
    fi

    if [[ $TARGET == win* || $TARGET == linux* ]]; then
        myconf+=(
            --cross-file=/cross.meson
        )
    else
        echo "Unknown target"
        return -1
    fi

    meson .. "${myconf[@]}" || cat meson-logs/meson-log.txt
    ninja -j"$(nproc)"
    DESTDIR="$FFBUILD_DESTDIR" ninja install

    sed -i 's/Libs.private:/Libs.private: -lstdc++/; t; $ a Libs.private: -lstdc++' "$FFBUILD_DESTPREFIX"/lib/pkgconfig/libvmaf.pc

    # If CUDA was enabled, append the static CUDA runtime + driver
    # stub to libvmaf.pc's Libs.private so ffmpeg's pkg-config
    # invocation pulls them into the final static link line.
    #
    # Path layout from cuda-cudart-dev-13-0 + cuda-driver-dev-13-0:
    #   /usr/local/cuda/lib64/libcudart_static.a   (runtime, static)
    #   /usr/local/cuda/lib64/stubs/libcuda.so     (driver shim,
    #                                               build-time only)
    # Note the stub for libcuda is in a `stubs/` SUBDIRECTORY, not
    # directly in lib64/, so a single `-L/usr/local/cuda/lib64` won't
    # find -lcuda. We pass both -L paths. The actual libcuda.so.1
    # used at runtime is mounted from the host by nvidia-container-
    # runtime; the stub is only there to satisfy the linker.
    #
    # -ldl + -lrt are transitive requirements of cudart_static.
    if [[ $TARGET == linux64 ]]; then
        sed -i 's|Libs.private:|Libs.private: -L/usr/local/cuda/lib64 -L/usr/local/cuda/lib64/stubs -lcudart_static -lcuda -ldl -lrt|' \
            "$FFBUILD_DESTPREFIX"/lib/pkgconfig/libvmaf.pc
        sed -i 's|Cflags:|Cflags: -I/usr/local/cuda/include|' \
            "$FFBUILD_DESTPREFIX"/lib/pkgconfig/libvmaf.pc
    fi
}

ffbuild_configure() {
    (( $(ffbuild_ffver) >= 501 )) || return 0
    echo --enable-libvmaf
}

ffbuild_unconfigure() {
    echo --disable-libvmaf
}
