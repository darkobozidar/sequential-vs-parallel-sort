#include <stdio.h>

#include <cuda.h>
#include "cuda_runtime.h"
#include "device_launch_parameters.h"

#include "data_types.h"
#include "constants.h"


/*
Compares 2 elements and exchanges them according to orderAsc.
*/
__device__ void compareExchange(el_t *elem1, el_t *elem2, bool orderAsc) {
    if ((elem1->key <= elem2->key) ^ orderAsc) {
        el_t temp = *elem1;
        *elem1 = *elem2;
        *elem2 = temp;
    }
}

/*
Sorts sub-blocks of input data with bitonic sort.
*/
__global__ void bitonicSortKernel(el_t *table, bool orderAsc) {
    extern __shared__ el_t sortTile[];
    // If shared memory size is lower than table length, than every block has to be ordered
    // in opposite direction -> bitonic sequence.
    bool blockDirection = orderAsc ^ (blockIdx.x & 1);

    // Every thread loads 2 elements
    uint_t index = blockIdx.x * 2 * blockDim.x + threadIdx.x;
    sortTile[threadIdx.x] = table[index];
    sortTile[blockDim.x + threadIdx.x] = table[blockDim.x + index];

    // Bitonic sort of shared memory
    for (uint_t subBlockSize = 1; subBlockSize <= blockDim.x; subBlockSize <<= 1) {
        bool direction = blockDirection ^ ((threadIdx.x & subBlockSize) != 0);

        for (uint_t stride = subBlockSize; stride > 0; stride >>= 1) {
            __syncthreads();
            uint_t start = 2 * threadIdx.x - (threadIdx.x & (stride - 1));
            compareExchange(&sortTile[start], &sortTile[start + stride], direction);
        }
    }

    __syncthreads();
    table[index] = sortTile[threadIdx.x];
    table[blockDim.x + index] = sortTile[blockDim.x + threadIdx.x];
}

/*
Global bitonic merge for sections, where stride IS GREATER than max shared memory.
*/
__global__ void bitonicMergeGlobalKernel(el_t *table, uint_t phase, uint_t step, bool orderAsc) {
    uint_t stride = 1 << (step - 1);
    uint_t indexThread = blockIdx.x * blockDim.x + threadIdx.x;
    uint_t indexTable = 2 * indexThread - (indexThread & (stride - 1));
    // Elements inside same sub-block have to be ordered in same direction
    bool direction = orderAsc ^ ((indexThread >> (phase - 1)) & 1);

    el_t el1 = table[indexTable];
    el_t el2 = table[indexTable + stride];

    compareExchange(&el1, &el2, direction);

    table[indexTable] = el1;
    table[indexTable + stride] = el2;
}

/*
Global bitonic merge for sections, where stride IS LOWER OR EQUAL than max shared memory.
*/
__global__ void bitonicMergeLocalKernel(el_t *table, uint_t phase, bool orderAsc) {
    extern __shared__ el_t mergeTile[];
    uint_t threadIndex = blockIdx.x * blockDim.x + threadIdx.x;
    uint_t threadsPerSubBlock = 1 << (phase - 1);
    // Elements inside same sub-block have to be ordered in same direction
    bool subBlockDirection = (threadIndex / threadsPerSubBlock) % 2;
    uint_t direction = orderAsc ^ ((threadIdx.x & blockDim.x) != 0) ^ subBlockDirection;

    // Every thread loads 2 elements
    uint_t index = blockIdx.x * 2 * blockDim.x + threadIdx.x;
    mergeTile[threadIdx.x] = table[index];
    mergeTile[blockDim.x + threadIdx.x] = table[blockDim.x + index];

    for (uint_t stride = blockDim.x; stride > 0; stride >>= 1) {
        __syncthreads();
        // In first step of every phase END index has to be reversed
        uint_t start = 2 * threadIdx.x - (threadIdx.x & (stride - 1));
        compareExchange(&mergeTile[start], &mergeTile[start + stride], direction);
    }

    __syncthreads();
    table[index] = mergeTile[threadIdx.x];
    table[blockDim.x + index] = mergeTile[blockDim.x + threadIdx.x];
}