/***************************************************************************
*   � 2012,2014 Advanced Micro Devices, Inc. All rights reserved.
*
*   Licensed under the Apache License, Version 2.0 (the "License");
*   you may not use this file except in compliance with the License.
*   You may obtain a copy of the License at
*
*       http://www.apache.org/licenses/LICENSE-2.0
*
*   Unless required by applicable law or agreed to in writing, software
*   distributed under the License is distributed on an "AS IS" BASIS,
*   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
*   See the License for the specific language governing permissions and
*   limitations under the License.

***************************************************************************/

#if !defined( BOLT_AMP_TRANSFORM_SCAN_INL )
#define BOLT_AMP_TRANSFORM_SCAN_INL
#pragma once

#define TRANSFORMSCAN_KERNELWAVES 4
#define TRANSFORMSCAN_WAVESIZE 128
#define TRANSFORMSCAN_TILE_MAX 65535


#include <algorithm>
#include <type_traits>
#include "bolt/amp/bolt.h"
#include "bolt/amp/device_vector.h"
#include "bolt/amp/transform.h"
#include "bolt/amp/iterator/iterator_traits.h"
#include <amp.h>

#include "bolt/amp/iterator/addressof.h"

#ifdef ENABLE_TBB
#include "bolt/btbb/transform.h"
#include "bolt/btbb/scan.h"
#endif
namespace bolt
{
namespace amp
{
namespace detail
{
/*!
*   \internal
*   \addtogroup detail
*   \ingroup scan
*   \{
*/
namespace serial{

template<
    typename InputIterator,
    typename OutputIterator,
    typename UnaryFunction1,
    typename T,
    typename BinaryFunction >
typename std::enable_if< (std::is_same< typename std::iterator_traits< OutputIterator >::iterator_category ,
                                       std::random_access_iterator_tag
                                     >::value), void
                           >::type
transform_scan(
    bolt::amp::control &ctl,
    const InputIterator& first,
    const InputIterator& last,
    const OutputIterator& result,
    const UnaryFunction1& unary_op,
    const T& init,
	const bool& inclusive,
    const BinaryFunction& binary_op)
{

	size_t sz = (last - first);
    if (sz == 0)
           return;

	typedef typename std::iterator_traits<InputIterator>::value_type iType;
    typedef typename std::iterator_traits<OutputIterator>::value_type oType;


	oType  sum, temp;


	if(inclusive)
	{
         *result = static_cast<oType>(unary_op( *first ) ); // assign value
         sum = *result;
    }
    else 
	{
         temp = static_cast<oType>(unary_op( *first ) );
         *result = (oType)init;
         sum = binary_op( *result, temp);  
    }

    for ( unsigned int index= 1; index<sz; index++)
    {
         oType currentValue =  static_cast<oType>(unary_op( *(first + index) ) ); // convertible
         if (inclusive)
         {
             oType r = binary_op( sum, currentValue);
             *(result + index) = r;
             sum = r;
         }
         else // new segment
         {
             *(result + index) = sum;
             sum = binary_op( sum, currentValue);
	  
         }
    }
       
	return;

}



template<
    typename InputIterator,
    typename OutputIterator,
    typename UnaryFunction1,
    typename T,
    typename BinaryFunction >
typename std::enable_if< (std::is_same< typename std::iterator_traits< OutputIterator >::iterator_category ,
                                         bolt::amp::device_vector_tag
                                     >::value), void
                           >::type
transform_scan(
    bolt::amp::control &ctl,
    const InputIterator& first,
    const InputIterator& last,
    const OutputIterator& result,
    const UnaryFunction1& unary_op,
    const T& init,
	const bool& inclusive,
    const BinaryFunction& binary_op)
{
	    typedef typename std::iterator_traits<OutputIterator>::value_type oType;

	    size_t sz = (last - first);
       
        auto mapped_fst_itr = create_mapped_iterator(typename std::iterator_traits<InputIterator>::iterator_category(), 
                                                        ctl, first);
        auto mapped_res_itr = create_mapped_iterator(typename std::iterator_traits<OutputIterator>::iterator_category(), 
                                                        ctl, result);


		oType  sum, temp;


		if(inclusive)
		{
		  *mapped_res_itr = static_cast<oType>(unary_op(*mapped_fst_itr) );
          sum =  *mapped_res_itr; 
        }
        else 
		{
		   temp =  static_cast<oType>( unary_op( *(mapped_fst_itr) ));
		   *mapped_res_itr = static_cast<oType>( init );
		   sum = binary_op( *mapped_res_itr, temp);
        }

        for ( unsigned int index= 1; index<sz; ++index)
        {
          oType currentValue =  static_cast<oType>( unary_op( *(mapped_fst_itr+index) ) ); 
          if (inclusive)
          {
              oType r = binary_op( sum, currentValue);
			  *(mapped_res_itr + index) = r;
              sum = r;
          }
          else // new segment
          {
			  *(mapped_res_itr + index) = sum;
              sum = binary_op( sum, currentValue);
          }
        }

        return ;

}


}//end of namespace serial


#ifdef ENABLE_TBB
namespace btbb
{

template<
    typename InputIterator,
    typename OutputIterator,
    typename UnaryFunction1,
    typename T,
    typename BinaryFunction >
typename std::enable_if< (std::is_same< typename std::iterator_traits< OutputIterator >::iterator_category ,
                                       std::random_access_iterator_tag
                                     >::value), void
                           >::type
transform_scan(
    bolt::amp::control &ctl,
    const InputIterator& first,
    const InputIterator& last,
    const OutputIterator& result,
    const UnaryFunction1& unary_op,
    const T& init,
	const bool& inclusive,
    const BinaryFunction& binary_op)
    {
		bolt::btbb::transform(first, last, result, unary_op);
        int sz = static_cast<int>( std::distance (first, last));
        if (sz == 0)
            return;
		if(inclusive)
			bolt::btbb::inclusive_scan( result, result  + sz,  result, binary_op);
		else
			bolt::btbb::exclusive_scan( result,  result  + sz , result, init, binary_op);
        return;

	}

template<
    typename InputIterator,
    typename OutputIterator,
    typename UnaryFunction1,
    typename T,
    typename BinaryFunction >
typename std::enable_if< (std::is_same< typename std::iterator_traits< OutputIterator >::iterator_category ,
                                       bolt::amp::device_vector_tag
                                     >::value), void
                           >::type
transform_scan(
    bolt::amp::control &ctl,
    const InputIterator& first,
    const InputIterator& last,
    const OutputIterator& result,
    const UnaryFunction1& unary_op,
    const T& init,
	const bool& inclusive,
    const BinaryFunction& binary_op)
    {
		size_t sz = (last - first);

       
        auto mapped_first_itr = create_mapped_iterator(typename std::iterator_traits<InputIterator>::
			                                            iterator_category(), 
                                                        ctl, first);
        auto mapped_result_itr = create_mapped_iterator(typename std::iterator_traits<OutputIterator>::
			                                            iterator_category(), 
                                                        ctl, result);
        bolt::btbb::transform(mapped_first_itr, mapped_first_itr + (int)sz, mapped_result_itr, unary_op);

		if(inclusive)
			bolt::btbb::inclusive_scan( mapped_result_itr, mapped_result_itr  + (int)sz,  mapped_result_itr, binary_op);
		else
			bolt::btbb::exclusive_scan( mapped_result_itr,  mapped_result_itr  + (int)sz , mapped_result_itr, init, binary_op);            
       
        return;

	}

}//end of namespace btbb
#endif


namespace amp{

//  All calls to transform_scan end up here, unless an exception was thrown
//  This is the function that sets up the kernels to compile (once only) and execute
template<
    typename DVInputIterator,
    typename DVOutputIterator,
    typename UnaryFunction1,
    typename T,
    typename BinaryFunction >
typename std::enable_if< std::is_same< typename std::iterator_traits< DVOutputIterator >::iterator_category ,
                                       bolt::amp::device_vector_tag
                                     >::value
                       >::type
transform_scan(
    control &ctl,
    const DVInputIterator& first,
    const DVInputIterator& last,
    const DVOutputIterator& result,
    const UnaryFunction1& unary_op,
    const T& init_T,
	const bool& inclusive,
    const BinaryFunction& binary_op)
{

    concurrency::accelerator_view av = ctl.getAccelerator().default_view;
    /**********************************************************************************
     * Type Names - used in KernelTemplateSpecializer
     *********************************************************************************/
    typedef typename std::iterator_traits< DVInputIterator  >::value_type iType;
    typedef typename std::iterator_traits< DVOutputIterator >::value_type oType;
  
	int exclusive = inclusive ? 0 : 1;

    int numElements = static_cast< int >( std::distance( first, last ) );
    const unsigned int kernel0_WgSize = TRANSFORMSCAN_WAVESIZE*TRANSFORMSCAN_KERNELWAVES;
    const unsigned int kernel1_WgSize = TRANSFORMSCAN_WAVESIZE*TRANSFORMSCAN_KERNELWAVES ;
    const unsigned int kernel2_WgSize = TRANSFORMSCAN_WAVESIZE*TRANSFORMSCAN_KERNELWAVES;

    //  Ceiling function to bump the size of input to the next whole wavefront size
    unsigned int sizeInputBuff = numElements;
    unsigned int modWgSize = (sizeInputBuff & ((kernel0_WgSize*2)-1));
    if( modWgSize )
    {
        sizeInputBuff &= ~modWgSize;
        sizeInputBuff += (kernel0_WgSize*2);
    }
    int numWorkGroupsK0 = static_cast< int >( sizeInputBuff / (kernel0_WgSize*2) );
    //  Ceiling function to bump the size of the sum array to the next whole wavefront size
    unsigned int sizeScanBuff = numWorkGroupsK0;
    modWgSize = (sizeScanBuff & ((kernel0_WgSize*2)-1));
    if( modWgSize )
    {
        sizeScanBuff &= ~modWgSize;
        sizeScanBuff += (kernel0_WgSize*2);
    }

    concurrency::array< oType >  preSumArray( sizeScanBuff, av );
    concurrency::array< oType >  preSumArray1( sizeScanBuff, av );

    /**********************************************************************************
     *  Kernel 0
     *********************************************************************************/

    const unsigned int tile_limit = TRANSFORMSCAN_TILE_MAX;
	const unsigned int max_ext = (tile_limit*kernel0_WgSize);
	unsigned int	   tempBuffsize = (sizeInputBuff/2); 
	unsigned int	   iteration = (tempBuffsize-1)/max_ext; 

    for(unsigned int i=0; i<=iteration; i++)
	{
	    unsigned int extent_sz =  (tempBuffsize > max_ext) ? max_ext : tempBuffsize; 
		concurrency::extent< 1 > inputExtent( extent_sz );
		concurrency::tiled_extent< kernel0_WgSize > tileK0 = inputExtent.tile< kernel0_WgSize >();
		unsigned int index = i*(tile_limit*kernel0_WgSize);
		unsigned int tile_index = i*tile_limit;
		try
		{
		concurrency::parallel_for_each( av, tileK0, //output.extent.tile< kernel0_WgSize >(),
		   [
				first,
				init_T,
				numElements,
				&preSumArray,
				&preSumArray1,
				binary_op,
				exclusive,
				index,
				tile_index,
				kernel0_WgSize,
				unary_op
			] 
			( concurrency::tiled_index< kernel0_WgSize > t_idx ) restrict(amp)
	  {
			unsigned int gloId = t_idx.global[ 0 ];
			unsigned int groId = t_idx.tile[ 0 ];
			unsigned int locId = t_idx.local[ 0 ];
			int wgSize = kernel0_WgSize;

			tile_static oType lds[ TRANSFORMSCAN_WAVESIZE*TRANSFORMSCAN_KERNELWAVES*2 ];

			wgSize *=2;

			oType val;
			int input_offset = (groId*wgSize)+locId+index;
			// load input into shared memory
			if(input_offset < numElements){
			  iType inVal = first[input_offset];
			  val = unary_op(inVal);
			  lds[locId] = val;
			}
			if(input_offset + (wgSize/2) < numElements){
			  iType inVal = first[ input_offset + (wgSize/2)];
			  val = unary_op(inVal);
			  lds[locId+(wgSize/2)] = val;
			}

			// Exclusive case
			if(exclusive && gloId == 0)
			{
				iType start_val = first[0];
				oType val = unary_op(start_val);
				lds[locId] = binary_op(init_T, val);
			}
			unsigned int  offset = 1;
			//  Computes a scan within a workgroup with two data per element

			 for (unsigned int start = wgSize>>1; start > 0; start >>= 1) 
			 {
			   t_idx.barrier.wait();
			   if (locId < start)
			   {
				  unsigned int temp1 = offset*(2*locId+1)-1;
				  unsigned int temp2 = offset*(2*locId+2)-1;
				  oType y = lds[temp2];
				  oType y1 =lds[temp1];
				  lds[temp2] = binary_op(y, y1);
			   }
			   offset *= 2;
			 }
			 t_idx.barrier.wait();
			 if (locId == 0)
			 {
				preSumArray[ groId + tile_index ] = lds[wgSize -1];
				preSumArray1[ groId + tile_index ] = lds[wgSize/2 -1];
			 }
	  } );

		}

		catch(std::exception &e)
		{
			std::cout << "Exception while calling bolt::amp::transform_scan parallel_for_each " ;
			std::cout<< e.what() << std::endl;
			throw std::exception();
		}
		tempBuffsize = tempBuffsize - max_ext;
	}
    //std::cout << "Kernel 0 Done" << std::endl;
 

    /**********************************************************************************
     *  Kernel 1
     *********************************************************************************/

    int workPerThread = static_cast< int >( sizeScanBuff / kernel1_WgSize );
    workPerThread = workPerThread ? workPerThread : 1;

    concurrency::extent< 1 > globalSizeK1( kernel1_WgSize );
    concurrency::tiled_extent< kernel1_WgSize > tileK1 = globalSizeK1.tile< kernel1_WgSize >();
    //std::cout << "Kernel 1 Launching w/" << sizeScanBuff << " threads for " << numWorkGroupsK0 << " elements. " << std::endl;
	try
	{
    concurrency::parallel_for_each( av, tileK1,
        [
            &preSumArray,
            numWorkGroupsK0,
            workPerThread,
            binary_op,
            kernel1_WgSize
        ] ( concurrency::tiled_index< kernel1_WgSize > t_idx ) restrict(amp)
  {
        unsigned int gloId = t_idx.global[ 0 ];
        unsigned int groId = t_idx.tile[ 0 ];
        int locId = t_idx.local[ 0 ];
        int wgSize = kernel1_WgSize;
        int mapId  = gloId * workPerThread;

        tile_static oType lds[ TRANSFORMSCAN_WAVESIZE*TRANSFORMSCAN_KERNELWAVES ];

        // do offset of zero manually
        int offset;
        oType workSum;
        if (mapId < numWorkGroupsK0)
        {
            // accumulate zeroth value manually
            offset = 0;
            workSum = preSumArray[mapId+offset];
            //  Serial accumulation
            for( offset = offset+1; offset < workPerThread; offset += 1 )
            {
                if (mapId+offset<numWorkGroupsK0)
                {
                    oType y = preSumArray[mapId+offset];
                    workSum = binary_op( workSum, y );
                }
            }
        }
        t_idx.barrier.wait();
        oType scanSum = workSum;
        offset = 1;
        // load LDS with register sums
        lds[ locId ] = workSum;

        // scan in lds
        for( offset = offset*1; offset < wgSize; offset *= 2 )
        {
            t_idx.barrier.wait();
            if (mapId < numWorkGroupsK0)
            {
                if (locId >= offset)
                {
                    oType y = lds[ locId - offset ];
                    scanSum = binary_op( scanSum, y );
                }

            }
            t_idx.barrier.wait();
            lds[ locId ] = scanSum;
        } // for offset
        t_idx.barrier.wait();
		workSum = preSumArray[mapId];
		if(locId > 0){
			oType y = lds[locId-1];
			workSum = binary_op(workSum, y);
			preSumArray[ mapId] = workSum;
		 }
		 else{
		   preSumArray[ mapId] = workSum;
		}
        // write final scan from pre-scan and lds scan
        for( offset = 1; offset < workPerThread; offset += 1 )
        {

		     t_idx.barrier.wait_with_global_memory_fence();
             if (mapId+offset < numWorkGroupsK0 && locId > 0)
             {
                iType y  = preSumArray[ mapId + offset ] ;
                iType y1 = binary_op(y, workSum);
                preSumArray[ mapId + offset ] = y1;
                workSum = y1;

             } // thread in bounds
             else if(mapId+offset < numWorkGroupsK0 ){
               iType y  = preSumArray[ mapId + offset ] ;
               preSumArray[ mapId + offset ] = binary_op(y, workSum);
               workSum = preSumArray[ mapId + offset ];
            }
        } // for

    } );
	}

	catch(std::exception &e)
    {
        std::cout << "Exception while calling bolt::amp::transform_scan parallel_for_each " ;
        std::cout<< e.what() << std::endl;
        throw std::exception();
    }

    //std::cout << "Kernel 1 Done" << std::endl;
   


    /**********************************************************************************
     *  Kernel 2
     *********************************************************************************/
	tempBuffsize = (sizeInputBuff); 
	iteration = (tempBuffsize-1)/max_ext; 

    for(unsigned int a=0; a<=iteration ; a++)
	{
	    unsigned int extent_sz =  (tempBuffsize > max_ext) ? max_ext : tempBuffsize; 
		concurrency::extent< 1 > inputExtent( extent_sz );
		concurrency::tiled_extent< kernel2_WgSize > tileK2 = inputExtent.tile< kernel2_WgSize >();
		unsigned int index = a*(tile_limit*kernel2_WgSize);
		unsigned int tile_index = a*tile_limit;
		try
		{
		concurrency::parallel_for_each( av, tileK2,
			[
				first,
				result,
				&preSumArray,
				&preSumArray1,
				numElements,
				binary_op,
				init_T,
				exclusive,
				index,
				tile_index,
				unary_op,
				kernel2_WgSize
			] ( concurrency::tiled_index< kernel2_WgSize > t_idx ) restrict(amp)
	  {
			int gloId = t_idx.global[ 0 ] + index;
			unsigned int groId = t_idx.tile[ 0 ] + tile_index;
			int locId = t_idx.local[ 0 ];
			int wgSize = kernel2_WgSize;

			tile_static oType lds[ TRANSFORMSCAN_WAVESIZE*TRANSFORMSCAN_KERNELWAVES ];
			// if exclusive, load gloId=0 w/ identity, and all others shifted-1
			iType val;
			oType oval;
  
			if (gloId < numElements){
			   if (exclusive)
			   {
				  if (gloId > 0)
				  { // thread>0
					  val = first[gloId-1];
					  oval = unary_op(val);
					  lds[ locId ] = oval;
				  }
				  else
				  { // thread=0
					  oval = init_T;
					  lds[ locId ] = oval;
				  }
			   }
			   else
			   {
				  val = first[gloId];
				  oval = unary_op(val);
				  lds[ locId ] = oval;
			   }
			}
  
			oType scanResult = lds[locId];
			oType postBlockSum, newResult;
			// accumulate prefix
			oType y, y1, sum;
			if(locId == 0 && gloId < numElements)
			{
				if(groId > 0) {
					if(groId % 2 == 0)
					   postBlockSum = preSumArray[ groId/2 -1 ];
					else if(groId == 1)
					   postBlockSum = preSumArray1[0];
					else {
					   y = preSumArray[ groId/2 -1 ];
					   y1 = preSumArray1[groId/2];
					   postBlockSum = binary_op(y, y1);
					}
					if (!exclusive)
					   newResult = binary_op( scanResult, postBlockSum );
					else 
					   newResult =  postBlockSum;
				}
				else {
				   newResult = scanResult;
				}
				lds[ locId ] = newResult;
			} 
			//  Computes a scan within a workgroup
			sum = lds[ locId ];
        
			for( int offset = 1; offset < wgSize; offset *= 2 )
			{
				t_idx.barrier.wait();
				if (locId >= offset)
				{
					oType y = lds[ locId - offset ];
					sum = binary_op( sum, y );
				}
				t_idx.barrier.wait();
				lds[ locId ] = sum;
			}
			 t_idx.barrier.wait();
		//  Abort threads that are passed the end of the input vector
			if (gloId >= numElements) return; 

			result[ gloId ] = sum;

		} );
		}

		catch(std::exception &e)
		{
			std::cout << "Exception while calling bolt::amp::transform_scan parallel_for_each " ;
			std::cout<< e.what() << std::endl;
			throw std::exception();
		}
	    tempBuffsize = tempBuffsize - max_ext;
	}
    //std::cout << "Kernel 2 Done" << std::endl;

}   //end of transform_scan_enqueue( )


