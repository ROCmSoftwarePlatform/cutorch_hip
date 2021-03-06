/***************************************************************************
*     2012,2014 Advanced Micro Devices, Inc. All rights reserved.
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
#pragma once
#if !defined( BOLT_AMP_TRANSFORM_ITERATOR_H )
#define BOLT_AMP_TRANSFORM_ITERATOR_H
#include "bolt/amp/bolt.h"
#include "bolt/amp/iterator/iterator_traits.h"
#include "bolt/amp/iterator/counting_iterator.h"
#include "bolt/amp/device_vector.h"

/*! \file bolt/amp/iterator/transform_iterator.h
    \brief
*/

/*! \addtogroup fancy_iterators
       */

      /*! \addtogroup AMP-TransformIterator
      *   \ingroup fancy_iterators
      *   \{
      */

      /*! transform iterator adapts an iterator by modifying the operator* to apply a function object to the
       *                     result of dereferencing the iterator and returning the result..
       *
       *
       *
       *  \details The following example demonstrates how to use a \p transform_iterator.
       *
       *  \code
       *  #include <bolt/amp/iterator/transform_iterator.h>
       *  #include <bolt/amp/transform.h>
       *  #include <bolt/amp/functional.h>
       *  //In AMP, Transform Iterator works only with device_vectors.
       *  //The example here uses device_vector iterators.
       *
       *    struct UDD
       *    {
       *        int i;
       *        float f;
       *
       *	    UDD operator = (const int rhs)
       *        {
       *            UDD _result;
       *            _result.i = i + rhs;
       *            _result.f = f + (float)rhs;
       *            return _result;
       *        }
       *
       *	    UDD operator + (const UDD &rhs) const
       *        {
       *            UDD _result;
       *            _result.i = this->i + rhs.i;
       *            _result.f = this->f + rhs.f;
       *            return _result;
       *        }
       *        UDD()
       *            : i(0), f(0) { }
       *        UDD(int _in)
       *            : i(_in), f((float)(_in+2) ){ }
       *     };
       *
       *
       *      struct UDDadd_3
       *      {
       *          UDD operator() (const UDD &x) const
       *  		  {
       *  			UDD temp;
       *  			temp.i = x.i + 3;
       *  			temp.f = x.f + 3.0f;
       *  			return temp;
       *  		  }
       *          typedef UDD result_type;
       *          //Note that the result_type needs to be defined and should be type-defined to the
       *          //return type of operator () overload.
       *      };
       *
       *
       *
       *
       *  int main() {
       *    // Create device_vectors
       *    bolt::amp::device_vector< UDD > dvInVec1( 5 );
       *    bolt::amp::device_vector< UDD > dvInVec2( 5 );
       *    bolt::amp::device_vector< UDD > dvDestVec( 5, 0 );
       *    UDDadd_3 add3;
       *
       *    typedef bolt::amp::transform_iterator< UDDadd_3, bolt::amp::device_vector< UDD >::iterator> dv_trf_itr_add3;
       *    dv_trf_itr_add3 dv_trf_begin (dvInVec1.begin(), add3), dv_trf_end (dvInVec1.end(), add3);
       *    // Fill values
       *    dvInVec1[ 0 ] = 10 ; dvInVec1[ 1 ] = 15 ; dvInVec1[ 2 ] = 20 ;
       *    dvInVec1[ 3 ] = 25 ; dvInVec1[ 4 ] = 30 ;
       *    dvInVec2[ 0 ] = 10 ; dvInVec2[ 1 ] = 15 ; dvInVec2[ 2 ] = 20 ;
       *    dvInVec2[ 3 ] = 25 ; dvInVec2[ 4 ] = 30 ;
       *
       *    ...
       *    bolt::amp::transform(dv_trf_begin,
       *                        dv_trf_end,
       *                        dvInVec2.begin( ),
       *                        dvDestVec.begin( ),
       *                        bolt::amp::plus< int >( ) );
       *
       *  }
       *  \endcode
       */

namespace bolt {
namespace amp {

  struct transform_iterator_tag
      : public fancy_iterator_tag
      {   // identifying tag for random-access iterators
      };

