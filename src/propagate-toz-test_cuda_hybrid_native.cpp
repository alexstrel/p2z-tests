/*
nvc++ -cuda -O2 -std=c++20 --gcc-toolchain=path-to-gnu-compiler -stdpar=gpu -gpu=cc86 -gpu=managed -gpu=fma -gpu=fastmath -gpu=autocollapse -gpu=loadcache:L1 -gpu=unroll ./src/propagate-toz-test_cuda_hybrid_native.cpp  -o ./propagate_nvcpp_cuda -Dntrks=8192 -Dnevts=100 -DNITER=5 -Dbsize=1 -Dnlayer=20

nvc++ -cuda -O2 -std=c++20 --gcc-toolchain=path-to-gnu-compiler -stdpar=multicore -gpu=cc86 -gpu=managed -gpu=fma -gpu=fastmath -gpu=autocollapse -gpu=loadcache:L1 -gpu=unroll ./src/propagate-toz-test_cuda_hybrid_native.cpp  -o ./propagate_nvcpp_cuda -Dntrks=8192 -Dnevts=100 -DNITER=5 -Dbsize=1 -Dnlayer=20

nvc++ -O2 -std=c++20 --gcc-toolchain=path-to-gnu-compiler -stdpar=multicore ./src/propagate-toz-test_cuda_hybrid_native.cpp  -o ./propagate_nvcpp_x86 -Dntrks=8192 -Dnevts=100 -DNITER=5 -Dbsize=32 -Dnlayer=20

*/

#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <unistd.h>
#include <iostream>
#include <chrono>
#include <iomanip>
#include <sys/time.h>

#include <concepts> 
#include <ranges>
#include <type_traits>

#include <algorithm>
#include <vector>
#include <memory>
#include <numeric>
#include <execution>
#include <random>

#ifndef bsize
#if defined(__NVCOMPILER_CUDA__)
#define bsize 1
#else
#define bsize 128
#endif//__NVCOMPILER_CUDA__
#endif

#ifndef ntrks
#define ntrks 8192
#endif

#define nb    (ntrks/bsize)

#ifndef nevts
#define nevts 100
#endif
#define smear 0.00001

#ifndef NITER
#define NITER 5
#endif
#ifndef nlayer
#define nlayer 20
#endif

#define num_streams 1

#ifndef threadsperblockx
#define threadsperblockx 16
#endif

#ifndef threadsperblocky
#define threadsperblocky 2
#endif

#ifdef __NVCOMPILER_CUDA__
//#include <nv/target>
#define __cuda_kernel__ __global__
constexpr bool enable_cuda         = true;
//
static int threads_per_blockx = threadsperblockx;
static int threads_per_blocky = threadsperblocky;
#ifdef include_data
constexpr bool include_data_transfer = true;
#else
constexpr bool include_data_transfer = false;
#endif
#else
#define __cuda_kernel__
constexpr bool enable_cuda           = false;
constexpr bool include_data_transfer = false;
#endif

constexpr int host_id = -1; /*cudaCpuDeviceId*/

static int nstreams           = num_streams;//we have only one stream, though

template <bool is_cuda_target>
concept CudaCompute = is_cuda_target == true;

//Collection of helper methods
//General helper routines:
template <bool is_cuda_target>
requires CudaCompute<is_cuda_target>
inline void p2z_check_error(){
  //	
  auto error = cudaGetLastError();
  if(error != cudaSuccess) std::cout << "Error detected, error " << error << std::endl;
  //
  return;
}

template <bool is_cuda_target>
inline void p2z_check_error(){
  return;
}

template <bool is_cuda_target>
requires CudaCompute<is_cuda_target>
inline int p2z_get_compute_device_id(){
  int dev = -1;
  cudaGetDevice(&dev);
  cudaDeviceSetCacheConfig(cudaFuncCachePreferL1);
  return dev;
}

//default version:
template <bool is_cuda_target>
inline int p2z_get_compute_device_id(){
  return 0;
}

template <bool is_cuda_target>
requires CudaCompute<is_cuda_target>
inline void p2z_set_compute_device(const int dev){
  cudaSetDevice(dev);
  cudaDeviceSetCacheConfig(cudaFuncCachePreferL1);
  return;
}

//default version:
template <bool is_cuda_target>
inline void p2z_set_compute_device(const int dev){
  return;
}

template <bool is_cuda_target>
requires CudaCompute<is_cuda_target>
inline decltype(auto) p2z_get_streams(const int n){
  std::vector<cudaStream_t> streams;
  streams.reserve(n);
  for (int i = 0; i < n; i++) {  
    cudaStream_t stream;
    cudaStreamCreate(&stream);
    streams.push_back(stream);
  }
  return streams;
}

template <bool is_cuda_target>
inline decltype(auto) p2z_get_streams(const int n){
  if(n > 1) std::cout << "Number of compute streams is not supported : " << n << std::endl; 
  std::vector<int> streams = {0};
  return streams;
}

//CUDA specialized version:
template <typename data_tp, bool is_cuda_target, typename stream_t, bool is_sync = false>
requires CudaCompute<is_cuda_target>
void p2z_prefetch(std::vector<data_tp> &v, int devId, stream_t stream) {
  cudaMemPrefetchAsync(v.data(), v.size() * sizeof(data_tp), devId, stream);
  //
  if constexpr (is_sync) {cudaStreamSynchronize(stream);}

  return;
}

//Default implementation
template <typename data_tp, bool is_cuda_target, typename stream_t, bool is_sync = false>
void p2z_prefetch(std::vector<data_tp> &v, int dev_id, stream_t stream) {
  return;
}


//CUDA specialized version:
template <bool is_cuda_target>
requires CudaCompute<is_cuda_target>
void p2z_wait() { 
  cudaDeviceSynchronize(); 
  return; 
}

template <bool is_cuda_target>
void p2z_wait() { 
  return; 
}