    template
	<
    typename InputIterator,
    typename OutputIterator,
    typename UnaryFunction1,
    typename T,
    typename BinaryFunction 
    >
    typename std::enable_if< std::is_same< typename std::iterator_traits< OutputIterator >::iterator_category ,
                                       std::random_access_iterator_tag
                                     >::value
                       >::type
    transform_scan(
    control &ctl,
    const InputIterator& first,
    const InputIterator& last,
    const OutputIterator& result,
    const UnaryFunction1& unary_op,
    const T& init,
    const bool& inclusive,
    const BinaryFunction& binary_op)
    {
 
	    typedef typename std::iterator_traits< InputIterator >::value_type iType;
        typedef typename std::iterator_traits< OutputIterator >::value_type oType;
	    
	    
        int sz = static_cast< int >( std::distance( first, last ) );
       
		// Map the output iterator to a device_vector
        device_vector< oType, concurrency::array_view > dvOutput( result, sz, true, ctl );

		// Map the input iterator to a device_vector
		// Use host pointers memory since these arrays are only read once - no benefit to copying.
        // Map the input iterator to a device_vector
		auto dvInput_itr  = bolt::amp::create_mapped_iterator(typename bolt::amp::iterator_traits< InputIterator >::iterator_category( ), first, sz, false, ctl );
		amp::transform_scan( ctl, dvInput_itr, dvInput_itr+sz, dvOutput.begin(), unary_op, init, inclusive, binary_op  );
       
        // This should immediately map/unmap the buffer
        dvOutput.data( );
	    
        return ;
     }

}//end of amp namespace


    
    template
	<
    typename InputIterator,
    typename OutputIterator,
    typename UnaryFunction1,
    typename T,
    typename BinaryFunction 
    >
    typename std::enable_if< 
               !(std::is_same< typename std::iterator_traits< OutputIterator>::iterator_category, 
                             std::input_iterator_tag 
                           >::value ||
               std::is_same< typename std::iterator_traits< OutputIterator>::iterator_category, 
                             bolt::amp::fancy_iterator_tag >::value ),
               OutputIterator
                           >::type
    transform_scan(
    control &ctl,
    const InputIterator& first,
    const InputIterator& last,
    const OutputIterator& result,
    const UnaryFunction1& unary_op,
    const T& init,
    const bool& inclusive,
    const BinaryFunction& binary_op)
    {


	    typedef typename std::iterator_traits< InputIterator >::value_type iType;
        typedef typename std::iterator_traits< OutputIterator >::value_type oType;


        unsigned int numElements = static_cast< unsigned int >( std::distance( first, last ) );
        if( numElements == 0 )
            return result;

        bolt::amp::control::e_RunMode runMode = ctl.getForceRunMode( );

        if( runMode == bolt::amp::control::Automatic )
        {
            runMode = ctl.getDefaultPathToRun();
        }
        if( runMode == bolt::amp::control::SerialCpu )
        {
	    	serial::transform_scan(ctl, first, last, result, unary_op, init, inclusive, binary_op );
            return result + numElements;
        }
        else if( runMode == bolt::amp::control::MultiCoreCpu )
        {
            #ifdef ENABLE_TBB
	    		 btbb::transform_scan(ctl, first, last, result, unary_op, init, inclusive, binary_op );
            #else
                 throw std::runtime_error("The MultiCoreCpu version of Transform_scan is not enabled to be built! \n");
            #endif
	    
            return result + numElements;
	    
        }
        else
		{
	    	amp::transform_scan(ctl, first, last, result, unary_op, init, inclusive, binary_op);
        }
            return result + numElements;
    };