      template< class UnaryFunc, class Iterator >
      class transform_iterator: public std::iterator< transform_iterator_tag,
                                                      std::result_of<UnaryFunc()>,
                                                      int >
      {

        typedef transform_iterator<UnaryFunc,Iterator>				transf_iterator;

        public:
         typedef typename std::iterator< transform_iterator_tag, typename std::result_of<UnaryFunc()>, int>::difference_type
         difference_type;

         typedef UnaryFunc                                          unary_func;
         typedef typename UnaryFunc::result_type					value_type;
         typedef typename std::iterator_traits<Iterator>::pointer   pointer;

        // Default constructor
        transform_iterator( ):m_Index( 0 ) {}

        ~transform_iterator( ) {}

        //  Basic constructor requires a reference to the container and a positional element
        transform_iterator( Iterator iiter, UnaryFunc ifunc, const control& ctl = control::getDefault( ) ) : iter(iiter), func(ifunc), m_Index(iiter.m_Index) {}

        //  This copy constructor allows an iterator to convert into a transf_iterator, but not vica versa
        template< class OtherUnaryFunc, class OtherIter>
        transform_iterator( const transform_iterator< OtherUnaryFunc, OtherIter >& rhs ) :m_Index( rhs.m_Index ){}

        //  This copy constructor allows an iterator to convert into a transf_iterator, but not vica versa
        transform_iterator< UnaryFunc, Iterator >& operator= ( const transform_iterator< UnaryFunc, Iterator >& rhs )
        {
            if( this == &rhs )
                return *this;

            func = rhs.func;
            iter = rhs.iter;

            m_Index = rhs.m_Index;
            return *this;
        }

        transform_iterator< UnaryFunc, Iterator >& operator+= ( const  difference_type & n )
        {
            advance( n );
            return *this;
        }

        const transform_iterator< UnaryFunc, Iterator > operator+ ( const difference_type & n ) const
        {
            transform_iterator< UnaryFunc, Iterator > result( *this );
            result.advance( n );
            return result;
        }


        const transform_iterator< UnaryFunc, Iterator > operator- ( const difference_type & n ) const
        {
            transform_iterator< UnaryFunc, Iterator > result( *this );
            result.advance( -n );
            return result;

        }


//        const concurrency::array_view<int> & getBuffer( transf_iterator itr ) const
//        {
//            return *value;
//        }
        UnaryFunc functor() const
        { return func; }

        Iterator getContainer( ) const
        {

             return iter;
        }

        difference_type operator- ( const transform_iterator< UnaryFunc, Iterator >& rhs ) const
        {
            return m_Index - rhs.m_Index;
        }

        //  Public member variables
        difference_type m_Index;

        //  Used for templatized copy constructor and the templatized equal operator
        template < typename, typename > friend class transform_iterator;

        //  For a transform_iterator, do nothing on an advance
        void advance( difference_type n )
        {
            m_Index += n;
        }

        // Pre-increment
        transform_iterator< UnaryFunc, Iterator > operator++ ( )
        {
            advance( 1 );
            transform_iterator< UnaryFunc, Iterator > result( *this );
            return result;
        }

        // Post-increment
        transform_iterator< UnaryFunc, Iterator > operator++ ( int )
        {
            transform_iterator< UnaryFunc, Iterator > result( *this );
            advance( 1 );
            return result;
        }

        // Pre-decrement
        transform_iterator< UnaryFunc, Iterator > operator--( ) const
        {
            transform_iterator< UnaryFunc, Iterator > result( *this );
            result.advance( -1 );
            return result;
        }

        // Post-decrement
        transform_iterator< UnaryFunc, Iterator > operator--( int ) const
        {
            transform_iterator< UnaryFunc, Iterator > result( *this );
            result.advance( -1 );
            return result;
        }

        difference_type getIndex() const
        {
            return m_Index;
        }

        value_type* getPointer()
        {
            Iterator base_iterator = this->base_reference();
            return &(*base_iterator);
        }

        const value_type* getPointer() const
        {
            Iterator base_iterator = this->base_reference();
            return &(*base_iterator);
        }


        template< class OtherUnaryFunc, class OtherIterator >
        bool operator== ( const transform_iterator< OtherUnaryFunc, OtherIterator >& rhs ) const
        {
            bool sameIndex = ( rhs.m_Index == m_Index );
            return sameIndex;
        }

        template< class OtherUnaryFunc, class OtherIterator >
        bool operator!= ( const transform_iterator< OtherUnaryFunc, OtherIterator >& rhs ) const
        {
            bool sameIndex = ( rhs.m_Index != m_Index );
            return sameIndex;
        }

        template< class OtherUnaryFunc, class OtherIterator >
        bool operator< ( const transform_iterator< OtherUnaryFunc, OtherIterator >& rhs ) const
        {
            bool sameIndex = (m_Index < rhs.m_Index);
            return sameIndex;
        }

        // Dereference operators
        value_type operator*() const
        {
          return func( iter[ m_Index ] );
        }

        value_type operator[](int x) const restrict(cpu,amp)
        {
          return func( iter[ x ] );
        }

        value_type operator[](int x) restrict(cpu,amp)
        {
          return func( iter[ x ] );
        }

        UnaryFunc func;
        Iterator iter;
        //value_type val_at;

      };


  template< class UnaryFunc, class Iterator >
  static
  inline
  transform_iterator< UnaryFunc, Iterator > make_transform_iterator( Iterator iter, UnaryFunc func )
  {
      transform_iterator< UnaryFunc, Iterator > tmp( iter, func );
      return tmp;
  }

}
}


#endif
