#include <stdio.h>
#include <Windows.h>

#include <cuda.h>
#include "cuda_runtime.h"
#include "device_launch_parameters.h"

#include "data_types.h"
#include "constants.h"
#include "utils_cuda.h"
#include "utils_host.h"
#include "kernels.h"



/*
Initializes memory needed for parallel implementation of merge sort.
*/
void memoryInit(data_t* inputDataHost, data_t** outputDataHost, data_t** inputDataDevice,
                data_t** outputDataDevice, uint_t** ranksDevice, uint_t dataLen, uint_t ranksLen) {
    cudaError_t error;

    // Host memory
    error = cudaHostAlloc(outputDataHost, dataLen * sizeof(**outputDataHost), cudaHostAllocDefault);
    checkCudaError(error);

    // Device memory
    error = cudaMalloc(inputDataDevice, dataLen * sizeof(**inputDataDevice));
    checkCudaError(error);
    error = cudaMalloc(outputDataDevice, dataLen * sizeof(**outputDataDevice));
    checkCudaError(error);
    error = cudaMalloc(ranksDevice, ranksLen * sizeof(**ranksDevice));
    checkCudaError(error);

    // Memory copy
    error = cudaMemcpy(*inputDataDevice, inputDataHost, dataLen * sizeof(**inputDataDevice),
                       cudaMemcpyHostToDevice);
    checkCudaError(error);
}

void runBitonicSortKernel(data_t* tableDevice, uint_t tableLen) {
    cudaError_t error;
    LARGE_INTEGER timerStart;

    // Every thread compares 2 elements
    uint_t blockSize = 4;  // arrayLen / 2 < getMaxThreadsPerBlock() ? arrayLen / 2 : getMaxThreadsPerBlock();
    uint_t blocksPerMultiprocessor = getMaxThreadsPerMultiProcessor() / blockSize;
    // TODO fix shared memory size from 46KB to 16KB
    uint_t sharedMemSize = 16384 / sizeof(*tableDevice) / blocksPerMultiprocessor;

    dim3 dimGrid((tableLen - 1) / (2 * blockSize) + 1, 1, 1);
    dim3 dimBlock(blockSize, 1, 1);

    startStopwatch(&timerStart);
    bitonicSortKernel<<<dimGrid, dimBlock, sharedMemSize * sizeof(*tableDevice)>>>(tableDevice, tableLen, sharedMemSize);
    error = cudaDeviceSynchronize();
    checkCudaError(error);
    endStopwatch(timerStart, "Executing Merge Sort Kernel");
}

void runGenerateSublocksKernel(data_t* tableDevice, uint_t* rankTable, uint_t tableLen,
                               uint_t tabBlockSize, uint_t tabSubBlockSize) {
    cudaError_t error;
    LARGE_INTEGER timerStart;

    // * 2 for table of ranks, which has the same size as table of samples
    uint_t sharedMemSize = tableLen / tabSubBlockSize * sizeof(sample_el_t);
    uint_t blockSize = tableLen / tabSubBlockSize;
    dim3 dimGrid((tableLen - 1) / (2 * blockSize * tabSubBlockSize) + 1, 1, 1);
    dim3 dimBlock(blockSize, 1, 1);

    startStopwatch(&timerStart);
    generateSublocksKernel<<<dimGrid, dimBlock, sharedMemSize>>>(
        tableDevice, rankTable, tableLen, tabBlockSize, tabSubBlockSize
    );
    error = cudaDeviceSynchronize();
    checkCudaError(error);
    endStopwatch(timerStart, "Executing Generate Sublocks kernel");
}

void runMergeKernel(data_t* inputTableDevice, data_t* outputTableDevice, uint_t* rankTable, uint_t tableLen,
                    uint_t rankTableLen, uint_t tabBlockSize, uint_t tabSubBlockSize) {
    cudaError_t error;
    LARGE_INTEGER timerStart;

    uint_t subBlocksPerMergedBlock = tabBlockSize / tabSubBlockSize * 2;
    uint_t numMergedBlocks = tableLen / (tabBlockSize * 2);
    uint_t sharedMemSize = tabSubBlockSize * sizeof(*inputTableDevice) * 2;
    dim3 dimGrid(subBlocksPerMergedBlock + 1, numMergedBlocks, 1);
    dim3 dimBlock(tabSubBlockSize, 1, 1);

    startStopwatch(&timerStart);
    mergeKernel<<<dimGrid, dimBlock, sharedMemSize>>>(
        inputTableDevice, outputTableDevice, rankTable, tableLen, rankTableLen, tabBlockSize, tabSubBlockSize
    );
    error = cudaDeviceSynchronize();
    checkCudaError(error);
    endStopwatch(timerStart, "Executing merge kernel");
}

data_t* sortParallel(data_t* inputDataHost, uint_t dataLen, bool orderAsc) {
    data_t* outputDataHost;
    data_t* inputDataDevice;
    data_t* outputDataDevice;
    uint_t* ranksDevice;
    uint_t tableBlockSize = 8;
    uint_t tableSubBlockSize = 4;  // TODO could be constant
    uint_t ranksLen = dataLen / tableSubBlockSize * 2;
    cudaError_t error;

    memoryInit(inputDataHost, &outputDataHost, &inputDataDevice, &outputDataDevice,
               &ranksDevice, dataLen, ranksLen);

    runBitonicSortKernel(inputDataDevice, dataLen);
    error = cudaDeviceSynchronize();
    checkCudaError(error);

    // TODO verify, if ALL (also up) device syncs are necessary
    for (; tableBlockSize < dataLen; tableBlockSize *= 2) {
        runGenerateSublocksKernel(inputDataDevice, ranksDevice, dataLen, tableBlockSize, tableSubBlockSize);
        error = cudaDeviceSynchronize();
        checkCudaError(error);

        runMergeKernel(inputDataDevice, outputDataDevice, ranksDevice, dataLen, ranksLen,
                       tableBlockSize, tableSubBlockSize);
        error = cudaDeviceSynchronize();
        checkCudaError(error);

        data_t* temp = inputDataDevice;
        inputDataDevice = outputDataDevice;
        outputDataDevice = temp;
    }

    error = cudaMemcpy(outputDataHost, inputDataDevice, dataLen * sizeof(*outputDataHost),
                       cudaMemcpyDeviceToHost);
    checkCudaError(error);

    return outputDataHost;
}
