/**
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#pragma once

#include <faiss/gpu/utils/StaticUtils.h>
#include <faiss/gpu/utils/DeviceDefs.cuh>
#include <faiss/gpu/utils/MergeNetworkUtils.cuh>
#include <faiss/gpu/utils/PtxUtils.cuh>
#include <faiss/gpu/utils/Select.cuh>
#include <faiss/gpu/utils/WarpShuffles.cuh>

#include "warp_select_faiss.cuh"

// TODO: Need to think further about the impact (and new boundaries created) on the registers
// because this will change the max k that can be processed. One solution might be to break
// up k into multiple batches for larger k.

namespace faiss {
namespace gpu {

// `Dir` true, produce largest values.
// `Dir` false, produce smallest values.
template <typename K, typename V, bool Dir, typename Comp, int NumWarpQ,
          int NumThreadQ, int ThreadsPerBlock>
struct KeyValueBlockSelect {
  static constexpr int kNumWarps = ThreadsPerBlock / kWarpSize;
  static constexpr int kTotalWarpSortSize = NumWarpQ;

  __device__ inline KeyValueBlockSelect(K initKVal, K initVKey, V initVVal,
                                        K* smemK, KeyValuePair<K, V>* smemV,
                                        int k)
    : initK(initKVal),
      initVk(initVKey),
      initVv(initVVal),
      numVals(0),
      warpKTop(initKVal),
      warpKTopRDist(initKVal),
      sharedK(smemK),
      sharedV(smemV),
      kMinus1(k - 1) {
    static_assert(utils::isPowerOf2(ThreadsPerBlock),
                  "threads must be a power-of-2");
    static_assert(utils::isPowerOf2(NumWarpQ), "warp queue must be power-of-2");

    // Fill the per-thread queue keys with the default value
#pragma unroll
    for (int i = 0; i < NumThreadQ; ++i) {
      threadK[i] = initK;
      threadV[i].key = initVk;
      threadV[i].value = initVv;
    }

    int laneId = getLaneId();
    int warpId = threadIdx.x / kWarpSize;
    warpK = sharedK + warpId * kTotalWarpSortSize;
    warpV = sharedV + warpId * kTotalWarpSortSize;

    // Fill warp queue (only the actual queue space is fine, not where
    // we write the per-thread queues for merging)
    for (int i = laneId; i < NumWarpQ; i += kWarpSize) {
      warpK[i] = initK;
      warpV[i].key = initVk;
      warpV[i].value = initVv;
    }

    warpFence();
  }

  __device__ inline void addThreadQ(K k, K vk, V vv) {
    if (Dir ? Comp::gt(k, warpKTop) : Comp::lt(k, warpKTop)) {
      // Rotate right
#pragma unroll
      for (int i = NumThreadQ - 1; i > 0; --i) {
        threadK[i] = threadK[i - 1];
        threadV[i].key = threadV[i - 1].key;
        threadV[i].value = threadV[i - 1].value;
      }

      threadK[0] = k;
      threadV[0].key = vk;
      threadV[0].value = vv;
      ++numVals;
    }
  }

  __device__ inline void checkThreadQ() {
    bool needSort = (numVals == NumThreadQ);

#if CUDA_VERSION >= 9000
    needSort = __any_sync(0xffffffff, needSort);
#else
    needSort = __any(needSort);
#endif

    if (!needSort) {
      // no lanes have triggered a sort
      return;
    }

    // This has a trailing warpFence
    mergeWarpQ();

    // Any top-k elements have been merged into the warp queue; we're
    // free to reset the thread queues
    numVals = 0;

#pragma unroll
    for (int i = 0; i < NumThreadQ; ++i) {
      threadK[i] = initK;
      threadV[i].key = initVk;
      threadV[i].value = initVv;
    }

    // We have to beat at least this element
    warpKTop = warpK[kMinus1];
    warpKTopRDist = warpV[kMinus1].key;

    warpFence();
  }

  /// This function handles sorting and merging together the
  /// per-thread queues with the warp-wide queue, creating a sorted
  /// list across both
  __device__ inline void mergeWarpQ() {
    int laneId = getLaneId();

    // Sort all of the per-thread queues
    warpSortAnyRegistersKVP<K, V, NumThreadQ, !Dir, Comp>(threadK, threadV);

    constexpr int kNumWarpQRegisters = NumWarpQ / kWarpSize;
    K warpKRegisters[kNumWarpQRegisters];
    KeyValuePair<K, V> warpVRegisters[kNumWarpQRegisters];

#pragma unroll
    for (int i = 0; i < kNumWarpQRegisters; ++i) {
      warpKRegisters[i] = warpK[i * kWarpSize + laneId];
      warpVRegisters[i].key = warpV[i * kWarpSize + laneId].key;
      warpVRegisters[i].value = warpV[i * kWarpSize + laneId].value;
    }

    warpFence();

    // The warp queue is already sorted, and now that we've sorted the
    // per-thread queue, merge both sorted lists together, producing
    // one sorted list
    warpMergeAnyRegistersKVP<K, V, kNumWarpQRegisters, NumThreadQ, !Dir, Comp,
                             false>(warpKRegisters, warpVRegisters, threadK,
                                    threadV);

    // Write back out the warp queue
#pragma unroll
    for (int i = 0; i < kNumWarpQRegisters; ++i) {
      warpK[i * kWarpSize + laneId] = warpKRegisters[i];
      warpV[i * kWarpSize + laneId].key = warpVRegisters[i].key;
      warpV[i * kWarpSize + laneId].value = warpVRegisters[i].value;
    }

    warpFence();
  }

  /// WARNING: all threads in a warp must participate in this.
  /// Otherwise, you must call the constituent parts separately.
  __device__ inline void add(K k, K vk, V vv) {
    addThreadQ(k, vk, vv);
    checkThreadQ();
  }

  __device__ inline void reduce() {
    // Have all warps dump and merge their queues; this will produce
    // the final per-warp results
    mergeWarpQ();

    // block-wide dep; thus far, all warps have been completely
    // independent
    __syncthreads();

    // All warp queues are contiguous in smem.
    // Now, we have kNumWarps lists of NumWarpQ elements.
    // This is a power of 2.
    FinalBlockMerge<kNumWarps, ThreadsPerBlock, K, KeyValuePair<K, V>, NumWarpQ,
                    Dir, Comp>::merge(sharedK, sharedV);

    // The block-wide merge has a trailing syncthreads
  }

  // Default element key
  const K initK;

  // Default element value
  const K initVk;
  const V initVv;

  // Number of valid elements in our thread queue
  int numVals;

  // The k-th highest (Dir) or lowest (!Dir) element
  K warpKTop;

  K warpKTopRDist;

  // Thread queue values
  K threadK[NumThreadQ];
  KeyValuePair<K, V> threadV[NumThreadQ];

  // Queues for all warps
  K* sharedK;
  KeyValuePair<K, V>* sharedV;

  // Our warp's queue (points into sharedK/sharedV)
  // warpK[0] is highest (Dir) or lowest (!Dir)
  K* warpK;
  KeyValuePair<K, V>* warpV;

  // This is a cached k-1 value
  int kMinus1;
};

}  // namespace gpu
}  // namespace faiss