    template
	<
    typename InputIterator,
    typename OutputIterator,
    typename UnaryFunction1,
    typename T,
    typename BinaryFunction 
	>
    typename std::enable_if< 
               (std::is_same< typename std::iterator_traits< OutputIterator>::iterator_category, 
                             std::input_iterator_tag 
                           >::value ||
               std::is_same< typename std::iterator_traits< OutputIterator>::iterator_category, 
                             bolt::amp::fancy_iterator_tag >::value ),
               OutputIterator
                           >::type
    transform_scan(
    bolt::amp::control& ctl,
    const InputIterator& first,
    const InputIterator& last,
    const OutputIterator& result,
    const UnaryFunction1& unary_op,
    const T& init,
    const bool& inclusive,
    const BinaryFunction& binary_op)
    {
       //  TODO:  It should be possible to support non-random_access_iterator_tag iterators, if we copied the data
       //  to a temporary buffer.  Should we?
	    static_assert( std::is_same< typename std::iterator_traits< OutputIterator>::iterator_category, 
                                     std::input_iterator_tag >::value , 
                       "Output vector should be a mutable vector. It cannot be of the type input_iterator_tag" );
        static_assert( std::is_same< typename std::iterator_traits< OutputIterator>::iterator_category, 
                                     bolt::amp::fancy_iterator_tag >::value , 
                       "Output vector should be a mutable vector. It cannot be of type fancy_iterator_tag" );

    };

