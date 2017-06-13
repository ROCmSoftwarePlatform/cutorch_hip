#ifndef THC_TENSORMATH_REDUCE_CUH
#define THC_TENSORMATH_REDUCE_CUH

#include "THCTensorMath.h"
#include "THCGeneral.h"
#include "THCNumerics.cuh"
#include "THCReduce.cuh"
#include "THCReduceAll.cuh"
#ifdef THRUST_PATH
#include "THCThrustAllocator.cuh"
#include <thrust/functional.h>
#include <thrust/device_ptr.h>
#include <thrust/transform_reduce.h>
#include <thrust/inner_product.h>
#if CUDA_VERSION >= 7000
#include <thrust/system/cuda/execution_policy.h>
#endif  // CUDA_VERSION
#else   // THRUST_PATH
    #include <bolt/amp/functional.h>
    #include <bolt/amp/pair.h>
    #include <bolt/amp/inner_product.h>
    #include <bolt/amp/iterator/ubiquitous_iterator.h>
    #include "hip/hcc_detail/hip_fp16.h"
#endif  // THRUST_PATH


// Reduction operators that support `half`, unlike Thrust
template <typename InT, typename AccT>
struct ReduceAdd {
  inline __device__ AccT operator()(AccT a, InT b) const {
    return a + (AccT) b;
  }
};

#ifdef CUDA_HALF_TENSOR
template <>
struct ReduceAdd<half, half> {
  inline __device__ half operator()(half a, half b) const {
#ifdef CUDA_HALF_INSTRUCTIONS
    return __hadd(a, b);
#else
    float fa = __half2float(a);
    float fb = __half2float(b);
    return __float2half(fa + fb);
#endif
  }
};

template <>
struct ReduceAdd<half, float> {
  inline __device__ float operator()(float a, half b) const {
    return a + __half2float(b);
  }
};
#endif // CUDA_HALF_TENSOR

template <typename InT, typename AccT>
struct ReduceMultiply {
  inline __device__ AccT operator()(AccT a, InT b) const {
    return a * (AccT) b;
  }
};

#ifdef CUDA_HALF_TENSOR
template <>
struct ReduceMultiply<half, half> {
  inline __device__ half operator()(half a, half b) const {
#ifdef CUDA_HALF_INSTRUCTIONS
    return __hmul(a, b);
#else
    float fa = __half2float(a);
    float fb = __half2float(b);
    return __float2half(fa * fb);
#endif
  }
};

template <>
struct ReduceMultiply<half, float> {
  inline __device__ float operator()(float a, half b) const {
    return a * __half2float(b);
  }
};
#endif // CUDA_HALF_TENSOR

template <typename ResT, typename ArgT>
struct SquareFunctor {
    __host__ __device__ SquareFunctor(ResT mean): mean_(mean) {}

    inline __device__ ResT operator()(ArgT x) const {
      return (((ResT) x) - mean_) * (((ResT) x) - mean_);
    }


    __host__ __device__ ~SquareFunctor() {}
    const ResT mean_;
};

#ifdef CUDA_HALF_TENSOR
template <typename ResT>
struct SquareFunctor<ResT, half> {
    __host__ __device__ SquareFunctor(ResT mean): mean_(mean) {}

    inline __device__ ResT operator()(half x) const {
      return THCNumerics<ResT>::mul(
        THCNumerics<ResT>::sub(mean_, ScalarConvert<half, ResT>::to(x)),
        THCNumerics<ResT>::sub(mean_, ScalarConvert<half, ResT>::to(x))
      );
    }

    __host__ __device__ ~SquareFunctor() {}
    const ResT mean_;
};
#endif // CUDA_HALF_TENSOR

template <typename T>
struct ReduceMin {
   __device__ 
    const T& operator()(const T& a, const T& b) const {
#ifdef __NVCC__
    return THCNumerics<T>::lt(a, b) ? a : b;
#else
    T diff = THCNumerics<T>::sub(a, b);
    return (diff < 0 ) ? a : b;
#endif
  }
};

