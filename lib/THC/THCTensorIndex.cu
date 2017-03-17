#include "THC.h"
#include "THCTensorMath.h"
#include "THCGeneral.h"
#include "THCBlas.h"
#include "THCTensorCopy.h"
#include "THCTensorRandom.h"
#include "THCHalf.h"
#include "THCApply.cuh"
#include "THCReduce.cuh"
#include "THCDeviceUtils.cuh"
#include "THCNumerics.cuh"
#include "THCAtomics.cuh"

#include "hip/hip_runtime.h"

#include <GGL/grid_launch.hpp>

#include <algorithm> // for std::min

// We prefer this kernel to avoid reloading index points if the number
// of indices is a small number.
// This kernel in fact works for all choices of problem size, but if
// the number of indices chosen is large, then the
// indexCopyLargeIndex kernel is a better choice to increase
// parallelism.
template <typename T, typename IndexType, int DstDim, int SrcDim, int IdxDim>
__global__
void indexCopySmallIndex(hipLaunchParm lp,
                         //TensorInfo<T, IndexType> dst,
                         T* dstData,
                         IndexType* dstSizes,
                         IndexType* dstStrides,
                         int dstDims,
                         //TensorInfo<T, IndexType> src,
                         T* srcData,
                         IndexType* srcSizes,
                         IndexType* srcStrides,
                         int srcDims,
                         //TensorInfo<long, IndexType> indices,
                         long* indicesData,
                         IndexType* indicesSizes,
                         IndexType* indicesStrides,
                         int indicesDims,
                         int dstCopyDim,
                         int srcCopyDim,
                         IndexType innerSize,
                         long dstCopyDimSize)
{
  // In order to avoid reloading the index that we are copying, load
  // it once to handle all of the points that are being selected, so
  // it can be reused as much as possible. This kernel is chosen when
  // this is a good choice (small number of chosen indices), since
  // re-accessing indices in addition to src elements can be slow.
  for (IndexType srcIndex = 0; srcIndex < indicesSizes[0]; ++srcIndex) {
    // Lua indices begin at 1
    IndexType dstIndex =
      indicesData[IndexToOffset<long, IndexType, IdxDim>::get(srcIndex,
                                                              indicesSizes,
                                                              indicesStrides,
                                                              indicesDims)] - TH_INDEX_BASE;

    if (dstIndex < dstCopyDimSize) {
      // We stride over the output ignoring the indexed dimension
      // (innerSize), whose offset calculation is handled differently
      for (IndexType linearIndex = hipBlockIdx_x * hipBlockDim_x + hipThreadIdx_x;
           linearIndex < innerSize;
           linearIndex += hipGridDim_x * hipBlockDim_x) {
        IndexType dstOffset =
          IndexToOffset<T, IndexType, DstDim>::get(linearIndex, dstSizes, dstStrides, dstDims);

        dstOffset += dstIndex * dstStrides[dstCopyDim];

        IndexType srcOffset =
          IndexToOffset<T, IndexType, SrcDim>::get(linearIndex, srcSizes, srcStrides, srcDims);
        srcOffset += srcIndex * srcStrides[srcCopyDim];

        dstData[dstOffset] = srcData[srcOffset];
      }
    }
  }
}