    /*!   \}  */
} //namespace detail


    //////////////////////////////////////////
    //  Transform Inclusive scan overloads
    //////////////////////////////////////////
    template<
        typename InputIterator,
        typename OutputIterator,
        typename UnaryFunction1,
        typename BinaryFunction>
    OutputIterator
    transform_inclusive_scan(
        InputIterator first,
        InputIterator last,
        OutputIterator result,
        UnaryFunction1 unary_op,
        BinaryFunction binary_op)
    {
        using bolt::amp::transform_inclusive_scan;
        return transform_inclusive_scan(
            control::getDefault( ),
            first,
            last,
            result,
            unary_op,
            binary_op
           );
    }

    template<
        typename InputIterator,
        typename OutputIterator,
        typename UnaryFunction1,
        typename BinaryFunction>
    OutputIterator
    transform_inclusive_scan(
        bolt::amp::control &ctl,
        InputIterator first,
        InputIterator last,
        OutputIterator result,
        UnaryFunction1 unary_op,
        BinaryFunction binary_op)
    {
        typedef typename std::iterator_traits<OutputIterator>::value_type oType;
        oType init; memset(&init, 0, sizeof(oType) );
		using bolt::amp::detail::transform_scan;
        return detail::transform_scan(
            ctl,
            first,
            last,
            result,
            unary_op,
            init,
            true, // inclusive
            binary_op);
    }

