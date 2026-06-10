ARG GH_REPO=ghcr.io/btbn/ffmpeg-builds
FROM $GH_REPO/base:latest

RUN --mount=src=ct-ng-config,dst=/.config \
    git clone --filter=blob:none https://github.com/crosstool-ng/crosstool-ng.git /ct-ng && cd /ct-ng && \
    ./bootstrap && \
    ./configure --enable-local && \
    make -j$(nproc) && \
    cp /.config .config && \
    ./ct-ng build && \
    cd / && \
    rm -rf ct-ng

# Prepare "cross" environment to heavily favour static builds
RUN \
    find /opt/ct-ng \( -type l \
        -and -name '*.so' \
        -and -not -ipath '*plugin*' \
        -and -not -name 'libdl.*' \
        -and -not -name 'libc.*' \
        -and -not -name 'libm.*' \
        -and -not -name 'libmvec.*' \
        -and -not -name 'librt.*' \
        -and -not -name 'libpthread.*' \
        \) -delete && \
    find /opt/ct-ng \( \
        -name 'libdl.a' \
        -or -name 'libc.a' \
        -or -name 'libm.a' \
        -or -name 'libmvec.a' \
        -or -name 'librt.a' \
        -or -name 'libpthread.a' \
        \) -delete && \
    mkdir /opt/ffbuild

ENV FFBUILD_TOOLCHAIN=x86_64-ffbuild-linux-gnu \
    FFBUILD_RUST_TARGET="x86_64-unknown-linux-gnu"

RUN \
    rustup default nightly && \
    echo "[unstable]\ntarget-applies-to-host = true\nhost-config = true\n" > "$CARGO_HOME"/config.toml && \
    echo "[target.$FFBUILD_RUST_TARGET]\nlinker = \"${FFBUILD_TOOLCHAIN}-gcc\"\nar = \"${FFBUILD_TOOLCHAIN}-gcc-ar\"\n" >> "$CARGO_HOME"/config.toml && \
    echo "[target.host]\nlinker = \"gcc\"\nar = \"ar\"\n" >> "$CARGO_HOME"/config.toml

ADD toolchain.cmake /toolchain.cmake
ADD cross.meson /cross.meson

ADD gen-implib.sh /usr/bin/gen-implib
RUN git clone --filter=blob:none --depth=1 https://github.com/yugr/Implib.so /opt/implib

ENV PATH="/opt/ct-ng/bin:${PATH}" \
    FFBUILD_TARGET_FLAGS="--pkg-config=pkg-config --cross-prefix=${FFBUILD_TOOLCHAIN}- --arch=x86_64 --target-os=linux" \
    FFBUILD_CROSS_PREFIX="${FFBUILD_TOOLCHAIN}-" \
    FFBUILD_PREFIX=/opt/ffbuild \
    FFBUILD_DESTDIR=/opt/ffdest \
    FFBUILD_DESTPREFIX=/opt/ffdest/opt/ffbuild \
    FFBUILD_CMAKE_TOOLCHAIN=/toolchain.cmake \
    PKG_CONFIG=pkg-config \
    PKG_CONFIG_LIBDIR=/opt/ffbuild/lib/pkgconfig:/opt/ffbuild/share/pkgconfig \
    CC="${FFBUILD_TOOLCHAIN}-gcc" \
    CXX="${FFBUILD_TOOLCHAIN}-g++" \
    LD="${FFBUILD_TOOLCHAIN}-ld" \
    AR="${FFBUILD_TOOLCHAIN}-gcc-ar" \
    RANLIB="${FFBUILD_TOOLCHAIN}-gcc-ranlib" \
    NM="${FFBUILD_TOOLCHAIN}-gcc-nm" \
    CFLAGS="-static-libgcc -static-libstdc++ -I/opt/ffbuild/include -O2 -pipe -fPIC -DPIC -D_FORTIFY_SOURCE=2 -fstack-protector-strong -fstack-clash-protection -pthread" \
    CXXFLAGS="-static-libgcc -static-libstdc++ -I/opt/ffbuild/include -O2 -pipe -fPIC -DPIC -D_FORTIFY_SOURCE=2 -fstack-protector-strong -fstack-clash-protection -pthread" \
    LDFLAGS="-static-libgcc -static-libstdc++ -L/opt/ffbuild/lib -O2 -pipe -fstack-protector-strong -fstack-clash-protection -Wl,-z,relro,-z,now -pthread -lm" \
    STAGE_CFLAGS="-fvisibility=hidden -fno-semantic-interposition" \
    STAGE_CXXFLAGS="-fvisibility=hidden -fno-semantic-interposition"

# === CUDA toolkit (for libvmaf-cuda) ===========================================
#
# Installs nvcc + cudart static + driver stubs from NVIDIA's apt repo so
# libvmaf can be built with `-Denable_cuda=true` and ffmpeg picks up
# the libvmaf_cuda filter automatically. We use the ubuntu2404 repo
# because NVIDIA has not yet published an ubuntu2604 repo as of CUDA
# 13.0; the packages are pure userspace (nvcc, cudart, libcuda stub)
# and have no kernel-side dependency, so they work fine on the ubuntu
# 26.04 base image.
#
# Only the minimal set:
#   cuda-nvcc-13-0          -- the CUDA C/C++ compiler
#   cuda-cudart-static-13-0 -- libcudart_static.a for static link into libvmaf
#   cuda-driver-dev-13-0    -- libcuda.so stub for build-time linking
#                              (real libcuda.so.1 is mounted by the
#                              runtime container's nvidia-container-runtime)
#
# Total install ~250 MB vs ~4 GB for the full toolkit.
#
# `nvcc` is told via NVCC_PREPEND_FLAGS to use the cross-toolchain g++
# for HOST-side compilation; device-side (.cu -> PTX/SASS) compilation
# uses nvcc's own bundled tooling and doesn't care about the cross
# toolchain. Without -ccbin, nvcc would default to /usr/bin/g++ (the
# build container's native gcc, NOT the crosstool-ng one), producing
# host objects ABI-incompatible with the rest of the libvmaf static
# library.
ARG CUDA_REPO_URL=https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
RUN curl -fsSL "$CUDA_REPO_URL" -o /tmp/cuda-keyring.deb \
 && dpkg -i /tmp/cuda-keyring.deb \
 && rm /tmp/cuda-keyring.deb \
 && apt-get -y update \
 && apt-get -y install --no-install-recommends \
        cuda-nvcc-13-0 \
        cuda-cudart-static-13-0 \
        cuda-driver-dev-13-0 \
 && apt-get -y clean autoclean \
 && rm -rf /var/lib/apt/lists/*

ENV CUDA_PATH=/usr/local/cuda \
    PATH="/usr/local/cuda/bin:${PATH}" \
    NVCC_PREPEND_FLAGS="-ccbin x86_64-ffbuild-linux-gnu-g++"