template <typename T>
struct ReduceMax {
  __device__ 
   const T& operator()(const T& a, const T& b) const {
#ifdef __NVCC__
    return THCNumerics<T>::gt(a, b) ? a : b;
#else
    T diff = THCNumerics<T>::sub(a, b);
    return (diff > 0 ) ? a : b;
#endif
  }
};

struct LogicalAll {
  inline __device__ unsigned char operator()(unsigned char x,
                                             unsigned char y) const {
    return (x && y);
  }
};

struct LogicalAny {
  inline __device__ unsigned char operator()(unsigned char x,
                                             unsigned char y) const {
    return (x || y);
  }
};

template<typename Real>
__global__ void THCTensor_kernel_renorm(Real *data, const Real value, const ptrdiff_t size, const Real maxnorm)
{
  __shared__ Real buffer[32];
  long tx = hipThreadIdx_x;
  long bx = hipBlockIdx_x;
  long step = hipBlockDim_x;
  Real *row = data + size*bx;

  buffer[tx] = ScalarConvert<int, Real>::to(0);

  // get norm of axis
  for (ptrdiff_t i=tx; i<size; i+=step)
  {
    buffer[tx] = THCNumerics<Real>::add(
      buffer[tx],
      THCNumerics<Real>::pow(
        THCNumerics<Real>::abs(row[i]),
        value)
    );
  }
  // add (reduce)
  for (unsigned int stride = hipBlockDim_x >> 1; stride > 0; stride >>= 1)
  {
    __syncthreads();
    if (tx < stride)
      buffer[tx] = THCNumerics<Real>::add(buffer[tx], buffer[tx+stride]);
  }
  // clip norms
  __syncthreads();
  Real norm = THCNumerics<Real>::pow(buffer[0], THCNumerics<Real>::cinv(value));
  if (THCNumerics<Real>::gt(norm, maxnorm))
  {
    norm = THCNumerics<Real>::div(
      maxnorm,
      THCNumerics<Real>::add(
        norm,
        ScalarConvert<float, Real>::to(1e-7)
      )
    );
    // renormalize
    for (ptrdiff_t i=tx; i<size; i+=step)
    {
      row[i] = THCNumerics<Real>::mul(row[i], norm);
    }
  }
}

template <typename T>
struct TensorNonZeroOp
{
  __host__ __device__ TensorNonZeroOp() {}
  __host__ __device__ T operator()(T lhs) const {
    if (THCNumerics<T>::eq(lhs, ScalarConvert<float, T>::to(0.0))) {
      return ScalarConvert<int, T>::to(0);
    } else {
      return ScalarConvert<int, T>::to(1);
    }
  }
};

template <typename T, int StaticExp>
struct TensorNormOp
{
  __host__ __device__ TensorNormOp(T exp) : exponent(exp) {}

  __host__ __device__ T operator()(T x) const {
    if (StaticExp == 1) {
      return (T) fabsf((float) x);
    } else if (StaticExp == 2) {
      return x * x;
    } else {
      return (T) powf(fabsf((float) x), (float) exponent);
    }
  }

  const T exponent;
};

template <int StaticExp>
struct TensorNormOp<double, StaticExp>
{
  __host__ __device__ TensorNormOp(double exp) : exponent(exp) {}

  __host__ __device__ double operator()(double x) const {
    if (StaticExp == 1) {
      return fabs(x);
    } else if (StaticExp == 2) {
      return x * x;
    } else {
      return pow(fabs(x), exponent);
    }
  }

  const double exponent;
};

#ifdef CUDA_HALF_TENSOR
template <int StaticExp>
struct TensorNormOp<half, StaticExp>
{
  __host__ __device__ TensorNormOp(half exp) : exponent(exp) {}

  __host__ __device__ half operator()(half x) const {
    if (StaticExp == 1) {
      return THCNumerics<half>::abs(x);
    } else if (StaticExp == 2) {
      return THCNumerics<half>::mul(x, x);
    } else {
      return THCNumerics<half>::pow(THCNumerics<half>::abs(x), exponent);
    }
  }

