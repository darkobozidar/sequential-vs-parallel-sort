#include <stdio.h>
#include <stdint.h>
#include <math.h>

#include <cuda.h>
#include "cuda_runtime.h"
#include "device_launch_parameters.h"
#include "math_functions.h"

#include "data_types.h"
#include "constants.h"


__global__ void bitonicSortKernel(data_t* array, uint_t arrayLen, uint_t sharedMemSize) {
	extern __shared__ data_t tile[];
	uint_t index = blockIdx.x * 2 * blockDim.x + threadIdx.x;
	uint_t numStages = ceil(log2((double) sharedMemSize));

	if (index < arrayLen) {
		tile[threadIdx.x] = array[index];
	}
	if (index + blockDim.x < arrayLen) {
		tile[threadIdx.x + blockDim.x] = array[index + blockDim.x];
	}

	for (uint_t stage = 0; stage < numStages; stage++) {
		for (uint_t pass = 0; pass <= stage; pass++) {
			__syncthreads();

			uint_t pairDistance = 1 << (stage - pass);
			uint_t blockWidth = 2 * pairDistance;
			uint_t leftId = (threadIdx.x & (pairDistance - 1)) + (threadIdx.x >> (stage - pass)) * blockWidth;
			uint_t rightId = leftId + pairDistance;

			data_t leftElement, rightElement;
			data_t greater, lesser;
			leftElement = tile[leftId];
			rightElement = tile[rightId];

			uint_t sameDirectionBlockWidth = threadIdx.x >> stage;
			uint_t sameDirection = sameDirectionBlockWidth & 0x1;

			uint_t temp = sameDirection ? rightId : temp;
			rightId = sameDirection ? leftId : rightId;
			leftId = sameDirection ? temp : leftId;

			bool compareResult = (leftElement < rightElement);
			greater = compareResult ? rightElement : leftElement;
			lesser = compareResult ? leftElement : rightElement;

			tile[leftId] = lesser;
			tile[rightId] = greater;
		}
	}

	__syncthreads();

	if (index < arrayLen) {
		array[index] = tile[threadIdx.x];
	}
	if (index + blockDim.x < arrayLen) {
		array[index + blockDim.x] = tile[threadIdx.x + blockDim.x];
	}
}

__global__ void generateSublocksKernel(data_t* table, uint_t tableLen, uint_t sharedMemSize) {
	extern __shared__ data_t tile[];
	int index = blockIdx.x * 2 * blockDim.x + threadIdx.x * blockDim.x;

	if (index < tableLen) {
		tile[threadIdx.x] = table[index];
	}
	if (index + sharedMemSize * 2 < tableLen) {
		tile[threadIdx.x + 4] = table[index + sharedMemSize * 2];
	}

	for (uint_t stride = blockDim.x / 2; stride > 0; stride /= 2) {
		__syncthreads();
		uint_t pos = 2 * threadIdx.x - (threadIdx.x & (stride - 1));

		if (tile[pos] > tile[pos + stride]) {
			data_t temp = tile[pos];
			tile[pos] = tile[pos + stride];
			tile[pos + stride] = temp;
		}
	}
}