//used only in cuda 
template <bool is_cuda_target, bool is_verbose = true>
requires CudaCompute<is_cuda_target>
void info(int device) {
  cudaDeviceProp deviceProp;

  int driver_version;
  cudaDriverGetVersion(&driver_version);
  if constexpr (is_verbose) { std::cout << "CUDA Driver version = " << driver_version << std::endl;}

  int runtime_version;
  cudaRuntimeGetVersion(&runtime_version);
  if constexpr (is_verbose) { std::cout << "CUDA Runtime version = " << runtime_version << std::endl;}

  cudaGetDeviceProperties(&deviceProp, device);

  if constexpr (is_verbose) {
    printf("%d - name:                    %s\n", device, deviceProp.name);
    printf("%d - totalGlobalMem:          %lu bytes ( %.2f Gbytes)\n", device, deviceProp.totalGlobalMem,
                   deviceProp.totalGlobalMem / (float)(1024 * 1024 * 1024));
    printf("%d - sharedMemPerBlock:       %lu bytes ( %.2f Kbytes)\n", device, deviceProp.sharedMemPerBlock, deviceProp.sharedMemPerBlock / (float)1024);
    printf("%d - regsPerBlock:            %d\n", device, deviceProp.regsPerBlock);
    printf("%d - warpSize:                %d\n", device, deviceProp.warpSize);
    printf("%d - memPitch:                %lu\n", device, deviceProp.memPitch);
    printf("%d - maxThreadsPerBlock:      %d\n", device, deviceProp.maxThreadsPerBlock);
    printf("%d - maxThreadsDim[0]:        %d\n", device, deviceProp.maxThreadsDim[0]);
    printf("%d - maxThreadsDim[1]:        %d\n", device, deviceProp.maxThreadsDim[1]);
    printf("%d - maxThreadsDim[2]:        %d\n", device, deviceProp.maxThreadsDim[2]);
    printf("%d - maxGridSize[0]:          %d\n", device, deviceProp.maxGridSize[0]);
    printf("%d - maxGridSize[1]:          %d\n", device, deviceProp.maxGridSize[1]);
    printf("%d - maxGridSize[2]:          %d\n", device, deviceProp.maxGridSize[2]);
    printf("%d - totalConstMem:           %lu bytes ( %.2f Kbytes)\n", device, deviceProp.totalConstMem,
                   deviceProp.totalConstMem / (float)1024);
    printf("%d - compute capability:      %d.%d\n", device, deviceProp.major, deviceProp.minor);
    printf("%d - deviceOverlap            %s\n", device, (deviceProp.deviceOverlap ? "true" : "false"));
    printf("%d - multiProcessorCount      %d\n", device, deviceProp.multiProcessorCount);
    printf("%d - kernelExecTimeoutEnabled %s\n", device,
                   (deviceProp.kernelExecTimeoutEnabled ? "true" : "false"));
    printf("%d - integrated               %s\n", device, (deviceProp.integrated ? "true" : "false"));
    printf("%d - canMapHostMemory         %s\n", device, (deviceProp.canMapHostMemory ? "true" : "false"));
    switch (deviceProp.computeMode) {
      case 0: printf("%d - computeMode              0: cudaComputeModeDefault\n", device); break;
      case 1: printf("%d - computeMode              1: cudaComputeModeExclusive\n", device); break;
      case 2: printf("%d - computeMode              2: cudaComputeModeProhibited\n", device); break;
      case 3: printf("%d - computeMode              3: cudaComputeModeExclusiveProcess\n", device); break;
      default: printf("Error: unknown deviceProp.computeMode."), exit(-1);
    }
    printf("%d - surfaceAlignment         %lu\n", device, deviceProp.surfaceAlignment);
    printf("%d - concurrentKernels        %s\n", device, (deviceProp.concurrentKernels ? "true" : "false"));
    printf("%d - ECCEnabled               %s\n", device, (deviceProp.ECCEnabled ? "true" : "false"));
    printf("%d - pciBusID                 %d\n", device, deviceProp.pciBusID);
    printf("%d - pciDeviceID              %d\n", device, deviceProp.pciDeviceID);
    printf("%d - pciDomainID              %d\n", device, deviceProp.pciDomainID);
    printf("%d - tccDriver                %s\n", device, (deviceProp.tccDriver ? "true" : "false"));

    switch (deviceProp.asyncEngineCount) {
      case 0: printf("%d - asyncEngineCount         1: host -> device only\n", device); break;
      case 1: printf("%d - asyncEngineCount         2: host <-> device\n", device); break;
      case 2: printf("%d - asyncEngineCount         0: not supported\n", device); break;
      default: printf("Error: unknown deviceProp.asyncEngineCount."), exit(-1);
    }
    printf("%d - unifiedAddressing        %s\n", device, (deviceProp.unifiedAddressing ? "true" : "false"));
    printf("%d - memoryClockRate          %d kilohertz\n", device, deviceProp.memoryClockRate);
    printf("%d - memoryBusWidth           %d bits\n", device, deviceProp.memoryBusWidth);
    printf("%d - l2CacheSize              %d bytes\n", device, deviceProp.l2CacheSize);
    printf("%d - maxThreadsPerMultiProcessor          %d\n\n", device, deviceProp.maxThreadsPerMultiProcessor);


  }

  p2z_check_error<is_cuda_target>();

  return;	  
}

template <bool is_cuda_target, bool is_verbose = true>
void info(int device) {
  return;
}

//////////

const std::array<size_t, 36> SymOffsets66{0, 1, 3, 6, 10, 15, 1, 2, 4, 7, 11, 16, 3, 4, 5, 8, 12, 17, 6, 7, 8, 9, 13, 18, 10, 11, 12, 13, 14, 19, 15, 16, 17, 18, 19, 20};

struct ATRK {
  std::array<float,6> par;
  std::array<float,21> cov;
  int q;
};

struct AHIT {
  std::array<float,3> pos;
  std::array<float,6> cov;
};

constexpr int iparX     = 0;
constexpr int iparY     = 1;
constexpr int iparZ     = 2;
constexpr int iparIpt   = 3;
constexpr int iparPhi   = 4;
constexpr int iparTheta = 5;

template <typename T, int N, int bSize>
struct MPNX {
   std::array<T,N*bSize> data;
   //basic accessors
   const T& operator[](const int idx) const {return data[idx];}
   T& operator[](const int idx) {return data[idx];}
   const T& operator()(const int m, const int b) const {return data[m*bSize+b];}
   T& operator()(const int m, const int b) {return data[m*bSize+b];}
   //
   void load(MPNX& dst) const{
     for (size_t it=0;it<bSize;++it) {
     //const int l = it+ib*bsize+ie*nb*bsize;
       for (size_t ip=0;ip<N;++ip) {    	
    	 dst.data[it + ip*bSize] = this->operator()(ip, it);  
       }
     }//
     
     return;
   }

   void save(const MPNX& src) {
     for (size_t it=0;it<bSize;++it) {
     //const int l = it+ib*bsize+ie*nb*bsize;
       for (size_t ip=0;ip<N;++ip) {    	
    	 this->operator()(ip, it) = src.data[it + ip*bSize];  
       }
     }//
     
     return;
   }
};

using MP1I    = MPNX<int,   1 , bsize>;
using MP1F    = MPNX<float, 1 , bsize>;
using MP2F    = MPNX<float, 3 , bsize>;
using MP3F    = MPNX<float, 3 , bsize>;
using MP6F    = MPNX<float, 6 , bsize>;
using MP2x2SF = MPNX<float, 3 , bsize>;
using MP3x3SF = MPNX<float, 6 , bsize>;
using MP6x6SF = MPNX<float, 21, bsize>;
using MP6x6F  = MPNX<float, 36, bsize>;
using MP3x3   = MPNX<float, 9 , bsize>;
using MP3x6   = MPNX<float, 18, bsize>;

struct MPTRK {
  MP6F    par;
  MP6x6SF cov;
  MP1I    q;

  //  MP22I   hitidx;
  void load(MPTRK &dst){
    par.load(dst.par);
    cov.load(dst.cov);
    q.load(dst.q);    
    return;	  
  }
  void save(const MPTRK &src){
    par.save(src.par);
    cov.save(src.cov);
    q.save(src.q);
    return;
  }
};

struct MPHIT {
  MP3F    pos;
  MP3x3SF cov;
  //
  void load(MPHIT &dst){
    pos.load(dst.pos);
    cov.load(dst.cov);
    return;
  }
  void save(const MPHIT &src){
    pos.save(src.pos);
    cov.save(src.cov);

    return;
  }

};

///////////////////////////////////////
//Gen. utils

float randn(float mu, float sigma) {
  float U1, U2, W, mult;
  static float X1, X2;
  static int call = 0;
  if (call == 1) {
    call = !call;
    return (mu + sigma * (float) X2);
  } do {
    U1 = -1 + ((float) rand () / RAND_MAX) * 2;
    U2 = -1 + ((float) rand () / RAND_MAX) * 2;
    W = pow (U1, 2) + pow (U2, 2);
  }
  while (W >= 1 || W == 0); 
  mult = sqrt ((-2 * log (W)) / W);
  X1 = U1 * mult;
  X2 = U2 * mult; 
  call = !call; 
  return (mu + sigma * (float) X1);
}

void prepareTracks(std::vector<MPTRK> &trcks, ATRK &inputtrk) {
  //
  for (size_t ie=0;ie<nevts;++ie) {
    for (size_t ib=0;ib<nb;++ib) {
      for (size_t it=0;it<bsize;++it) {
	      //par
	      for (size_t ip=0;ip<6;++ip) {
	        trcks[ib + nb*ie].par.data[it + ip*bsize] = (1+smear*randn(0,1))*inputtrk.par[ip];
	      }
	      //cov, scale by factor 100
	      for (size_t ip=0;ip<21;++ip) {
	        trcks[ib + nb*ie].cov.data[it + ip*bsize] = (1+smear*randn(0,1))*inputtrk.cov[ip]*100;
	      }
	      //q
	      trcks[ib + nb*ie].q.data[it] = inputtrk.q;//can't really smear this or fit will be wrong
      }
    }
  }
  //
  return;
}