// We prefer this kernel to balance parallelism across index points,
// if there are a large number of indices.
// This kernel in fact works for all choices of problem size, but if
// the number of indices chosen is small, then the
// indexCopySmallIndex kernel is a better choice to reduce memory
// accesses.
template <typename T, typename IndexType, int DstDim, int SrcDim, int IdxDim>
__global__
void indexCopyLargeIndex(hipLaunchParm lp,
                         //TensorInfo<T, IndexType> dst,
                         T* dstData,
                         IndexType* dstSizes,
                         IndexType* dstStrides,
                         int dstDims,
                         //TensorInfo<T, IndexType> src,
                         T* srcData,
                         IndexType* srcSizes,
                         IndexType* srcStrides,
                         int srcDims,
                         //TensorInfo<long, IndexType> indices,
                         long* indicesData,
                         IndexType* indicesSizes,
                         IndexType* indicesStrides,
                         int indicesDims,
                         int dstCopyDim,
                         int srcCopyDim,
                         IndexType innerSize,
                         long dstCopyDimSize)
{
  // We stride over the output including the indexed dimension
  // (totalSize), and calculate the destination index point based on that
  for (IndexType linearIndex = hipBlockIdx_x * hipBlockDim_x + hipThreadIdx_x;
       linearIndex < innerSize * indicesSizes[0];
       linearIndex += hipGridDim_x * hipBlockDim_x) {
    IndexType srcIndex = linearIndex / innerSize;
    IndexType elementInSlice = linearIndex % innerSize;

    // Lua indices begin at 1
    IndexType dstIndex =
      indicesData[IndexToOffset<long, IndexType, IdxDim>::get(srcIndex,
                                                              indicesSizes,
                                                              indicesStrides,
                                                              indicesDims)] - TH_INDEX_BASE;

    if (dstIndex < dstCopyDimSize) {
      IndexType dstOffset =
        IndexToOffset<T, IndexType, DstDim>::get(elementInSlice,
                                                 dstSizes,
                                                 dstStrides,
                                                 dstDims);
      dstOffset += dstIndex * dstStrides[dstCopyDim];

      IndexType srcOffset =
        IndexToOffset<T, IndexType, SrcDim>::get(elementInSlice,
                                                 srcSizes,
                                                 srcStrides,
                                                 srcDims);
      srcOffset += srcIndex * srcStrides[srcCopyDim];

      dstData[dstOffset] = srcData[srcOffset];
    }
  }
}

// We prefer this kernel to avoid reloading index points if the number
// of indices is a small number.
// This kernel in fact works for all choices of problem size, but if
// the number of indices chosen is large, then the
// indexAddLargeIndex kernel is a better choice to increase
// parallelism.
template <typename T, typename IndexType, int DstDim, int SrcDim, int IdxDim>
__global__
void indexAddSmallIndex(hipLaunchParm lp,
                        //TensorInfo<T, IndexType> dst,
                        T* dstData,
                        IndexType* dstSizes,
                        IndexType* dstStrides,
                        int dstDims,
                        //TensorInfo<T, IndexType> src,
                        T* srcData,
                        IndexType* srcSizes,
                        IndexType* srcStrides,
                        int srcDims,
                        //TensorInfo<long, IndexType> indices,
                        long* indicesData,
                        IndexType* indicesSizes,
                        IndexType* indicesStrides,
                        int indicesDims,
                        int dstAddDim,
                        int srcAddDim,
                        IndexType innerSize,
                        long dstAddDimSize)
{
  // In order to avoid reloading the index that we are copying, load
  // it once to handle all of the points that are being selected, so
  // it can be reused as much as possible. This kernel is chosen when
  // this is a good choice (small number of chosen indices), since
  // re-accessing indices in addition to src elements can be slow.
  for (IndexType srcIndex = 0; srcIndex < indicesSizes[0]; ++srcIndex) {
    // Lua indices begin at 1
    IndexType dstIndex =
      indicesData[IndexToOffset<long, IndexType, IdxDim>::get(srcIndex,
                                                              indicesSizes,
                                                              indicesStrides,
                                                              indicesDims)] - TH_INDEX_BASE;

    if (dstIndex < dstAddDimSize) {
      // We stride over the output ignoring the indexed dimension
      // (innerSize), whose offset calculation is handled differently
      for (IndexType linearIndex = hipBlockIdx_x * hipBlockDim_x + hipThreadIdx_x;
           linearIndex < innerSize;
           linearIndex += hipGridDim_x * hipBlockDim_x) {
        IndexType dstOffset =
          IndexToOffset<T, IndexType, DstDim>::get(linearIndex,
                                                   dstSizes,
                                                   dstStrides,
                                                   dstDims);
        dstOffset += dstIndex * dstStrides[dstAddDim];

        IndexType srcOffset =
          IndexToOffset<T, IndexType, SrcDim>::get(linearIndex,
                                                   srcSizes,
                                                   srcStrides,
                                                   srcDims);
        srcOffset += srcIndex * srcStrides[srcAddDim];

      // TODO: the below is temporarily disabled as it triggers a compiler bug.
      //  atomicAdd(&dstData[dstOffset], srcData[srcOffset]);
      }
    }
  }
}

