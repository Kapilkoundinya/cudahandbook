/*
 *
 * histogramPrivatizedPerThread4x32.cuh
 *
 * Implementation of histogram that uses 8-bit privatized counters
 * and uses 32-bit increments to process them.
 * This version is the same as histogramPrivatizedPerThread32.cuh,
 * but unrolls the inner loop 4x.  That requires the number of blocks
 * to be adjusted upward, accordingly, to keep the counters from
 * rolling over.
 *
 * Requires: SM 1.2, for shared atomics.
 *
 * Copyright (c) 2013, Archaea Software, LLC.
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions 
 * are met: 
 *
 * 1. Redistributions of source code must retain the above copyright 
 *    notice, this list of conditions and the following disclaimer. 
 * 2. Redistributions in binary form must reproduce the above copyright 
 *    notice, this list of conditions and the following disclaimer in 
 *    the documentation and/or other materials provided with the 
 *    distribution. 
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS 
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT 
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS 
 * FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE 
 * COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, 
 * INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, 
 * BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER 
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT 
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN 
 * ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE 
 * POSSIBILITY OF SUCH DAMAGE.
 *
 */

template<bool bCheckOverflow>
inline __device__ void
incPrivatized32Element4x( unsigned int *pHist, unsigned char pixval )
{
    extern __shared__ unsigned int privHist[];
    const int blockDimx = 64;
    unsigned int increment = 1<<8*(pixval&3);
    int index = pixval>>2;
    unsigned int value = privHist[index*blockDimx+threadIdx.x];
    value += increment;
    if ( bCheckOverflow ) {
        if ( value & 0x80808080 ) {
            atomicAdd( pHist+pixval, 0x80 );
        }
        value &= 0x7f7f7f7f;
    }
    privHist[index*blockDimx+threadIdx.x] = value;
}

__device__ void
finalizeHistograms64( unsigned int *pHist )
{
    extern __shared__ unsigned int privHist[];

    unsigned int sum02 = 0;
    unsigned int sum13 = 0;
    for ( int i = 0; i < 64; i++ ) {
        int index = (i+threadIdx.x)&63;
        unsigned int myValue = privHist[threadIdx.x*64+index];
        sum02 += myValue & 0xff00ff;
        myValue >>= 8;
        sum13 += myValue & 0xff00ff;
        
    }
    atomicAdd( &pHist[threadIdx.x*4+0], sum02&0xffff );
    sum02 >>= 16;
    atomicAdd( &pHist[threadIdx.x*4+2], sum02 );

    atomicAdd( &pHist[threadIdx.x*4+1], sum13&0xffff );
    sum13 >>= 16;
    atomicAdd( &pHist[threadIdx.x*4+3], sum13 );
}

template<bool bCheckOverflow>
__global__ void
histogram1DPrivatizedPerThread4x32(
    unsigned int *pHist,
    const unsigned char *base, size_t N )
{
    extern __shared__ unsigned int privHist[];
    const int blockDimx = 64;

    if ( blockDim.x != blockDimx ) return;
    
    for ( int i = threadIdx.x;
              i < 64*blockDimx;
              i += blockDimx ) {
        privHist[i] = 0;
    }
    __syncthreads();
    for ( int i = blockIdx.x*HISTOGRAM_PRIVATIZED_NUMTHREADS+threadIdx.x;
              i < N/4;
              i += HISTOGRAM_PRIVATIZED_NUMTHREADS*gridDim.x ) {
        unsigned int value = ((unsigned int *) base)[i];
        incPrivatized32Element4x<bCheckOverflow>( pHist, value & 0xff ); value >>= 8;
        incPrivatized32Element4x<bCheckOverflow>( pHist, value & 0xff ); value >>= 8;
        incPrivatized32Element4x<bCheckOverflow>( pHist, value & 0xff ); value >>= 8;
        incPrivatized32Element4x<bCheckOverflow>( pHist, value );
    }
    __syncthreads();

    finalizeHistograms64( pHist );
}

template<bool bCheckOverflow>
void
GPUhistogramPrivatizedPerThread4x32(
    float *ms,
    unsigned int *pHist,
    const unsigned char *dptrBase, size_t dPitch,
    int x, int y,
    int w, int h, 
    dim3 threads )
{
    cudaError_t status;
    cudaEvent_t start = 0, stop = 0;
    int numthreads = threads.x*threads.y;
    int numblocks = bCheckOverflow ? 256 : INTDIVIDE_CEILING( w*h, numthreads*(255/4) );

    CUDART_CHECK( cudaEventCreate( &start, 0 ) );
    CUDART_CHECK( cudaEventCreate( &stop, 0 ) );

    CUDART_CHECK( cudaMemset( pHist, 0, 256*sizeof(unsigned int) ) );

    CUDART_CHECK( cudaEventRecord( start, 0 ) );
    histogram1DPrivatizedPerThread4x32<bCheckOverflow><<<numblocks,numthreads,numthreads*256>>>( pHist, dptrBase, w*h );
    CUDART_CHECK( cudaEventRecord( stop, 0 ) );
    CUDART_CHECK( cudaDeviceSynchronize() );
    CUDART_CHECK( cudaEventElapsedTime( ms, start, stop ) );
Error:
    cudaEventDestroy( start );
    cudaEventDestroy( stop );
    return;
}

void
GPUhistogramPrivatizedPerThread4x32(
    float *ms,
    unsigned int *pHist,
    const unsigned char *dptrBase, size_t dPitch,
    int x, int y,
    int w, int h, 
    dim3 threads )
{
    GPUhistogramPrivatizedPerThread4x32<false>( ms, pHist, dptrBase, dPitch, x, y, w, h, threads );
}

void
GPUhistogramPrivatizedPerThread4x32_CheckOverflow(
    float *ms,
    unsigned int *pHist,
    const unsigned char *dptrBase, size_t dPitch,
    int x, int y,
    int w, int h, 
    dim3 threads )
{
    GPUhistogramPrivatizedPerThread4x32<true>( ms, pHist, dptrBase, dPitch, x, y, w, h, threads );
}