void prepareHits(std::vector<MPHIT> &hits, std::vector<AHIT>& inputhits) {
  // store in element order for bunches of bsize matrices (a la matriplex)
  for (size_t lay=0;lay<nlayer;++lay) {

    size_t mylay = lay;
    if (lay>=inputhits.size()) {
      // int wraplay = inputhits.size()/lay;
      exit(1);
    }
    AHIT& inputhit = inputhits[mylay];

    for (size_t ie=0;ie<nevts;++ie) {
      for (size_t ib=0;ib<nb;++ib) {
        for (size_t it=0;it<bsize;++it) {
        	//pos
        	for (size_t ip=0;ip<3;++ip) {
        	  hits[lay+nlayer*(ib + nb*ie)].pos.data[it + ip*bsize] = (1+smear*randn(0,1))*inputhit.pos[ip];
        	}
        	//cov
        	for (size_t ip=0;ip<6;++ip) {
        	  hits[lay+nlayer*(ib + nb*ie)].cov.data[it + ip*bsize] = (1+smear*randn(0,1))*inputhit.cov[ip];
        	}
        }
      }
    }
  }
  return;
}

//////////////////////////////////////////////////////////////////////////////////////
// Aux utils 
MPTRK* bTk(MPTRK* tracks, size_t ev, size_t ib) {
  return &(tracks[ib + nb*ev]);
}

const MPTRK* bTk(const MPTRK* tracks, size_t ev, size_t ib) {
  return &(tracks[ib + nb*ev]);
}

float q(const MP1I* bq, size_t it){
  return (*bq).data[it];
}
//
float par(const MP6F* bpars, size_t it, size_t ipar){
  return (*bpars).data[it + ipar*bsize];
}
float x    (const MP6F* bpars, size_t it){ return par(bpars, it, 0); }
float y    (const MP6F* bpars, size_t it){ return par(bpars, it, 1); }
float z    (const MP6F* bpars, size_t it){ return par(bpars, it, 2); }
float ipt  (const MP6F* bpars, size_t it){ return par(bpars, it, 3); }
float phi  (const MP6F* bpars, size_t it){ return par(bpars, it, 4); }
float theta(const MP6F* bpars, size_t it){ return par(bpars, it, 5); }
//
float par(const MPTRK* btracks, size_t it, size_t ipar){
  return par(&(*btracks).par,it,ipar);
}
float x    (const MPTRK* btracks, size_t it){ return par(btracks, it, 0); }
float y    (const MPTRK* btracks, size_t it){ return par(btracks, it, 1); }
float z    (const MPTRK* btracks, size_t it){ return par(btracks, it, 2); }
float ipt  (const MPTRK* btracks, size_t it){ return par(btracks, it, 3); }
float phi  (const MPTRK* btracks, size_t it){ return par(btracks, it, 4); }
float theta(const MPTRK* btracks, size_t it){ return par(btracks, it, 5); }
//
float par(const MPTRK* tracks, size_t ev, size_t tk, size_t ipar){
  size_t ib = tk/bsize;
  const MPTRK* btracks = bTk(tracks, ev, ib);
  size_t it = tk % bsize;
  return par(btracks, it, ipar);
}
float x    (const MPTRK* tracks, size_t ev, size_t tk){ return par(tracks, ev, tk, 0); }
float y    (const MPTRK* tracks, size_t ev, size_t tk){ return par(tracks, ev, tk, 1); }
float z    (const MPTRK* tracks, size_t ev, size_t tk){ return par(tracks, ev, tk, 2); }
float ipt  (const MPTRK* tracks, size_t ev, size_t tk){ return par(tracks, ev, tk, 3); }
float phi  (const MPTRK* tracks, size_t ev, size_t tk){ return par(tracks, ev, tk, 4); }
float theta(const MPTRK* tracks, size_t ev, size_t tk){ return par(tracks, ev, tk, 5); }
//

const MPHIT* bHit(const MPHIT* hits, size_t ev, size_t ib) {
  return &(hits[ib + nb*ev]);
}
const MPHIT* bHit(const MPHIT* hits, size_t ev, size_t ib,size_t lay) {
return &(hits[lay + (ib*nlayer) +(ev*nlayer*nb)]);
}
//
float Pos(const MP3F* hpos, size_t it, size_t ipar){
  return (*hpos).data[it + ipar*bsize];
}
float x(const MP3F* hpos, size_t it)    { return Pos(hpos, it, 0); }
float y(const MP3F* hpos, size_t it)    { return Pos(hpos, it, 1); }
float z(const MP3F* hpos, size_t it)    { return Pos(hpos, it, 2); }
//
float Pos(const MPHIT* hits, size_t it, size_t ipar){
  return Pos(&(*hits).pos,it,ipar);
}
float x(const MPHIT* hits, size_t it)    { return Pos(hits, it, 0); }
float y(const MPHIT* hits, size_t it)    { return Pos(hits, it, 1); }
float z(const MPHIT* hits, size_t it)    { return Pos(hits, it, 2); }
//
float Pos(const MPHIT* hits, size_t ev, size_t tk, size_t ipar){
  size_t ib = tk/bsize;
  const MPHIT* bhits = bHit(hits, ev, ib);
  size_t it = tk % bsize;
  return Pos(bhits,it,ipar);
}
float x(const MPHIT* hits, size_t ev, size_t tk)    { return Pos(hits, ev, tk, 0); }
float y(const MPHIT* hits, size_t ev, size_t tk)    { return Pos(hits, ev, tk, 1); }
float z(const MPHIT* hits, size_t ev, size_t tk)    { return Pos(hits, ev, tk, 2); }


