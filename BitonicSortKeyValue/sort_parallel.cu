#include <stdio.h>
#include <math.h>
#include <Windows.h>

#include <cuda.h>
#include "cuda_runtime.h"
#include "device_launch_parameters.h"

#include "../Utils/data_types_common.h"
#include "../Utils/cuda.h"
#include "../Utils/host.h"
#include "constants.h"
#include "kernels.h"
#include "sort_parallel.h"


/*
Sorts sub-blocks of input data with bitonic sort.
*/
template <order_t sortOrder>
void BitonicSortParallelKeyValue::runBitoicSortKernel(data_t *d_keys, data_t *d_values, uint_t arrayLength)
{
    uint_t elemsPerThreadBlock = THREADS_PER_BITONIC_SORT * ELEMS_PER_THREAD_BITONIC_SORT;
    // "2 *" becaues of key-value pairs
    uint_t sharedMemSize = 2 * elemsPerThreadBlock * sizeof(*d_keys);

    dim3 dimGrid((arrayLength - 1) / elemsPerThreadBlock + 1, 1, 1);
    dim3 dimBlock(THREADS_PER_BITONIC_SORT, 1, 1);

    if (sortOrder == ORDER_ASC)
    {
        bitonicSortKernel<sortOrder><<<dimGrid, dimBlock, sharedMemSize>>>(d_keys, d_values, arrayLength);
    }
}

/*
Merges array, if data blocks are larger than shared memory size. It executes only of STEP on PHASE per
kernel launch.
*/
template <order_t sortOrder>
void BitonicSortParallelKeyValue::runBitonicMergeGlobalKernel(
    data_t *d_keys, data_t *d_values, uint_t arrayLength, uint_t phase, uint_t step
)
{
    uint_t elemsPerThreadBlock = THREADS_PER_GLOBAL_MERGE * ELEMS_PER_THREAD_GLOBAL_MERGE;
    dim3 dimGrid((arrayLength - 1) / elemsPerThreadBlock + 1, 1, 1);
    dim3 dimBlock(THREADS_PER_GLOBAL_MERGE, 1, 1);

    bool isFirstStepOfPhase = phase == step;

    if (isFirstStepOfPhase)
    {
        bitonicMergeGlobalKernel<sortOrder, true><<<dimGrid, dimBlock>>>(d_keys, d_values, arrayLength, step);
    }
    else
    {
        bitonicMergeGlobalKernel<sortOrder, false><<<dimGrid, dimBlock>>>(d_keys, d_values, arrayLength, step);
    }
}

/*
Merges array when stride is lower than shared memory size. It executes all remaining STEPS of current PHASE.
*/
template <order_t sortOrder>
void BitonicSortParallelKeyValue::runBitoicMergeLocalKernel(
    data_t *d_keys, data_t *d_values, uint_t arrayLength, uint_t phase, uint_t step
)
{
    // Every thread loads and sorts 2 elements
    uint_t elemsPerThreadBlock = THREADS_PER_LOCAL_MERGE * ELEMS_PER_THREAD_LOCAL_MERGE;
    uint_t sharedMemSize = 2 * elemsPerThreadBlock * sizeof(*d_keys);  // "2 *" becaues of key-value pairs
    dim3 dimGrid((arrayLength - 1) / elemsPerThreadBlock + 1, 1, 1);
    dim3 dimBlock(THREADS_PER_LOCAL_MERGE, 1, 1);

    bool isFirstStepOfPhase = phase == step;


    if (isFirstStepOfPhase) {
        bitonicMergeLocalKernel<sortOrder, true><<<dimGrid, dimBlock, sharedMemSize>>>(
            d_keys, d_values, arrayLength, step
        );
    }
    else
    {
        bitonicMergeLocalKernel<sortOrder, false><<<dimGrid, dimBlock, sharedMemSize>>>(
            d_keys, d_values, arrayLength, step
        );
    }
}

/*
Sorts data with parallel NORMALIZED BITONIC SORT.
*/
template <order_t sortOrder>
void BitonicSortParallelKeyValue::bitonicSortParallelKeyValue(
    data_t *d_keys, data_t *d_values, uint_t arrayLength
)
{
    uint_t arrayLenPower2 = nextPowerOf2(arrayLength);
    uint_t elemsPerBlockBitonicSort = THREADS_PER_BITONIC_SORT * ELEMS_PER_THREAD_BITONIC_SORT;
    uint_t elemsPerBlockMergeLocal = THREADS_PER_LOCAL_MERGE * ELEMS_PER_THREAD_LOCAL_MERGE;

    // Number of phases, which can be executed in shared memory (stride is lower than shared memory size)
    uint_t phasesBitonicSort = log2((double)min(arrayLenPower2, elemsPerBlockBitonicSort));
    uint_t phasesMergeLocal = log2((double)min(arrayLenPower2, elemsPerBlockMergeLocal));
    uint_t phasesAll = log2((double)arrayLenPower2);

    // Sorts blocks of input data with bitonic sort
    runBitoicSortKernel<sortOrder>(d_keys, d_values, arrayLength);

    // Bitonic merge
    for (uint_t phase = phasesBitonicSort + 1; phase <= phasesAll; phase++)
    {
        uint_t step = phase;
        while (step > phasesMergeLocal)
        {
            runBitonicMergeGlobalKernel<sortOrder>(d_keys, d_values, arrayLength, phase, step);
            step--;
        }

        runBitoicMergeLocalKernel<sortOrder>(d_keys, d_values, arrayLength, phase, step);
    }
}

/*
Wrapper for bitonic sort method.
The code runs faster if arguments are passed to method. If members are accessed directly, code runs slower.
*/
void BitonicSortParallelKeyValue::sortPrivate()
{
    if (_sortOrder == ORDER_ASC)
    {
        bitonicSortParallelKeyValue<ORDER_ASC>(_d_keys, _d_values, _arrayLength);
    }
    else
    {
        bitonicSortParallelKeyValue<ORDER_DESC>(_d_keys, _d_values, _arrayLength);
    }
}