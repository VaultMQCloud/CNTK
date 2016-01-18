//
// <copyright file="BestGPU.cpp" company="Microsoft">
//     Copyright (c) Microsoft Corporation.  All rights reserved.
// </copyright>
//

#include "BestGpu.h"
#include "CommonMatrix.h" // for CPUDEVICE and AUTOPLACEMATRIX

#ifdef CPUONLY
namespace Microsoft {
    namespace MSR {
        namespace CNTK {
            short DeviceFromConfig(const ConfigParameters& config)
            {
                return CPUDEVICE;
            }
        }
    }
}
#else

// CUDA-C includes
#include <cuda.h>
#include <windows.h>
#include <delayimp.h>
#include <Shlobj.h>
#include <stdio.h>

// The "notify hook" gets called for every call to the
// delay load helper.  This allows a user to hook every call and
// skip the delay load helper entirely.
//
// dliNotify == {
//  dliStartProcessing |
//  dliNotePreLoadLibrary  |
//  dliNotePreGetProc |
//  dliNoteEndProcessing}
//  on this call.
//

extern "C" INT_PTR WINAPI DelayLoadNofify(
	unsigned        dliNotify,
	PDelayLoadInfo  pdli
	)
{
	// load the library from an alternate path
	if (dliNotify == dliNotePreLoadLibrary && !strcmp(pdli->szDll, "nvml.dll"))
	{
		WCHAR *path;
		WCHAR nvmlPath[MAX_PATH] = { 0 };
		HRESULT hr = SHGetKnownFolderPath(FOLDERID_ProgramFiles, 0, NULL, &path);
		lstrcpy(nvmlPath, path);
		CoTaskMemFree(path);
		if (SUCCEEDED(hr))
		{
			HMODULE module = NULL;
			WCHAR* dllName = L"\\NVIDIA Corporation\\NVSMI\\nvml.dll";
			lstrcat(nvmlPath, dllName);
			module = LoadLibraryEx(nvmlPath, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
			return (INT_PTR)module;
		}
	}
    // check for failed GetProc, old version of the driver
	if (dliNotify == dliFailGetProc && !strcmp(pdli->szDll, "nvml.dll"))
    {
        char name[256];
        int len = (int)strlen(pdli->dlp.szProcName);
        strcpy_s(name, pdli->dlp.szProcName);
        // if the version 2 APIs are not supported, truncate "_v2"
        if (name[len-1] == '2')
            name[len-3] = 0;
        FARPROC pfnRet = ::GetProcAddress(pdli->hmodCur, name);
        return (INT_PTR)pfnRet;
    }

	return NULL;
}

ExternC
PfnDliHook __pfnDliNotifyHook2 = (PfnDliHook)DelayLoadNofify;
// This is the failure hook, dliNotify = {dliFailLoadLib|dliFailGetProc}
ExternC
PfnDliHook   __pfnDliFailureHook2 = (PfnDliHook)DelayLoadNofify;

// Beginning of GPU Architecture definitions
inline int _ConvertSMVer2Cores(int major, int minor)
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
}