  const half exponent;
};
#endif

template <typename Tacc, typename T>
struct TensorDistOp
{
  __host__ __device__ TensorDistOp(Tacc exp) : exponent(exp) {}

  __host__ __device__ Tacc operator()(T x, T y) const {
    Tacc xr = ScalarConvert<T, Tacc>::to(x);
    Tacc yr = ScalarConvert<T, Tacc>::to(y);
    return THCNumerics<Tacc>::pow(
      THCNumerics<Tacc>::abs(THCNumerics<Tacc>::sub(xr, yr)),
      exponent
    );
  }

  const Tacc exponent;
};

#ifdef THRUST_PATH
  #include <thrust/functional.h>
#else
  #include <bolt/amp/functional.h>
  #include <bolt/amp/pair.h>
#endif

// Given the sum of values and the sum of squares, compute the variance or standard deviation.
template<typename Real, bool flag, bool apply_sqrt>
__forceinline__ __device__ Real THCTensor_computeVar(Real sum, Real sum2, unsigned row_size) {
  Real rs2 = ScalarConvert<unsigned, Real>::to(row_size);
  Real rs2m = ScalarConvert<unsigned, Real>::to(row_size - 1);
  Real zero = ScalarConvert<int, Real>::to(0);
  if (flag) {
    sum = THCNumerics<Real>::div(sum, rs2);
    sum2 = THCNumerics<Real>::div(sum2, rs2);
    sum2 = THCNumerics<Real>::sub(sum2, THCNumerics<Real>::mul(sum, sum));
    sum2 = (THCNumerics<Real>::lt(sum2, zero) ? zero : sum2);
  }
  else {
    sum = THCNumerics<Real>::div(sum, rs2);
    sum2 = THCNumerics<Real>::div(sum2, rs2m);
    sum2 = THCNumerics<Real>::sub(sum2,
      THCNumerics<Real>::mul(
        THCNumerics<Real>::div(rs2 ,rs2m),
        THCNumerics<Real>::mul(sum, sum)));
    sum2 = (THCNumerics<Real>::lt(sum2, zero) ? zero : sum2);
  }
  if (apply_sqrt)
    return THCNumerics<Real>::sqrt(sum2);
  else
    return sum2;
}

/* Compute the variance (or standard deviation) along an outer dimension of a tensor.
 *
 * - num_orows is the size of the flattened outer dimensions;
 * - num_irows is the size of the flattened inner dimensions;
 * - row_size is the size of the dimension along which to compute the variance;
 * - if flag is set, normalize by `row_size` instead of `row_size - 1`
 * - if apply_sqrt is set, compute the standard deviation instead of variance
 *
 * The dimensions to the outside and inside of the specified dimension are considered as flattened.
 * Thread blocks with the same hipBlockIdx_y process an "outer row" (i.e. an element of the flattened
 * outer dimensions, which contains several "inner rows").
 * Each thread processes a single inner row at a time.
 */
template<typename Real, bool flag, bool apply_sqrt>
__global__ void THCTensor_kernel_varOuterDim(Real *tgt, Real *src_, unsigned num_orows, unsigned num_irows, unsigned row_size)
{
  for (unsigned orow = hipBlockIdx_x; orow < num_orows; orow += hipGridDim_x) {
    for (unsigned irow = hipBlockIdx_y * hipBlockDim_x + hipThreadIdx_x; irow < num_irows; irow += hipGridDim_y * hipBlockDim_x) {
      Real *src = src_ + orow * row_size * num_irows + irow;
      Real sum = ScalarConvert<int, Real>::to(0), sum2 = ScalarConvert<int, Real>::to(0);

      for (unsigned col = 0; col < row_size; ++col) {
        Real val = *src;
        sum = THCNumerics<Real>::add(sum, val);
        sum2 = THCNumerics<Real>::add(
          sum2,
          THCNumerics<Real>::mul(val, val)
        );

        src += num_irows;
      }

      tgt[orow * num_irows + irow] = THCTensor_computeVar<Real, flag, apply_sqrt>(sum, sum2, row_size);
    }
  }
}