////////////////////////////////////////////////////////////////////////
///MAIN compute kernels
template<int N = 1>
inline void MultHelixPropEndcap(const MP6x6F &a, const MP6x6SF &b, MP6x6F &c) {
//#pragma omp simd 
 for (int n = 0; n < N; ++n)
  {
    c[ 0*N+n] = b[ 0*N+n] + a[ 2*N+n]*b[ 3*N+n] + a[ 3*N+n]*b[ 6*N+n] + a[ 4*N+n]*b[10*N+n] + a[ 5*N+n]*b[15*N+n];
    c[ 1*N+n] = b[ 1*N+n] + a[ 2*N+n]*b[ 4*N+n] + a[ 3*N+n]*b[ 7*N+n] + a[ 4*N+n]*b[11*N+n] + a[ 5*N+n]*b[16*N+n];
    c[ 2*N+n] = b[ 3*N+n] + a[ 2*N+n]*b[ 5*N+n] + a[ 3*N+n]*b[ 8*N+n] + a[ 4*N+n]*b[12*N+n] + a[ 5*N+n]*b[17*N+n];
    c[ 3*N+n] = b[ 6*N+n] + a[ 2*N+n]*b[ 8*N+n] + a[ 3*N+n]*b[ 9*N+n] + a[ 4*N+n]*b[13*N+n] + a[ 5*N+n]*b[18*N+n];
    c[ 4*N+n] = b[10*N+n] + a[ 2*N+n]*b[12*N+n] + a[ 3*N+n]*b[13*N+n] + a[ 4*N+n]*b[14*N+n] + a[ 5*N+n]*b[19*N+n];
    c[ 5*N+n] = b[15*N+n] + a[ 2*N+n]*b[17*N+n] + a[ 3*N+n]*b[18*N+n] + a[ 4*N+n]*b[19*N+n] + a[ 5*N+n]*b[20*N+n];
    c[ 6*N+n] = b[ 1*N+n] + a[ 8*N+n]*b[ 3*N+n] + a[ 9*N+n]*b[ 6*N+n] + a[10*N+n]*b[10*N+n] + a[11*N+n]*b[15*N+n];
    c[ 7*N+n] = b[ 2*N+n] + a[ 8*N+n]*b[ 4*N+n] + a[ 9*N+n]*b[ 7*N+n] + a[10*N+n]*b[11*N+n] + a[11*N+n]*b[16*N+n];
    c[ 8*N+n] = b[ 4*N+n] + a[ 8*N+n]*b[ 5*N+n] + a[ 9*N+n]*b[ 8*N+n] + a[10*N+n]*b[12*N+n] + a[11*N+n]*b[17*N+n];
    c[ 9*N+n] = b[ 7*N+n] + a[ 8*N+n]*b[ 8*N+n] + a[ 9*N+n]*b[ 9*N+n] + a[10*N+n]*b[13*N+n] + a[11*N+n]*b[18*N+n];
    c[10*N+n] = b[11*N+n] + a[ 8*N+n]*b[12*N+n] + a[ 9*N+n]*b[13*N+n] + a[10*N+n]*b[14*N+n] + a[11*N+n]*b[19*N+n];
    c[11*N+n] = b[16*N+n] + a[ 8*N+n]*b[17*N+n] + a[ 9*N+n]*b[18*N+n] + a[10*N+n]*b[19*N+n] + a[11*N+n]*b[20*N+n];
    c[12*N+n] = 0.f;
    c[13*N+n] = 0.f;
    c[14*N+n] = 0.f;
    c[15*N+n] = 0.f;
    c[16*N+n] = 0.f;
    c[17*N+n] = 0.f;
    c[18*N+n] = b[ 6*N+n];
    c[19*N+n] = b[ 7*N+n];
    c[20*N+n] = b[ 8*N+n];
    c[21*N+n] = b[ 9*N+n];
    c[22*N+n] = b[13*N+n];
    c[23*N+n] = b[18*N+n];
    c[24*N+n] = a[26*N+n]*b[ 3*N+n] + a[27*N+n]*b[ 6*N+n] + b[10*N+n] + a[29*N+n]*b[15*N+n];
    c[25*N+n] = a[26*N+n]*b[ 4*N+n] + a[27*N+n]*b[ 7*N+n] + b[11*N+n] + a[29*N+n]*b[16*N+n];
    c[26*N+n] = a[26*N+n]*b[ 5*N+n] + a[27*N+n]*b[ 8*N+n] + b[12*N+n] + a[29*N+n]*b[17*N+n];
    c[27*N+n] = a[26*N+n]*b[ 8*N+n] + a[27*N+n]*b[ 9*N+n] + b[13*N+n] + a[29*N+n]*b[18*N+n];
    c[28*N+n] = a[26*N+n]*b[12*N+n] + a[27*N+n]*b[13*N+n] + b[14*N+n] + a[29*N+n]*b[19*N+n];
    c[29*N+n] = a[26*N+n]*b[17*N+n] + a[27*N+n]*b[18*N+n] + b[19*N+n] + a[29*N+n]*b[20*N+n];
    c[30*N+n] = b[15*N+n];
    c[31*N+n] = b[16*N+n];
    c[32*N+n] = b[17*N+n];
    c[33*N+n] = b[18*N+n];
    c[34*N+n] = b[19*N+n];
    c[35*N+n] = b[20*N+n];
  }
  return;
}

template<int N = 1>
inline void MultHelixPropTranspEndcap(const MP6x6F &a, const MP6x6F &b, MP6x6SF &c) {
//#pragma omp simd
  for (int n = 0; n < N; ++n)
  {
    c[ 0*N+n] = b[ 0*N+n] + b[ 2*N+n]*a[ 2*N+n] + b[ 3*N+n]*a[ 3*N+n] + b[ 4*N+n]*a[ 4*N+n] + b[ 5*N+n]*a[ 5*N+n];
    c[ 1*N+n] = b[ 6*N+n] + b[ 8*N+n]*a[ 2*N+n] + b[ 9*N+n]*a[ 3*N+n] + b[10*N+n]*a[ 4*N+n] + b[11*N+n]*a[ 5*N+n];
    c[ 2*N+n] = b[ 7*N+n] + b[ 8*N+n]*a[ 8*N+n] + b[ 9*N+n]*a[ 9*N+n] + b[10*N+n]*a[10*N+n] + b[11*N+n]*a[11*N+n];
    c[ 3*N+n] = b[12*N+n] + b[14*N+n]*a[ 2*N+n] + b[15*N+n]*a[ 3*N+n] + b[16*N+n]*a[ 4*N+n] + b[17*N+n]*a[ 5*N+n];
    c[ 4*N+n] = b[13*N+n] + b[14*N+n]*a[ 8*N+n] + b[15*N+n]*a[ 9*N+n] + b[16*N+n]*a[10*N+n] + b[17*N+n]*a[11*N+n];
    c[ 5*N+n] = 0.f;
    c[ 6*N+n] = b[18*N+n] + b[20*N+n]*a[ 2*N+n] + b[21*N+n]*a[ 3*N+n] + b[22*N+n]*a[ 4*N+n] + b[23*N+n]*a[ 5*N+n];
    c[ 7*N+n] = b[19*N+n] + b[20*N+n]*a[ 8*N+n] + b[21*N+n]*a[ 9*N+n] + b[22*N+n]*a[10*N+n] + b[23*N+n]*a[11*N+n];
    c[ 8*N+n] = 0.f;
    c[ 9*N+n] = b[21*N+n];
    c[10*N+n] = b[24*N+n] + b[26*N+n]*a[ 2*N+n] + b[27*N+n]*a[ 3*N+n] + b[28*N+n]*a[ 4*N+n] + b[29*N+n]*a[ 5*N+n];
    c[11*N+n] = b[25*N+n] + b[26*N+n]*a[ 8*N+n] + b[27*N+n]*a[ 9*N+n] + b[28*N+n]*a[10*N+n] + b[29*N+n]*a[11*N+n];
    c[12*N+n] = 0.f;
    c[13*N+n] = b[27*N+n];
    c[14*N+n] = b[26*N+n]*a[26*N+n] + b[27*N+n]*a[27*N+n] + b[28*N+n] + b[29*N+n]*a[29*N+n];
    c[15*N+n] = b[30*N+n] + b[32*N+n]*a[ 2*N+n] + b[33*N+n]*a[ 3*N+n] + b[34*N+n]*a[ 4*N+n] + b[35*N+n]*a[ 5*N+n];
    c[16*N+n] = b[31*N+n] + b[32*N+n]*a[ 8*N+n] + b[33*N+n]*a[ 9*N+n] + b[34*N+n]*a[10*N+n] + b[35*N+n]*a[11*N+n];
    c[17*N+n] = 0.f;
    c[18*N+n] = b[33*N+n];
    c[19*N+n] = b[32*N+n]*a[26*N+n] + b[33*N+n]*a[27*N+n] + b[34*N+n] + b[35*N+n]*a[29*N+n];
    c[20*N+n] = b[35*N+n];
  }
  return;
}

