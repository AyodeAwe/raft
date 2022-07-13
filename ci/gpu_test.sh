#!/bin/bash
# Copyright (c) 2020-2022, NVIDIA CORPORATION.
#########################################
# RAFT GPU build and test script for CI #
#########################################

set -e
NUMARGS=$#
ARGS=$*

# Arg parsing function
function hasArg {
    (( ${NUMARGS} != 0 )) && (echo " ${ARGS} " | grep -q " $1 ")
}

# Set path and build parallel level
export PATH=/opt/conda/bin:/usr/local/cuda/bin:$PATH
export PARALLEL_LEVEL=${PARALLEL_LEVEL:-8}
export CUDA_REL=${CUDA_VERSION%.*}

# Set home to the job's workspace
export HOME="$WORKSPACE"

# Parse git describe
cd "$WORKSPACE"
export GIT_DESCRIBE_TAG=`git describe --tags`
export MINOR_VERSION=`echo $GIT_DESCRIBE_TAG | grep -o -E '([0-9]+\.[0-9]+)'`
unset GIT_DESCRIBE_TAG

# ucx-py version
export UCX_PY_VERSION='0.27.*'

################################################################################
# SETUP - Check environment
################################################################################

gpuci_logger "Check environment"
env

gpuci_logger "Check GPU usage"
nvidia-smi

gpuci_logger "Activate conda env"
. /opt/conda/etc/profile.d/conda.sh
conda activate rapids

CPP_CHANNEL=$(rapids-download-conda-from-s3 cpp)
PYTHON_CHANNEL=$(rapids-download-conda-from-s3 python)

# Install pre-built conda packages from previous CI step
gpuci_logger "Install libraft conda packages from CPU job"
gpuci_mamba_retry install -c "${CPP_CHANNEL}" libraft-headers libraft-distance libraft-nn libraft-tests

gpuci_logger "Check compiler versions"
python --version
$CC --version
$CXX --version

gpuci_logger "Check conda environment"
conda info
conda config --show-sources
conda list --show-channel-urls

################################################################################
# BUILD - Build RAFT tests
################################################################################

gpuci_logger "Build and install Python targets"
gpuci_mamba_retry install -c "${CPP_CHANNEL}" -c "${PYTHON_CHANNEL}" pyraft pylibraft

gpuci_logger "sccache stats"
sccache --show-stats

################################################################################
# TEST - Run GoogleTest and py.tests for RAFT
################################################################################

if hasArg --skip-tests; then
    gpuci_logger "Skipping Tests"
    exit 0
fi

# Install the master version of dask, distributed, and dask-ml
gpuci_logger "Install the master version of dask and distributed"
set -x
pip install "git+https://github.com/dask/distributed.git@2022.05.2" --upgrade --no-deps
pip install "git+https://github.com/dask/dask.git@2022.05.2" --upgrade --no-deps
set +x

gpuci_logger "Check GPU usage"
nvidia-smi

gpuci_logger "GoogleTest for raft"
cd "$WORKSPACE"
GTEST_OUTPUT="xml:$WORKSPACE/test-results/raft_cpp/" "$CONDA_PREFIX/bin/libraft/gtests/test_raft"

gpuci_logger "Python pytest for pyraft"
cd "$WORKSPACE/python/raft/raft/test"
python -m pytest --cache-clear --junitxml="$WORKSPACE/junit-pyraft.xml" -v -s

gpuci_logger "Python pytest for pylibraft"
cd "$WORKSPACE/python/pylibraft/pylibraft/test"
python -m pytest --cache-clear --junitxml="$WORKSPACE/junit-pylibraft.xml" -v -s

if [ "$(arch)" = "x86_64" ]; then
  gpuci_logger "Building docs"
  gpuci_mamba_retry install "rapids-doc-env=${MINOR_VERSION}.*"
  "$WORKSPACE/build.sh" docs -v
fi