// We prefer this kernel to balance parallelism across index points,
// if there are a large number of indices.
// This kernel in fact works for all choices of problem size, but if
// the number of indices chosen is small, then the
// indexAddSmallIndex kernel is a better choice to reduce memory
// accesses.
template <typename T, typename IndexType, int DstDim, int SrcDim, int IdxDim>
__global__
void indexAddLargeIndex(hipLaunchParm lp,
                        //TensorInfo<T, IndexType> dst,
                        T* dstData,
                        IndexType* dstSizes,
                        IndexType* dstStrides,
                        int dstDims,
                        //TensorInfo<T, IndexType> src,
                        T* srcData,
                        IndexType* srcSizes,
                        IndexType* srcStrides,
                        int srcDims,
                        //TensorInfo<long, IndexType> indices,
                        long* indicesData,
                        IndexType* indicesSizes,
                        IndexType* indicesStrides,
                        int indicesDims,
                        int dstAddDim,
                        int srcAddDim,
                        IndexType innerSize,
                        long dstAddDimSize)
{
  // We stride over the output including the indexed dimension
  // (totalSize), and calculate the destination index point based on that
  for (IndexType linearIndex = hipBlockIdx_x * hipBlockDim_x + hipThreadIdx_x;
       linearIndex < innerSize * indicesSizes[0];
       linearIndex += hipGridDim_x * hipBlockDim_x) {
    IndexType srcIndex = linearIndex / innerSize;
    IndexType elementInSlice = linearIndex % innerSize;

    // Lua indices begin at 1
    IndexType dstIndex =
      indicesData[IndexToOffset<long, IndexType, IdxDim>::get(srcIndex,
                                                              indicesSizes,
                                                              indicesStrides,
                                                              indicesDims)] - TH_INDEX_BASE;

    if (dstIndex < dstAddDimSize) {
      IndexType dstOffset =
        IndexToOffset<T, IndexType, DstDim>::get(elementInSlice,
                                                 dstSizes,
                                                 dstStrides,
                                                 dstDims);
      dstOffset += dstIndex * dstStrides[dstAddDim];

      IndexType srcOffset =
        IndexToOffset<T, IndexType, SrcDim>::get(elementInSlice,
                                                 srcSizes,
                                                 srcStrides,
                                                 srcDims);
      srcOffset += srcIndex * srcStrides[srcAddDim];

    // TODO: the below is temporarily disabled as it triggers a compiler bug.
    //  atomicAdd(&dstData[dstOffset], srcData[srcOffset]);
    }
  }
}

// We prefer this kernel to avoid reloading index points if the number
// of indices is a small number.
// This kernel in fact works for all choices of problem size, but if
// the number of indices chosen is large, then the
// indexFillLargeIndex kernel is a better choice to increase
// parallelism.
template <typename T, typename IndexType, int DstDim, int IdxDim>
__global__
void indexFillSmallIndex(hipLaunchParm lp,
                         //TensorInfo<T, IndexType> dst,
                         T* dstData,
                         IndexType* dstSizes,
                         IndexType* dstStrides,
                         int dstDims,
                         //TensorInfo<long, IndexType> indices,
                         long* indicesData,
                         IndexType* indicesSizes,
                         IndexType* indicesStrides,
                         int indicesDims,
                         int dstFillDim,
                         IndexType innerSize,
                         long dstFillDimSize,
                         T val)
{
  // In order to avoid reloading the index that we are copying, load
  // it once to handle all of the points that are being selected, so
  // it can be reused as much as possible. This kernel is chosen when
  // this is a good choice (small number of chosen indices), since
  // re-accessing indices in addition to src elements can be slow.
  for (IndexType dstIndex = 0; dstIndex < indicesSizes[0]; ++dstIndex) {
    // Lua indices begin at 1
    IndexType dstIndex_ =
      indicesData[IndexToOffset<long, IndexType, IdxDim>::get(dstIndex,
                                                              indicesSizes,
                                                              indicesStrides,
                                                              indicesDims)] - TH_INDEX_BASE;

    if (dstIndex < dstFillDimSize) {
      // We stride over the output ignoring the indexed dimension
      // (innerSize), whose offset calculation is handled differently
      for (IndexType linearIndex = hipBlockIdx_x * hipBlockDim_x + hipThreadIdx_x;
           linearIndex < innerSize;
           linearIndex += hipGridDim_x * hipBlockDim_x) {
        IndexType dstOffset =
          IndexToOffset<T, IndexType, DstDim>::get(linearIndex,
                                                   dstSizes,
                                                   dstStrides,
                                                   dstDims);
        dstOffset += dstIndex_ * dstStrides[dstFillDim];

        dstData[dstOffset] = val;
      }
    }
  }
}