template<int N = 1>
inline void KalmanGainInv(const MP6x6SF &a, const MP3x3SF &b, MP3x3 &c) {

//#pragma omp simd
  for (int n = 0; n < N; ++n)
  {
    double det =
      ((a[0*N+n]+b[0*N+n])*(((a[ 6*N+n]+b[ 3*N+n]) *(a[11*N+n]+b[5*N+n])) - ((a[7*N+n]+b[4*N+n]) *(a[7*N+n]+b[4*N+n])))) -
      ((a[1*N+n]+b[1*N+n])*(((a[ 1*N+n]+b[ 1*N+n]) *(a[11*N+n]+b[5*N+n])) - ((a[7*N+n]+b[4*N+n]) *(a[2*N+n]+b[2*N+n])))) +
      ((a[2*N+n]+b[2*N+n])*(((a[ 1*N+n]+b[ 1*N+n]) *(a[7*N+n]+b[4*N+n])) - ((a[2*N+n]+b[2*N+n]) *(a[6*N+n]+b[3*N+n]))));
    double invdet = 1.0/det;

    c[ 0*N+n] =   invdet*(((a[ 6*N+n]+b[ 3*N+n]) *(a[11*N+n]+b[5*N+n])) - ((a[7*N+n]+b[4*N+n]) *(a[7*N+n]+b[4*N+n])));
    c[ 1*N+n] =  -invdet*(((a[ 1*N+n]+b[ 1*N+n]) *(a[11*N+n]+b[5*N+n])) - ((a[2*N+n]+b[2*N+n]) *(a[7*N+n]+b[4*N+n])));
    c[ 2*N+n] =   invdet*(((a[ 1*N+n]+b[ 1*N+n]) *(a[7*N+n]+b[4*N+n])) - ((a[2*N+n]+b[2*N+n]) *(a[7*N+n]+b[4*N+n])));
    c[ 3*N+n] =  -invdet*(((a[ 1*N+n]+b[ 1*N+n]) *(a[11*N+n]+b[5*N+n])) - ((a[7*N+n]+b[4*N+n]) *(a[2*N+n]+b[2*N+n])));
    c[ 4*N+n] =   invdet*(((a[ 0*N+n]+b[ 0*N+n]) *(a[11*N+n]+b[5*N+n])) - ((a[2*N+n]+b[2*N+n]) *(a[2*N+n]+b[2*N+n])));
    c[ 5*N+n] =  -invdet*(((a[ 0*N+n]+b[ 0*N+n]) *(a[7*N+n]+b[4*N+n])) - ((a[2*N+n]+b[2*N+n]) *(a[1*N+n]+b[1*N+n])));
    c[ 6*N+n] =   invdet*(((a[ 1*N+n]+b[ 1*N+n]) *(a[7*N+n]+b[4*N+n])) - ((a[2*N+n]+b[2*N+n]) *(a[6*N+n]+b[3*N+n])));
    c[ 7*N+n] =  -invdet*(((a[ 0*N+n]+b[ 0*N+n]) *(a[7*N+n]+b[4*N+n])) - ((a[2*N+n]+b[2*N+n]) *(a[1*N+n]+b[1*N+n])));
    c[ 8*N+n] =   invdet*(((a[ 0*N+n]+b[ 0*N+n]) *(a[6*N+n]+b[3*N+n])) - ((a[1*N+n]+b[1*N+n]) *(a[1*N+n]+b[1*N+n])));
  }
  
  return;
}

template <int N = 1>
inline void KalmanGain(const MP6x6SF &a, const MP3x3 &b, MP3x6 &c) {

//#pragma omp simd
  for (int n = 0; n < N; ++n)
  {
    c[ 0*N+n] = a[0*N+n]*b[0*N+n] + a[ 1*N+n]*b[3*N+n] + a[2*N+n]*b[6*N+n];
    c[ 1*N+n] = a[0*N+n]*b[1*N+n] + a[ 1*N+n]*b[4*N+n] + a[2*N+n]*b[7*N+n];
    c[ 2*N+n] = a[0*N+n]*b[2*N+n] + a[ 1*N+n]*b[5*N+n] + a[2*N+n]*b[8*N+n];
    c[ 3*N+n] = a[1*N+n]*b[0*N+n] + a[ 6*N+n]*b[3*N+n] + a[7*N+n]*b[6*N+n];
    c[ 4*N+n] = a[1*N+n]*b[1*N+n] + a[ 6*N+n]*b[4*N+n] + a[7*N+n]*b[7*N+n];
    c[ 5*N+n] = a[1*N+n]*b[2*N+n] + a[ 6*N+n]*b[5*N+n] + a[7*N+n]*b[8*N+n];
    c[ 6*N+n] = a[2*N+n]*b[0*N+n] + a[ 7*N+n]*b[3*N+n] + a[11*N+n]*b[6*N+n];
    c[ 7*N+n] = a[2*N+n]*b[1*N+n] + a[ 7*N+n]*b[4*N+n] + a[11*N+n]*b[7*N+n];
    c[ 8*N+n] = a[2*N+n]*b[2*N+n] + a[ 7*N+n]*b[5*N+n] + a[11*N+n]*b[8*N+n];
    c[ 9*N+n] = a[3*N+n]*b[0*N+n] + a[ 8*N+n]*b[3*N+n] + a[12*N+n]*b[6*N+n];
    c[10*N+n] = a[3*N+n]*b[1*N+n] + a[ 8*N+n]*b[4*N+n] + a[12*N+n]*b[7*N+n];
    c[11*N+n] = a[3*N+n]*b[2*N+n] + a[ 8*N+n]*b[5*N+n] + a[12*N+n]*b[8*N+n];
    c[12*N+n] = a[4*N+n]*b[0*N+n] + a[ 9*N+n]*b[3*N+n] + a[13*N+n]*b[6*N+n];
    c[13*N+n] = a[4*N+n]*b[1*N+n] + a[ 9*N+n]*b[4*N+n] + a[13*N+n]*b[7*N+n];
    c[14*N+n] = a[4*N+n]*b[2*N+n] + a[ 9*N+n]*b[5*N+n] + a[13*N+n]*b[8*N+n];
    c[15*N+n] = a[5*N+n]*b[0*N+n] + a[10*N+n]*b[3*N+n] + a[14*N+n]*b[6*N+n];
    c[16*N+n] = a[5*N+n]*b[1*N+n] + a[10*N+n]*b[4*N+n] + a[14*N+n]*b[7*N+n];
    c[17*N+n] = a[5*N+n]*b[2*N+n] + a[10*N+n]*b[5*N+n] + a[14*N+n]*b[8*N+n];
  }
  
  return;
}

