#include "hip/hip_runtime.h"
#include <unittest/unittest.h>
#include <thrust/extrema.h>
#include <thrust/execution_policy.h>


template<typename ExecutionPolicy, typename Iterator, typename Iterator2>
__global__
void max_element_kernel(ExecutionPolicy exec, Iterator first, Iterator last, Iterator2 result)
{
  *result = thrust::max_element(exec, first, last);
}


template<typename ExecutionPolicy, typename Iterator, typename BinaryPredicate, typename Iterator2>
__global__
void max_element_kernel(ExecutionPolicy exec, Iterator first, Iterator last, BinaryPredicate pred, Iterator2 result)
{
  *result = thrust::max_element(exec, first, last, pred);
}


template<typename ExecutionPolicy>
void TestMaxElementDevice(ExecutionPolicy exec)
{
  size_t n = 1000;
  thrust::host_vector<int> h_data = unittest::random_samples<int>(n);
  thrust::device_vector<int> d_data = h_data;

  typedef typename thrust::device_vector<int>::iterator iter_type;

  thrust::device_vector<iter_type> d_result(1);
  
  typename thrust::host_vector<int>::iterator   h_max = thrust::max_element(h_data.begin(), h_data.end());

  hipLaunchKernelGGL(HIP_KERNEL_NAME(max_element_kernel), dim3(1), dim3(1), 0, 0, exec, d_data.begin(), d_data.end(), d_result.begin());
  ASSERT_EQUAL(h_max - h_data.begin(), (iter_type)d_result[0] - d_data.begin());

  
  typename thrust::host_vector<int>::iterator   h_min = thrust::max_element(h_data.begin(), h_data.end(), thrust::greater<int>());

  hipLaunchKernelGGL(HIP_KERNEL_NAME(max_element_kernel), dim3(1), dim3(1), 0, 0, exec, d_data.begin(), d_data.end(), thrust::greater<int>(), d_result.begin());
  ASSERT_EQUAL(h_min - h_data.begin(), (iter_type)d_result[0] - d_data.begin());
}


void TestMaxElementDeviceSeq()
{
  TestMaxElementDevice(thrust::seq);
}
DECLARE_UNITTEST(TestMaxElementDeviceSeq);


void TestMaxElementDeviceDevice()
{
  TestMaxElementDevice(thrust::device);
}
DECLARE_UNITTEST(TestMaxElementDeviceDevice);


void TestMaxElementCudaStreams()
{
  typedef thrust::device_vector<int> Vector;
  typedef Vector::value_type T;

  Vector data(6);
  data[0] = 3;
  data[1] = 5;
  data[2] = 1;
  data[3] = 2;
  data[4] = 5;
  data[5] = 1;

  hipStream_t s;
  hipStreamCreate(&s);

  ASSERT_EQUAL( *thrust::max_element(thrust::cuda::par.on(s), data.begin(), data.end()), 5);
  ASSERT_EQUAL( thrust::max_element(thrust::cuda::par.on(s), data.begin(), data.end()) - data.begin(), 1);
  
  ASSERT_EQUAL( *thrust::max_element(thrust::cuda::par.on(s), data.begin(), data.end(), thrust::greater<T>()), 1);
  ASSERT_EQUAL( thrust::max_element(thrust::cuda::par.on(s), data.begin(), data.end(), thrust::greater<T>()) - data.begin(), 2);

  hipStreamDestroy(s);
}
DECLARE_UNITTEST(TestMaxElementCudaStreams);

void TestMaxElementDevicePointer()
{
  typedef thrust::device_vector<int> Vector;
  typedef Vector::value_type T;

  Vector data(6);
  data[0] = 3;
  data[1] = 5;
  data[2] = 1;
  data[3] = 2;
  data[4] = 5;
  data[5] = 1;

  T* raw_ptr = thrust::raw_pointer_cast(data.data());
  size_t n = data.size();
  ASSERT_EQUAL( thrust::max_element(thrust::device, raw_ptr, raw_ptr+n) - raw_ptr, 1);
  ASSERT_EQUAL( thrust::max_element(thrust::device, raw_ptr, raw_ptr+n, thrust::greater<T>()) - raw_ptr, 2);
}
DECLARE_UNITTEST(TestMaxElementDevicePointer);