template<typename TensorTypeK, typename Real, bool apply_sqrt>
__host__ void THCTensor_varOuterDim(THCState *state, TensorTypeK *tgt, TensorTypeK *src, long dimension, int flag)
{
  unsigned ndim = TensorUtils<TensorTypeK>::getDims(state, src);
  // Treat all outer dimensions (i.e. dim < dimension) as one.
  unsigned num_orows = 1;
  for (long dim = 0; dim < dimension; dim++) {
    num_orows *= TensorUtils<TensorTypeK>::getSize(state, src, dim);
  }
  unsigned row_size = TensorUtils<TensorTypeK>::getSize(state, src, dimension);
  // Treat all inner dimensions (i.e. dim > dimension) as one.
  unsigned num_irows = 1;
  for (unsigned dim = dimension + 1; dim < ndim; dim++) {
    num_irows *= TensorUtils<TensorTypeK>::getSize(state, src, dim);
  }

  dim3 threads(min(512, num_irows));
  unsigned maxGridDim = 1024;
  dim3 grid(min(maxGridDim, num_orows), min(maxGridDim, THCCeilDiv(num_irows, threads.x)));

  if (flag) {
    hipLaunchKernelGGL((THCTensor_kernel_varOuterDim<Real, true, apply_sqrt>), grid, threads, 0, THCState_getCurrentStream(state),
        TensorUtils<TensorTypeK>::getData(state, tgt), TensorUtils<TensorTypeK>::getData(state, src), num_orows, num_irows, row_size);
  } else {
    hipLaunchKernelGGL((THCTensor_kernel_varOuterDim<Real, false, apply_sqrt>), grid, threads, 0, THCState_getCurrentStream(state),
        TensorUtils<TensorTypeK>::getData(state, tgt), TensorUtils<TensorTypeK>::getData(state, src), num_orows, num_irows, row_size);
  }
  hipError_t errcode = hipGetLastError();
  if (errcode != hipSuccess) {
    THError(hipGetErrorString(errcode));
  }
}

/* Compute the variance (or standard deviation) of the innermost dimension of a tensor.
 *
 * - num_rows is the size of the flattened outer dimensions;
 * - row_size is the size of the innermost dimension;
 * - if flag is set, normalize by `row_size` instead of `row_size - 1`
 * - if apply_sqrt is set, compute the standard deviation instead of variance
 *
 * The outer dimensions of the tensor are considered as a single dimension, i.e. the tensor is
 * considered as having 'num_rows' rows of size 'row_size'.
 * Each thread block processes one or more sets of contiguous rows (processing multiple rows
 * per thread block is quicker than processing a single row, especially for short rows).
 */
template<typename Real, bool flag, bool apply_sqrt>
__global__ void THCTensor_kernel_varInnermostDim(Real *tgt, Real *src_, unsigned num_rows, unsigned row_size)
{
  __shared__ Real ssum[32][16];
  __shared__ Real ssum2[32][16];

  for (unsigned block_row = hipBlockIdx_x * hipBlockDim_y; block_row < num_rows; block_row += hipBlockDim_y * hipGridDim_x) {
    unsigned row = block_row + hipThreadIdx_y;
    Real sum = ScalarConvert<int, Real>::to(0), sum2 = ScalarConvert<int, Real>::to(0);
    if (row < num_rows) {
      Real *src = src_ + row * row_size;
      // Sequential reduction within a thread.
      for (unsigned col = hipThreadIdx_x; col < row_size; col += hipBlockDim_x) {
        Real val = src[col];
        sum = THCNumerics<Real>::add(sum, val);
        sum2 = THCNumerics<Real>::add(sum2, THCNumerics<Real>::mul(val, val));
      }
    }
    ssum[hipThreadIdx_y][hipThreadIdx_x] = sum;
    ssum2[hipThreadIdx_y][hipThreadIdx_x] = sum2;
    __syncthreads();

    // Reduce intermediate values to single value.
    for (unsigned s = 8; s > 1; s >>= 1) {
      if (row < num_rows && hipThreadIdx_x < s) {
        ssum[hipThreadIdx_y][hipThreadIdx_x] =
          THCNumerics<Real>::add(ssum[hipThreadIdx_y][hipThreadIdx_x], ssum[hipThreadIdx_y][hipThreadIdx_x + s]);
        ssum2[hipThreadIdx_y][hipThreadIdx_x] =
          THCNumerics<Real>::add(ssum2[hipThreadIdx_y][hipThreadIdx_x], ssum2[hipThreadIdx_y][hipThreadIdx_x + s]);
      }
      __syncthreads();
    }

    if (row < num_rows && hipThreadIdx_x == 0) {
      sum = THCNumerics<Real>::add(ssum[hipThreadIdx_y][0], ssum[hipThreadIdx_y][1]);
      sum2 = THCNumerics<Real>::add(ssum2[hipThreadIdx_y][0], ssum2[hipThreadIdx_y][1]);
      tgt[row] = THCTensor_computeVar<Real, flag, apply_sqrt>(sum, sum2, row_size);
    }
    __syncthreads();
  }
}