template <int N = 1>
void KalmanUpdate(MP6x6SF &trkErr, MP6F &inPar, const MP3x3SF &hitErr, const MP3F &msP){

  MP3x3 inverse_temp;
  MP3x6 kGain;
  MP6x6SF newErr;
  
  KalmanGainInv<N>(trkErr, hitErr, inverse_temp);
  KalmanGain<N>(trkErr, inverse_temp, kGain);

//#pragma omp simd
  for (size_t it = 0;it < N;++it) {
    const auto xin     = inPar(iparX,it);
    const auto yin     = inPar(iparY,it);
    const auto zin     = inPar(iparZ,it);
    const auto ptin    = 1.f/ inPar(iparIpt,it);
    const auto phiin   = inPar(iparPhi,it);
    const auto thetain = inPar(iparTheta,it);
    const auto xout    = msP(iparX,it);
    const auto yout    = msP(iparY,it);
    //const auto zout    = msP(iparZ,it);

    auto xnew     = xin + (kGain[0*N+it]*(xout-xin)) +(kGain[1*N+it]*(yout-yin)); 
    auto ynew     = yin + (kGain[3*N+it]*(xout-xin)) +(kGain[4*N+it]*(yout-yin)); 
    auto znew     = zin + (kGain[6*N+it]*(xout-xin)) +(kGain[7*N+it]*(yout-yin)); 
    auto ptnew    = ptin + (kGain[9*N+it]*(xout-xin)) +(kGain[10*N+it]*(yout-yin)); 
    auto phinew   = phiin + (kGain[12*N+it]*(xout-xin)) +(kGain[13*N+it]*(yout-yin)); 
    auto thetanew = thetain + (kGain[15*N+it]*(xout-xin)) +(kGain[16*N+it]*(yout-yin)); 

    newErr[ 0*N+it] = trkErr[ 0*N+it] - (kGain[ 0*N+it]*trkErr[0*N+it]+kGain[1*N+it]*trkErr[1*N+it]+kGain[2*N+it]*trkErr[2*N+it]);
    newErr[ 1*N+it] = trkErr[ 1*N+it] - (kGain[ 0*N+it]*trkErr[1*N+it]+kGain[1*N+it]*trkErr[6*N+it]+kGain[2*N+it]*trkErr[7*N+it]);
    newErr[ 2*N+it] = trkErr[ 2*N+it] - (kGain[ 0*N+it]*trkErr[2*N+it]+kGain[1*N+it]*trkErr[7*N+it]+kGain[2*N+it]*trkErr[11*N+it]);
    newErr[ 3*N+it] = trkErr[ 3*N+it] - (kGain[ 0*N+it]*trkErr[3*N+it]+kGain[1*N+it]*trkErr[8*N+it]+kGain[2*N+it]*trkErr[12*N+it]);
    newErr[ 4*N+it] = trkErr[ 4*N+it] - (kGain[ 0*N+it]*trkErr[4*N+it]+kGain[1*N+it]*trkErr[9*N+it]+kGain[2*N+it]*trkErr[13*N+it]);
    newErr[ 5*N+it] = trkErr[ 5*N+it] - (kGain[ 0*N+it]*trkErr[5*N+it]+kGain[1*N+it]*trkErr[10*N+it]+kGain[2*N+it]*trkErr[14*N+it]);

    newErr[ 6*N+it] = trkErr[ 6*N+it] - (kGain[ 3*N+it]*trkErr[1*N+it]+kGain[4*N+it]*trkErr[6*N+it]+kGain[5*N+it]*trkErr[7*N+it]);
    newErr[ 7*N+it] = trkErr[ 7*N+it] - (kGain[ 3*N+it]*trkErr[2*N+it]+kGain[4*N+it]*trkErr[7*N+it]+kGain[5*N+it]*trkErr[11*N+it]);
    newErr[ 8*N+it] = trkErr[ 8*N+it] - (kGain[ 3*N+it]*trkErr[3*N+it]+kGain[4*N+it]*trkErr[8*N+it]+kGain[5*N+it]*trkErr[12*N+it]);
    newErr[ 9*N+it] = trkErr[ 9*N+it] - (kGain[ 3*N+it]*trkErr[4*N+it]+kGain[4*N+it]*trkErr[9*N+it]+kGain[5*N+it]*trkErr[13*N+it]);
    newErr[10*N+it] = trkErr[10*N+it] - (kGain[ 3*N+it]*trkErr[5*N+it]+kGain[4*N+it]*trkErr[10*N+it]+kGain[5*N+it]*trkErr[14*N+it]);

    newErr[11*N+it] = trkErr[11*N+it] - (kGain[ 6*N+it]*trkErr[2*N+it]+kGain[7*N+it]*trkErr[7*N+it]+kGain[8*N+it]*trkErr[11*N+it]);
    newErr[12*N+it] = trkErr[12*N+it] - (kGain[ 6*N+it]*trkErr[3*N+it]+kGain[7*N+it]*trkErr[8*N+it]+kGain[8*N+it]*trkErr[12*N+it]);
    newErr[13*N+it] = trkErr[13*N+it] - (kGain[ 6*N+it]*trkErr[4*N+it]+kGain[7*N+it]*trkErr[9*N+it]+kGain[8*N+it]*trkErr[13*N+it]);
    newErr[14*N+it] = trkErr[14*N+it] - (kGain[ 6*N+it]*trkErr[5*N+it]+kGain[7*N+it]*trkErr[10*N+it]+kGain[8*N+it]*trkErr[14*N+it]);

    newErr[15*N+it] = trkErr[15*N+it] - (kGain[ 9*N+it]*trkErr[3*N+it]+kGain[10*N+it]*trkErr[8*N+it]+kGain[11*N+it]*trkErr[12*N+it]);
    newErr[16*N+it] = trkErr[16*N+it] - (kGain[ 9*N+it]*trkErr[4*N+it]+kGain[10*N+it]*trkErr[9*N+it]+kGain[11*N+it]*trkErr[13*N+it]);
    newErr[17*N+it] = trkErr[17*N+it] - (kGain[ 9*N+it]*trkErr[5*N+it]+kGain[10*N+it]*trkErr[10*N+it]+kGain[11*N+it]*trkErr[14*N+it]);

    newErr[18*N+it] = trkErr[18*N+it] - (kGain[12*N+it]*trkErr[4*N+it]+kGain[13*N+it]*trkErr[9*N+it]+kGain[14*N+it]*trkErr[13*N+it]);
    newErr[19*N+it] = trkErr[19*N+it] - (kGain[12*N+it]*trkErr[5*N+it]+kGain[13*N+it]*trkErr[10*N+it]+kGain[14*N+it]*trkErr[14*N+it]);

    newErr[20*N+it] = trkErr[20*N+it] - (kGain[15*N+it]*trkErr[5*N+it]+kGain[16*N+it]*trkErr[10*N+it]+kGain[17*N+it]*trkErr[14*N+it]);
    
    inPar(iparX, it)     = xnew;
    inPar(iparY, it)     = ynew;
    inPar(iparZ, it)     = znew;
    inPar(iparIpt, it)   = ptnew;
    inPar(iparPhi, it)   = phinew;
    inPar(iparTheta, it) = thetanew;
    
 #pragma unroll
    for (int i = 0; i < 21; i++){
      trkErr[ i*N+it] = trkErr[ i*N+it] - newErr[ i*N+it];
    }

  }
  
  return;
}              

//constexpr auto kfact= 100/(-0.299792458*3.8112);
constexpr auto kfact= 100/3.8;

template<int N = 1>
void propagateToZ(const MP6x6SF &inErr, const MP6F &inPar, const MP1I &inChg, 
                  const MP3F &msP, MP6x6SF &outErr, MP6F &outPar) {
  
  MP6x6F errorProp;
  MP6x6F temp;

  auto PosInMtrx = [=] (int i, int j, int D, int block_size = 1) consteval {return block_size*(i*D+j);};
//#pragma omp simd
  for (size_t it=0;it<N;++it) {	
    const auto zout = msP(iparZ,it);
    //note: in principle charge is not needed and could be the sign of ipt
    const auto k = inChg[it]*kfact;
    const auto deltaZ = zout - inPar(iparZ,it);
    const auto ipt  = inPar(iparIpt,it);
    const auto pt   = 1.f/ipt;
    const auto phi  = inPar(iparPhi,it);
    const auto cosP = cosf(phi);
    const auto sinP = sinf(phi);
    const auto theta= inPar(iparTheta,it);
    const auto cosT = cosf(theta);
    const auto sinT = sinf(theta);
    const auto pxin = cosP*pt;
    const auto pyin = sinP*pt;
    const auto icosT  = 1.f/cosT;
    const auto icosTk = icosT/k;
    const auto alpha  = deltaZ*sinT*ipt*icosTk;
    //const auto alpha = deltaZ*sinT*ipt(inPar,it)/(cosT*k);
    const auto sina = sinf(alpha); // this can be approximated;
    const auto cosa = cosf(alpha); // this can be approximated;
    //
    outPar(iparX, it)     = inPar(iparX,it) + k*(pxin*sina - pyin*(1.f-cosa));
    outPar(iparY, it)     = inPar(iparY,it) + k*(pyin*sina + pxin*(1.f-cosa));
    outPar(iparZ, it)     = zout;
    outPar(iparIpt, it)   = ipt;
    outPar(iparPhi, it)   = phi +alpha;
    outPar(iparTheta, it) = theta;
    
    const auto sCosPsina = sinf(cosP*sina);
    const auto cCosPsina = cosf(cosP*sina);
    
    //for (size_t i=0;i<6;++i) errorProp[bsize*PosInMtrx(i,i,6) + it] = 1.;
    errorProp[PosInMtrx(0,0,6, N) + it] = 1.0f;
    errorProp[PosInMtrx(1,1,6, N) + it] = 1.0f;
    errorProp[PosInMtrx(2,2,6, N) + it] = 1.0f;
    errorProp[PosInMtrx(3,3,6, N) + it] = 1.0f;
    errorProp[PosInMtrx(4,4,6, N) + it] = 1.0f;
    errorProp[PosInMtrx(5,5,6, N) + it] = 1.0f;
    //
    errorProp[PosInMtrx(0,1,6, N) + it] = 0.f;
    errorProp[PosInMtrx(0,2,6, N) + it] = cosP*sinT*(sinP*cosa*sCosPsina-cosa)*icosT;
    errorProp[PosInMtrx(0,3,6, N) + it] = cosP*sinT*deltaZ*cosa*(1.f-sinP*sCosPsina)*(icosT*pt)-k*(cosP*sina-sinP*(1.f-cCosPsina))*(pt*pt);
    errorProp[PosInMtrx(0,4,6, N) + it] = (k*pt)*(-sinP*sina+sinP*sinP*sina*sCosPsina-cosP*(1.f-cCosPsina));
    errorProp[PosInMtrx(0,5,6, N) + it] = cosP*deltaZ*cosa*(1.f-sinP*sCosPsina)*(icosT*icosT);
    errorProp[PosInMtrx(1,2,6, N) + it] = cosa*sinT*(cosP*cosP*sCosPsina-sinP)*icosT;
    errorProp[PosInMtrx(1,3,6, N) + it] = sinT*deltaZ*cosa*(cosP*cosP*sCosPsina+sinP)*(icosT*pt)-k*(sinP*sina+cosP*(1.f-cCosPsina))*(pt*pt);
    errorProp[PosInMtrx(1,4,6, N) + it] = (k*pt)*(-sinP*(1.f-cCosPsina)-sinP*cosP*sina*sCosPsina+cosP*sina);
    errorProp[PosInMtrx(1,5,6, N) + it] = deltaZ*cosa*(cosP*cosP*sCosPsina+sinP)*(icosT*icosT);
    errorProp[PosInMtrx(4,2,6, N) + it] = -ipt*sinT*(icosTk);//!
    errorProp[PosInMtrx(4,3,6, N) + it] = sinT*deltaZ*(icosTk);
    errorProp[PosInMtrx(4,5,6, N) + it] = ipt*deltaZ*(icosT*icosTk);//!
  }
  
  MultHelixPropEndcap<N>(errorProp, inErr, temp);
  MultHelixPropTranspEndcap<N>(errorProp, temp, outErr);
  
  return;
}

