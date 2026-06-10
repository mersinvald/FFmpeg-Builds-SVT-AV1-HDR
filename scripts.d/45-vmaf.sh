#!/bin/bash

SCRIPT_REPO="https://github.com/Netflix/vmaf.git"
SCRIPT_COMMIT="32780bd9b635532f3dd63a7eb202b8cc54574fc6"

ffbuild_enabled() {
    return 0
}

ffbuild_dockerbuild() {
    # Kill build of unused and broken tools
    echo > libvmaf/tools/meson.build

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

    meson "${myconf[@]}" ../libvmaf || cat meson-logs/meson-log.txt
    ninja -j"$(nproc)"
    DESTDIR="$FFBUILD_DESTDIR" ninja install

    sed -i 's/Libs.private:/Libs.private: -lstdc++/; t; $ a Libs.private: -lstdc++' "$FFBUILD_DESTPREFIX"/lib/pkgconfig/libvmaf.pc

    # If CUDA was enabled, append the static CUDA runtime + driver
    # stub to libvmaf.pc's Libs.private so ffmpeg's pkg-config
    # invocation pulls them into the final static link line.
    # libcudart_static.a is in /usr/local/cuda/lib64; libcuda is the
    # driver shim from cuda-driver-dev-13-0 (resolved at runtime
    # against /usr/lib/x86_64-linux-gnu/libcuda.so.1 mounted by
    # nvidia-container-runtime). -ldl + -lrt are required by
    # cudart_static.
    if [[ $TARGET == linux64 ]]; then
        sed -i 's|Libs.private:|Libs.private: -L/usr/local/cuda/lib64 -lcudart_static -lcuda -ldl -lrt|' \
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
