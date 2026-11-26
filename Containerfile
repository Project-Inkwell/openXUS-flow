FROM docker.io/library/ubuntu:24.04@sha256:496754492fb28b4d3049432f2ca787449331e23fb14f0dd3fffea86bf5a93eb4

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential cmake ninja-build git ca-certificates pkg-config python3 python3-dev \
        libboost-filesystem-dev libboost-program-options-dev libboost-thread-dev \
        libboost-iostreams-dev libboost-system-dev libeigen3-dev \
        bison flex gawk libreadline-dev tcl-dev libffi-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

ARG YOSYS_TAG=v0.69
RUN git clone -q --depth 1 --branch ${YOSYS_TAG} --recurse-submodules --shallow-submodules \
        https://github.com/YosysHQ/yosys /tmp/yosys \
    && cd /tmp/yosys && cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local . \
    && cmake --build build -j"$(nproc)" && cmake --install build \
    && rm -rf /tmp/yosys
