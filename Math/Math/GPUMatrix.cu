//
// <copyright file="GPUMatrix.cu" company="Microsoft">
//     Copyright (c) Microsoft Corporation.  All rights reserved.
// </copyright>
//
#pragma once
#include "stdafx.h"
#include "cublas_v2.h"
#include <assert.h>
#include <cuda.h>
#include <cuda_runtime.h>
#include <curand.h>
#include <curand_kernel.h>
#include <omp.h>
#include <iostream>
#include <stdexcept>
#include "device_launch_parameters.h"
#include "GPUMatrix.cuh"
#include "GPUMatrixCUDAKernels.cu"
#include "GPUSparseMatrix.cuh"

#pragma warning (disable: 4267)

#ifdef NO_SYNC
bool do_sync = false;
#else
bool do_sync = true;
#endif

#ifndef	LINUX
// thread local storage to access the current stream, initalize to default stream
__declspec( thread ) 
#endif	/* LINUX */
		cudaStream_t t_stream = cudaStreamDefault;

extern int _ConvertSMVer2Cores(int major, int minor);

// SetStream - set the stream that will be used by the GPU routines
void MATH_API SetStream(cudaStream_t stream)
{
    t_stream = stream;
}

// GetStream - get the stream that will be used by the GPU routines
cudaStream_t MATH_API GetStream()
{
    return t_stream;
}


void CURAND_CALL(curandStatus x)
{
    if(x!=CURAND_STATUS_SUCCESS) 
    { 
#ifndef	LINUX
        throw std::exception("CURAND fail");
#else /* LINUX */
        throw std::exception();
#endif	/* LINUX */
    }        
}

void CUBLAS_CALL(cublasStatus_t x)
{
    if(x!=CUBLAS_STATUS_SUCCESS) 
    { 
#ifndef	LINUX
        throw std::exception("CUBLAS fail");
#else	 /* LINUX */
        throw std::exception();
#endif /* LINUX */
    }
}

void CUDA_CALL(cudaError_t x) 
{
    if(x!=cudaSuccess) 
    { 
        const char* errmsg = cudaGetErrorString(x);
        std::cout<<"!!!!!!!!CUDA EXCEPTION: "<<errmsg<<std::endl;
        cudaDeviceSynchronize();
#ifndef	LINUX
        throw std::exception(errmsg);
#else
        throw std::exception();
#endif
    }    
}

namespace Microsoft { namespace MSR { namespace CNTK {

    // PrepareDevice - Setup the correct cuda context for an operation
    // deviceId - the device on which the operation will take place
    void PrepareDevice(short deviceId)
    {
        static short currentDevice = AUTOPLACEMATRIX; // set to anything invalid
        // externally managed matrices are guaranteed to be on the right device
        if (deviceId == MANAGEDEXTERN)
            return;
        // and if we last set the device to be this device we are good
        if (deviceId == currentDevice)
            return;
        CUDA_CALL(cudaSetDevice(deviceId));
        currentDevice=deviceId;
    }

#pragma region DeviceBoundNumber class

    template<class ElemType>
    DeviceBoundNumber<ElemType>::DeviceBoundNumber(const DeviceBoundNumber<ElemType> &deepCopy)
    {
        NOT_IMPLEMENTED;
    }

#ifndef	LINUX
    template<class ElemType>
    DeviceBoundNumber<ElemType>::DeviceBoundNumber(DeviceBoundNumber<ElemType> &&shallowCopy)
    {
        this->ShallowCopyFrom(shallowCopy.m_data,shallowCopy.m_computeDevice);
        shallowCopy.m_data=NULL;
    }
#endif

    template<class ElemType>
    void DeviceBoundNumber<ElemType>::ShallowCopyFrom(ElemType* newVal,int newValsDevceId)
    {
        this->m_computeDevice = newValsDevceId;
        this->m_data = newVal;
    }

    template<class ElemType>
    DeviceBoundNumber<ElemType>::~DeviceBoundNumber()
    {
        if (this->m_data!=NULL)
        {
            if (this->m_computeDevice<0)
            {
                delete this->m_data;
                this->m_data = NULL;
            }
            else if (this->m_computeDevice != MANAGEDEXTERN)
                CUDA_CALL(cudaFree(this->m_data));
        }
    }

#pragma endregion DeviceBoundNumber class

#pragma region Helper functions
    template<class ElemType>    
    cublasHandle_t _initCUBLAS(int devId)
    {
        PrepareDevice(devId);
        cublasHandle_t cuHandle;
        CUBLAS_CALL(cublasCreate(&cuHandle));
        return cuHandle;
    }

    // GetBestGPUDeviceId - Get the best GPU DeviceId, based on cuda information
    //  TODO: should be replaced by BestGpu class instead, it's much better
    template<class ElemType>
    int GPUMatrix<ElemType>::GetBestGPUDeviceId() //returns -1 if no GPUs can be used
    {      
        // currently there is little point in giving out different device IDs each time ask for a matrix, 
        // we really want them all on the same device eventually
        static int chosenDeviceId = AUTOPLACEMATRIX;
        if (chosenDeviceId != AUTOPLACEMATRIX)
            return chosenDeviceId;

        try
        {
            // stash previous device state
            // if there was one on entry:
            int nPrevDev = -1;
            cudaError_t ePrevDev = cudaGetDevice(&nPrevDev);
 
            int deviceCount = -1;
            cudaError_t error_id = cudaGetDeviceCount(&deviceCount);
            if (error_id != cudaSuccess || deviceCount==0) 
            { 
                return -1;            
            }

            int setDev = -1;
            int curDev=0;
            long curPower = 0;
            for (short dev = 0; dev < deviceCount; ++dev)
            {
                CUDA_CALL(cudaSetDevice(dev));
                setDev = dev;
                cudaDeviceProp deviceProp;
                cudaGetDeviceProperties(&deviceProp, dev);
                long power = _ConvertSMVer2Cores(deviceProp.major, deviceProp.minor) * deviceProp.multiProcessorCount;
                //long power = _GetFreeMemoryOnCUDADevice(dev);
                if (power>curPower)
                {
                    curPower=power;
                    curDev = dev;
                }
            }

            if(nPrevDev >= 0 && ePrevDev == cudaSuccess && 
                setDev >= 0 && setDev != nPrevDev) {
                // restore current context to the one we entered with
                // if there was one the caller might want unchanged.
                cudaSetDevice(nPrevDev);
            }
            chosenDeviceId = curDev;
            return curDev;
        }
        catch (int e)
        {
            return -1; // CPU
        }
    }

    // PrepareDevice - Setup the correct cuda context for an operation
    // deviceId - the device on which the operation will take place
    //            defaults to -1, which means use matrices current device
    template<class ElemType>
    void GPUMatrix<ElemType>::PrepareDevice(short deviceId /*=-1*/) const
    {
        // if default value use current compute device
        if (deviceId == -1)
            deviceId = this->m_computeDevice;
        Microsoft::MSR::CNTK::PrepareDevice(deviceId);
    }

    template<class ElemType>
    ElemType* GPUMatrix<ElemType>::CopyToArray() const
    {
        size_t numElements = this->GetNumElements();
        if (numElements != 0)
        {
            PrepareDevice();
            ElemType* pArray = new ElemType[numElements];                    
            CUDA_CALL(cudaMemcpy(pArray,this->m_pArray,sizeof(ElemType)*this->m_numRows*this->m_numCols,cudaMemcpyDeviceToHost));
            return pArray;
        }
        else
        {
            return NULL;
        }
    }

    //memory will be allocated by the callee if not enough but need to be deleted by the caller after it's done
    //return number of elements copied
    template<class ElemType>
    size_t  GPUMatrix<ElemType>::CopyToArray(ElemType*& arrayCopyTo, size_t& currentArraySize) const
    {
        size_t numElements = this->GetNumElements();

        if (numElements > currentArraySize)
        {
            delete arrayCopyTo;
            arrayCopyTo = new ElemType[numElements];  
            currentArraySize = numElements;
        }

        if (numElements != 0)
        {
            PrepareDevice();
            CUDA_CALL(cudaMemcpy(arrayCopyTo, this->m_pArray, sizeof(ElemType)*numElements, cudaMemcpyDeviceToHost));
        }

        return numElements;
    }

    template<class ElemType>
    void GPUMatrix<ElemType>::ChangeDeviceTo(int to_id)
    {
        if (!this->OwnBuffer())
            throw std::logic_error("Cannot change device on Managed external matrix");
        if (to_id == CPUDEVICE)
            throw std::logic_error("to_id must be valid GPU");
        if (this->m_computeDevice==to_id) 
            return;

        PrepareDevice(to_id);       
        ElemType* d_dst=NULL;
        CUDA_CALL(cudaMalloc((void**)&d_dst,sizeof(ElemType)*this->m_numRows*this->m_numCols));

        this->m_elemSizeAllocated = this->m_numRows*this->m_numCols;

		// check to make sure we have something to copy (on init we often have zero sized allocations)
		if (this->m_elemSizeAllocated > 0)
		{
			// first try peer access
			int canAccessPeer = false;
			CUDA_CALL(cudaDeviceCanAccessPeer(&canAccessPeer, to_id, this->m_computeDevice));
			if (canAccessPeer)
			{
				CUDA_CALL(cudaDeviceEnablePeerAccess(this->m_computeDevice, 0));
				CUDA_CALL(cudaMemcpyPeer(d_dst,to_id,this->m_pArray,this->m_computeDevice,sizeof(ElemType)*this->m_numRows*this->m_numCols));  
			}
			else
			{
				// peer access didn't work, just copy normal
				// make this more efficient by keeping some buffers available for each copy
				ElemType* h_dst=NULL;
				PrepareDevice();
				CUDA_CALL(cudaMallocHost((void**)&h_dst,sizeof(ElemType)*this->m_numRows*this->m_numCols));
				CUDA_CALL(cudaMemcpy(h_dst,this->m_pArray,sizeof(ElemType)*this->m_numRows*this->m_numCols, cudaMemcpyDeviceToHost));  
				PrepareDevice(to_id);       
				CUDA_CALL(cudaMemcpy(d_dst,h_dst,sizeof(ElemType)*this->m_numRows*this->m_numCols, cudaMemcpyHostToDevice)); 
				CUDA_CALL(cudaFreeHost(h_dst));  
			}
		}
        PrepareDevice();
        CUDA_CALL(cudaFree(this->m_pArray));
        this->m_pArray=d_dst;

        PrepareDevice(to_id);       
        this->m_computeDevice=to_id;
    }

    template<class ElemType>
    void GPUMatrix<ElemType>::performInplaceFunction(int kind)    
    {        
        PrepareDevice();
        LONG64 N= (LONG64) this->GetNumElements();
        int blocksPerGrid =(int)ceil(1.0*N/threadsPerBlock);                
        cudaEvent_t done;       
        if (do_sync)    CUDA_CALL(cudaEventCreate(&done));        
        switch (kind)
        {
        case 0:
			_inplaceSigmoidOnCuda<ElemType><<<blocksPerGrid, threadsPerBlock, 0, t_stream>>>(this->m_pArray, N);
            break;
        case 1:
			_inplaceTanhOnCuda<ElemType><<<blocksPerGrid, threadsPerBlock, 0, t_stream>>>(this->m_pArray, N);
            break;
        case 2:
			_inplaceSqrtOnCuda<ElemType><<<blocksPerGrid, threadsPerBlock, 0, t_stream>>>(this->m_pArray, N);
            break;
        case 3:
            _inplaceExpOnCuda<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(this->m_pArray,N);
            break;
        case 4:
            _inplaceLogOnCuda<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(this->m_pArray,N);
            break;
        case 5:
            _inplaceAbsOnCuda<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(this->m_pArray,N);
            break;
        case 6:
            _inplaceLinRectDerivative<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(this->m_pArray,N);
            break;
        case 7:
            _inplaceCosineOnCuda<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(this->m_pArray,N);
            break;
        case 8:
            _inplaceNegativeSineOnCuda<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(this->m_pArray,N);
            break;
        } 
        if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
        if (do_sync)    CUDA_CALL(cudaEventSynchronize(done));       
        if (do_sync)    CUDA_CALL(cudaEventDestroy(done));
    }


#pragma endregion Helper functions

#pragma region Constructors and Destructor

   //should only be used by constructors.
    template<class ElemType>
    void GPUMatrix<ElemType>::ZeroInit(int deviceId)
    {
        this->m_computeDevice = deviceId;
        this->m_pArray = NULL;
        this->m_numRows = 0;
        this->m_numCols = 0;
        this->m_elemSizeAllocated = 0;
        this->m_matrixName=NULL;
        this->m_format = matrixFormatDense; 
        this->m_externalBuffer = false;
    }

    template<class ElemType>
    GPUMatrix<ElemType>::GPUMatrix(int deviceId) 
    {
        if (deviceId == MANAGEDEXTERN)
            throw std::logic_error("Basic constructor cannot be used with Managed Extern types");

        ZeroInit(deviceId);
    };

    //matrixName is used to verify that correct matrix is read.
    template<class ElemType>
    GPUMatrix<ElemType>::GPUMatrix(FILE* f, const char * matrixName, int deviceId)
    {
        if (deviceId == MANAGEDEXTERN)
            throw std::logic_error("File constructor cannot be used with Managed Extern types");

        ReadFromFile(f, matrixName);
    }

    template<class ElemType>
    GPUMatrix<ElemType>::GPUMatrix(const size_t numRows, const size_t numCols,int deviceId)
    {
        if (deviceId == MANAGEDEXTERN)
            throw std::logic_error("constructor cannot be used with Managed Extern types");
        ZeroInit(deviceId);
        this->m_numRows = numRows;
        this->m_numCols = numCols;
        this->m_elemSizeAllocated = this->GetNumElements();

        if (this->m_elemSizeAllocated != 0)
        {
            PrepareDevice();        
            CUDA_CALL(cudaMalloc((void**)&this->m_pArray,sizeof(ElemType)*this->m_elemSizeAllocated));      
        CUDA_CALL(cudaMemset(this->m_pArray,0,sizeof(ElemType)*this->m_elemSizeAllocated));  
        }
    };

    template<class ElemType>
    GPUMatrix<ElemType>::GPUMatrix(const size_t numRows, const size_t numCols, ElemType *pArray, const size_t matrixFlags, int deviceId)
    {
        ZeroInit(deviceId);
        SetValue(numRows, numCols, pArray, matrixFlags, deviceId);
    };               

    template<class ElemType>
    GPUMatrix<ElemType>::GPUMatrix(const GPUMatrix<ElemType>& deepCopyFrom)
    {
        ZeroInit(deepCopyFrom.m_computeDevice);
        SetValue(deepCopyFrom);
        this->SetMatrixName(deepCopyFrom.m_matrixName);       
    }

#ifndef	LINUX
    template<class ElemType>
    GPUMatrix<ElemType>::GPUMatrix(GPUMatrix<ElemType>&& moveFrom)
    {
        this->m_numRows = moveFrom.m_numRows;
        this->m_numCols = moveFrom.m_numCols;
        this->m_computeDevice = moveFrom.m_computeDevice;
        this->m_pArray = moveFrom.m_pArray;  //shallow copy the pointer       
        this->m_matrixName=moveFrom.m_matrixName;
        this->m_elemSizeAllocated = moveFrom.m_elemSizeAllocated;
        this->m_format = moveFrom.m_format;
        this->m_externalBuffer = moveFrom.m_externalBuffer;

        //release the pointer from the source object so that the destructor won't release it twice
        moveFrom.ZeroInit(0);       
    }
#endif

    //assignment operator, deep copy
    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::operator=(const GPUMatrix<ElemType>& deepCopyFrom)  
    {
        if (this != &deepCopyFrom)
        {
            SetValue(deepCopyFrom);
            this->SetMatrixName(deepCopyFrom.m_matrixName);       
        }
        return *this;
    }

#ifndef	LINUX
    //move assignment operator, shallow copy
    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::operator=(GPUMatrix<ElemType>&& moveFrom)  
    {
        if (this != &moveFrom)
        {
            if (this->OwnBuffer() && this->m_pArray!=NULL)
            {
                CUDA_CALL(cudaFree(this->m_pArray));  
            }

            this->m_numRows = moveFrom.m_numRows;
            this->m_numCols = moveFrom.m_numCols;
            this->m_elemSizeAllocated =  moveFrom.m_elemSizeAllocated;
            this->m_pArray = moveFrom.m_pArray;
            this->m_computeDevice = moveFrom.m_computeDevice;
            this->m_format = moveFrom.m_format;
            this->m_externalBuffer = moveFrom.m_externalBuffer;

            //release the pointer from the source object so that the destructor won't release it twice
            moveFrom.ZeroInit(0);
        }
        return *this;
    }
#endif /* LINUX */

    template<class ElemType>
    GPUMatrix<ElemType>::~GPUMatrix(void)
    {
        Clear();
    }

    template<class ElemType>
    void GPUMatrix<ElemType>::Clear()
    {
        if (this->OwnBuffer() && this->m_pArray!=NULL)
        {
            if (this->m_computeDevice>=0)
            {            
                PrepareDevice();
                cudaFree(this->m_pArray);
                this->m_pArray = NULL;
                this->m_elemSizeAllocated = 0;
            }        
        }
        BaseMatrix<ElemType>::Clear();

        ZeroInit(this->m_computeDevice);
    }
#pragma endregion Constructors and Destructor 

