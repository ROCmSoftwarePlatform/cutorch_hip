#ifndef THC_SORT_UTILS_INC
#define THC_SORT_UTILS_INC

#include "THCReduceApplyUtils.cuh"
#include "THCTensorTypeUtils.cuh"
#include "THCNumerics.cuh"

#include <hip/hip_runtime.h>

// Collection of kernel sort routines
template <typename T>
struct LTComp {
  __device__
  bool operator()(const T& a, const T& b) const {
    return THCNumerics<T>::lt(a, b);
  }
};

template <typename T>
struct GTComp {
  __device__
  bool operator()(const T& a, const T& b) const {
    return THCNumerics<T>::gt(a, b);
  }
};

template <typename T>
__device__
inline
void swapVars(T& t1, T& t2) {
  T tmp = t1;
  t1 = t2;
  t2 = tmp;
}

template <typename Comparator, typename K, typename V>
__device__
inline
void bitonicSwap(K& kA,
                 V& vA,
                 bool& validA,
                 K& kB,
                 V& vB,
                 bool& validB,
                 bool dir,
                 Comparator comp) {
  // Invalid entries always sort to the end
  // TODO: the comparison causes a Promote pass failure, trace the root cause,
  //       which might be one of the comparison functors.
  bool swap = (comp(kA, kB) && validA) || !validB;
  if (swap == dir) {
    swapVars(kA, kB);
    swapVars(vA, vB);
    swapVars(validA, validB);
  }
};

template <typename K, typename V, int Power2SortSize, typename Comparator>
__device__
inline
void bitonicSort(K (&keys)[Power2SortSize],
                 V (&values)[Power2SortSize],
                 bool (&valid)[Power2SortSize],
                 Comparator comp)
{
  #pragma unroll
  for (unsigned int size = 2; size < Power2SortSize; size *= 2) {
    bool flag = ((hipThreadIdx_x & (size / 2)) != 0);

    #pragma unroll
    for (unsigned int stride = size / 2; stride > 0; stride /= 2) {
      // Single warp per slice is completely synchronous
      if (Power2SortSize > warpSize) {
        __syncthreads();
      }

      unsigned int pos = 2 * hipThreadIdx_x - (hipThreadIdx_x & (stride - 1));
      bitonicSwap(keys[pos],
                  values[pos],
                  valid[pos],
                  keys[pos + stride],
                  values[pos + stride],
                  valid[pos + stride],
                  flag,
                  comp);
    }
  }

  #pragma unroll
  for (unsigned int stride = Power2SortSize / 2; stride > 0; stride /= 2) {
    // Single warp per slice is completely synchronous
    if (Power2SortSize > warpSize) {
      __syncthreads();
    }

    unsigned int pos = 2 * hipThreadIdx_x - (hipThreadIdx_x & (stride - 1));
    bitonicSwap(keys[pos],
                values[pos],
                valid[pos],
                keys[pos + stride],
                values[pos + stride],
                valid[pos + stride],
                false,
                comp);
  }

  // Single warp per slice is completely synchronous
  if (Power2SortSize > 2 * warpSize) {
    __syncthreads();
  }
}

// Sorts (key, value) pairs (in different tensors) in-place; i.e.,
// modifies the input `keys` and `values`
template <typename K,
          typename V,
          int KeyDims,
          int ValueDims,
          typename Comparator,
          typename IndexType,
          int Power2SortSize>
__global__
inline
void
bitonicSortKVInPlace(reference_to_const(TensorInfo<K, IndexType>) keys,
                     IndexType keySlices,
                     IndexType keySliceSize,
                     IndexType keySliceStride,
                     reference_to_const(TensorInfo<V, IndexType>) values,
                     IndexType valueSliceStride,
                     Comparator comp)
{
  // Find the slice of the tensor that we are sorting
  const IndexType linearIndex = getLinearBlockId<IndexType>();
  // Tiling the slices could have us be out of bounds, if there are a
  // lot of slices to sort
  if (linearIndex >= keySlices) {
    return;
  }

  __shared__ K sharedKeys[Power2SortSize];
  __shared__ V sharedValues[Power2SortSize];
  __shared__ bool sharedValid[Power2SortSize];

  const IndexType keyStartOffset =
    IndexToOffset<K, IndexType, KeyDims>::get(linearIndex, keys);
  const IndexType valueStartOffset =
    IndexToOffset<V, IndexType, ValueDims>::get(linearIndex, values);

  // If the sort size is 1, the data is already sorted
  if (Power2SortSize == 1) {
    return;
  } else {
    // Otherwise, each thread is responsible for loading and storing 2
    // elements. The sort size is guaranteed to be >= 2
    const int elem1 = hipThreadIdx_x;
    const int elem2 = hipThreadIdx_x + (Power2SortSize / 2);

    bool valid1 = (elem1 < keySliceSize);
    K k1 = valid1 ?
      keys.data[keyStartOffset + elem1 * keySliceStride] : ScalarConvert<int, K>::to(0);
    V v1 = valid1 ?
      values.data[valueStartOffset + elem1 * valueSliceStride] : ScalarConvert<int, V>::to(0);

    sharedKeys[elem1] = k1;
    sharedValues[elem1] = v1;
    sharedValid[elem1] = valid1;

    bool valid2 = (elem2 < keySliceSize);
    K k2 = valid2 ?
      keys.data[keyStartOffset + elem2 * keySliceStride] : ScalarConvert<int, K>::to(0);
    V v2 = valid2 ?
      values.data[valueStartOffset + elem2 * valueSliceStride] : ScalarConvert<int, V>::to(0);

    sharedKeys[elem2] = k2;
    sharedValues[elem2] = v2;
    sharedValid[elem2] = valid2;

    // Sort!
    bitonicSort(sharedKeys, sharedValues, sharedValid, comp);

    // elem1 and elem2 values might be out-of-range, if the data size we are
    // sorting is smaller than half the power2 size
    if (valid1) {
      keys.data[keyStartOffset + elem1 * keySliceStride] =
        sharedKeys[elem1];
      values.data[valueStartOffset + elem1 * valueSliceStride] =
        sharedValues[elem1];
    }

    if (valid2) {
      keys.data[keyStartOffset + elem2 * keySliceStride] =
        sharedKeys[elem2];
      values.data[valueStartOffset + elem2 * valueSliceStride] =
        sharedValues[elem2];
    }
  }
}

#endif // THC_SORT_UTILS_INC