template<typename TensorTypeK, typename Real, bool apply_sqrt>
__host__ void THCTensor_varInnermostDim(THCState *state, TensorTypeK *tgt, TensorTypeK *src, int flag)
{
  unsigned ndim = TensorUtils<TensorTypeK>::getDims(state, src);
  // Treat all outer dimensions as a single dimension.
  unsigned num_rows = 1;
  for (unsigned dim = 0; dim < ndim - 1; dim++) {
    num_rows *= TensorUtils<TensorTypeK>::getSize(state, src, dim);
  }
  unsigned row_size = TensorUtils<TensorTypeK>::getSize(state, src, ndim - 1);

  // From limited testing, 16x32 seemed a good compromise for handling both long and short dimensions.
  dim3 threads(16, 32);
  dim3 grid(min(1024, THCCeilDiv(num_rows, threads.y)));

  if (flag) {
    hipLaunchKernelGGL((THCTensor_kernel_varInnermostDim<Real, true, apply_sqrt>), grid, threads, 0, THCState_getCurrentStream(state),
        TensorUtils<TensorTypeK>::getData(state, tgt), TensorUtils<TensorTypeK>::getData(state, src), num_rows, row_size);
  } else {
    hipLaunchKernelGGL((THCTensor_kernel_varInnermostDim<Real, false, apply_sqrt>), grid, threads, 0, THCState_getCurrentStream(state),
        TensorUtils<TensorTypeK>::getData(state, tgt), TensorUtils<TensorTypeK>::getData(state, src), num_rows, row_size);
  }
  hipError_t errcode = hipGetLastError();
  if (errcode != hipSuccess) {
    THError(hipGetErrorString(errcode));
  }
}


/* A set of reduction kernels that take in binary ops on thrust pairs (of value, index).
   These are useful when you not only have to do a reduction, but you might have
   to preserve the location of contention (for example min/max operations).
   The structure of the kernels follows the structure of the reduction kernels.
*/
template <typename K, typename Index, class BinaryFunction>
__global__ void
kernelTransformReduceOuterDimIndex(K *tgt1,
                                   Index *tgt2,
                                   K *src_,
                                   unsigned num_orows,
                                   unsigned num_irows,
                                   unsigned row_size,
                                   #if defined(THRUST_PATH)
                                     thrust::pair<K, Index> init,
                                   #else
                                     bolt::amp::pair<K, Index> init,
                                   #endif
                                   BinaryFunction binary_op) {
  for (unsigned orow = hipBlockIdx_x; orow < num_orows; orow += hipGridDim_x) {
    for (unsigned irow = hipBlockIdx_y * hipBlockDim_x + hipThreadIdx_x;
         irow < num_irows;
         irow += hipGridDim_y * hipBlockDim_x) {
      K *src = src_ + orow * row_size * num_irows + irow;
      #if defined(THRUST_PATH)
        thrust::pair<K, Index> acc = init;
      #else
        bolt::amp::pair<K, Index> acc = init;
      #endif

      for (unsigned col = 0; col < row_size; ++col) {
        // +1 for Lua index
        #if defined(THRUST_PATH)
          acc = binary_op(thrust::make_pair<K, Index>(*src, col + TH_INDEX_BASE),
                            acc);
        #else
          acc = binary_op(bolt::amp::make_pair(*src, col + TH_INDEX_BASE), acc);
        #endif
        src += num_irows;
      }

      tgt1[orow * num_irows + irow] = acc.first;
      tgt2[orow * num_irows + irow] = acc.second;
    }
  }
}