template <typename lambda_tp, bool grid_stride = false>
requires (enable_cuda == true)
__cuda_kernel__ void launch_p2z_cuda_kernel(const lambda_tp p2z_kernel, const int length){

  auto ib = threadIdx.x + blockIdx.x * blockDim.x;
  auto ie = threadIdx.y + blockIdx.y * blockDim.y;

  auto i = ib + nb*ie;

  while (i < length) {
    p2z_kernel(i);

    if constexpr (grid_stride) { i += (gridDim.x * blockDim.x)*(gridDim.y * blockDim.y);}
    else  break;
  }

  return;
}

//CUDA specialized version:
template <typename stream_tp, bool is_cuda_target>
requires CudaCompute<is_cuda_target>
void dispatch_p2z_kernels(auto&& p2z_kernel, stream_tp stream, const int ntrks_, const int nevnts_){

  const int outer_loop_range = nevnts_*ntrks_;

  const int blockx = threads_per_blockx;
  const int blocky = threads_per_blocky;

  dim3 blocks(blockx, blocky, 1);
  dim3 grid(((ntrks_ + blockx - 1)/ blockx), ((nevnts_ + blocky - 1)/ blocky),1);
  //
  launch_p2z_cuda_kernel<<<grid, blocks, 0, stream>>>(p2z_kernel, outer_loop_range);
  //
  p2z_check_error<is_cuda_target>();

  return;
}

//General (default) implementation for both x86 and nvidia accelerators:
template <typename stream_tp, bool is_cuda_target>
void dispatch_p2z_kernels(auto&& p2z_kernel, stream_tp stream, const int ntrks_, const int nevnts_){
  //
  auto policy = std::execution::par_unseq;
  //
  auto outer_loop_range = std::ranges::views::iota(0, ntrks_*nevnts_);
  //
  std::for_each(policy,
                std::ranges::begin(outer_loop_range),
                std::ranges::end(outer_loop_range),
                p2z_kernel);

  return;
}