    template<class ElemType>
    int GPUMatrix<ElemType>::GetComputeDeviceId() const 
    {
        // for externally managed memory the CUDA context will have the current device
        if (this->m_computeDevice == MANAGEDEXTERN)
        {
            int devId;
            assert(this->m_externalBuffer);
            CUDA_CALL(cudaGetDevice(&devId));
            return devId;
        }
        return this->m_computeDevice;
    }

#pragma region Basic Operators
    template<class ElemType>
    GPUMatrix<ElemType> GPUMatrix<ElemType>::ColumnSlice(size_t startColumn, size_t numCols) const
    {
        if (numCols == 0)
            throw std::logic_error("The slice cannot have 0 columns.");

        if (startColumn + numCols > this->m_numCols)
            throw std::logic_error("The slice is out of range of the source matrix.");
            
        GPUMatrix<ElemType> slice(this->m_numRows, numCols, this->m_pArray + startColumn * this->m_numRows, matrixFlagDontOwnBuffer, this->m_computeDevice);

        return slice;
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::AssignColumnSlice(const GPUMatrix<ElemType>& fromMatrix, size_t startColumn, size_t numCols)
    {
        if (numCols == 0)
            throw std::logic_error("The slice cannot have 0 columns.");

        if (startColumn + numCols > this->m_numCols)
            throw std::logic_error("The slice is out of range of the source matrix.");
        
        Clear();

        this->m_computeDevice=fromMatrix.m_computeDevice;
        this->m_externalBuffer=true;
        this->m_numRows = fromMatrix.m_numRows;
        this->m_pArray=fromMatrix.m_pArray + startColumn * this->m_numRows;

        this->m_elemSizeAllocated = this->GetNumElements();
        this->m_matrixName=NULL;
        this->m_format = fromMatrix.m_format;

        return *this;
    }     


    //for each column of a, we assign numRows starting from startIndex to this
    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::AssignRowSliceValuesOf(const GPUMatrix<ElemType>& a, const size_t startIndex, const size_t numRows)
    {
        if (a.IsEmpty())
            throw std::logic_error("AssignRowSliceValuesOf: input matrix a is empty.");

        if (startIndex + numRows > a.GetNumRows())
            throw std::logic_error("AssignRowSliceValuesOf: startIndex + numRows exceeds a.GetNumRows().");

        Resize(numRows, a.GetNumCols());

        LONG64 N=(LONG64)this->GetNumElements();
        int blocksPerGrid =(int)ceil(1.0*N/threadsPerBlock);
        PrepareDevice();
        cudaEvent_t done;       
        if (do_sync)    CUDA_CALL(cudaEventCreate(&done));
        _assignRowSliceValuesOf<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(this->m_pArray, a.m_pArray, N, (long)startIndex, (long)numRows, (long)a.GetNumRows());
        if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
        if (do_sync)    CUDA_CALL(cudaEventSynchronize(done)); 
        if (do_sync)    CUDA_CALL(cudaEventDestroy(done));

        return *this;
    }

    //for each column of a, we add all rows of a to this starting from startIndex
    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::AddToRowSliceValuesOf(const GPUMatrix<ElemType>& a, const size_t startIndex, const size_t numRows)
    {
        if (a.IsEmpty())
            throw std::logic_error("AddToRowSliceValuesOf: input matrix a is empty.");

        if (a.GetNumRows() != numRows)
            throw std::logic_error("AddToRowSliceValuesOf: a.GetNumRows() != numRows.");

        if (startIndex + numRows > this->GetNumRows())
            throw std::logic_error("AddToRowSliceValuesOf: startIndex + numRows exceeds GetNumRows().");

        if (a.GetNumCols() != this->GetNumCols())
            throw std::logic_error("AddToRowSliceValuesOf: columns does not match.");

        LONG64 N=(LONG64)a.GetNumElements();
        int blocksPerGrid =(int)ceil(1.0*N/threadsPerBlock);
        PrepareDevice();
        cudaEvent_t done;       
        if (do_sync)    CUDA_CALL(cudaEventCreate(&done));
        _addToRowSliceValuesOf<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(this->m_pArray, a.m_pArray, N, (long)startIndex, (long)this->GetNumRows(), (long)a.GetNumRows());
        if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
        if (do_sync)    CUDA_CALL(cudaEventSynchronize(done)); 
        if (do_sync)    CUDA_CALL(cudaEventDestroy(done));

        return *this;
    }

    template<class ElemType>
    GPUMatrix<ElemType> GPUMatrix<ElemType>::Transpose() const
    {
        if (this->IsEmpty())
            throw std::logic_error("Transpose: Matrix is empty.");

        GPUMatrix<ElemType> c(this->GetComputeDeviceId());
        c.AssignTransposeOf(*this);
        return c;
    }

    // GetCublasHandle - get a cublas handle for the given GPU, should only need one per GPU
    // computeDevice - The compute device for which the cublas handle is desired
    // returns: cublas handle
    // NOTE: we currently don't bother to ever free the CUBLAS handle, it will be freed automatically by CUDA when the process ends
    template<class ElemType>
    cublasHandle_t GPUMatrix<ElemType>::GetCublasHandle(int computeDevice/*=-1*/)
    {
        // if the compute device is not passed, get the current device from CUDA
        if (computeDevice < 0)
            cudaGetDevice(&computeDevice);

        if (computeDevice < 0 || computeDevice >= MaxGpus)
            throw std::logic_error("GetCublasHandle: Maximum GPU exceeded");
        cublasHandle_t cuHandle = s_cuHandle[computeDevice];
        if (cuHandle == NULL)
        {
            s_cuHandle[computeDevice] = cuHandle = _initCUBLAS<ElemType>(computeDevice);
        }
        CUBLAS_CALL(cublasSetStream(cuHandle, t_stream));

        return cuHandle;
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::AssignTransposeOf (const GPUMatrix<ElemType>& a)
    {
        if (this == &a)
            throw std::logic_error("AssignTransposeOf: a is the same as [this]. Does not support inplace transpose.");

        if (a.IsEmpty())
            throw std::logic_error("AssignTransposeOf: Matrix a is empty.");

        if (this->GetNumRows()!=a.GetNumCols() || this->GetNumCols()!=a.GetNumRows())
            Resize(a.GetNumCols(), a.GetNumRows());

        cublasHandle_t cuHandle = GetCublasHandle(a.GetComputeDeviceId());
        cublasOperation_t transA =  CUBLAS_OP_T;
        cublasOperation_t transB =  CUBLAS_OP_T;
        int m = (int)a.m_numCols;
        int n = (int)a.m_numRows;                
        ElemType alpha=1;
        ElemType beta=0;
        cublasStatus_t st;
        if (sizeof(ElemType)==sizeof(float))
        {
            st = cublasSgeam(cuHandle,transA,transB,m,n,reinterpret_cast<float*>(&alpha),reinterpret_cast<float*>(a.m_pArray),(int)a.m_numRows,reinterpret_cast<float*>(&beta),reinterpret_cast<float*>(a.m_pArray),(int)a.m_numRows,reinterpret_cast<float*>(this->m_pArray),(int)this->m_numRows);
        }
        else if (sizeof(ElemType)==sizeof(double))
        {            
            st = cublasDgeam(cuHandle,transA,transB,m,n,reinterpret_cast<double*>(&alpha),reinterpret_cast<double*>(a.m_pArray),(int)a.m_numRows,reinterpret_cast<double*>(&beta),reinterpret_cast<double*>(a.m_pArray),(int)a.m_numRows,reinterpret_cast<double*>(this->m_pArray),(int)this->m_numRows);
        }
        else  
        {
#ifndef	LINUX
            throw std::exception("Unsupported template argument in GPUMatrix"); 
#else
            throw std::exception(); 
#endif	/* LINUX */
        }
        if (st!=CUBLAS_STATUS_SUCCESS)
        {
#ifndef	LINUX
            throw std::exception("AssignTransposeOf failed");     
#else
            throw std::exception();     
#endif	/* LINUX */
        }
        this->m_numRows=a.m_numCols;
        this->m_numCols=a.m_numRows;
        this->SetMatrixName(a.GetMatrixName());
        return *this;
    }

    template<class ElemType>
    void GPUMatrix<ElemType>::SetValue(const ElemType v)
    {
        if (this->IsEmpty())
            throw std::logic_error("SetValue: Matrix is empty.");

        LONG64 N=(LONG64)this->GetNumElements();
        int blocksPerGrid =(int)ceil(1.0*N/threadsPerBlock);
        PrepareDevice();
        cudaEvent_t done;       
        if (do_sync)    CUDA_CALL(cudaEventCreate(&done));
        _setValue<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(this->m_pArray,v,N);
        if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
        if (do_sync)    CUDA_CALL(cudaEventSynchronize(done)); 
        if (do_sync)    CUDA_CALL(cudaEventDestroy(done));
    }

    template<class ElemType>
    void GPUMatrix<ElemType>::SetValue(const ElemType* d_v) //d_v is pointer to the the value in GPU memory
    {
        if (this->IsEmpty())
            throw std::logic_error("SetValue: Matrix is empty.");

        LONG64 N=(LONG64)this->GetNumElements();
        int blocksPerGrid =(int)ceil(1.0*N/threadsPerBlock);
        PrepareDevice();
        cudaEvent_t done;       
        if (do_sync)    CUDA_CALL(cudaEventCreate(&done));
        _setValue<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(this->m_pArray,d_v,N);
        if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
        if (do_sync)    CUDA_CALL(cudaEventSynchronize(done)); 
        if (do_sync)    CUDA_CALL(cudaEventDestroy(done)); 
    }

    template<class ElemType>
    void GPUMatrix<ElemType>::SetColumn(const ElemType* colPointer, size_t colInd)
    {
        if (this->IsEmpty())
            throw std::logic_error("SetValue: Matrix is empty.");
        if (colPointer==NULL)
            return;
        CUDA_CALL(cudaMemcpy(this->m_pArray+LocateColumn(colInd),colPointer,sizeof(ElemType)*this->m_numRows,cudaMemcpyHostToDevice));
    }

    template<class ElemType>
    void GPUMatrix<ElemType>::SetValue(const GPUMatrix<ElemType>& deepCopyFrom)
    {
        if (this == &deepCopyFrom)
            return;

        Resize(deepCopyFrom.GetNumRows(), deepCopyFrom.GetNumCols());
        this->m_format = deepCopyFrom.m_format; // copy the format over just to be sure
        size_t cpSize = deepCopyFrom.GetNumRows() * deepCopyFrom.GetNumCols();
        if (cpSize != 0)
            CUDA_CALL(cudaMemcpy(this->m_pArray,deepCopyFrom.m_pArray,cpSize*sizeof(ElemType),cudaMemcpyDeviceToDevice));        
    }

    template<class ElemType>    
    void GPUMatrix<ElemType>::SetValue(const size_t numRows, const size_t numCols, ElemType *pArray, size_t matrixFlags, int deviceId)
    {
        // handle externally managed case
        if (matrixFlags&matrixFlagDontOwnBuffer)
        {
            // free the existing array if it used to be an owned array
            if (this->OwnBuffer() && this->m_pArray!=NULL)
            {
                PrepareDevice();
                CUDA_CALL(cudaFree(this->m_pArray));
            }
            this->m_numRows = numRows;
            this->m_numCols = numCols;
            this->m_pArray = pArray;
            this->m_elemSizeAllocated = this->GetNumElements();
            this->m_matrixName = NULL;
            this->m_format = matrixFormatDense;
            this->m_externalBuffer = true;
            this->m_computeDevice = deviceId;
        }
        else 
        {
            // if didn't previously own the buffer, wipe it clean 
            if (!this->OwnBuffer())
            {
                ZeroInit(deviceId);
            }

            // if the devices are different move it now
            if (this->m_computeDevice != deviceId && deviceId >= 0)
            {
                Clear();
                ZeroInit(deviceId);
            }

            // now resize/allocate as necessary
            Resize(numRows, numCols);
            this->m_externalBuffer = false;

            // copy over the content to the buffer
            PrepareDevice();
            if (pArray!=NULL) 
            {
                if (!(matrixFlags&matrixFormatRowMajor))
                {
				    CUDA_CALL(cudaMemcpy(this->m_pArray, pArray, sizeof(ElemType)*this->GetNumElements(), 
                        (matrixFlags&matrixFlagSetValueOnDevice)?cudaMemcpyDeviceToDevice:cudaMemcpyHostToDevice));
                }
                else
                {
#ifndef	LINUX
                    throw std::exception("Row major isn't implemented");
#else
                    throw std::exception();
#endif	/* LINUX */
                }
            }
        }
        this->m_format = matrixFormatDense;
    }


    template<class ElemType>
    void GPUMatrix<ElemType>::SetDiagonalValue(const ElemType v)
    {
        unsigned long N=(unsigned long)this->GetNumRows();
        int blocksPerGrid =(int)ceil(1.0*N/threadsPerBlock);
        PrepareDevice();
        cudaEvent_t done;       
        if (do_sync)    CUDA_CALL(cudaEventCreate(&done));
        _setDiagonalValue<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(this->m_pArray,v,N,(unsigned long)this->GetNumRows());
        if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
        if (do_sync)    CUDA_CALL(cudaEventSynchronize(done)); 
        if (do_sync)    CUDA_CALL(cudaEventDestroy(done));
    }

    template<class ElemType>
    void GPUMatrix<ElemType>::SetDiagonalValue(GPUMatrix<ElemType>& vector)
    {
        if (this->IsEmpty() || vector.IsEmpty())
            throw std::logic_error("SetDiagonalValue: Matrix is empty.");

        if (this->GetNumRows() != this->GetNumCols())
            throw std::logic_error("SetDiagonalValue: NumRows and NumCols do not agree.");

        if (vector.GetNumRows() != 1 && vector.GetNumCols() != 1)
            throw std::logic_error("SetDiagonalValue: input vector must be a vector.");

        if (vector.GetNumElements() == 1) //reduce to simple form
            SetDiagonalValue(vector.m_pArray[0]);

        else if (vector.GetNumRows() != this->GetNumRows())
            throw std::logic_error("SetDiagonalValue: input vector's dimension does not agree with [this].");
        else
        {
            long N=(long)this->GetNumRows();
            int blocksPerGrid =(int)ceil(1.0*N/threadsPerBlock);
            PrepareDevice();
            cudaEvent_t done;       
            if (do_sync)    CUDA_CALL(cudaEventCreate(&done));
            _setDiagonalValueFromVector<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(this->m_pArray,vector.m_pArray,N);
            if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
            if (do_sync)    CUDA_CALL(cudaEventSynchronize(done));
            if (do_sync)    CUDA_CALL(cudaEventDestroy(done));
        }
    }

    template<class ElemType>
    void GPUMatrix<ElemType>::SetUniformRandomValue(const ElemType low, const ElemType high, unsigned long seed)
    {
        PrepareDevice();
        if (s_curandGenerator==NULL)
        {            
            s_curandGenerator = new curandGenerator_t;
            /* Create pseudo-random number generator */        
            CURAND_CALL(curandCreateGenerator(&(((curandGenerator_t*)s_curandGenerator)[0]),CURAND_RNG_PSEUDO_XORWOW));        
            CURAND_CALL(curandSetPseudoRandomGeneratorSeed(((curandGenerator_t*)s_curandGenerator)[0], seed==USE_TIME_BASED_SEED ? time(NULL) : seed));       
            CURAND_CALL(curandSetGeneratorOrdering(((curandGenerator_t*)s_curandGenerator)[0],CURAND_ORDERING_PSEUDO_SEEDED));
        }

        cudaEvent_t done;       
        CUDA_CALL(cudaEventCreate(&done));
        if (sizeof(ElemType)==sizeof(float))
        {
            CURAND_CALL(curandGenerateUniform(((curandGenerator_t*)s_curandGenerator)[0], reinterpret_cast<float*>(this->m_pArray), this->GetNumElements()));
        }
        else
        {
            CURAND_CALL(curandGenerateUniformDouble(((curandGenerator_t*)s_curandGenerator)[0], reinterpret_cast<double*>(this->m_pArray), this->GetNumElements()));
        }
        CUDA_CALL(cudaEventRecord(done));        
        CUDA_CALL(cudaEventSynchronize(done)); 
        //CURAND_CALL(curandDestroyGenerator(gen));
        CUDA_CALL(cudaEventDestroy(done));

        float N=(float)this->GetNumElements();
        int blocksPerGrid =(int)ceil(1.0*N/threadsPerBlock);

        if (do_sync)    CUDA_CALL(cudaEventCreate(&done));
        _rescaleToRange<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(this->m_pArray,N,low,high);
        if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
        if (do_sync)    CUDA_CALL(cudaEventSynchronize(done)); 
        if (do_sync)    CUDA_CALL(cudaEventDestroy(done));
    }

    template<class ElemType>
    void GPUMatrix<ElemType>::SetGaussianRandomValue(const ElemType mean, const ElemType sigma, unsigned long seed)
    {
        PrepareDevice();
        if (s_curandGenerator==NULL)
        {            
            s_curandGenerator = new curandGenerator_t;
            /* Create pseudo-random number generator */        
            CURAND_CALL(curandCreateGenerator(&(((curandGenerator_t*)s_curandGenerator)[0]),CURAND_RNG_PSEUDO_XORWOW));        
            CURAND_CALL(curandSetPseudoRandomGeneratorSeed(((curandGenerator_t*)s_curandGenerator)[0], seed==USE_TIME_BASED_SEED ? time(NULL) : seed));       
            CURAND_CALL(curandSetGeneratorOrdering(((curandGenerator_t*)s_curandGenerator)[0],CURAND_ORDERING_PSEUDO_SEEDED));
        }

        if (sizeof(ElemType)==sizeof(float))
        {
            CURAND_CALL(curandGenerateNormal(((curandGenerator_t*)s_curandGenerator)[0], reinterpret_cast<float*>(this->m_pArray), this->GetNumElements(),mean, sigma));
        }
        else
        {
            CURAND_CALL(curandGenerateNormalDouble(((curandGenerator_t*)s_curandGenerator)[0], reinterpret_cast<double*>(this->m_pArray), this->GetNumElements(),mean, sigma));
        }
        //CURAND_CALL(curandDestroyGenerator(gen));
    }

    //maskRate: percentage of values masked out (similar to dropout rate)
    //scaleValue: which scale value to set to the left ones (unmasked items).
    template<class ElemType>
    void GPUMatrix<ElemType>::SetUniformRandomMask(const ElemType maskRate, const ElemType scaleValue, unsigned long seed)
    {
        PrepareDevice();
        if (s_curandGenerator==NULL)
        {            
            s_curandGenerator = new curandGenerator_t;
            /* Create pseudo-random number generator */        
            CURAND_CALL(curandCreateGenerator(&(((curandGenerator_t*)s_curandGenerator)[0]),CURAND_RNG_PSEUDO_XORWOW));        
            CURAND_CALL(curandSetPseudoRandomGeneratorSeed(((curandGenerator_t*)s_curandGenerator)[0], seed==USE_TIME_BASED_SEED ? time(NULL) : seed));       
            CURAND_CALL(curandSetGeneratorOrdering(((curandGenerator_t*)s_curandGenerator)[0],CURAND_ORDERING_PSEUDO_SEEDED));
        }

        cudaEvent_t done;       
        CUDA_CALL(cudaEventCreate(&done));
        if (sizeof(ElemType)==sizeof(float))
        {
            CURAND_CALL(curandGenerateUniform((((curandGenerator_t*)s_curandGenerator)[0]), reinterpret_cast<float*>(this->m_pArray), this->GetNumElements()));
        }
        else
        {
            CURAND_CALL(curandGenerateUniformDouble((((curandGenerator_t*)s_curandGenerator)[0]), reinterpret_cast<double*>(this->m_pArray), this->GetNumElements()));
        }
        CUDA_CALL(cudaEventRecord(done));        
        CUDA_CALL(cudaEventSynchronize(done)); 
        CUDA_CALL(cudaEventDestroy(done));
        //CURAND_CALL(curandDestroyGenerator(gen));

        float N=(float)this->GetNumElements();
        int blocksPerGrid =(int)ceil(1.0*N/threadsPerBlock);        
        if (do_sync)    CUDA_CALL(cudaEventCreate(&done));
        _setMaskAndScale<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(this->m_pArray,N,maskRate,scaleValue);
        if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
        if (do_sync)    CUDA_CALL(cudaEventSynchronize(done)); 
        if (do_sync)    CUDA_CALL(cudaEventDestroy(done));
    }

    template<class ElemType>
    void GPUMatrix<ElemType>::Adagrad(GPUMatrix<ElemType>& gradients)
    {
        if (this->IsEmpty())
        {
            this->Resize(gradients.GetNumRows(), gradients.GetNumCols());
            this->SetValue(0.0);
        }

        assert(this->GetNumRows() == gradients.GetNumRows() && this->GetNumCols() == gradients.GetNumCols());

        int blocksPerGrid = (this->GetNumElements() + threadsPerBlock -1 )/threadsPerBlock;
        _adagrad<ElemType><<<blocksPerGrid, threadsPerBlock>>>(this->m_pArray, gradients.m_pArray, this->GetNumElements());
    }

    template<class ElemType>
    void GPUMatrix<ElemType>::Reshape(const size_t numRows, const size_t numCols)
    {
        assert (numRows*numCols == this->GetNumElements());
        if (numRows*numCols != this->GetNumElements())
            throw std::invalid_argument("Reshape: total number of elements does not match.");

        this->m_numRows = numRows;
        this->m_numCols = numCols;
    }

    template<class ElemType>
    void GPUMatrix<ElemType>::Resize(const size_t numRows, const size_t numCols, bool growOnly)
    {
        if (this->m_numRows==numRows && this->m_numCols==numCols)
            return;   

        this->m_numRows = numRows;
        this->m_numCols = numCols;

        size_t numElements = this->GetNumElements();
        if (numElements > this->m_elemSizeAllocated || (!growOnly && numElements != this->m_elemSizeAllocated))
        {
            if (this->IsEmpty())
            {
                this->m_elemSizeAllocated = 0;
                this->m_pArray = NULL;
            }
            else
            {            
                if (!this->OwnBuffer())
                    throw std::invalid_argument("Can't resize a externally managed matrix");
                PrepareDevice();
                if (this->m_pArray!=NULL)
                    CUDA_CALL(cudaFree(this->m_pArray)); //delete and reallocate                            
                this->m_elemSizeAllocated = numElements;
                CUDA_CALL(cudaMalloc((void**)&this->m_pArray,sizeof(ElemType)*this->m_elemSizeAllocated));
                CUDA_CALL(cudaMemset(this->m_pArray,0,sizeof(ElemType)*this->m_elemSizeAllocated));
            }
        }
    }

    template<class ElemType>
    size_t GPUMatrix<ElemType>::LocateElement (const size_t row, const size_t col) const 
    { 
        assert (row < this->m_numRows && col < this->m_numCols); 
        return col * this->m_numRows  + row;  // matrix in column-wise storage
    }  

    template<class ElemType>
    size_t GPUMatrix<ElemType>::LocateColumn (const size_t col) const 
    { 
        assert (col < this->m_numCols); 
        return col * this->m_numRows;  // matrix in column-wise storage
    }  

    template<class ElemType>
    ElemType GPUMatrix<ElemType>::Get00Element() const 
    {        
        ElemType res=0;        
        CUDA_CALL(cudaMemcpy(&res,this->m_pArray,sizeof(ElemType),cudaMemcpyDeviceToHost));
        return res;
    }
#pragma endregion Basic Operators

#pragma region Member BLAS Functions
    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::operator+= (ElemType alpha) 
    {
        if (this->IsEmpty())
            throw std::logic_error("operator+=: Matrix is empty.");
        LONG64 N=(LONG64)this->GetNumElements();
        int blocksPerGrid =(int)ceil(1.0*N/threadsPerBlock);
        cudaEvent_t done;       
        if (do_sync)    CUDA_CALL(cudaEventCreate(&done));
        _addValue<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(this->m_pArray,alpha,N);
        if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
        if (do_sync)    CUDA_CALL(cudaEventSynchronize(done));
        if (do_sync)    CUDA_CALL(cudaEventDestroy(done));
        return *this;
    }

    template<class ElemType>
    GPUMatrix<ElemType> GPUMatrix<ElemType>::operator+ (ElemType alpha) const
    {
        if (this->IsEmpty())
            throw std::logic_error("operator+: Matrix is empty.");

        const GPUMatrix<ElemType>& us=*this;
        GPUMatrix<ElemType> c(us);
        c+=alpha;
        return c;
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::AssignSumOf(const ElemType alpha, const GPUMatrix<ElemType>& a)
    {
        this->SetValue(a);
        (*this)+=alpha;
        return (*this);
    }


    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::operator+= (const GPUMatrix<ElemType>& a) 
    {
        //if (a.GetNumElements()==1)
        //{
        //    //*this += a.Get00Element();
        //    LONG64 N=(LONG64)GetNumElements();
        //    int blocksPerGrid =(int)ceil(1.0*N/threadsPerBlock);
        //    cudaEvent_t done;       
        //    if (do_sync)    CUDA_CALL(cudaEventCreate(&done));
        //    _addValue<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(m_pArray,a.m_pArray,N);
        //    if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
        //    if (do_sync)    CUDA_CALL(cudaEventSynchronize(done));
        //    if (do_sync)    CUDA_CALL(cudaEventDestroy(done));
        //}
        //else 
        //{
            ScaleAndAdd(1, a, *this);
        //}
        return *this;
    }

    template<class ElemType>
    GPUMatrix<ElemType> GPUMatrix<ElemType>::operator+ (const GPUMatrix<ElemType>& a) const
    {
        if (this->GetNumElements()==1)
        {
            GPUMatrix<ElemType> c(a);
            c+=this->Get00Element();
            return c;
        }
        else if (a.GetNumElements()==1)
        {
            GPUMatrix<ElemType> c(*this);
            c+=a.Get00Element();
            return c;
        }
        else
        {
            GPUMatrix<ElemType> c(*this); //this implementation will introduce a copy overhead. but make resue of the code
            c += a;
            return c;
        }
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::AssignSumOf(const GPUMatrix<ElemType>& a, const GPUMatrix<ElemType>& b)
    {
        this->SetValue(a);
        (*this)+=b;
        return (*this);
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::operator-= (ElemType alpha) 
    {
        if (this->IsEmpty())
            throw std::logic_error("operato-=: Matrix is empty.");
        return this->operator+=(-1*alpha);        
    }

    template<class ElemType>
    GPUMatrix<ElemType> GPUMatrix<ElemType>::operator- (ElemType alpha) const
    {
        if (this->IsEmpty())
            throw std::logic_error("operator-: Matrix is empty.");
        return this->operator+(-1*alpha);
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::AssignDifferenceOf(const ElemType alpha, const GPUMatrix<ElemType>& a)
    {
        this->Resize(a.m_numRows,a.m_numCols);
        LONG64 N=(LONG64)this->GetNumElements();
        int blocksPerGrid =(int)ceil(1.0*N/threadsPerBlock);
        a.PrepareDevice();
        cudaEvent_t done;       
        if (do_sync)    CUDA_CALL(cudaEventCreate(&done));
        _assignDifferenceOf1<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(this->m_pArray,alpha,a.m_pArray,N);
        if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
        if (do_sync)    CUDA_CALL(cudaEventSynchronize(done));
        if (do_sync)    CUDA_CALL(cudaEventDestroy(done));
        return *this;
        /*this->Resize(a.m_numRows,a.m_numCols);
        this->SetValue(alpha);
        (*this)-=a;
        return *this;*/
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::AssignDifferenceOf(const GPUMatrix<ElemType>& a, const ElemType alpha)
    {
        this->Resize(a.m_numRows,a.m_numCols);
        LONG64 N=(LONG64)this->GetNumElements();
        int blocksPerGrid =(int)ceil(1.0*N/threadsPerBlock);
        a.PrepareDevice();
        cudaEvent_t done;       
        if (do_sync)    CUDA_CALL(cudaEventCreate(&done));
        _assignDifferenceOf2<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(this->m_pArray,alpha,a.m_pArray,N);
        if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
        if (do_sync)    CUDA_CALL(cudaEventSynchronize(done));
        if (do_sync)    CUDA_CALL(cudaEventDestroy(done));
        return *this;
        /*this->SetValue(a);
        (*this)-=alpha;
        return *this;*/
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::operator-= (const GPUMatrix<ElemType>& a)
    {
        //if (a.GetNumElements() == 1)
        //    AssignDifferenceOf(*this, a.Get00Element());
        //else if (GetNumElements() == 1)
        //    AssignDifferenceOf(this->Get00Element(), a);
        //else
            ScaleAndAdd(-1, a, *this);

        return *this;
    }

    template<class ElemType>
    GPUMatrix<ElemType> GPUMatrix<ElemType>::operator- (const GPUMatrix<ElemType>& a) const
    {
        GPUMatrix<ElemType> c(*this); //this implementation will introduce a copy overhead. but make resue of the code
        c -= a;
        return c;
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::AssignDifferenceOf(const GPUMatrix<ElemType>& a, const GPUMatrix<ElemType>& b)
    {
        if (this != &a)
        {
            Resize(a.GetNumRows(), a.GetNumCols());
            SetValue(a);
        }
        (*this) -= b;
        return *this;
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::operator*= (ElemType alpha)
    {
        Scale(alpha, *this);
        return *this;
    }

    template<class ElemType>
    GPUMatrix<ElemType> GPUMatrix<ElemType>::operator* (ElemType alpha) const
    {
        GPUMatrix<ElemType> c(this->GetNumRows(), this->GetNumCols());
        Scale(alpha, *this, c);
        return c;
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::AssignProductOf(const ElemType alpha, const GPUMatrix<ElemType>& a)
    {
        Scale(alpha, a, *this);
        return *this;
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::AssignProductOf (const GPUMatrix<ElemType>& a, const bool transposeA, const GPUMatrix<ElemType>& b, const bool transposeB)
    {
        if (a.GetNumElements() == 1)
        {  
            if (transposeB)
                AssignTransposeOf(b);
            (*this) *= a.Get00Element();
        }
        else if (b.GetNumElements() == 1)
        { 
            if (transposeA)
                AssignTransposeOf(a);
            (*this) *= b.Get00Element();
        }
        else
            Multiply(a, transposeA, b, transposeB, *this);
        return *this;
    }

    template<class ElemType>
    GPUMatrix<ElemType> GPUMatrix<ElemType>::operator* (const GPUMatrix<ElemType>& a) const
    {
        const GPUMatrix<ElemType>& us = *this;
        if (this->GetNumElements() == 1)
        {
            GPUMatrix<ElemType> c(this->GetComputeDeviceId());
            c.AssignProductOf(this->Get00Element(), a);
            return c;
        }
        else if (a.GetNumElements() == 1)
        {
            GPUMatrix<ElemType> c(this->GetComputeDeviceId());
            c.AssignProductOf(a.Get00Element(), us);
            return c;
        }
        else
        {
            GPUMatrix<ElemType> c(this->GetNumRows(),a.GetNumCols(),this->GetComputeDeviceId());
            Multiply(*this, a, c);
            return c;
        }
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::operator/= (ElemType alpha)
    {
        (*this) *= 1/alpha;
        return (*this);
    }

    template<class ElemType>
    GPUMatrix<ElemType> GPUMatrix<ElemType>::operator/ (ElemType alpha) const
    {
        return ((*this) * (1/alpha));
    }

    //element-wise power
    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::operator^= (ElemType alpha)
    {
        GPUMatrix<ElemType>& us = *this;
        ElementWisePower(alpha, us, us);
        return us;
    }

    template<class ElemType>
    GPUMatrix<ElemType> GPUMatrix<ElemType>::operator^ (ElemType alpha) const
    {
        GPUMatrix<ElemType> c(this->GetNumRows(), this->GetNumCols());
        ElementWisePower(alpha, *this, c);
        return c;
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::AssignElementPowerOf(const GPUMatrix<ElemType>& a, const ElemType power)
    {
        ElementWisePower(power, a, *this);
        return *this;
    }


    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::AddElementProductOf (const GPUMatrix<ElemType>& a, const GPUMatrix<ElemType>& b)
    {
        if (a.IsEmpty() || b.IsEmpty())
            throw std::logic_error("AddElementProductOf: Matrix is empty.");

        assert (a.GetNumRows() == b.GetNumRows() && a.GetNumCols() == b.GetNumCols());
        if (!(a.GetNumRows() == b.GetNumRows() && a.GetNumCols() == b.GetNumCols()))
            throw std::invalid_argument("The input matrix dimensions do not match.");

        if (!(a.GetNumRows() == this->GetNumRows() && a.GetNumCols() == this->GetNumCols()))
            throw std::invalid_argument("The input matrix dimensions do not match [this].");

        LONG64 N=(LONG64)this->GetNumElements();
        int blocksPerGrid =(int)ceil(1.0*N/threadsPerBlock);    
        a.PrepareDevice();
        cudaEvent_t done;       
        if (do_sync)    CUDA_CALL(cudaEventCreate(&done));        
        _addElementProductOf<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(this->m_pArray,a.m_pArray,b.m_pArray,N);
        if (do_sync)    CUDA_CALL(cudaEventRecord(done));      
        if (do_sync)    CUDA_CALL(cudaEventSynchronize(done));
        if (do_sync)    CUDA_CALL(cudaEventDestroy(done));
        return *this;
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::ColumnElementMultiplyWith(const GPUMatrix<ElemType>& a)
    {
        if (a.IsEmpty() || this->IsEmpty())
            throw std::logic_error("ColumnElementMultiplyWith: Matrix is empty.");

        if (!(a.GetNumRows() == this->GetNumRows() && a.GetNumCols() == 1))
            throw std::invalid_argument("ColumnElementMultiplyWith: The input matrix should be a col vector and match [this]'s rows.");

        long N=(long)a.GetNumRows();
        long M=(long)this->GetNumCols();        
        int blocksPerGrid =(int)ceil(1.0*N/threadsPerBlock);  
        a.PrepareDevice();
        cudaEvent_t done;       
        if (do_sync)    CUDA_CALL(cudaEventCreate(&done));        
        _columnElementMultiplyWith<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(this->m_pArray,a.m_pArray,N,M);
        if (do_sync)    CUDA_CALL(cudaEventRecord(done));      
        if (do_sync)    CUDA_CALL(cudaEventSynchronize(done));
        if (do_sync)    CUDA_CALL(cudaEventDestroy(done));

        return *this;
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::RowElementMultiplyWith(const GPUMatrix<ElemType>& a)
    {
        if (a.IsEmpty() || this->IsEmpty())
            throw std::logic_error("RowElementMultiplyWith: Matrix is empty.");

        if (!(a.GetNumRows() == 1 && a.GetNumCols() == this->GetNumCols()))
            throw std::invalid_argument("RowElementMultiplyWith: The input matrix should be a row vector and match [this]'s columns.");

        long N=(long)a.GetNumRows();
        long M=(long)this->GetNumCols();        
        int blocksPerGrid =(int)ceil(1.0*N/threadsPerBlock);  
        a.PrepareDevice();
        cudaEvent_t done;       
        if (do_sync)    CUDA_CALL(cudaEventCreate(&done));        
        _rowElementMultiplyWith<ElemType><<<blocksPerGrid,threadsPerBlock>>>(this->m_pArray,a.m_pArray,N,M);
        if (do_sync)    CUDA_CALL(cudaEventRecord(done));      
        if (do_sync)    CUDA_CALL(cudaEventSynchronize(done));
        if (do_sync)    CUDA_CALL(cudaEventDestroy(done));

        return *this;
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::ElementInverse ()
    {
        if (this->IsEmpty())
            throw std::logic_error("ElementInverse: Matrix is empty.");

        LONG64 N=(LONG64)this->GetNumElements();
        int blocksPerGrid =(int)ceil(1.0*N/threadsPerBlock);  
        PrepareDevice();
        cudaEvent_t done;       
        if (do_sync)    CUDA_CALL(cudaEventCreate(&done));        
        _elemInverse<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(this->m_pArray,N);
        if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
        if (do_sync)    CUDA_CALL(cudaEventSynchronize(done));     
        if (do_sync)    CUDA_CALL(cudaEventDestroy(done));
        return *this;
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::AssignElementInverseOf (const GPUMatrix<ElemType>& a)
    {
        this->SetValue(a);
        return this->ElementInverse();
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::InplaceSigmoid()
    {
        performInplaceFunction(0);                    
        return *this;
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::AssignSigmoidOf (const GPUMatrix<ElemType>& a)
    {
        this->Resize(a.GetNumRows(),a.GetNumCols());
        LONG64 N=(LONG64)this->GetNumElements();
        int blocksPerGrid =(int)ceil(1.0*N/threadsPerBlock);
        PrepareDevice();
        cudaEvent_t done;       
        if (do_sync)    CUDA_CALL(cudaEventCreate(&done));
        _assignSigmoidOf<<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(a.m_pArray,this->m_pArray,N);
        if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
        if (do_sync)    CUDA_CALL(cudaEventSynchronize(done));
        if (do_sync)    CUDA_CALL(cudaEventDestroy(done));
        /*this->SetValue(a);
        this->InplaceSigmoid();*/
        return *this;
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::InplaceSigmoidDerivative()
    {
        AssignSigmoidDerivativeOf(*this);                    
        return *this;
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::AssignSigmoidDerivativeOf (const GPUMatrix<ElemType>& a)
    {
        if (a.IsEmpty())
            throw std::logic_error("AssignSigmoidDerivativeOf: Matrix a is empty.");

        //auto& us=*this;
        if (this != &a)
            Resize(a.GetNumRows(), a.GetNumCols());

        PrepareDevice();
        LONG64 N=(LONG64)this->GetNumElements();
        int blocksPerGrid =(int)ceil(1.0*N/threadsPerBlock);                
        cudaEvent_t done;       
        if (do_sync)    CUDA_CALL(cudaEventCreate(&done));        

        _assignSigmoidDerivative<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(a.m_pArray, this->m_pArray, N);
        if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
        if (do_sync)    CUDA_CALL(cudaEventSynchronize(done)); 
        if (do_sync)    CUDA_CALL(cudaEventDestroy(done));
        return *this;
    }


    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::InplaceTanh()
    {
        performInplaceFunction(1);
        return *this;
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::AssignTanhOf (const GPUMatrix<ElemType>& a)
    {
        this->SetValue(a);
        this->InplaceTanh();
        return *this;
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::InplaceSoftmax (const bool isColWise)
    {
        if (this->IsEmpty())
            throw std::logic_error("InplaceSoftmax: Matrix is empty.");

        PrepareDevice();
        if (isColWise)
        {
            long N=(long)this->GetNumCols(); //one kernel per column
            int blocksPerGrid =(int)ceil(N*1.0/threadsPerBlock);             
            cudaEvent_t done;      
            if (do_sync)    CUDA_CALL(cudaEventCreate(&done));
            _softMaxColWise<<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(this->m_pArray,(long)this->m_numCols,(long)this->m_numRows);
            if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
            if (do_sync)    CUDA_CALL(cudaEventSynchronize(done));  
            if (do_sync)    CUDA_CALL(cudaEventDestroy(done));
        }
        else
        {
            long N=(long)this->GetNumRows(); //one kernel per column
            int blocksPerGrid =(int)ceil(N*1.0/threadsPerBlock);                
            cudaEvent_t done;       
            if (do_sync)    CUDA_CALL(cudaEventCreate(&done));
            _softMaxRowWise<<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(this->m_pArray,(long)this->m_numCols,(long)this->m_numRows);
            if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
            if (do_sync)    CUDA_CALL(cudaEventSynchronize(done));
            if (do_sync)    CUDA_CALL(cudaEventDestroy(done));
        }
        return *this; 
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::AssignSoftmaxOf (const GPUMatrix<ElemType>& a, const bool isColWise)
    {
        this->Resize(a.GetNumRows(),a.GetNumCols());        
        if (isColWise)
        {            
            PrepareDevice();
            long N = (long)this->GetNumCols();
            long M = (long)this->GetNumRows();
            cudaEvent_t done;       
            if (do_sync)    CUDA_CALL(cudaEventCreate(&done));
            _assignColumnwiseSoftmaxOf<<<N,512,0,t_stream>>>(a.m_pArray,this->m_pArray,N,M);
            if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
            if (do_sync)    CUDA_CALL(cudaEventSynchronize(done)); 
            if (do_sync)    CUDA_CALL(cudaEventDestroy(done));
        }
        else
        {
            NOT_IMPLEMENTED;
        }

        /*this->SetValue(a);
        this->InplaceSoftmax(isColWise);*/
        return *this;
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::InplaceSqrt()
    {
        performInplaceFunction(2);        
        return *this;
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::AssignSqrtOf (const GPUMatrix<ElemType>& a)
    {
        this->SetValue(a);
        this->InplaceSqrt();
        return *this;
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::InplaceExp()
    {
        performInplaceFunction(3);        
        return *this;
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::AssignExpOf (const GPUMatrix<ElemType>& a)
    {
        this->SetValue(a);
        this->InplaceExp();
        return *this;
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::InplaceLog()
    {
        performInplaceFunction(4);        
        return *this;
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::AssignLogOf (const GPUMatrix<ElemType>& a)
    {
        this->SetValue(a);
        this->InplaceLog();
        return *this;
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::InplaceAbs()
    {
        performInplaceFunction(5);        
        return *this;
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::AssignAbsOf (const GPUMatrix<ElemType>& a)
    {
        this->SetValue(a);
        this->InplaceAbs();
        return *this;
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::InplaceLinearRectifierDerivative()
    {
        performInplaceFunction(6);                    
        return *this;
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::AssignLinearRectifierDerivativeOf (const GPUMatrix<ElemType>& a)
    {
        this->SetValue(a);
        this->InplaceLinearRectifierDerivative();
        return *this;
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::InplaceCosine()
    {
        performInplaceFunction(7);        
        return *this;
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::AssignCosineOf (const GPUMatrix<ElemType>& a)
    {
        this->SetValue(a);
        this->InplaceCosine();
        return *this;
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::InplaceNegativeSine()
    {
        performInplaceFunction(8);        
        return *this;
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::AssignNegativeSineOf (const GPUMatrix<ElemType>& a)
    {
        this->SetValue(a);
        this->InplaceNegativeSine();
        return *this;
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::InplaceTruncateBottom (const ElemType threshold)
    {
        if (this->IsEmpty())
            throw std::logic_error("InplaceTruncateBottom: Matrix is empty.");    

        LONG64 N=(LONG64)this->GetNumElements();
        int blocksPerGrid =(int)ceil(N*1.0/threadsPerBlock); 
        PrepareDevice();
        cudaEvent_t done;       
        if (do_sync)    CUDA_CALL(cudaEventCreate(&done));        
        _inplaceTruncateBottom<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(this->m_pArray,threshold,N);
        if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
        if (do_sync)    CUDA_CALL(cudaEventSynchronize(done)); 
        if (do_sync)    CUDA_CALL(cudaEventDestroy(done));
        return *this;
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::AssignTruncateBottomOf (const GPUMatrix<ElemType>& a, const ElemType threshold)
    {
        if (a.IsEmpty())
            throw std::logic_error("AssignTruncateBottomOf: Matrix a is empty.");

        if (this!=&a)
        {
            Resize(a.GetNumRows(), a.GetNumCols());
        }

        LONG64 N=(LONG64)this->GetNumElements();
        int blocksPerGrid =(int)ceil(N*1.0/threadsPerBlock);      
        PrepareDevice();
        cudaEvent_t done;       
        if (do_sync)    CUDA_CALL(cudaEventCreate(&done));        
        _assignTruncateBottom<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(this->m_pArray,a.m_pArray,threshold,N);
        if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
        if (do_sync)    CUDA_CALL(cudaEventSynchronize(done));
        if (do_sync)    CUDA_CALL(cudaEventDestroy(done));

        return *this;
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::InplaceTruncateTop (const ElemType threshold)
    {
        if (this->IsEmpty())
            throw std::logic_error("InplaceTruncateTop: Matrix is empty.");
        LONG64 N=(LONG64)this->GetNumElements();
        int blocksPerGrid =(int)ceil(N*1.0/threadsPerBlock);      
        PrepareDevice();
        cudaEvent_t done;       
        if (do_sync)    CUDA_CALL(cudaEventCreate(&done));        
        _inplaceTruncateTop<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(this->m_pArray,threshold,N);
        if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
        if (do_sync)    CUDA_CALL(cudaEventSynchronize(done)); 
        if (do_sync)    CUDA_CALL(cudaEventDestroy(done));
        return *this;        
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::AssignTruncateTopOf (const GPUMatrix<ElemType>& a, const ElemType threshold)
    {
        if (a.IsEmpty())
            throw std::logic_error("AssignTruncateTopOf: Matrix a is empty.");

        if (this!=&a)
        {
            Resize(a.GetNumRows(), a.GetNumCols());
        }

        LONG64 N=(LONG64)this->GetNumElements();
        int blocksPerGrid =(int)ceil(N*1.0/threadsPerBlock); 
        a.PrepareDevice();
        cudaEvent_t done;       
        if (do_sync)    CUDA_CALL(cudaEventCreate(&done));        
        _assignTruncateTop<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(this->m_pArray,a.m_pArray,threshold,N);
        if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
        if (do_sync)    CUDA_CALL(cudaEventSynchronize(done));
        if (do_sync)    CUDA_CALL(cudaEventDestroy(done));

        return *this;        
    }
    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::SetToZeroIfAbsLessThan (const ElemType threshold)
    {
        if (this->IsEmpty())
            throw std::logic_error("SetToZeroIfAbsLessThan: Matrix is empty.");
        LONG64 N=(LONG64)this->GetNumElements();
        int blocksPerGrid =(int)ceil(N*1.0/threadsPerBlock); 
        PrepareDevice();
        cudaEvent_t done;       
        if (do_sync)    CUDA_CALL(cudaEventCreate(&done));        
        _setToZeroIfAbsLessThan<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(this->m_pArray,threshold,N);
        if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
        if (do_sync)    CUDA_CALL(cudaEventSynchronize(done)); 
        if (do_sync)    CUDA_CALL(cudaEventDestroy(done));
        return *this;  
    }

    template<class ElemType>
    ElemType GPUMatrix<ElemType>::SumOfAbsElements() const
    {
        if (this->IsEmpty())
            throw std::logic_error("SumOfAbsElements: Matrix is empty");

        cublasHandle_t cuHandle = GetCublasHandle(GetComputeDeviceId());          
        if (sizeof(ElemType)==sizeof(float))
        {
            float res=0;
            cublasSasum(cuHandle,(LONG64)this->GetNumElements(),reinterpret_cast<float*>(this->m_pArray),1,&res);
            return res;
        }
        else
        {
            double res=0;
            cublasDasum(cuHandle,(LONG64)this->GetNumElements(),reinterpret_cast<double*>(this->m_pArray),1,&res);
            return ElemType(res);
        }         
    }

    template<class ElemType>
    ElemType GPUMatrix<ElemType>::SumOfElements() const
    {
        if (this->IsEmpty())
            throw std::logic_error("SumOfElements: Matrix is empty");

        PrepareDevice();
        ElemType* d_sum = NULL;
        ElemType h_sum;
        CUDA_CALL(cudaMalloc((void**)&d_sum,sizeof(ElemType)));
        //WARNING: THIS kernel is not the most efficient way!
        _reductionSum<ElemType><<<1,1024,0,t_stream>>>(this->m_pArray,d_sum,(LONG64)this->GetNumElements());
        CUDA_CALL(cudaMemcpy(&h_sum,d_sum,sizeof(ElemType),cudaMemcpyDeviceToHost));
        CUDA_CALL(cudaFree(d_sum));               
        return h_sum;        
    }

    
    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::AssignSumOfElements(const GPUMatrix<ElemType>& a)
    {
        if (a.IsEmpty())
            throw std::logic_error("AssignSumOfElements: Matrix a is empty");

        this->Resize(1,1);

        PrepareDevice();     
        cudaEvent_t done;
        if (do_sync)    CUDA_CALL(cudaEventCreate(&done));
        //WARNING: THIS kernel is not the most efficient way!
        _reductionSumAndAssign<ElemType><<<1,1024>>>(this->m_pArray,a.m_pArray,(LONG64)a.GetNumElements(),(LONG64)this->GetNumElements());
        if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
        if (do_sync)    CUDA_CALL(cudaEventSynchronize(done));
        if (do_sync)    CUDA_CALL(cudaEventDestroy(done));
        return (*this);
    }

    template<class ElemType>
    DeviceBoundNumber<ElemType> GPUMatrix<ElemType>::Sum_AsDeviceBoundNum() const
    {
        if (this->IsEmpty())
            throw std::logic_error("Matrix is empty");
        PrepareDevice();
        ElemType* d_sum = NULL;        
        CUDA_CALL(cudaMalloc((void**)&d_sum,sizeof(ElemType)));
        //WARNING: THIS kernel is not the most efficient way!
        _reductionSum<ElemType><<<1,1024,0,t_stream>>>(this->m_pArray,d_sum,(LONG64)this->GetNumElements());
        DeviceBoundNumber<ElemType> result;
        result.ShallowCopyFrom(d_sum,GetComputeDeviceId());
        return result;
    }

    template<class ElemType>
    ElemType GPUMatrix<ElemType>::Max() const
    {
        cublasHandle_t cuHandle = GetCublasHandle(GetComputeDeviceId());   
        ElemType res;
        if (sizeof(ElemType)==sizeof(float))
        {
            int resInd=0;
            cublasIsamax(cuHandle,(LONG64)this->GetNumElements(),reinterpret_cast<float*>(this->m_pArray),1,&resInd); 
            resInd--;
            CUDA_CALL(cudaMemcpy(reinterpret_cast<float*>(&res),reinterpret_cast<float*>(this->m_pArray+resInd),sizeof(float),cudaMemcpyDeviceToHost));
            return res;
        }
        else
        {
            int resInd=0;
            cublasIdamax(cuHandle,(LONG64)this->GetNumElements(),reinterpret_cast<double*>(this->m_pArray),1,&resInd);
            resInd--;
            CUDA_CALL(cudaMemcpy(reinterpret_cast<double*>(&res),this->m_pArray+resInd,sizeof(float),cudaMemcpyDeviceToHost));
            return res;
        }        
    }


    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::ElementMultiplyWith (const GPUMatrix<ElemType>& a)
    {
        if (this->IsEmpty() || a.IsEmpty())
            throw std::logic_error("ElementMultiplyWith: Matrix is empty.");

        GPUMatrix<ElemType>& us=*this;
        assert (us.GetNumRows() == a.GetNumRows() && us.GetNumCols() == a.GetNumCols());
        if (us.GetNumRows() != a.GetNumRows() || us.GetNumCols() != a.GetNumCols())
            throw std::invalid_argument("The matrix dimensions do not match.");

        LONG64 N=(LONG64)this->GetNumElements();
        int blocksPerGrid =(int)ceil(((double)N)/threadsPerBlock); 
        a.PrepareDevice();
        cudaEvent_t done;       
        if (do_sync)    CUDA_CALL(cudaEventCreate(&done));        
        _elemMul<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(this->m_pArray,a.m_pArray,N);
        if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
        if (do_sync)    CUDA_CALL(cudaEventSynchronize(done)); 
        if (do_sync)    CUDA_CALL(cudaEventDestroy(done));
        return *this;
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::AssignElementProductOf (const GPUMatrix<ElemType>& a, const GPUMatrix<ElemType>& b)
    {
        if (a.IsEmpty() || b.IsEmpty())
            throw std::logic_error("AssignElementProductOf: Matrix is empty.");

        assert (a.GetNumRows() == b.GetNumRows() && a.GetNumCols() == b.GetNumCols());
        if (!(a.GetNumRows() == b.GetNumRows() && a.GetNumCols() == b.GetNumCols()))
            throw std::invalid_argument("The input matrix dimensions do not match.");

        Resize(a.GetNumRows(), a.GetNumCols());
        LONG64 N=(LONG64)this->GetNumElements();
        int blocksPerGrid =(int)ceil(((double)N)/threadsPerBlock);  
        a.PrepareDevice();
        cudaEvent_t done;       
        if (do_sync)    CUDA_CALL(cudaEventCreate(&done));        
        _assignElementProductOf<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(this->m_pArray,a.m_pArray,b.m_pArray,N);
        if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
        if (do_sync)    CUDA_CALL(cudaEventSynchronize(done)); 
        if (do_sync)    CUDA_CALL(cudaEventDestroy(done));
        return *this;
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::AssignElementDivisionOf (const GPUMatrix<ElemType>& a, const GPUMatrix<ElemType>& b)
    {
        if (a.IsEmpty() || b.IsEmpty())
            throw std::logic_error("AssignElementDivisionOf: Matrix is empty.");

        assert (a.GetNumRows() == b.GetNumRows() && a.GetNumCols() == b.GetNumCols());
        if (!(a.GetNumRows() == b.GetNumRows() && a.GetNumCols() == b.GetNumCols()))
            throw std::invalid_argument("The input matrix dimensions do not match.");

        Resize(a.GetNumRows(), a.GetNumCols());
        LONG64 N=(LONG64)this->GetNumElements();
        int blocksPerGrid =(int)ceil(((double)N)/threadsPerBlock);  
        a.PrepareDevice();
        cudaEvent_t done;       
        if (do_sync)    CUDA_CALL(cudaEventCreate(&done));        
        _assignElementDivisionOf<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(this->m_pArray,a.m_pArray,b.m_pArray,N);
        if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
        if (do_sync)    CUDA_CALL(cudaEventSynchronize(done)); 
        if (do_sync)    CUDA_CALL(cudaEventDestroy(done));
        return *this;
    }

    template<class ElemType>
    bool GPUMatrix<ElemType>::IsEqualTo(const GPUMatrix<ElemType>& a, const ElemType threshold /*= 1e-8*/) const
    {
        return AreEqual(*this, a, threshold);
    }

    template<class ElemType>
    void GPUMatrix<ElemType>::VectorNorm1(GPUMatrix<ElemType>& c, const bool isColWise) const
    {
        if (this->IsEmpty())
            throw std::logic_error("VectorNorm1: Matrix is empty.");

        const long n = (long)this->GetNumRows();
        const long m = (long)this->GetNumCols();
        assert (m>0 && n>0); //converting from size_t to int may cause overflow

        cudaEvent_t done;  
        PrepareDevice();
        c.ChangeDeviceTo(GetComputeDeviceId());

        int blocksPerGrid=0;
        if (isColWise)  //col-wise
        {
            c.Resize(1,m);   
            blocksPerGrid =(int)ceil(1.0*m/threadsPerBlock);                                        
        }
        else
        {
            c.Resize(n, 1);
            c.ChangeDeviceTo(GetComputeDeviceId());
            blocksPerGrid =(int)ceil(1.0*n/threadsPerBlock);                        
        }       

        if (do_sync)    CUDA_CALL(cudaEventCreate(&done));  
        _vectorNorm1<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(c.m_pArray, this->m_pArray,n,m,isColWise);
        if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
        if (do_sync)    CUDA_CALL(cudaEventSynchronize(done));
        if (do_sync)    CUDA_CALL(cudaEventDestroy(done));
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::AssignVectorNorm1Of(GPUMatrix<ElemType>& a, const bool isColWise)
    {
        a.VectorNorm1(*this, isColWise);
        return *this;
    }

    template<class ElemType>
    void GPUMatrix<ElemType>::VectorNorm2(GPUMatrix<ElemType>& c, const bool isColWise) const
    {
        if (this->IsEmpty())
            throw std::logic_error("VectorNorm2: Matrix is empty.");

        const long n = (long)this->GetNumRows();
        const long m = (long)this->GetNumCols();
        assert (m>0 && n>0); //converting from size_t to int may cause overflow

        cudaEvent_t done;  
        PrepareDevice();
        c.ChangeDeviceTo(GetComputeDeviceId());

        int blocksPerGrid=0;
        if (isColWise)  //col-wise
        {
            c.Resize(1,m);   
            blocksPerGrid =(int)ceil(1.0*m/threadsPerBlock);                                        
        }
        else
        {
            c.Resize(n, 1);
            c.ChangeDeviceTo(GetComputeDeviceId());
            blocksPerGrid =(int)ceil(1.0*n/threadsPerBlock);                        
        }       

        if (do_sync)    CUDA_CALL(cudaEventCreate(&done));  
        _vectorNorm2<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(c.m_pArray, this->m_pArray,n,m,isColWise);
        if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
        if (do_sync)    CUDA_CALL(cudaEventSynchronize(done));
        if (do_sync)    CUDA_CALL(cudaEventDestroy(done));
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::AssignVectorNorm2Of(GPUMatrix<ElemType>& a, const bool isColWise)
    {
        a.VectorNorm2(*this, isColWise);
        return *this;
    }

    template<class ElemType>
    void GPUMatrix<ElemType>::VectorNormInf(GPUMatrix<ElemType>& c, const bool isColWise) const
    {
        if (this->IsEmpty())
            throw std::logic_error("VectorMax: Matrix is empty.");

        //this implementation is not efficient
        GPUMatrix<ElemType> tmp;
        GPUMatrix<ElemType> tmp1;
        tmp.AssignAbsOf((*this));
        tmp.VectorMax(tmp1,c,isColWise);
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::AssignVectorNormInfOf(GPUMatrix<ElemType>& a, const bool isColWise)
    {
        a.VectorNormInf(*this, isColWise);
        return *this;
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::AssignInnerProductOf(const GPUMatrix<ElemType>& a, const GPUMatrix<ElemType>& b, const bool isColWise)
    {
        InnerProduct (a, b, *this,isColWise);
        return *this;
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::AssignKhatriRaoProductOf(const GPUMatrix<ElemType>& a, const GPUMatrix<ElemType>& b)
    {
        if (a.IsEmpty() || b.IsEmpty())
            throw std::logic_error("AssignKhatriRaoProductOf: Matrix is empty.");

        long cols = a.GetNumCols();
        assert (cols == b.GetNumCols());
        if (!(cols == b.GetNumCols()))
            throw std::invalid_argument("AssignKhatriRaoProductOf: The input matrix dimensions do not match.");

        long rowsA = (long)a.GetNumRows();
        long rowsB = (long)b.GetNumRows();
        Resize(rowsA * rowsB, cols);
        float N=(float)this->GetNumElements();
        int blocksPerGrid =(int)ceil(N/threadsPerBlock);  
        a.PrepareDevice();
        cudaEvent_t done;       
        if (do_sync)    CUDA_CALL(cudaEventCreate(&done));        
        _assignKhatriRaoProductOf<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(this->m_pArray,a.m_pArray,b.m_pArray,rowsA, rowsB, cols);
        if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
        if (do_sync)    CUDA_CALL(cudaEventSynchronize(done)); 
        if (do_sync)    CUDA_CALL(cudaEventDestroy(done));

        return *this;
    }

    //column-wise reshaped product. Used to compute KhatriRaoProduct Gradient
    //   this = reshape each column of a from (K1xK2,1) to (K1, K2) 
    //   if each column of a is not transposed, each (K1, K2) times each column of b (K2, frames).
    //   the output is a (K1, frames) matrix
    //   if each column of a is tranposed, each (K1, K2)^T times each column of b(K1, frames) and output is (K2, frames)
    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::AddColumnReshapeProductOf(const GPUMatrix<ElemType>& a, const GPUMatrix<ElemType>& b, const bool transposeAColumn)
    {
        if (a.IsEmpty() || b.IsEmpty())
            throw std::logic_error("AddColumnReshapeProductOf: Matrix is empty.");

        long cols = a.GetNumCols();
        assert (cols == b.GetNumCols());
        if (!(cols == b.GetNumCols()))
            throw std::invalid_argument("AddColumnReshapeProductOf: The input matrix dimensions do not match.");

        long rowsA = (long)a.GetNumRows();
        long rowsB = (long)b.GetNumRows();
        if (rowsA % rowsB != 0)
            throw std::invalid_argument("AddColumnReshapeProductOf: number of rows in a should be multiples of that in b.");

        long rowsC = rowsA / rowsB;
        if (rowsC != this->GetNumRows() || cols != this->GetNumCols())
            throw  std::invalid_argument("AddColumnReshapeProductOf: This matrix does not have the right size.");

        float N=(float)this->GetNumElements();
        int blocksPerGrid =(int)ceil(N/threadsPerBlock);  
        a.PrepareDevice();
        cudaEvent_t done;       
        if (do_sync)    CUDA_CALL(cudaEventCreate(&done));        
        _addColumnReshapeProductOf<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(this->m_pArray,a.m_pArray,b.m_pArray, rowsB, rowsC, cols, transposeAColumn);
        if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
        if (do_sync)    CUDA_CALL(cudaEventSynchronize(done)); 
        if (do_sync)    CUDA_CALL(cudaEventDestroy(done));

        return *this;
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::AddWithScaleOf(ElemType alpha, const GPUMatrix<ElemType>& a)
    {
        ScaleAndAdd(alpha, a, *this);
        return *this;
    }

    template<class ElemType>
    ElemType GPUMatrix<ElemType>::FrobeniusNorm() const
    {
        if (this->IsEmpty())
            throw std::logic_error("FrobeniusNorm: Matrix is empty.");

        PrepareDevice();
        ElemType* d_sum = NULL;
        ElemType h_sum=0;
        CUDA_CALL(cudaMalloc((void**)&d_sum,sizeof(ElemType)));
        //WARNING: THIS kernel is not the most efficient way!
        _reductionSum2<ElemType><<<1,1024,0,t_stream>>>(this->m_pArray,d_sum,(LONG64)this->GetNumElements(), true);
        CUDA_CALL(cudaMemcpy(&h_sum,d_sum,sizeof(ElemType),cudaMemcpyDeviceToHost));
        CUDA_CALL(cudaFree(d_sum));               

        return (h_sum); 
    }
    
    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::AssignFrobeniusNormOf (const GPUMatrix<ElemType>& a)
    {
        if (a.IsEmpty())
            throw std::logic_error("AssignFrobeniusNormOf: Matrix a is empty.");

        this->Resize(1,1);        
    
        PrepareDevice();
        //WARNING: THIS kernel is not the most efficient way!
        _reductionSum2<ElemType><<<1,1024,0,t_stream>>>(a.m_pArray,this->m_pArray,(LONG64)a.GetNumElements(), true);

        return *this;
    }

    template<class ElemType>
    ElemType GPUMatrix<ElemType>::MatrixNormInf() const
    {
        if (this->IsEmpty())
            throw std::logic_error("MatrixNorm1: Matrix is empty.");

        PrepareDevice();
        ElemType* d_maxAbs = NULL;
        ElemType h_maxAbs=0;
        CUDA_CALL(cudaMalloc((void**)&d_maxAbs,sizeof(ElemType)));
        //WARNING: THIS kernel is not the most efficient way!
        _reductionMatrixNormInf<ElemType><<<1,1024,0,t_stream>>>(this->m_pArray,d_maxAbs,(LONG64)this->GetNumElements());
        CUDA_CALL(cudaMemcpy(&h_maxAbs,d_maxAbs,sizeof(ElemType),cudaMemcpyDeviceToHost));
        CUDA_CALL(cudaFree(d_maxAbs));               
        return h_maxAbs; 
    }

    template<class ElemType>
    ElemType GPUMatrix<ElemType>::MatrixNorm1() const
    {
        if (this->IsEmpty())
            throw std::logic_error("MatrixNorm1: Matrix is empty.");
        return this->SumOfAbsElements();              
    }

    template<class ElemType>
    ElemType GPUMatrix<ElemType>::MatrixNorm0() const
    {
        if (this->IsEmpty())
            throw std::logic_error("MatrixNorm0: Matrix is empty.");

        PrepareDevice();
        ElemType* d_nz = NULL;
        ElemType h_nz=0;
        CUDA_CALL(cudaMalloc((void**)&d_nz,sizeof(ElemType)));
        //WARNING: THIS kernel is not the most efficient way!
        _reductionMatrixNorm0<ElemType><<<1,1024,0,t_stream>>>(this->m_pArray,d_nz,(LONG64)this->GetNumElements());
        CUDA_CALL(cudaMemcpy(&h_nz,d_nz,sizeof(ElemType),cudaMemcpyDeviceToHost));
        CUDA_CALL(cudaFree(d_nz));               
        return h_nz; 
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::AssignSignOf(const GPUMatrix<ElemType>& a)
    {
        if (a.IsEmpty())
            throw std::logic_error("AssignSignOf: Matrix a is empty.");

        if (this != &a)
            Resize(a.GetNumRows(), a.GetNumCols());

        PrepareDevice();
        cudaEvent_t done;
        int blocksPerGrid=(int)ceil(1.0*this->GetNumElements()/threadsPerBlock);  
        if (do_sync)    CUDA_CALL(cudaEventCreate(&done));        
        _assignSignOf<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(this->m_pArray, a.m_pArray, (long)this->GetNumElements());
        if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
        if (do_sync)    CUDA_CALL(cudaEventSynchronize(done));    
        if (do_sync)    CUDA_CALL(cudaEventDestroy(done));
        return *this;
    }

    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::AddSignOf(const GPUMatrix<ElemType>& a)
    {
        if (a.IsEmpty())
            throw std::logic_error("AddSignOf: Matrix a is empty.");

        if (this != &a)
            Resize(a.GetNumRows(), a.GetNumCols());

        PrepareDevice();
        cudaEvent_t done;
        int blocksPerGrid=(int)ceil(1.0*this->GetNumElements()/threadsPerBlock);  
        if (do_sync)    CUDA_CALL(cudaEventCreate(&done));        
        _addSignOf<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(this->m_pArray, a.m_pArray, (LONG64)this->GetNumElements());
        if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
        if (do_sync)    CUDA_CALL(cudaEventSynchronize(done));    
        if (do_sync)    CUDA_CALL(cudaEventDestroy(done));
        return *this;
    }

    template<class ElemType>
    void GPUMatrix<ElemType>::VectorMax(GPUMatrix<ElemType>& maxIndexes, GPUMatrix<ElemType>& maxValues, const bool isColWise) const
    {
        if (this->IsEmpty())
            throw std::logic_error("VectorMax: Matrix is empty.");

        const GPUMatrix<ElemType>& us=*this;
        const long m = (long)this->GetNumRows();
        const long n = (long)this->GetNumCols();
        assert (m>0 && n>0); //converting from size_t to int may cause overflow
        PrepareDevice();
        cudaEvent_t done;
        if (do_sync)     CUDA_CALL(cudaEventCreate(&done));                
        if (isColWise)
        {
            maxValues.Resize(1, n);
            maxIndexes.Resize(1, n);

            int blocksPerGrid = n; //we'll have 1 block processing 1 column
            _vectorMaxMinReduce<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(us.m_pArray,maxIndexes.m_pArray,maxValues.m_pArray,m,n,true);

            /*int blocksPerGrid=(int)ceil(1.0*n/threadsPerBlock);  
            _vectorMax<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(us.m_pArray,maxIndexes.m_pArray,maxValues.m_pArray,m,n,isColWise);*/
        }
        else
        {
            maxValues.Resize(m, 1);
            maxIndexes.Resize(m, 1);
            int blocksPerGrid=(int)ceil(1.0*m/threadsPerBlock);  
            _vectorMax<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(us.m_pArray,maxIndexes.m_pArray,maxValues.m_pArray,m,n,isColWise);
        }
        if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
        if (do_sync)    CUDA_CALL(cudaEventSynchronize(done));
        if (do_sync)    CUDA_CALL(cudaEventDestroy(done));
    }

    template<class ElemType>
    void GPUMatrix<ElemType>::VectorMin(GPUMatrix<ElemType>& minIndexes, GPUMatrix<ElemType>& minValues, const bool isColWise) const
    {
        if (this->IsEmpty())
            throw std::logic_error("VectorMax: Matrix is empty.");

        const GPUMatrix<ElemType>& us=*this;
        const int m = (int)this->GetNumRows();
        const int n = (int)this->GetNumCols();

        assert (m>0 && n>0); //converting from size_t to int may cause overflow
        PrepareDevice();
        cudaEvent_t done;
        if (do_sync)    CUDA_CALL(cudaEventCreate(&done));                
        if (isColWise)
        {
            minValues.Resize(1, n);
            minIndexes.Resize(1, n);

            int blocksPerGrid = n; //we'll have 1 block processing 1 column
            _vectorMaxMinReduce<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(us.m_pArray,minIndexes.m_pArray,minValues.m_pArray,m,n,false);

            /*
            int blocksPerGrid=(int)ceil(1.0*n/threadsPerBlock);  
            _vectorMin<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(us.m_pArray,minIndexes.m_pArray,minValues.m_pArray,m,n,isColWise);*/
        }
        else
        {
            minValues.Resize(m, 1);
            minIndexes.Resize(m, 1);
            int blocksPerGrid=(int)ceil(1.0*m/threadsPerBlock);  
            _vectorMin<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(us.m_pArray,minIndexes.m_pArray,minValues.m_pArray,m,n,isColWise);
        }
        if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
        if (do_sync)    CUDA_CALL(cudaEventSynchronize(done));
        if (do_sync)    CUDA_CALL(cudaEventDestroy(done));
    }

    template<class ElemType>
    GPUMatrix<ElemType>&  GPUMatrix<ElemType>::AssignNumOfDiff(const GPUMatrix<ElemType>& a, const GPUMatrix<ElemType>& b)
    {
        if (a.GetNumRows() != b.GetNumRows() || a.GetNumCols() != b.GetNumCols())
            throw std::invalid_argument ("AssignNumOfDiff: a and b must have same dimension.");

        Resize(1,1); //result should be one element

        PrepareDevice();
        cudaEvent_t done;
        //int blocksPerGrid=(int)ceil(1.0*a.GetNumElements()/threadsPerBlock);  
        if (do_sync)    CUDA_CALL(cudaEventCreate(&done));        
        //_assignNumOfDiff<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(a.m_pArray, b.m_pArray, this->m_pArray, a.GetNumElements());
        _assignNumOfDiff<ElemType><<<1,1024,0,t_stream>>>(a.m_pArray, b.m_pArray, this->m_pArray, (LONG64)a.GetNumElements());
        if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
        if (do_sync)    CUDA_CALL(cudaEventSynchronize(done));  
        if (do_sync)    CUDA_CALL(cudaEventDestroy(done));
        return *this;
    }

#pragma endregion Member BLAS Functions    

#pragma region Other helper functions
    template<class ElemType>
    void GPUMatrix<ElemType>::Print(const char* matrixName, size_t rowStart, size_t rowEnd, size_t colStart, size_t colEnd) const
    {
        NOT_IMPLEMENTED;
    }

    template<class ElemType>
    void GPUMatrix<ElemType>::Print(const char* matrixName /*=nullptr*/) const
    {
        Print(matrixName, 0, this->GetNumRows()-1, 0, this->GetNumCols()-1);
    }

    // file I/O
    //matrixName is used to verify that correct matrix is read.
    template<class ElemType>
    void GPUMatrix<ElemType>::ReadFromFile(FILE* f, const char * matrixName) 
    {
        NOT_IMPLEMENTED;
    }

    //matrixName is used to verify that correct matrix is read.
    template<class ElemType>
    void GPUMatrix<ElemType>::WriteToFile(FILE* f, const char * matrixName) 
    {
        NOT_IMPLEMENTED;
    }

    //helpfer function used for convolution neural network 
    template<class ElemType>
    GPUMatrix<ElemType>&  GPUMatrix<ElemType>::AssignPackedConvolutionInput(const GPUMatrix<ElemType>& inputSubBatch, 
                                            const size_t inputWidth, const size_t inputHeight, const size_t inputChannels,
                                            const size_t outputWidth, const size_t outputHeight, const size_t outputChannels,
                                            const size_t kernelWidth, const size_t kernelHeight, const size_t horizontalSubsample, const size_t verticalSubsample, 
                                            const bool zeroPadding)
    {
        assert (verticalSubsample <= kernelHeight && horizontalSubsample <= kernelWidth);

        size_t packedInputRows = kernelWidth * kernelHeight * inputChannels;
        size_t packedInputColsPerSample = outputWidth * outputHeight;
        size_t smallBatchSize = inputSubBatch.GetNumCols();
        Resize(packedInputRows, packedInputColsPerSample * smallBatchSize);
        if (zeroPadding) 
            this->SetValue((ElemType)0);

        PrepareDevice();
        int numThreadPerBlock = threadsPerBlock; 
#if 1
        int blocksPerGrid = (smallBatchSize * inputWidth*inputHeight*inputChannels + numThreadPerBlock - 1)/numThreadPerBlock; 
#else
        dim3 blocksPerGrid((inputWidth*inputHeight*inputChannels + numThreadPerBlock - 1)/numThreadPerBlock, smallBatchSize);
#endif
        cudaEvent_t done;       
        if (do_sync)    CUDA_CALL(cudaEventCreate(&done));
        _assignPackedConvolutionInput<<<blocksPerGrid, numThreadPerBlock,0,t_stream>>>(this->m_pArray, 
                                            inputSubBatch.m_pArray, 
                                            smallBatchSize,
                                            inputWidth, inputHeight, inputChannels,
                                            outputWidth, outputHeight, outputChannels,
                                            kernelWidth, kernelHeight, horizontalSubsample, verticalSubsample, zeroPadding);
        if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
        if (do_sync)    CUDA_CALL(cudaEventSynchronize(done)); 
        if (do_sync)    CUDA_CALL(cudaEventDestroy(done));

        return *this;
    }

    //helpfer function used for convolution neural network 
    template<class ElemType>
    GPUMatrix<ElemType>&  GPUMatrix<ElemType>::UnpackConvolutionInput(GPUMatrix<ElemType>& inputSubBatch, 
                                            const size_t inputWidth, const size_t inputHeight, const size_t inputChannels,
                                            const size_t outputWidth, const size_t outputHeight, const size_t outputChannels,
                                            const size_t kernelWidth, const size_t kernelHeight, const size_t horizontalSubsample, const size_t verticalSubsample, 
                                            const bool zeroPadding) const
    {
        assert (verticalSubsample <= kernelHeight && horizontalSubsample <= kernelWidth);

        size_t smallBatchSize = inputSubBatch.GetNumCols();

        PrepareDevice();
        int numThreadPerBlock = threadsPerBlock; 
#if 1
        int blocksPerGrid = (smallBatchSize * inputWidth*inputHeight*inputChannels + numThreadPerBlock - 1)/numThreadPerBlock; 
#else
        dim3 blocksPerGrid((inputWidth*inputHeight*inputChannels + numThreadPerBlock - 1)/numThreadPerBlock, smallBatchSize);
#endif
        cudaEvent_t done;       
        if (do_sync)    CUDA_CALL(cudaEventCreate(&done));
        _unpackConvolutionInput<<<blocksPerGrid, numThreadPerBlock,0,t_stream>>>(this->m_pArray, 
                                            inputSubBatch.m_pArray, 
                                            smallBatchSize,
                                            inputWidth, inputHeight, inputChannels,
                                            outputWidth, outputHeight, outputChannels,
                                            kernelWidth, kernelHeight, horizontalSubsample, verticalSubsample, zeroPadding);
        if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
        if (do_sync)    CUDA_CALL(cudaEventSynchronize(done)); 
        if (do_sync)    CUDA_CALL(cudaEventDestroy(done));

        return inputSubBatch;
    }

    template<class ElemType>
    GPUMatrix<ElemType>&  GPUMatrix<ElemType>::AssignMaxPoolingResult(const GPUMatrix<ElemType>& inputBatch, const size_t channels, 
                                                const size_t inputWidth, const size_t inputHeight, const size_t inputSizePerSample, 
                                                const size_t outputWidth, const size_t outputHeight, const size_t outputSizePerSample, 
                                                const size_t windowWidth, const size_t windowHeight, const size_t horizontalSubsample, const size_t verticalSubsample)
    {
        assert (verticalSubsample <= windowHeight && horizontalSubsample <= windowWidth);

        unsigned int batchSize = inputBatch.GetNumCols();
        Resize(outputSizePerSample, batchSize);

        int numThreadPerBlock = threadsPerBlock; 
        int blocksPerGrid = (batchSize * outputSizePerSample + numThreadPerBlock - 1)/numThreadPerBlock; 

        PrepareDevice();
        cudaEvent_t done;       
        if (do_sync)    CUDA_CALL(cudaEventCreate(&done));
        _assignMaxPoolingResult<<<blocksPerGrid, numThreadPerBlock,0,t_stream>>>(this->m_pArray, inputBatch.m_pArray, batchSize, channels,
                                                 inputWidth, inputHeight,inputSizePerSample, 
                                                 outputWidth, outputHeight, outputSizePerSample, 
                                                 windowWidth, windowHeight, horizontalSubsample, verticalSubsample);
        if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
        if (do_sync)    CUDA_CALL(cudaEventSynchronize(done)); 
        if (do_sync)    CUDA_CALL(cudaEventDestroy(done));

        return *this;
    }

    template<class ElemType>
    GPUMatrix<ElemType>&  GPUMatrix<ElemType>::AddMaxPoolingGradient(const GPUMatrix<ElemType>& outputGradientBatch, const GPUMatrix<ElemType>& inputBatch, const GPUMatrix<ElemType>& outputBatch, 
                                                const size_t channels, 
                                                const size_t inputWidth, const size_t inputHeight, const size_t inputSizePerSample, 
                                                const size_t outputWidth, const size_t outputHeight, const size_t outputSizePerSample, 
                                                const size_t windowWidth, const size_t windowHeight, const size_t horizontalSubsample, const size_t verticalSubsample)
    {
        assert (verticalSubsample <= windowHeight && horizontalSubsample <= windowWidth);

        unsigned int batchSize = outputGradientBatch.GetNumCols();
        int numThreadPerBlock = threadsPerBlock; 

        PrepareDevice();
        cudaEvent_t done;       
        if (do_sync)    CUDA_CALL(cudaEventCreate(&done));

        int blocksPerGrid = (batchSize * inputSizePerSample + numThreadPerBlock - 1)/numThreadPerBlock; 
        _addMaxPoolingGradient<<<blocksPerGrid, numThreadPerBlock,0,t_stream>>>(this->m_pArray, outputGradientBatch.m_pArray, inputBatch.m_pArray, outputBatch.m_pArray, batchSize, channels,
                                                 inputWidth, inputHeight,inputSizePerSample, 
                                                 outputWidth, outputHeight,  outputSizePerSample, 
                                                 windowWidth, windowHeight, horizontalSubsample, verticalSubsample);
        if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
        if (do_sync)    CUDA_CALL(cudaEventSynchronize(done)); 
        if (do_sync)    CUDA_CALL(cudaEventDestroy(done));

        return *this;
    }

    template<class ElemType>
    GPUMatrix<ElemType>&  GPUMatrix<ElemType>::AssignAveragePoolingResult(const GPUMatrix<ElemType>& inputBatch, const size_t channels, 
                                                const size_t inputWidth, const size_t inputHeight, const size_t inputSizePerSample, 
                                                const size_t outputWidth, const size_t outputHeight, const size_t outputSizePerSample, 
                                                const size_t windowWidth, const size_t windowHeight, const size_t horizontalSubsample, const size_t verticalSubsample)
    {
        assert (verticalSubsample <= windowHeight && horizontalSubsample <= windowWidth);

        unsigned int batchSize = inputBatch.GetNumCols();
        Resize(outputSizePerSample, batchSize);

        int numThreadPerBlock = threadsPerBlock; 
        int blocksPerGrid = (batchSize * outputSizePerSample + numThreadPerBlock - 1)/numThreadPerBlock; 

        PrepareDevice();
        cudaEvent_t done;       
        if (do_sync)    CUDA_CALL(cudaEventCreate(&done));
        _assignAveragePoolingResult<<<blocksPerGrid, numThreadPerBlock,0,t_stream>>>(this->m_pArray, inputBatch.m_pArray, batchSize, channels,
                                                 inputWidth, inputHeight,inputSizePerSample, 
                                                 outputWidth, outputHeight, outputSizePerSample, 
                                                 windowWidth, windowHeight, horizontalSubsample, verticalSubsample);
        if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
        if (do_sync)    CUDA_CALL(cudaEventSynchronize(done)); 
        if (do_sync)    CUDA_CALL(cudaEventDestroy(done));

        return *this;
    }

    template<class ElemType>
    GPUMatrix<ElemType>&  GPUMatrix<ElemType>::AddAveragePoolingGradient(const GPUMatrix<ElemType>& outputGradientBatch, 
                                                const size_t channels, 
                                                const size_t inputWidth, const size_t inputHeight, const size_t inputSizePerSample, 
                                                const size_t outputWidth, const size_t outputHeight, const size_t outputSizePerSample, 
                                                const size_t windowWidth, const size_t windowHeight, const size_t horizontalSubsample, const size_t verticalSubsample)
    {
        assert (verticalSubsample <= windowHeight && horizontalSubsample <= windowWidth);

        unsigned int batchSize = outputGradientBatch.GetNumCols();
        int numThreadPerBlock = threadsPerBlock; 

        PrepareDevice();
        cudaEvent_t done;       
        if (do_sync)    CUDA_CALL(cudaEventCreate(&done));

        int blocksPerGrid = (batchSize * inputSizePerSample + numThreadPerBlock - 1)/numThreadPerBlock; 
        _addAveragePoolingGradient<<<blocksPerGrid, numThreadPerBlock,0,t_stream>>>(this->m_pArray, outputGradientBatch.m_pArray, batchSize, channels,
                                                 inputWidth, inputHeight,inputSizePerSample, 
                                                 outputWidth, outputHeight,  outputSizePerSample, 
                                                 windowWidth, windowHeight, horizontalSubsample, verticalSubsample);
        if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
        if (do_sync)    CUDA_CALL(cudaEventSynchronize(done)); 
        if (do_sync)    CUDA_CALL(cudaEventDestroy(done));

        return *this;
    }

#pragma endregion Other helper functions

#pragma region Static BLAS Functions
    template<class ElemType>
    void GPUMatrix<ElemType>::MultiplyAndWeightedAdd(ElemType alpha, const GPUMatrix<ElemType>& a, const bool transposeA, const GPUMatrix<ElemType>& b, const bool transposeB, 
        ElemType beta, GPUMatrix<ElemType>& c)
    {
		a.PrepareDevice();
        if ((a.GetComputeDeviceId()!=b.GetComputeDeviceId()) || (b.GetComputeDeviceId()!=c.GetComputeDeviceId())) //different GPUs
        {
            throw std::invalid_argument("All matrices must be on the same GPU");
        }
        else
        {  
            cublasHandle_t cuHandle = GetCublasHandle(b.GetComputeDeviceId());
            cublasOperation_t transA =  transposeA ? CUBLAS_OP_T : CUBLAS_OP_N;
            cublasOperation_t transB =  transposeB ? CUBLAS_OP_T : CUBLAS_OP_N;
            int m = int(transposeA ? a.m_numCols : a.m_numRows);
            int n = int(transposeB ? b.m_numRows : b.m_numCols);
            int k = int(transposeA ? a.m_numRows : a.m_numCols);
            int l = int(transposeB ? b.m_numCols : b.m_numRows);
            c.Resize(m,n);

            if (!(m>0 && k>0 && l>0 && n>0)) 
            {
#ifndef	LINUX
                throw std::exception("!(m>0 && k>0 && l>0 && n>0)");  //converting from size_t to int may cause overflow
#else
                throw std::exception();  //converting from size_t to int may cause overflow
#endif	/* LINUX */
            }
            if (k!=l) 
            {
#ifndef	LINUX
                throw std::exception("matrix dim mismatch in MultiplyAndWeightedAdd");
#else
                throw std::exception();
#endif	/* LINUX */
            }
            if (sizeof(ElemType)==sizeof(float))
            {
                CUBLAS_CALL(cublasSgemm(cuHandle,transA,transB,m,n,k,reinterpret_cast<float*>(&alpha),reinterpret_cast<float*>(a.m_pArray),(int)a.m_numRows,reinterpret_cast<float*>(b.m_pArray),(int)b.m_numRows,reinterpret_cast<float*>(&beta),reinterpret_cast<float*>(c.m_pArray),(int)c.m_numRows));
            }
            else if (sizeof(ElemType)==sizeof(double))
            {            
                CUBLAS_CALL(cublasDgemm(cuHandle,transA,transB,m,n,k,reinterpret_cast<double*>(&alpha),reinterpret_cast<double*>(a.m_pArray),(int)a.m_numRows,reinterpret_cast<double*>(b.m_pArray),(int)b.m_numRows,reinterpret_cast<double*>(&beta),reinterpret_cast<double*>(c.m_pArray),(int)c.m_numRows));
            }
            else 
            {
#ifndef	LINUX
                throw std::exception("Unsupported template argument in GPUMatrix");             
#else
                throw std::exception();             
#endif	/* LINUX */
            }
            c.m_numRows=m;
            c.m_numCols=n;
        }
    }

    template<class ElemType>
    void GPUMatrix<ElemType>::MultiplyAndAdd(const GPUMatrix<ElemType>& a, const bool transposeA, const GPUMatrix<ElemType>& b, const bool transposeB, GPUMatrix<ElemType>& c)
    {
        return GPUMatrix<ElemType>::MultiplyAndWeightedAdd(1, a, transposeA, b, transposeB, 1, c);
    }

    template<class ElemType>
    void GPUMatrix<ElemType>::Multiply(const GPUMatrix<ElemType>& a, const bool transposeA, const GPUMatrix<ElemType>& b, const bool transposeB, GPUMatrix<ElemType>& c)
    {    
        return GPUMatrix<ElemType>::MultiplyAndWeightedAdd(1, a, transposeA, b, transposeB, 0, c);
    }

    template<class ElemType>
    void GPUMatrix<ElemType>::Multiply(const GPUMatrix<ElemType>& a, const GPUMatrix<ElemType>& b, GPUMatrix<ElemType>& c)
    {
        return GPUMatrix<ElemType>::MultiplyAndWeightedAdd(1, a, false, b, false, 0, c);
    }

    /// <summary>Matrix-scalar multiply with col-major matrices: c = alpha * a + c</summary>
    /// if a is a column vector, add to all columns of c 
    /// if a is a row vector, add to all rows of c    
    /// if a is a scalar, add to all elements of c
    /// <param name="alpha">Scalar</param>
    /// <param name="a">Input matrix</param>
    /// <param name="c">Resulting matrix, user is responsible for allocating this</param>
    template<class ElemType>
    void GPUMatrix<ElemType>::ScaleAndAdd(ElemType alpha,const GPUMatrix<ElemType>& a, GPUMatrix<ElemType>& c)
    {
        if (a.GetComputeDeviceId()!=c.GetComputeDeviceId())
        {
            throw std::invalid_argument("All matrices must be on the same GPU");
        }
        else
        {
            a.PrepareDevice();
            if (a.IsEmpty() || c.IsEmpty())
                throw std::logic_error("ScaleAndAdd:  one of the input matrices is empty.");
            //if (a.GetNumRows() != 1 && a.GetNumCols() != 1) // a is not a col or row vector
            if (a.GetNumRows()==c.GetNumRows() && a.GetNumCols()==c.GetNumCols()) // dimensions match
            {
                const int m = (int)a.GetNumRows();
                const int n = (int)a.GetNumCols();
                const int len = m * n;
                const int incx = 1;
                const int incy = 1;

                assert (m>0 && n>0 && len>0); //converting from size_t to int may cause overflow
                assert ((int)c.GetNumRows() == m && (int)c.GetNumCols() == n);
                if ((int)c.GetNumRows() != m || (int)c.GetNumCols() != n)
                    throw std::invalid_argument("Dimention of matrix c does not match dimention of matrix a.");

                cublasHandle_t cuHandle = GetCublasHandle(a.GetComputeDeviceId());
                if (sizeof(ElemType) == sizeof(float))
                {
                    CUBLAS_CALL(cublasSaxpy(cuHandle,len,reinterpret_cast <float*>(&alpha),reinterpret_cast <float*>(a.m_pArray),incx,reinterpret_cast <float*>(c.m_pArray) ,incy));                
                }
                else if (sizeof(ElemType) == sizeof(double))
                {   
                    CUBLAS_CALL(cublasDaxpy(cuHandle,len,reinterpret_cast <double*>(&alpha),reinterpret_cast <double*>(a.m_pArray),incx,reinterpret_cast <double*>(c.m_pArray) ,incy)); 
                }
                else 
                {
#ifndef	LINUX
                    throw std::exception("Unsupported template argument in GPUMatrix"); 
#else
                    throw std::exception(); 
#endif /* LINUX */
                }
            }
            else if (a.GetNumElements() == 1)
            {
                LONG64 N=(LONG64)c.GetNumElements();
                int blocksPerGrid =(int)ceil(1.0*N/threadsPerBlock);
                c.PrepareDevice();
                cudaEvent_t done;       
                if (do_sync)    CUDA_CALL(cudaEventCreate(&done));
                _scaleAndAddScalar<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(c.m_pArray, N, alpha, a.m_pArray);
                if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
                if (do_sync)    CUDA_CALL(cudaEventSynchronize(done));
                if (do_sync)    CUDA_CALL(cudaEventDestroy(done));
            }
            else if (a.GetNumCols() == 1) //col vector, add it to all columns
            {                
                long m = (long)c.GetNumRows();
                long n = (long)c.GetNumCols();                
                if (m != (long)a.GetNumRows())
                    throw std::invalid_argument("To add column vector, rows should match.");

                cudaEvent_t done;
                int blocksPerGrid = (int)ceil(1.0*m/threadsPerBlock);
                if (do_sync)    CUDA_CALL(cudaEventCreate(&done));   
#ifdef VALIDATION
                printf(">>>> CUDA compute device is %d\n", a.GetComputeDeviceId());
                printf(">>>> a.m_pArray = %p, c.m_pArray = %p, alpha = %f, m = %ld, n = %ld\n", a.m_pArray,c.m_pArray,alpha,m,n);   
                for (int i=0; i < 2; i++)
                {
                    ElemType buffer[10] = {-1.234f};
                    cudaError_t error = cudaMemcpy(buffer, !i?a.m_pArray:c.m_pArray, sizeof(buffer), cudaMemcpyKind::cudaMemcpyDeviceToHost);
                    if (error == cudaError::cudaSuccess)
                        printf("buffer valid\n"); 
                }
#endif

                _matrixVectorColumnWiseAdd<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(a.m_pArray,c.m_pArray,alpha,m,n);
                if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
                if (do_sync)    CUDA_CALL(cudaEventSynchronize(done));   
                if (do_sync)    CUDA_CALL(cudaEventDestroy(done));                
            }
            else  if (a.GetNumRows()==1)  //row vector, add it to all rows
            {
                cublasHandle_t cuHandle = GetCublasHandle(a.GetComputeDeviceId());
                int m = (int)c.GetNumRows();
                int n = (int)c.GetNumCols();
                assert (n == (int)a.GetNumCols());
                if (n != (int)a.GetNumCols())
                    throw std::invalid_argument("To add row vector, cols should match.");

                if (sizeof(ElemType) == sizeof(double))
                {
#pragma omp parallel for
                    foreach_row(i,c)
                    {
                        CUBLAS_CALL(cublasDaxpy(cuHandle,n,reinterpret_cast <double*>(&alpha),reinterpret_cast <double*>(a.m_pArray),1,reinterpret_cast <double*>(c.m_pArray+i),m));
                    }                    
                }
                else
                {
#pragma omp parallel for
                    foreach_row(i,c)
                    {
                        CUBLAS_CALL(cublasSaxpy(cuHandle,n,reinterpret_cast <float*>(&alpha),reinterpret_cast <float*>(a.m_pArray),1,reinterpret_cast <float*>(c.m_pArray+i),m));
                    }                    
                }
            }
            else
                throw std::invalid_argument("Dimention of matrix c does not match dimention of matrix a.");
        }
    }

    /// <summary>c += alpha * (a-b)</summary>
    /// if a, b, c  must have same dim 
    /// <param name="alpha">Scalar</param>
    /// <param name="a">Input matrix</param>
    /// <param name="b">Input matrix</param>
    /// <param name="c">Resulting matrix, user is responsible for allocating this</param>
    template<class ElemType>
    void GPUMatrix<ElemType>::AddScaledDifference(const ElemType alpha, const GPUMatrix<ElemType>& a, const GPUMatrix<ElemType>& b, GPUMatrix<ElemType>& c)
    {
        if (a.GetComputeDeviceId()!=c.GetComputeDeviceId())
        {
            throw std::invalid_argument("All matrices must be on the same GPU");
        }
        else
        {
            a.PrepareDevice();

            assert(a.GetNumRows() == b.GetNumRows() && a.GetNumRows() == c.GetNumRows() &&
                a.GetNumCols() == b.GetNumCols() && a.GetNumCols() == c.GetNumCols());

            if (!(a.GetNumRows() == b.GetNumRows() && a.GetNumRows() == c.GetNumRows() &&
                a.GetNumCols() == b.GetNumCols() && a.GetNumCols() == c.GetNumCols()))
            {
                throw std::invalid_argument("AddScaledDifference:  a, b, and c must have same dimension.");
            }

            if (a.IsEmpty())
                throw std::logic_error("AddScaledDifference:  Input matrix a is empty.");

            cudaEvent_t done;
            LONG64 n=(LONG64)a.GetNumElements();            
            int blocksPerGrid=(int)ceil(1.0*n/threadsPerBlock);  
            if (do_sync)    CUDA_CALL(cudaEventCreate(&done));        
            _addScaledDifference<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(alpha, a.m_pArray, b.m_pArray, c.m_pArray, n);
            if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
            if (do_sync)    CUDA_CALL(cudaEventSynchronize(done));   
            if (do_sync)    CUDA_CALL(cudaEventDestroy(done));
        }
    }

    /// <summary> c = alpha * (a-b)</summary>
    /// if a, b, c  must have same dim 
    /// <param name="alpha">Scalar</param>
    /// <param name="a">Input matrix</param>
    /// <param name="b">Input matrix</param>
    /// <param name="c">Resulting matrix, user is responsible for allocating this</param>
    template<class ElemType>    
    void GPUMatrix<ElemType>::AssignScaledDifference(const ElemType alpha, const GPUMatrix<ElemType>& a, const GPUMatrix<ElemType>& b, GPUMatrix<ElemType>& c)
    {
        if (a.GetComputeDeviceId()!=c.GetComputeDeviceId())
        {
            throw std::invalid_argument("All matrices must be on the same GPU");
        }
        else
        {
            a.PrepareDevice();

            assert(a.GetNumRows() == b.GetNumRows() && a.GetNumCols() == b.GetNumCols() );

            if (!(a.GetNumRows() == b.GetNumRows()  && a.GetNumCols() == b.GetNumCols()))
            {
                throw std::invalid_argument("AssignScaledDifference:  a, b must have same dimension.");
            }

            if (a.IsEmpty())
                throw std::logic_error("AssignScaledDifference:  Input matrix a is empty.");

            if (&c != &a && &c != &b)
                c.Resize(a.GetNumRows(), a.GetNumCols());

            cudaEvent_t done;
            LONG64 n=(LONG64)a.GetNumElements();            
            int blocksPerGrid=(int)ceil(1.0*n/threadsPerBlock);  
            if (do_sync)    CUDA_CALL(cudaEventCreate(&done));        
            _assignScaledDifference<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(alpha, a.m_pArray, b.m_pArray, c.m_pArray, n);
            if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
            if (do_sync)    CUDA_CALL(cudaEventSynchronize(done));   
            if (do_sync)    CUDA_CALL(cudaEventDestroy(done));
        }
    }

    /// <summary>c += alpha * (a-b)</summary>
    /// if a, b, c  must have same dim 
    /// <param name="alpha">1X1 matrix</param>
    /// <param name="a">Input matrix</param>
    /// <param name="b">Input matrix</param>
    /// <param name="c">Resulting matrix, user is responsible for allocating this</param>
    template<class ElemType>
    void GPUMatrix<ElemType>::AddScaledDifference(const GPUMatrix<ElemType>& alpha, const GPUMatrix<ElemType>& a, const GPUMatrix<ElemType>& b, GPUMatrix<ElemType>& c)
    {
        assert(alpha.GetNumElements() == 1);
        if (!(alpha.GetNumElements() == 1))
            throw std::invalid_argument("AddScaledDifference:  alpha must be a 1X1 matrix.");

        if (a.GetComputeDeviceId()!=c.GetComputeDeviceId())
        {
            throw std::invalid_argument("All matrices must be on the same GPU");
        }
        else
        {
            a.PrepareDevice();

            assert(a.GetNumRows() == b.GetNumRows() && a.GetNumRows() == c.GetNumRows() &&
                a.GetNumCols() == b.GetNumCols() && a.GetNumCols() == c.GetNumCols());

            if (!(a.GetNumRows() == b.GetNumRows() && a.GetNumRows() == c.GetNumRows() &&
                a.GetNumCols() == b.GetNumCols() && a.GetNumCols() == c.GetNumCols()))
            {
                throw std::invalid_argument("AddScaledDifference:  a, b, and c must have same dimension.");
            }

            if (a.IsEmpty())
                throw std::logic_error("AddScaledDifference:  Input matrix a is empty.");

            cudaEvent_t done;
            LONG64 n=(LONG64)a.GetNumElements();            
            int blocksPerGrid=(int)ceil(1.0*n/threadsPerBlock);  
            if (do_sync)    CUDA_CALL(cudaEventCreate(&done));        
            _addScaledDifference<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(alpha.m_pArray, a.m_pArray, b.m_pArray, c.m_pArray, n);
            if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
            if (do_sync)    CUDA_CALL(cudaEventSynchronize(done));   
            if (do_sync)    CUDA_CALL(cudaEventDestroy(done));
        }
    }

    /// <summary> c = alpha * (a-b)</summary>
    /// if a, b, c  must have same dim 
    /// <param name="alpha">Scalar</param>
    /// <param name="a">Input matrix</param>
    /// <param name="b">Input matrix</param>
    /// <param name="c">Resulting matrix, user is responsible for allocating this</param>
    template<class ElemType>    
    void GPUMatrix<ElemType>::AssignScaledDifference(const GPUMatrix<ElemType>& alpha, const GPUMatrix<ElemType>& a, const GPUMatrix<ElemType>& b, GPUMatrix<ElemType>& c)
    {
        assert(alpha.GetNumElements() == 1);
        if (!(alpha.GetNumElements() == 1))
            throw std::invalid_argument("AddScaledDifference:  alpha must be a 1X1 matrix.");

        if (a.GetComputeDeviceId()!=c.GetComputeDeviceId())
        {
            throw std::invalid_argument("All matrices must be on the same GPU");
        }
        else
        {
            a.PrepareDevice();

            assert(a.GetNumRows() == b.GetNumRows() && a.GetNumCols() == b.GetNumCols() );

            if (!(a.GetNumRows() == b.GetNumRows()  && a.GetNumCols() == b.GetNumCols()))
            {
                throw std::invalid_argument("AssignScaledDifference:  a, b must have same dimension.");
            }

            if (a.IsEmpty())
                throw std::logic_error("AssignScaledDifference:  Input matrix a is empty.");

            c.Resize(a.GetNumRows(), a.GetNumCols());

            cudaEvent_t done;
            LONG64 n=(LONG64)a.GetNumElements();            
            int blocksPerGrid=(int)ceil(1.0*n/threadsPerBlock);  
            if (do_sync)    CUDA_CALL(cudaEventCreate(&done));        
            _assignScaledDifference<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(alpha.m_pArray, a.m_pArray, b.m_pArray, c.m_pArray, n);
            if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
            if (do_sync)    CUDA_CALL(cudaEventSynchronize(done)); 
            if (do_sync)    CUDA_CALL(cudaEventDestroy(done));
        }
    }

    //c[ci,cj] += a[ai,aj]
    template<class ElemType>
    void GPUMatrix<ElemType>::AddElementToElement(const GPUMatrix<ElemType>& a, const size_t ai, const size_t aj, GPUMatrix<ElemType>& c, const size_t ci, const size_t cj)
    {
        if (ai >= a.GetNumRows() || aj >=a.GetNumCols() ||
            ci >= c.GetNumRows() || cj >=c.GetNumCols())
            throw std::invalid_argument("AddElementToElement:  index out of range.");

        a.PrepareDevice();
        cudaEvent_t done;
        int blocksPerGrid=1;  //only one element
        if (do_sync)    CUDA_CALL(cudaEventCreate(&done));        
        _addElementToElement<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(a.m_pArray, (LONG64)a.LocateElement(ai, aj), c.m_pArray, (LONG64)c.LocateElement(ci, cj));
        if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
        if (do_sync)    CUDA_CALL(cudaEventSynchronize(done));  
        if (do_sync)    CUDA_CALL(cudaEventDestroy(done));
    }

    template<class ElemType>
    void GPUMatrix<ElemType>::Scale(ElemType alpha, GPUMatrix<ElemType>& a)
    {   
        cublasHandle_t cuHandle = GetCublasHandle(a.GetComputeDeviceId());
        if (sizeof(ElemType)==sizeof(float))
        {
            float alph = alpha;            
            CUBLAS_CALL(cublasSscal(cuHandle,int(a.m_numRows*a.m_numCols),&alph,(float*)a.m_pArray,1));
        }
        else if (sizeof(ElemType)==sizeof(double))
        {
            double alph = alpha;
            CUBLAS_CALL(cublasDscal(cuHandle,int(a.m_numRows*a.m_numCols),&alph,(double*)a.m_pArray,1));
        }
        else 
        {
#ifndef	LINUX
            throw std::exception("Unsupported template argument in GPUMatrix");            
#else
            throw std::exception();            
#endif	/* LINUX */
        }
    }


    template<class ElemType>
    void GPUMatrix<ElemType>::Scale(GPUMatrix<ElemType>& alpha, GPUMatrix<ElemType>& a)
    {           
        if (alpha.GetNumElements()!=1)
        {
#ifndef	LINUX
            throw std::exception("Matrix alpha must be 1x1");
#else
            throw std::exception();
#endif /* LINUX */
        }
        cublasHandle_t cuHandle = GetCublasHandle(a.GetComputeDeviceId());
        cublasSetPointerMode(cuHandle, CUBLAS_POINTER_MODE_DEVICE);
        if (sizeof(ElemType)==sizeof(float))
        {
            CUBLAS_CALL(cublasSscal(cuHandle,int(a.m_numRows*a.m_numCols),(float*)alpha.m_pArray,(float*)a.m_pArray,1));
        }
        else if (sizeof(ElemType)==sizeof(double))
        {            
            CUBLAS_CALL(cublasDscal(cuHandle,int(a.m_numRows*a.m_numCols),(double*)alpha.m_pArray,(double*)a.m_pArray,1));
        }
        else 
        {
            cublasSetPointerMode(cuHandle, CUBLAS_POINTER_MODE_HOST);
#ifndef	LINUX
            throw std::exception("Unsupported template argument in GPUMatrix");            
#else
            throw std::exception();            
#endif /* LINUX */
        }
        cublasSetPointerMode(cuHandle, CUBLAS_POINTER_MODE_HOST);
    }

    template<class ElemType> //c = alpha * a
    void GPUMatrix<ElemType>::Scale(ElemType alpha, const GPUMatrix<ElemType>& a, GPUMatrix<ElemType>& c)
    {
        if (a.IsEmpty())
            throw std::logic_error("Scale:  Input matrix a is empty.");

        c=a;
        Scale(alpha,c);
    }


    template<class ElemType>
    void GPUMatrix<ElemType>::InnerProduct (const GPUMatrix<ElemType>& a, const GPUMatrix<ElemType>& b, GPUMatrix<ElemType>& c, const bool isColWise)
    {
        if (a.GetComputeDeviceId()!=b.GetComputeDeviceId() || b.GetComputeDeviceId()!=c.GetComputeDeviceId()) //different GPUs
            throw std::invalid_argument("All matrices must be on the same GPU");

        if (a.IsEmpty() || b.IsEmpty())
            throw std::logic_error("Scale:  one of the input matrices is empty.");

        const int m = (int)a.GetNumRows();
        const int n = (int)a.GetNumCols();
        const int k = (int)b.GetNumRows();
        const int l = (int)b.GetNumCols();

        assert (m>0 && n>0 && k>0 && l>0); //converting from size_t to int may cause overflow
        assert (m==k && n==l); //converting from size_t to int may cause overflow
        if (m!=k || n!=l)
            throw std::invalid_argument("Matrices a and b should have same dimension.");

        if (isColWise)
            c.Resize(1,n);
        else
            c.Resize(m,1);

        if ((isColWise && m == 1) || !isColWise && n == 1)  //in this case it's equivalent to element-wise product
        {
            c.AssignElementProductOf(a, b);
        }
        else 
        {
            cudaEvent_t done;  
            c.PrepareDevice();

            int blocksPerGrid=0;
            if (isColWise)  //col-wise
            {
                c.Resize(1,n);   
                blocksPerGrid =(int)ceil(1.0*n/threadsPerBlock);                                        
            }
            else
            {
                c.Resize(m, 1);
                blocksPerGrid =(int)ceil(1.0*m/threadsPerBlock);                        
            }       

            if (do_sync)    CUDA_CALL(cudaEventCreate(&done));  
            _innerProduct<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(c.m_pArray, a.m_pArray,b.m_pArray,m,n,isColWise);
            if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
            if (do_sync)    CUDA_CALL(cudaEventSynchronize(done));
            if (do_sync)    CUDA_CALL(cudaEventDestroy(done));
        }             
    }

    template<class ElemType>
    ElemType GPUMatrix<ElemType>::InnerProductOfMatrices(const GPUMatrix<ElemType>& a, const GPUMatrix<ElemType>& b)
    {
        if (a.IsEmpty() || b.IsEmpty())
            throw std::logic_error("InnerProductOfMatrices:  one of the input matrices is empty.");

        const int m = (int)a.GetNumRows();
        const int n = (int)a.GetNumCols();
        const int k = (int)b.GetNumRows();
        const int l = (int)b.GetNumCols();

        assert (m>0 && n>0 && k>0 && l>0); //converting from size_t to int may cause overflow
        assert (m==k && n==l); //converting from size_t to int may cause overflow
        if (m!=k || n!=l)
            throw std::invalid_argument("InnerProductOfMatrices: Matrices a and b should have same dimension.");

        cublasHandle_t cuHandle = GetCublasHandle(a.GetComputeDeviceId());
        if (sizeof(ElemType) == sizeof(double))
        {
            double tmp=0;                        
            CUBLAS_CALL(cublasDdot(cuHandle,m*n, reinterpret_cast <double*>(a.m_pArray), 1, reinterpret_cast <double*>(b.m_pArray), 1,&tmp));
            return ElemType(tmp);
            //return (ElemType)ddot((int)a.GetNumElements(), reinterpret_cast <double*>(a.m_pArray), 1, reinterpret_cast <double*>(b.m_pArray), 1);
        }
        else
        {
            float tmp=0;                        
            CUBLAS_CALL(cublasSdot(cuHandle,m*n, reinterpret_cast <float*>(a.m_pArray), 1, reinterpret_cast <float*>(b.m_pArray), 1,&tmp));
            return tmp;
            //return (ElemType)sdot((int)a.GetNumElements(), reinterpret_cast <float*>(a.m_pArray), 1, reinterpret_cast <float*>(b.m_pArray), 1);
        }
    }


    template<class ElemType>
    GPUMatrix<ElemType>& GPUMatrix<ElemType>::AssignInnerProductOfMatrices(const GPUMatrix<ElemType>& a, const GPUMatrix<ElemType>& b)
    {
        if (a.IsEmpty() || b.IsEmpty())
            throw std::logic_error("InnerProductOfMatrices:  one of the input matrices is empty.");        

        this->Resize(1,1);

        const int m = (int)a.GetNumRows();
        const int n = (int)a.GetNumCols();
        const int k = (int)b.GetNumRows();
        const int l = (int)b.GetNumCols();

        assert (m>0 && n>0 && k>0 && l>0); //converting from size_t to int may cause overflow
        assert (m==k && n==l); //converting from size_t to int may cause overflow
        if (m!=k || n!=l)
            throw std::invalid_argument("InnerProductOfMatrices: Matrices a and b should have same dimension.");

        cublasHandle_t cuHandle = GetCublasHandle(a.GetComputeDeviceId());
        cublasSetPointerMode(cuHandle, CUBLAS_POINTER_MODE_DEVICE);
        if (sizeof(ElemType) == sizeof(double))
        {   
            CUBLAS_CALL(cublasDdot(cuHandle,m*n, reinterpret_cast <double*>(a.m_pArray), 1, reinterpret_cast <double*>(b.m_pArray), 1,reinterpret_cast <double*>(this->m_pArray)));                    
        }
        else
        {   
            CUBLAS_CALL(cublasSdot(cuHandle,m*n, reinterpret_cast <float*>(a.m_pArray), 1, reinterpret_cast <float*>(b.m_pArray), 1,reinterpret_cast <float*>(this->m_pArray)));                      
        }
        cublasSetPointerMode(cuHandle, CUBLAS_POINTER_MODE_HOST);
        return *this;
    }


    template<class ElemType>
    void GPUMatrix<ElemType>::ElementWisePower(ElemType alpha, const GPUMatrix<ElemType>& a, GPUMatrix<ElemType>& c)
    {
        if (a.GetComputeDeviceId() != c.GetComputeDeviceId())
        {
            throw std::invalid_argument("All matrices must be on the same GPU");
        }
        else 
        {
            if (a.IsEmpty())
                throw std::logic_error("ElementWisePower:  The input matrix a is empty.");
            if (a.GetNumRows()!=c.GetNumRows() || a.GetNumCols()!=c.GetNumCols())
                throw std::logic_error("ElementWisePower: matrices must be of the same size");

            cudaEvent_t done;
            a.PrepareDevice();
            if (do_sync)    CUDA_CALL(cudaEventCreate(&done));            
            LONG64 N=(LONG64)a.GetNumElements();
            int blocksPerGrid =(int)ceil(1.0*N/threadsPerBlock);                
            _elementWisePowerOnCuda<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(alpha,a.m_pArray,c.m_pArray,N);
            if (do_sync)    CUDA_CALL(cudaEventRecord(done));        
            if (do_sync)    CUDA_CALL(cudaEventSynchronize(done)); 
            if (do_sync)    CUDA_CALL(cudaEventDestroy(done));
        }
    }

    template<class ElemType>
    bool GPUMatrix<ElemType>::AreEqual(const GPUMatrix<ElemType>& a, const GPUMatrix<ElemType>& b, const ElemType threshold /*= 1e-8*/)
    {
        if (a.IsEmpty() || b.IsEmpty())
            throw std::logic_error("AreEqual: one of the input matrices is empty.");

        if (a.GetNumRows()  != b.GetNumRows() || a.GetNumCols() != b.GetNumCols())
            return false;

        a.PrepareDevice();
        long *res = new long[1];
        res[0]=1;
        long *d_res = NULL;
        CUDA_CALL(cudaMalloc((void**)&d_res,sizeof(long)*1));
        CUDA_CALL(cudaMemcpy(d_res,res,sizeof(long)*1,cudaMemcpyHostToDevice));
        long N=(long)a.GetNumElements();
        int blocksPerGrid =(int)ceil(1.0*N/threadsPerBlock);
        _areEqual<ElemType><<<blocksPerGrid,threadsPerBlock,0,t_stream>>>(a.m_pArray,b.m_pArray,N,threshold,d_res);
        CUDA_CALL(cudaMemcpy(res,d_res,sizeof(long)*1,cudaMemcpyDeviceToHost));
        if (res[0]!=0)
            return true;
        else
            return false;
    }

    template<class ElemType>
    GPUMatrix<ElemType>  GPUMatrix<ElemType>::Ones(const size_t rows, const size_t cols)
    {
        GPUMatrix<ElemType> c(rows, cols); //will initialize to 0
        c.SetValue(1);
        return c;
    }

    template<class ElemType>
    GPUMatrix<ElemType>  GPUMatrix<ElemType>::Zeros(const size_t rows, const size_t cols)
    {
        GPUMatrix<ElemType> c(rows, cols); //will initialize to 0
        //c.SetValue(0);
        return c;
    }

    template<class ElemType>
    GPUMatrix<ElemType>  GPUMatrix<ElemType>::Eye(const size_t rows)
    {
        GPUMatrix<ElemType> c(rows, rows); //will initialize to 0
        c.SetDiagonalValue(1);
        return c;
    }

    template<class ElemType>
    GPUMatrix<ElemType>  GPUMatrix<ElemType>::RandomUniform(const size_t rows, const size_t cols, const ElemType low, const ElemType high, unsigned long seed)
    {
        GPUMatrix<ElemType> c(rows, cols); //will initialize to 0
        c.SetUniformRandomValue(low, high, seed);
        return c;
    }

    template<class ElemType>
    GPUMatrix<ElemType> GPUMatrix<ElemType>::RandomGaussian(const size_t rows, const size_t cols, const ElemType mean, const ElemType sigma, unsigned long seed)
    {
        GPUMatrix<ElemType> c(rows, cols); //will initialize to 0
        c.SetGaussianRandomValue(mean, sigma, seed);
        return c;
    }

    template<class ElemType>
    ElemType GPUMatrix<ElemType>::GetLearnRateForBlock_Helper(const GPUMatrix<ElemType> &Gradients, const GPUMatrix<ElemType> &SmoothedGradients)
    {                
        Gradients.PrepareDevice();
        ElemType* d_res=NULL;
        CUDA_CALL(cudaMalloc((void**)&d_res,sizeof(ElemType))); //we allocate memory on the device

        //Compute inner product of matrices and keep it on device
        const int m = (int)Gradients.GetNumRows();
        const int n = (int)Gradients.GetNumCols();
        const int k = (int)SmoothedGradients.GetNumRows();
        const int l = (int)SmoothedGradients.GetNumCols();
        assert (m>0 && n>0 && k>0 && l>0); //converting from size_t to int may cause overflow
        assert (m==k && n==l); //converting from size_t to int may cause overflow
        if (m!=k || n!=l) throw std::invalid_argument("InnerProductOfMatrices: Matrices a and b should have same dimension.");

        if (sizeof(ElemType) == sizeof(double))
        {                 
            cublasHandle_t cuHandle = GetCublasHandle(Gradients.GetComputeDeviceId());
            cublasSetPointerMode(cuHandle, CUBLAS_POINTER_MODE_DEVICE);
            CUBLAS_CALL(cublasDdot(cuHandle,m*n, reinterpret_cast <double*>(Gradients.m_pArray), 1, reinterpret_cast <double*>(SmoothedGradients.m_pArray), 1,reinterpret_cast <double*>(d_res)));
            cublasSetPointerMode(cuHandle, CUBLAS_POINTER_MODE_HOST);
        }
        else
        {            
            cublasHandle_t cuHandle = GetCublasHandle(Gradients.GetComputeDeviceId());
            cublasSetPointerMode(cuHandle, CUBLAS_POINTER_MODE_DEVICE);
            CUBLAS_CALL(cublasSdot(cuHandle,m*n, reinterpret_cast <float*>(Gradients.m_pArray), 1, reinterpret_cast <float*>(SmoothedGradients.m_pArray), 1,reinterpret_cast <float*>(d_res)));
            cublasSetPointerMode(cuHandle, CUBLAS_POINTER_MODE_HOST);
        }
        // d_res[0] should now contain inner product of matrices
        // Compute squared Frobenius norms (squared sums of elements)       
        _lrHelper<ElemType><<<1,512,0,t_stream>>>(Gradients.m_pArray,SmoothedGradients.m_pArray, (LONG64)Gradients.GetNumElements(), d_res);
        ElemType res;
        CUDA_CALL(cudaMemcpy(&res,d_res,sizeof(ElemType),cudaMemcpyDeviceToHost));
        CUDA_CALL(cudaFree(d_res));
        return res;
    }

#pragma endregion Static BLAS Functions


    //#pragma region File << and >> operators
    //    template<class ElemType>
    //    File& operator>>(File& stream, GPUMatrix<ElemType> &us)
    //    {
    //        //auto& us = *this;
    //
    //        stream.GetMarker(fileMarkerBeginSection, std::string("BMAT"));
    //        size_t elsize;
    //        stream>>elsize;
    //        if (sizeof(ElemType)!=elsize)
    //            throw std::exception("Template argument size doesn't match those in file");
    //        std::wstring matrixName;
    //        size_t numRows, numCols;
    //        stream>>matrixName>>numRows>>numCols;
    //        ElemType* d_array = new ElemType[numRows*numCols];
    //        for (long i=0;i<numRows*numCols;++i)
    //            stream>>d_array[i];
    //        stream.GetMarker(fileMarkerEndSection, std::string("EMAT"));
    //        us.SetValue(numRows,numCols,d_array, matrixFlagNormal);
    //        us.m_matrixName = matrixName;
    //        return stream;
    //    }
    //
    //    template<class ElemType>
    //    File& operator<<(File& stream, GPUMatrix<ElemType> &us)
    //    {
    //        //auto& us = *this;
    //
    //        stream.PutMarker(fileMarkerBeginSection, std::string("BMAT"));
    //        stream<<sizeof(ElemType)<<us.m_matrixName<<us.m_numRows<<us.m_numCols;
    //        ElemType *d_array = us.CopyToArray();
    //        for (long i=0;i<us.GetNumElements();++i)
    //            stream<<d_array[i];
    //        stream.PutMarker(fileMarkerEndSection, std::string("EMAT"));
    //        return stream;
    //    }
    //
    //#pragma endregion File << and >> operators

    template class GPUMatrix<float>; 
    template class GPUMatrix<double>;
    template class DeviceBoundNumber<float>;
    template class DeviceBoundNumber<double>;

    template<class ElemType>
    cublasHandle_t GPUMatrix<ElemType>::s_cuHandle[GPUMatrix<ElemType>::MaxGpus]={0};

    template<class ElemType>
    void* GPUMatrix<ElemType>::s_curandGenerator=NULL;    
}}}

// !!!!This is from helper_cuda.h which comes with CUDA samples!!!! Consider if it is benefitial to just include all helper_cuda.h
// Beginning of GPU Architecture definitions
int _ConvertSMVer2Cores(int major, int minor)
{
    // Defines for GPU Architecture types (using the SM version to determine the # of cores per SM
    typedef struct
    {
        int SM; // 0xMm (hexidecimal notation), M = SM Major version, and m = SM minor version
        int Cores;
    } sSMtoCores;

    sSMtoCores nGpuArchCoresPerSM[] =
    {
        { 0x10,  8 }, // Tesla Generation (SM 1.0) G80 class
        { 0x11,  8 }, // Tesla Generation (SM 1.1) G8x class
        { 0x12,  8 }, // Tesla Generation (SM 1.2) G9x class
        { 0x13,  8 }, // Tesla Generation (SM 1.3) GT200 class
        { 0x20, 32 }, // Fermi Generation (SM 2.0) GF100 class
        { 0x21, 48 }, // Fermi Generation (SM 2.1) GF10x class
        { 0x30, 192}, // Kepler Generation (SM 3.0) GK10x class
        { 0x35, 192}, // Kepler Generation (SM 3.5) GK11x class
        {   -1, -1 }
    };

    int index = 0;

    while (nGpuArchCoresPerSM[index].SM != -1)
    {
        if (nGpuArchCoresPerSM[index].SM == ((major << 4) + minor))
        {
            return nGpuArchCoresPerSM[index].Cores;
        }

        index++;
    }
    return nGpuArchCoresPerSM[7].Cores;
};
// end of GPU Architecture definitions

//inline long _GetFreeMemoryOnCUDADevice(int devId)
//{   
//    CUdevice cudaDevice;  
//    CUresult result = cuDeviceGet(&cudaDevice, devId);  
//    if(result!= CUDA_SUCCESS)  
//    {          
//        return 0;         
//    }  
//  
//    //create cuda context  
//    CUcontext cudaContext;    
//    result = cuCtxCreate(&cudaContext, CU_CTX_SCHED_AUTO, cudaDevice);  
//    if(result != CUDA_SUCCESS)  
//    {          
//        return 0;         
//    }  
//  
//    //get the amount of free memory on the graphics card  
//    size_t free;  
//    size_t total;  
//    result = cuMemGetInfo(&free, &total);  
//    if (result!=CUDA_SUCCESS)
//    {
//        return 0;
//    }
//    else
//        return (long)free;
//}