template <typename TensorTypeK,
          typename TensorTypeIndex,
          typename BinaryFunction>
__host__ void
THC_transformReduceOuterDimIndex(THCState *state,
                                 TensorTypeK *tgt1,
                                 TensorTypeIndex *tgt2,
                                 TensorTypeK *src,
                                 long rdim,
    #if defined(THRUST_PATH)
        const thrust::pair<typename TensorUtils<TensorTypeK>::DataType,
                                                         typename TensorUtils<TensorTypeIndex>::DataType>& init,
    #else
        const bolt::amp::pair<
            typename TensorUtils<TensorTypeK>::DataType,
            typename TensorUtils<TensorTypeIndex>::DataType>& init,
    #endif
                                 BinaryFunction binary_op) {
  unsigned ndim = TensorUtils<TensorTypeK>::getDims(state, src);
  unsigned num_orows = 1;
  for (long dim = 0; dim < rdim; dim++) {
    num_orows *= TensorUtils<TensorTypeK>::getSize(state, src, dim);
  }
  unsigned row_size = TensorUtils<TensorTypeK>::getSize(state, src, rdim);
  unsigned num_irows = 1;
  for (unsigned dim = rdim + 1; dim < ndim; dim++) {
    num_irows *= TensorUtils<TensorTypeK>::getSize(state, src, dim);
  }

  dim3 threads(min(512, num_irows));
  unsigned maxGridDim = 1024;
  dim3 grid(min(maxGridDim, num_orows),
            min(maxGridDim, THCCeilDiv(num_irows, threads.x)));

  hipLaunchKernelGGL(kernelTransformReduceOuterDimIndex,
      grid, threads, 0, THCState_getCurrentStream(state),
      TensorUtils<TensorTypeK>::getData(state, tgt1),
      TensorUtils<TensorTypeIndex>::getData(state, tgt2),
      TensorUtils<TensorTypeK>::getData(state, src),
      num_orows, num_irows, row_size, init, binary_op);

  THCudaCheck(hipGetLastError());
}

/* Reduce the innermost dimension of a tensor (on thrust::pair functors which are (value, index))
 *
 * For an n-d tensor (n <= 4) where the reduction is along the innermost dimension:
 *
 * - block.x is the innermost dimension, i.e. dimension 0;
 * - block.y and grid.y make up dimension 1; and
 * - grid.x and grid z are the remaining two outer dimensions (if any)
 *
 * Reduction along other dimensions is handled in a separate kernel.
 */