namespace Microsoft { namespace MSR { namespace CNTK {

BestGpu* g_bestGpu = NULL;
// DeviceFromConfig - Parse deviceId to determine what type of behavior is desired
//Symbol - Meaning
// Auto - automatically pick a single GPU based on �BestGpu� score
// CPU  - use the CPU
// 0    - or some other single number, use a single GPU with CUDA ID same as the number
// 0:2:3- an array of ids to use, (PTask will only use the specified IDs)
// *3   - a count of GPUs to use (PTask)
// All  - Use all the GPUs (PTask) 
short DeviceFromConfig(const ConfigParameters& config)
{
    short deviceId = CPUDEVICE;
    ConfigValue val = config("deviceId", "auto");
    if (!_stricmp(val.c_str(), "CPU"))
    {
        return CPUDEVICE;
    }

    // potential GPU device, so init our class
    if (g_bestGpu == NULL)
    {
        g_bestGpu = new BestGpu();
    }
    if (!_stricmp(val.c_str(), "Auto"))
    {
        std::vector<int> devices = g_bestGpu->GetDevices(1);
        deviceId = devices[0];
    }
    else if (!_stricmp(val.c_str(), "All"))
    {
        std::vector<int> devices = g_bestGpu->GetDevices(BestGpu::AllDevices);
        deviceId = devices[0];
    }
    else if (val.size() == 2 && val[0] == '*' && isdigit(val[1]))
    {
        int number = (int)(val[1] - '0');
        std::vector<int> devices = g_bestGpu->GetDevices(number);
        deviceId = devices[0];
    }
    else
    {
        ConfigArray arr = val;
        if (arr.size() == 1)
        {
            deviceId = arr[0];
        }
        else
        {
            argvector<int> allowed = arr;
            g_bestGpu->SetAllowedDevices(allowed);
            std::vector<int> devices = g_bestGpu->GetDevices();
            deviceId = devices[0];
        }
    }
    return deviceId;
}

void BestGpu::GetCudaProperties()
{
	if (m_cudaData)
		return;

	int dev = 0;

	for each (ProcessorData* pd in m_procData)
	{
		cudaSetDevice(dev);
		pd->deviceId = dev;
		cudaGetDeviceProperties(&pd->deviceProp, dev);
		size_t free;
		size_t total;
		cudaMemGetInfo(&free, &total);
		pd->cores = _ConvertSMVer2Cores(pd->deviceProp.major, pd->deviceProp.minor) * pd->deviceProp.multiProcessorCount;
		pd->cudaFreeMem = free;
		pd->cudaTotalMem = total;
		dev++;
        cudaDeviceReset();
    }
	m_cudaData = m_procData.size() > 0;
}

void BestGpu::Init()
{
	if (m_initialized)
		return;

	//get the count of objects
	cudaError_t err = cudaGetDeviceCount(&m_deviceCount);

	ProcessorData pdEmpty = { 0 };
	for (int i = 0; i < m_deviceCount; i++)
	{
		ProcessorData* data = new ProcessorData();
		*data = pdEmpty;
		m_procData.push_back(data);
	}

    if (m_deviceCount > 0)
    {
	    GetCudaProperties();
	    GetNvmlData();
    }
    m_initialized = true;
}


BestGpu::~BestGpu()
{
	for each (ProcessorData* data in m_procData)
	{
		delete data;
	}
	m_procData.clear();

	if (m_nvmlData)
	{
		nvmlShutdown();
	}
}

// GetNvmlData - Get data from the Nvidia Management Library
void BestGpu::GetNvmlData()
{
	// if we already did this, or we couldn't initialize the CUDA data, skip it
	if (m_nvmlData || !m_cudaData)
		return;

    // First initialize NVML library
    nvmlReturn_t result = nvmlInit();
    if (NVML_SUCCESS != result)
    { 
        return;
    }

	QueryNvmlData();
}

// GetDevice - Determine the best device ID to use
// bestFlags - flags that modify how the score is calculated
int BestGpu::GetDevice(BestGpuFlags bestFlags)
{
    std::vector<int> best = GetDevices(1, bestFlags);
    return best[0];
}

// SetAllowedDevices - set the allowed devices array up
// devices - vector of allowed devices
void BestGpu::SetAllowedDevices(const std::vector<int>& devices)
{
    m_allowedDevices = 0;
    for each (int device in devices)
    {
        m_allowedDevices |= (1 << device);
    }
}

// DeviceAllowed - is a particular device allowed?
// returns: true if the device is allowed, otherwise false
bool BestGpu::DeviceAllowed(int device)
{
    return !!(m_allowedDevices & (1<<device));
}

// AllowAll - Reset the allowed filter to allow all GPUs
void BestGpu::AllowAll()
{
    m_allowedDevices = -1; // set all bits
}

// UseMultiple - Are we using multiple GPUs?
// returns: true if more than one GPU was returned in last call
bool BestGpu::UseMultiple()
{
    return m_lastCount > 1;
}

// GetDevices - Determine the best device IDs to use
// number - how many devices do we want?
// bestFlags - flags that modify how the score is calculated
std::vector<int> BestGpu::GetDevices(int number, BestGpuFlags p_bestFlags)
{
    BestGpuFlags bestFlags = p_bestFlags;

    // if they want all devices give them eveything we have
    if (number == AllDevices)
        number = max(m_deviceCount,1);
    else if (number == RequeryDevices)
    {
        number = m_lastCount;
    }

    // create the initial array, initialized to all CPU
    std::vector<int> best(number, -1);
    std::vector<double> scores(number, -1.0);

    // if no GPUs were found, we should use the CPU
    if (m_procData.size() == 0)
    {
        best.resize(1);
        return best;
    }

	// get latest data
	QueryNvmlData();

	double utilGpuW = 0.15;
	double utilMemW = 0.1;
	double speedW = 0.2;
	double freeMemW = 0.2;
	double mlAppRunningW = 0.2;

    // if it's a requery, just use the same flags as last time
    if (bestFlags & bestGpuRequery)
        bestFlags = m_lastFlags;

	// adjust weights if necessary
	if (bestFlags&bestGpuAvoidSharing)
	{
		mlAppRunningW *= 3;
	}
	if (bestFlags&bestGpuFavorMemory) // favor memory
	{
		freeMemW *= 2;
	}
	if (bestFlags&bestGpuFavorUtilization) // favor low utilization
	{
		utilGpuW *= 2;
		utilMemW *= 2;
	}
	if (bestFlags&bestGpuFavorSpeed) // favor fastest processor
	{
		speedW *= 2;
	}

	for each (ProcessorData* pd in m_procData)
	{
		double score = 0.0;

        if (!DeviceAllowed(pd->deviceId))
            continue;

		// GPU utilization score
		score = (1.0-pd->utilization.gpu/75.0f) * utilGpuW;
		score += (1.0-pd->utilization.memory/60.0f) * utilMemW;
		score += pd->cores/1000.0f * speedW;
		double mem = pd->memory.free/(double)pd->memory.total;
		// if it's not a tcc driver, then it's WDDM driver and values will be off because windows allocates all the memory from the nvml point of view
		if (!pd->deviceProp.tccDriver)
			mem = pd->cudaFreeMem/(double)pd->cudaTotalMem;
		score += mem * freeMemW;
		score += ((pd->cnFound || pd->dbnFound)?0:1)*mlAppRunningW;
        for (int i = 0; i < best.size(); i++)
        {
            // look for a better score
		    if (score > scores[i])
		    {
                // make room for this score in the correct location (insertion sort)
                for (int j=(int)best.size()-1; j > i; --j)
                {
                    scores[j] = scores[j-1];
                    best[j] = best[j-1];
                }
			    scores[i] = score;
			    best[i] = pd->deviceId;
                break;
		    }
        }
	}

    // now get rid of any extra empty slots and disallowed devices
    for (int j=(int)best.size()-1; j > 0; --j)
    {
        // if this device is not allowed, or never was set remove it
        if (best[j] == -1)
            best.pop_back();
        else
            break;
    }

    // save off the last values for future requeries
    m_lastFlags = bestFlags;
    m_lastCount = (int)best.size();

    // if we eliminated all GPUs, use CPU
    if (best.size() == 0)
    {
        best.push_back(-1);
    }

	return best; // return the array of the best GPUs
}

// QueryNvmlData - Query data from the Nvidia Management Library, and accumulate counters
void BestGpu::QueryNvmlData()
{
	if (!m_cudaData)
		return;

    for (int i = 0; i < m_deviceCount; i++)
    {
        nvmlDevice_t device;
        nvmlPciInfo_t pci;
		nvmlMemory_t memory;
		nvmlUtilization_t utilization;

		// Query for device handle to perform operations on a device
        nvmlReturn_t result = nvmlDeviceGetHandleByIndex(i, &device);
        if (NVML_SUCCESS != result)
        { 
            return;
        }
      
        // pci.busId is very useful to know which device physically you're talking to
        // Using PCI identifier you can also match nvmlDevice handle to CUDA device.
        result = nvmlDeviceGetPciInfo(device, &pci);
        if (NVML_SUCCESS != result)
        { 
            return;
        }

		ProcessorData* curPd = NULL;
		for each (ProcessorData* pd in m_procData)
		{
			if (pd->deviceProp.pciBusID == pci.bus)
			{
				curPd = pd;
				break;
			}
		}

		// Get the memory usage, will only work for TCC drivers
		result = nvmlDeviceGetMemoryInfo(device, &memory);
		if (NVML_SUCCESS != result)
		{
			return;
		}
		curPd->memory = memory;


		// Get the memory usage, will only work for TCC drivers
		result = nvmlDeviceGetUtilizationRates(device, &utilization);
		if (NVML_SUCCESS != result)
		{
			return;
		}
		if (m_queryCount)
		{
			// average, slightly overweighting the most recent query
			curPd->utilization.gpu = (curPd->utilization.gpu*m_queryCount + utilization.gpu*2)/(m_queryCount+2);
			curPd->utilization.memory = (curPd->utilization.memory*m_queryCount + utilization.memory*2)/(m_queryCount+2);
		}
		else
		{
			curPd->utilization = utilization;
		}
		m_queryCount++;

		unsigned size = 0;
		result = nvmlDeviceGetComputeRunningProcesses(device, &size, NULL);
		if (size > 0)
		{
			std::vector<nvmlProcessInfo_t> processInfo(size);
			processInfo.resize(size);
			for each (nvmlProcessInfo_t info in processInfo)
				info.usedGpuMemory = 0;
			result = nvmlDeviceGetComputeRunningProcesses(device, &size, &processInfo[0]);
			if (NVML_SUCCESS != result)
			{
				return;
			}
			bool cnFound = false;
			bool dbnFound = false;
			for each (nvmlProcessInfo_t info in processInfo)
			{
				std::string name;
				name.resize(256);
				unsigned len = (unsigned)name.length();
				nvmlSystemGetProcessName(info.pid, (char*)name.data(), len);
				name.resize(strlen(name.c_str()));
				size_t pos = name.find_last_of('\\');
				if (pos != std::string::npos)
					name = name.substr(pos+1);
				if (GetCurrentProcessId() == info.pid || name.length() == 0)
					continue;
				cnFound = (cnFound || (!name.compare("cn.exe")));
				dbnFound = (dbnFound || (!name.compare("dbn.exe")));
			}
			// set values to save
			curPd->cnFound = cnFound;
			curPd->dbnFound = dbnFound;
		}
    }
	m_nvmlData = true;
	return;
}
}}}
#endif