int main (int argc, char* argv[]) {
   #include "input_track.h"

   std::vector<AHIT> inputhits{inputhit21,inputhit20,inputhit19,inputhit18,inputhit17,inputhit16,inputhit15,inputhit14,
                               inputhit13,inputhit12,inputhit11,inputhit10,inputhit09,inputhit08,inputhit07,inputhit06,
                               inputhit05,inputhit04,inputhit03,inputhit02,inputhit01,inputhit00};

   printf("track in pos: x=%f, y=%f, z=%f, r=%f, pt=%f, phi=%f, theta=%f \n", inputtrk.par[0], inputtrk.par[1], inputtrk.par[2],
	  sqrtf(inputtrk.par[0]*inputtrk.par[0] + inputtrk.par[1]*inputtrk.par[1]),
	  1./inputtrk.par[3], inputtrk.par[4], inputtrk.par[5]);
   printf("track in cov: xx=%.2e, yy=%.2e, zz=%.2e \n", inputtrk.cov[SymOffsets66[0]],
	                                       inputtrk.cov[SymOffsets66[(1*6+1)]],
	                                       inputtrk.cov[SymOffsets66[(2*6+2)]]);
   for (size_t lay=0; lay<nlayer; lay++){
     printf("hit in layer=%lu, pos: x=%f, y=%f, z=%f, r=%f \n", lay, inputhits[lay].pos[0], inputhits[lay].pos[1], inputhits[lay].pos[2], sqrtf(inputhits[lay].pos[0]*inputhits[lay].pos[0] + inputhits[lay].pos[1]*inputhits[lay].pos[1]));
   }
   
   printf("produce nevts=%i ntrks=%i smearing by=%f \n", nevts, ntrks, smear);
   printf("NITER=%d\n", NITER);

   long setup_start, setup_stop;
   struct timeval timecheck;

   gettimeofday(&timecheck, NULL);
   setup_start = (long)timecheck.tv_sec * 1000 + (long)timecheck.tv_usec / 1000;

   if( (nevts*nb) % nstreams != 0 ) {
     std::cout << "Wrong number of streams :: " << nstreams << std::endl;
     exit(-1);
   }

   auto dev_id = p2z_get_compute_device_id<enable_cuda>();
   auto streams= p2z_get_streams<enable_cuda>(nstreams);

   auto stream = streams[0];//with UVM, we use only one compute stream 

   std::vector<MPTRK> outtrcks(nevts*nb);
   // migrate output object to dev memory:
   p2z_prefetch<MPTRK, enable_cuda>(outtrcks, dev_id, stream);

   std::vector<MPTRK> trcks(nevts*nb); 
   prepareTracks(trcks, inputtrk);
   //
   std::vector<MPHIT> hits(nlayer*nevts*nb);
   prepareHits(hits, inputhits);
   //
   if constexpr (include_data_transfer == false) {
     p2z_prefetch<MPTRK, enable_cuda>(trcks, dev_id, stream);
     p2z_prefetch<MPHIT, enable_cuda>(hits,  dev_id, stream);
   }
   //
   auto p2z_kernels = [=,btracksPtr    = trcks.data(),
                         outtracksPtr  = outtrcks.data(),
                         bhitsPtr      = hits.data()] (const auto i) {
                         //  
                         MPTRK btracks;
                         MPTRK obtracks;
                         MPHIT bhits;
                         //
                         btracksPtr[i].load(btracks);
                         //
                         for(int layer=0; layer<nlayer; ++layer) {
                           //
                           bhitsPtr[layer+nlayer*i].load(bhits);
                           //
                           propagateToZ<bsize>(btracks.cov, btracks.par, btracks.q, bhits.pos, obtracks.cov, obtracks.par);
                           KalmanUpdate<bsize>(obtracks.cov, obtracks.par, bhits.cov, bhits.pos);
                           //
                         }
                         //
                         outtracksPtr[i].save(obtracks);
                       };
   // synchronize to ensure that all needed data is on the device:
   p2z_wait<enable_cuda>();
 
   gettimeofday(&timecheck, NULL);
   setup_stop = (long)timecheck.tv_sec * 1000 + (long)timecheck.tv_usec / 1000;

   printf("done preparing!\n");

   printf("Size of struct MPTRK trk[] = %ld\n", nevts*nb*sizeof(MPTRK));
   printf("Size of struct MPTRK outtrk[] = %ld\n", nevts*nb*sizeof(MPTRK));
   printf("Size of struct struct MPHIT hit[] = %ld\n", nevts*nb*sizeof(MPHIT));

   //info<enable_cuda>(dev_id);
   double wall_time = 0.0;

   for(int itr=0; itr<NITER; itr++) {

     auto wall_start = std::chrono::high_resolution_clock::now();
     //
     if constexpr (include_data_transfer) {
       p2z_prefetch<MPTRK, enable_cuda>(trcks, dev_id, stream);
       p2z_prefetch<MPHIT, enable_cuda>(hits,  dev_id, stream);
     }
     //
     dispatch_p2z_kernels<decltype(stream), enable_cuda>(p2z_kernels, stream, nb, nevts);
     //
     if constexpr (include_data_transfer) {  
       p2z_prefetch<MPTRK, enable_cuda>(outtrcks, host_id, stream); 
     }
     //
     p2z_wait<enable_cuda>();
     //
     auto wall_stop = std::chrono::high_resolution_clock::now();
     //
     auto wall_diff = wall_stop - wall_start;
     //
     wall_time += static_cast<double>(std::chrono::duration_cast<std::chrono::microseconds>(wall_diff).count()) / 1e6;
     // reset initial states (don't need if we won't measure data migrations):
     if constexpr (include_data_transfer) {

       p2z_prefetch<MPTRK, enable_cuda>(trcks, host_id, stream);
       p2z_prefetch<MPHIT, enable_cuda>(hits,  host_id, stream);
       //
       p2z_prefetch<MPTRK, enable_cuda, decltype(stream), true>(outtrcks, dev_id, stream);
     }
   } //end of itr loop

   printf("setup time time=%f (s)\n", (setup_stop-setup_start)*0.001);
   printf("done ntracks=%i tot time=%f (s) time/trk=%e (s)\n", nevts*ntrks*int(NITER), wall_time, wall_time/(nevts*ntrks*int(NITER)));
   printf("formatted %i %i %i %i %i %f 0 %f %i\n",int(NITER),nevts, ntrks, bsize, nb, wall_time, (setup_stop-setup_start)*0.001, -1);

   auto outtrk = outtrcks.data();

   int nnans = 0, nfail = 0;
   float avgx = 0, avgy = 0, avgz = 0, avgr = 0;
   float avgpt = 0, avgphi = 0, avgtheta = 0;
   float avgdx = 0, avgdy = 0, avgdz = 0, avgdr = 0;

   for (size_t ie=0;ie<nevts;++ie) {
     for (size_t it=0;it<ntrks;++it) {
       float x_ = x(outtrk,ie,it);
       float y_ = y(outtrk,ie,it);
       float z_ = z(outtrk,ie,it);
       float r_ = sqrtf(x_*x_ + y_*y_);
       float pt_ = std::abs(1./ipt(outtrk,ie,it));
       float phi_ = phi(outtrk,ie,it);
       float theta_ = theta(outtrk,ie,it);
       float hx_ = inputhits[nlayer-1].pos[0];
       float hy_ = inputhits[nlayer-1].pos[1];
       float hz_ = inputhits[nlayer-1].pos[2];
       float hr_ = sqrtf(hx_*hx_ + hy_*hy_);
       if (std::isfinite(x_)==false ||
          std::isfinite(y_)==false ||
          std::isfinite(z_)==false ||
          std::isfinite(pt_)==false ||
          std::isfinite(phi_)==false ||
          std::isfinite(theta_)==false
          ) {
        nnans++;
        continue;
       }
       if (fabs( (x_-hx_)/hx_ )>1. ||
	   fabs( (y_-hy_)/hy_ )>1. ||
	   fabs( (z_-hz_)/hz_ )>1.) {
	 nfail++;
	 continue;
       }
       avgpt += pt_;
       avgphi += phi_;
       avgtheta += theta_;
       avgx += x_;
       avgy += y_;
       avgz += z_;
       avgr += r_;
       avgdx += (x_-hx_)/x_;
       avgdy += (y_-hy_)/y_;
       avgdz += (z_-hz_)/z_;
       avgdr += (r_-hr_)/r_;
       //if((it+ie*ntrks)%100000==0) printf("iTrk = %i,  track (x,y,z,r)=(%.6f,%.6f,%.6f,%.6f) \n", it+ie*ntrks, x_,y_,z_,r_);
     }
   }

   avgpt = avgpt/float(nevts*ntrks);
   avgphi = avgphi/float(nevts*ntrks);
   avgtheta = avgtheta/float(nevts*ntrks);
   avgx = avgx/float(nevts*ntrks);
   avgy = avgy/float(nevts*ntrks);
   avgz = avgz/float(nevts*ntrks);
   avgr = avgr/float(nevts*ntrks);
   avgdx = avgdx/float(nevts*ntrks);
   avgdy = avgdy/float(nevts*ntrks);
   avgdz = avgdz/float(nevts*ntrks);
   avgdr = avgdr/float(nevts*ntrks);

   float stdx = 0, stdy = 0, stdz = 0, stdr = 0;
   float stddx = 0, stddy = 0, stddz = 0, stddr = 0;
   for (size_t ie=0;ie<nevts;++ie) {
     for (size_t it=0;it<ntrks;++it) {
       float x_ = x(outtrk,ie,it);
       float y_ = y(outtrk,ie,it);
       float z_ = z(outtrk,ie,it);
       float r_ = sqrtf(x_*x_ + y_*y_);
       float hx_ = inputhits[nlayer-1].pos[0];
       float hy_ = inputhits[nlayer-1].pos[1];
       float hz_ = inputhits[nlayer-1].pos[2];
       float hr_ = sqrtf(hx_*hx_ + hy_*hy_);
       if (std::isfinite(x_)==false ||
          std::isfinite(y_)==false ||
          std::isfinite(z_)==false
          ) {
        continue;
       }
       if (fabs( (x_-hx_)/hx_ )>1. ||
	   fabs( (y_-hy_)/hy_ )>1. ||
	   fabs( (z_-hz_)/hz_ )>1.) {
	 continue;
       }
       stdx += (x_-avgx)*(x_-avgx);
       stdy += (y_-avgy)*(y_-avgy);
       stdz += (z_-avgz)*(z_-avgz);
       stdr += (r_-avgr)*(r_-avgr);
       stddx += ((x_-hx_)/x_-avgdx)*((x_-hx_)/x_-avgdx);
       stddy += ((y_-hy_)/y_-avgdy)*((y_-hy_)/y_-avgdy);
       stddz += ((z_-hz_)/z_-avgdz)*((z_-hz_)/z_-avgdz);
       stddr += ((r_-hr_)/r_-avgdr)*((r_-hr_)/r_-avgdr);
     }
   }

   stdx = sqrtf(stdx/float(nevts*ntrks));
   stdy = sqrtf(stdy/float(nevts*ntrks));
   stdz = sqrtf(stdz/float(nevts*ntrks));
   stdr = sqrtf(stdr/float(nevts*ntrks));
   stddx = sqrtf(stddx/float(nevts*ntrks));
   stddy = sqrtf(stddy/float(nevts*ntrks));
   stddz = sqrtf(stddz/float(nevts*ntrks));
   stddr = sqrtf(stddr/float(nevts*ntrks));

   printf("track x avg=%f std/avg=%f\n", avgx, fabs(stdx/avgx));
   printf("track y avg=%f std/avg=%f\n", avgy, fabs(stdy/avgy));
   printf("track z avg=%f std/avg=%f\n", avgz, fabs(stdz/avgz));
   printf("track r avg=%f std/avg=%f\n", avgr, fabs(stdr/avgz));
   printf("track dx/x avg=%f std=%f\n", avgdx, stddx);
   printf("track dy/y avg=%f std=%f\n", avgdy, stddy);
   printf("track dz/z avg=%f std=%f\n", avgdz, stddz);
   printf("track dr/r avg=%f std=%f\n", avgdr, stddr);
   printf("track pt avg=%f\n", avgpt);
   printf("track phi avg=%f\n", avgphi);
   printf("track theta avg=%f\n", avgtheta);
   printf("number of tracks with nans=%i\n", nnans);
   printf("number of tracks failed=%i\n", nfail);

   return 0;
}