template <typename K, typename Index, class BinaryFunction>
__global__ void
kernelTransformReduceInnermostDimIndex(K *tgt1,
                                       Index* tgt2,
                                       K *src_,
                                       unsigned num_rows,
                                       unsigned row_size,
    #if defined(THRUST_PATH)
      thrust::pair<K, Index> init,
    #else
      bolt::amp::pair<K, Index> init,
    #endif
                                       BinaryFunction binary_op) {
  __shared__ K sbuf[32][16 + 1]; // avoid bank conflict
  __shared__ Index ibuf[32][16 + 1]; // avoid bank conflict

  for (unsigned block_row = hipBlockIdx_x * hipBlockDim_y;
       block_row < num_rows;
       block_row += hipBlockDim_y * hipGridDim_x) {
    unsigned row = block_row + hipThreadIdx_y;
#if defined(THRUST_PATH)
    thrust::pair<K, Index> acc = init;
#else
    bolt::amp::pair<K, Index> acc = init;
#endif
    if (row < num_rows) {
      K *src = src_ + row * row_size;
      // Sequential reduction within a thread.
      for (unsigned col = hipThreadIdx_x; col < row_size; col += hipBlockDim_x) {
#if defined(THRUST_PATH)
        acc = binary_op(thrust::make_pair<K, Index>(src[col], col + TH_INDEX_BASE), acc);
#else
        acc = binary_op(bolt::amp::make_pair(src[col], col + TH_INDEX_BASE), acc);
#endif
      }
    }

    sbuf[hipThreadIdx_y][hipThreadIdx_x] = acc.first;
    ibuf[hipThreadIdx_y][hipThreadIdx_x] = acc.second;

    __syncthreads();

    // Reduce intermediate values to single value.
    K* sline = &sbuf[hipThreadIdx_y][0];
    Index* iline = &ibuf[hipThreadIdx_y][0];
    for (unsigned s = 8; s > 0; s >>= 1) {
      if (row < num_rows && hipThreadIdx_x < s) {
        #if defined(THRUST_PATH)
          thrust::pair<K, Index> arg1{sline[hipThreadIdx_x], iline[hipThreadIdx_x]};
        thrust::pair<K, Index> arg2{sline[hipThreadIdx_x + s], iline[hipThreadIdx_x + s]};
        thrust::pair<K, Index> res = binary_op(arg1, arg2);
        #else
          bolt::amp::pair<K, Index> arg1{
              sline[hipThreadIdx_x], iline[hipThreadIdx_x]};
          bolt::amp::pair<K, Index> arg2{
              sline[hipThreadIdx_x + s], iline[hipThreadIdx_x + s]};
          bolt::amp::pair<K, Index> res = binary_op(arg1, arg2);
        #endif

        sline[hipThreadIdx_x] = res.first;
        iline[hipThreadIdx_x] = res.second;
      }
      __syncthreads();
    }

    if (row < num_rows && hipThreadIdx_x == 0) {
      tgt1[row] = sline[0];
      tgt2[row] = iline[0];
    }
    __syncthreads();
  }
}

template <typename TensorTypeK,
          typename TensorTypeIndex,
          typename BinaryFunction>
__host__ void
THC_transformReduceInnermostDimIndex(THCState *state,
                                     TensorTypeK *tgt1,
                                     TensorTypeIndex *tgt2,
                                     TensorTypeK *src,
    #if defined(THRUST_PATH)
        const thrust::pair<typename TensorUtils<TensorTypeK>::DataType,
                                                         typename TensorUtils<TensorTypeIndex>::DataType>& init,
    #else
        const bolt::amp::pair<
            typename TensorUtils<TensorTypeK>::DataType,
            typename TensorUtils<TensorTypeIndex>::DataType>& init,
    #endif
                                     BinaryFunction binary_op) {
  unsigned ndim = TensorUtils<TensorTypeK>::getDims(state, src);
  unsigned num_rows = 1;
  for (unsigned dim = 0; dim < ndim - 1; dim++) {
    num_rows *= TensorUtils<TensorTypeK>::getSize(state, src, dim);
  }
  unsigned row_size = TensorUtils<TensorTypeK>::getSize(state, src, ndim - 1);

  dim3 threads(16, 32);
  dim3 grid(min(1024, THCCeilDiv(num_rows, threads.y)));

  hipLaunchKernelGGL(kernelTransformReduceInnermostDimIndex,
      grid, threads, 0, THCState_getCurrentStream(state),
      TensorUtils<TensorTypeK>::getData(state, tgt1),
      TensorUtils<TensorTypeIndex>::getData(state, tgt2),
      TensorUtils<TensorTypeK>::getData(state, src),
      num_rows, row_size, init, binary_op);

  THCudaCheck(hipGetLastError());
}

template <typename TensorTypeK,
          typename TensorTypeIndex,
          typename BinaryFunction>