// We prefer this kernel to balance parallelism across index points,
// if there are a large number of indices.
// This kernel in fact works for all choices of problem size, but if
// the number of indices chosen is small, then the
// indexFillSmallIndex kernel is a better choice to reduce memory
// accesses.
template <typename T, typename IndexType, int DstDim, int IdxDim>
__global__
void indexFillLargeIndex(hipLaunchParm lp,
                         //TensorInfo<T, IndexType> dst,
                         T* dstData,
                         IndexType* dstSizes,
                         IndexType* dstStrides,
                         int dstDims,
                         //TensorInfo<long, IndexType> indices,
                         long* indicesData,
                         IndexType* indicesSizes,
                         IndexType* indicesStrides,
                         int indicesDims,
                         int dstFillDim,
                         IndexType innerSize,
                         long dstFillDimSize,
                         T val)
{
  // We stride over the output including the indexed dimension
  // (totalSize), and calculate the destination index point based on that
  for (IndexType linearIndex = hipBlockIdx_x * hipBlockDim_x + hipThreadIdx_x;
       linearIndex < innerSize * indicesSizes[0];
       linearIndex += hipGridDim_x * hipBlockDim_x) {
    IndexType dstIndex = linearIndex / innerSize;
    IndexType elementInSlice = linearIndex % innerSize;

    // Lua indices begin at 1
    IndexType dstIndex_ =
      indicesData[IndexToOffset<long, IndexType, IdxDim>::get(dstIndex,
                                                              indicesSizes,
                                                              indicesStrides,
                                                              indicesDims)] - TH_INDEX_BASE;

    if (dstIndex_ < dstFillDimSize) {
      IndexType dstOffset =
        IndexToOffset<T, IndexType, DstDim>::get(elementInSlice,
                                                 dstSizes,
                                                 dstStrides,
                                                 dstDims);
      dstOffset += dstIndex_ * dstStrides[dstFillDim];

      dstData[dstOffset] = val;
    }
  }
}