    //////////////////////////////////////////
    //   Transform Exclusive scan overloads
    //////////////////////////////////////////
    template<
        typename InputIterator,
        typename OutputIterator,
        typename UnaryFunction1,
        typename T,
        typename BinaryFunction>
    OutputIterator
    transform_exclusive_scan(
        InputIterator first,
        InputIterator last,
        OutputIterator result,
        UnaryFunction1 unary_op,
        T init,
        BinaryFunction binary_op )
    {
        using bolt::amp::transform_exclusive_scan;

        return transform_exclusive_scan(
            bolt::amp::control::getDefault( ),
            first,
            last,
            result,
            unary_op,
            init,
            binary_op);
    }

    template<
        typename InputIterator,
        typename OutputIterator,
        typename UnaryFunction1,
        typename T,
        typename BinaryFunction>
    OutputIterator
    transform_exclusive_scan(
        bolt::amp::control &ctl,
        InputIterator first,
        InputIterator last,
        OutputIterator result,
        UnaryFunction1 unary_op,
        T init,
        BinaryFunction binary_op)
    {
         using bolt::amp::detail::transform_scan;

         return detail::transform_scan(
            ctl,
            first,
            last,
            result,
            unary_op,
            init,
            false, // exclusive
            binary_op);
    }

////////////////////////////////////////////////////////////////////////////////////////////////

} //namespace amp
} //namespace bolt

#endif