void
THC_reduceDimIndex(THCState *state,
                   TensorTypeK *tgt1_,
                   TensorTypeIndex *tgt2_,
                   TensorTypeK *src,
                   long dimension,
                   int keepdim,
    #if defined(THRUST_PATH)
        const thrust::pair<typename TensorUtils<TensorTypeK>::DataType,
                                           typename TensorUtils<TensorTypeIndex>::DataType>& init,
    #else
        const bolt::amp::pair<
            typename TensorUtils<TensorTypeK>::DataType,
            typename TensorUtils<TensorTypeIndex>::DataType>& init,
    #endif
                   BinaryFunction binary_op)
{
  THArgCheck(dimension >= 0 &&
             dimension < TensorUtils<TensorTypeK>::getDims(state, src),
             3, "dimension out of range");

  THLongStorage *dim = TensorUtils<TensorTypeK>::newSizeOf(state, src);
  THLongStorage_set(dim, dimension, 1);
  TensorUtils<TensorTypeK>::resize(state, tgt1_, dim, NULL);
  TensorUtils<TensorTypeIndex>::resize(state, tgt2_, dim, NULL);
  THLongStorage_free(dim);

  TensorTypeK *tgt1 = TensorUtils<TensorTypeK>::newContiguous(state, tgt1_);
  TensorTypeIndex *tgt2 = TensorUtils<TensorTypeIndex>::newContiguous(state, tgt2_);
  src = TensorUtils<TensorTypeK>::newContiguous(state, src);

  if (dimension == TensorUtils<TensorTypeK>::getDims(state, src) - 1) {
    THC_transformReduceInnermostDimIndex(state, tgt1, tgt2, src, init, binary_op);
  } else {
    THC_transformReduceOuterDimIndex(state, tgt1, tgt2, src, dimension, init, binary_op);
  }

  TensorUtils<TensorTypeK>::free(state, src);
  TensorUtils<TensorTypeK>::freeCopyTo(state, tgt1, tgt1_);
  TensorUtils<TensorTypeIndex>::freeCopyTo(state, tgt2, tgt2_);
  if (!keepdim) {
    TensorUtils<TensorTypeK>::squeeze1d(state, tgt1_, tgt1_, dimension);
    TensorUtils<TensorTypeIndex>::squeeze1d(state, tgt2_, tgt2_, dimension);
  }
}

template <typename T, typename Index>
struct MaxValuePair {
  __host__ __device__
  #if defined(THRUST_PATH)
    thrust::pair<T, Index> operator()(const thrust::pair<T, Index>& a,
                                    const thrust::pair<T, Index>& b) const
    {
      return THCNumerics<T>::ge(a.first, b.first) ? a : b;
    }
  #else
    bolt::amp::pair<T, Index> operator()(
      const bolt::amp::pair<T, Index>& a,
      const bolt::amp::pair<T, Index>& b) const
    {
      return THCNumerics<T>::ge(a.first, b.first) ? a : b;
    }
  #endif
};

template <typename T, typename Index>
struct MinValuePair {
  __host__ __device__
    #if defined(THRUST_PATH)
      thrust::pair<T, Index> operator()(const thrust::pair<T, Index>& a,
                                        const thrust::pair<T, Index>& b) const
      {
        return THCNumerics<T>::le(a.first, b.first) ? a : b;
      }
    #else
      bolt::amp::pair<T, Index> operator()(
        const bolt::amp::pair<T, Index>& a,
        const bolt::amp::pair<T, Index>& b) const
      {
        return THCNumerics<T>::le(a.first, b.first) ? a : b;
      }
    #endif
};

template <typename T>
struct AddOp {
  __device__ __forceinline__ T operator()(T &lhs, T &rhs) {
    return THCNumerics<T>::add(lhs, rhs);
  }
};

template <typename T>
struct MulOp {
  __device__ __forceinline__ T operator()(T &lhs, T &rhs) {
    return THCNumerics<T>::mul(lhs, rhs);
  }
};

#endif // THC_TENSORMATH_REDUCE_CUH