// We prefer this kernel to avoid reloading index points if the number
// of indices is a small number.
// This kernel in fact works for all choices of problem size, but if
// the number of indices chosen is large, then the
// indexSelectLargeIndex kernel is a better choice to increase
// parallelism.
template <typename T, typename IndexType, int DstDim, int SrcDim, int IdxDim>
__global__
void indexSelectSmallIndex(hipLaunchParm lp,
                           //TensorInfo<T, IndexType> dst,
                           T* dstData,
                           IndexType* dstSizes,
                           IndexType* dstStrides,
                           int dstDims,
                           //TensorInfo<T, IndexType> src,
                           T* srcData,
                           IndexType* srcSizes,
                           IndexType* srcStrides,
                           int srcDims,
                           //TensorInfo<long, IndexType> indices,
                           long* indicesData,
                           IndexType* indicesSizes,
                           IndexType* indicesStrides,
                           int indicesDims,
                           int dstSelectDim,
                           int srcSelectDim,
                           IndexType innerSize,
                           long srcSelectDimSize)
{
  // In order to avoid reloading the index that we are copying, load
  // it once to handle all of the points that are being selected, so
  // it can be reused as much as possible. This kernel is chosen when
  // this is a good choice (small number of chosen indices), since
  // re-accessing indices in addition to src elements can be slow.
  for (IndexType dstIndex = 0; dstIndex < indicesSizes[0]; ++dstIndex) {
    // Lua indices begin at 1
    IndexType srcIndex =
      indicesData[IndexToOffset<long, IndexType, IdxDim>::get(dstIndex,
                                                              indicesSizes,
                                                              indicesStrides,
                                                              indicesDims)] - TH_INDEX_BASE;

    if (srcIndex < srcSelectDimSize) {
      // We stride over the output ignoring the indexed dimension
      // (innerSize), whose offset calculation is handled differently
      for (IndexType linearIndex = hipBlockIdx_x * hipBlockDim_x + hipThreadIdx_x;
           linearIndex < innerSize;
           linearIndex += hipGridDim_x * hipBlockDim_x) {
        IndexType dstOffset =
          IndexToOffset<T, IndexType, DstDim>::get(linearIndex,
                                                   dstSizes,
                                                   dstStrides,
                                                   dstDims);
        dstOffset += dstIndex * dstStrides[dstSelectDim];

        IndexType srcOffset =
          IndexToOffset<T, IndexType, SrcDim>::get(linearIndex,
                                                   srcSizes,
                                                   srcStrides,
                                                   srcDims);
        srcOffset += srcIndex * srcStrides[srcSelectDim];

        dstData[dstOffset] = srcData[srcOffset];
      }
    }
  }
}

// We prefer this kernel to balance parallelism across index points,
// if there are a large number of indices.
// This kernel in fact works for all choices of problem size, but if
// the number of indices chosen is small, then the
// indexSelectSmallIndex kernel is a better choice to reduce memory
// accesses.
template <typename T, typename IndexType, int DstDim, int SrcDim, int IdxDim>
__global__
void indexSelectLargeIndex(hipLaunchParm lp,
                           //TensorInfo<T, IndexType> dst,
                           T* dstData,
                           IndexType* dstSizes,
                           IndexType* dstStrides,
                           int dstDims,
                           //TensorInfo<T, IndexType> src,
                           T* srcData,
                           IndexType* srcSizes,
                           IndexType* srcStrides,
                           int srcDims,
                           //TensorInfo<long, IndexType> indices,
                           long* indicesData,
                           IndexType* indicesSizes,
                           IndexType* indicesStrides,
                           int indicesDims,
                           int dstSelectDim,
                           int srcSelectDim,
                           IndexType totalSize,
                           IndexType innerSize,
                           long srcSelectDimSize)
{
  // We stride over the output including the indexed dimension
  // (totalSize), and calculate the destination index point based on that
  for (IndexType linearIndex = hipBlockIdx_x * hipBlockDim_x + hipThreadIdx_x;
       linearIndex < totalSize;
       linearIndex += hipGridDim_x * hipBlockDim_x) {
    IndexType dstIndex = linearIndex / innerSize;
    IndexType elementInSlice = linearIndex % innerSize;

    // Lua indices begin at 1
    IndexType srcIndex =
      indicesData[IndexToOffset<long, IndexType, IdxDim>::get(dstIndex,
                                                              indicesSizes,
                                                              indicesStrides,
                                                              indicesDims)] - TH_INDEX_BASE;

    if (srcIndex < srcSelectDimSize) {
      IndexType dstOffset =
        IndexToOffset<T, IndexType, DstDim>::get(elementInSlice,
                                                 dstSizes,
                                                 dstStrides,
                                                 dstDims);
      dstOffset += dstIndex * dstStrides[dstSelectDim];

      IndexType srcOffset =
        IndexToOffset<T, IndexType, SrcDim>::get(elementInSlice, srcSizes, srcStrides, srcDims);
      srcOffset += srcIndex * srcStrides[srcSelectDim];

      dstData[dstOffset] = srcData[srcOffset];
    }
  }
}

#include "generic/THCTensorIndex.cu"
#include "THCGenerateAllTypes.h"
