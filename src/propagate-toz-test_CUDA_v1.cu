/*
icc propagate-toz-test.C -o propagate-toz-test.exe -fopenmp -O3
*/
#include "cuda_runtime.h"
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <unistd.h>
#include <sys/time.h>
#include <iostream>
#include <chrono>
#include <iomanip>

//#define DUMP_OUTPUT
#define FIXED_RSEED
//#define USE_ASYNC
#ifndef USE_ASYNC
#define num_streams 1
#endif

#ifndef nevts
#define nevts 100
#endif
#ifndef bsize
#define bsize 32
#endif
#ifndef ntrks
#define ntrks 9600
#endif

#define nb    (ntrks/bsize)
#define smear 0.00001

#ifndef NITER
#define NITER 5
#endif
#ifndef nlayer
#define nlayer 20
#endif
#ifndef num_streams
#define num_streams 10
#endif

#ifndef threadsperblockx
#define threadsperblockx bsize
#endif
#define threadsperblocky 1
#ifndef blockspergrid
#define blockspergrid nevts*nb/num_streams
#endif

#define HOSTDEV __host__ __device__

#define loadData(dst, src, tid, itrsize) \
  _Pragma("unroll")                      \
  for(int ip=0; ip<itrsize; ++ip) {      \
    dst[ip] = src[ip*bsize + tid];       \
  }                               

#define saveData(dst, src, tid, itrsize) \
  _Pragma("unroll")                      \
  for(int ip=0; ip<itrsize; ++ip) {      \
    dst[ip*bsize + tid] = src[ip];       \
  }         

#define iparX     0
#define iparY     1
#define iparZ     2
#define iparIpt   3
#define iparPhi   4
#define iparTheta 5

HOSTDEV size_t PosInMtrx(size_t i, size_t j, size_t D) {
  return i*D+j;
}

HOSTDEV size_t SymOffsets33(size_t i) {
  const size_t offs[9] = {0, 1, 3, 1, 2, 4, 3, 4, 5};
  return offs[i];
}

HOSTDEV size_t SymOffsets66(size_t i) {
  const size_t offs[36] = {0, 1, 3, 6, 10, 15, 1, 2, 4, 7, 11, 16, 3, 4, 5, 8, 12, 17, 6, 7, 8, 9, 13, 18, 10, 11, 12, 13, 14, 19, 15, 16, 17, 18, 19, 20};
  return offs[i];
}


struct ATRK {
  float par[6];
  float cov[21];
  int q;
  //  int hitidx[22];
};

struct AHIT {
  float pos[3];
  float cov[6];
};

struct MP1I {
  int data[1*bsize];
};

struct MP22I {
  int data[22*bsize];
};

struct MP3F {
  float data[3*bsize];
};

struct MP6F {
  float data[6*bsize];
};

struct MP3x3 {
  float data[9*bsize];
};

struct MP3x6 {
  float data[18*bsize];
};

struct MP3x3SF {
  float data[6*bsize];
};

struct MP6x6SF {
  float data[21*bsize];
};

struct MP6x6F {
  float data[36*bsize];
};

struct MP2x2SF {
  float data[3*bsize];
};

struct MP2x6 {
  float data[12*bsize];
};

struct MP2F {
  float data[2*bsize];
};

struct MPTRK {
  MP6F    par;
  MP6x6SF cov;
  MP1I    q;
  //  MP22I   hitidx;
};

struct MPHIT {
  MP3F    pos;
  MP3x3SF cov;
};

struct MP1I_ {
  int data[1];
};

struct MP22I_ {
  int data[22];
};

struct MP3F_ {
  float data[3];
};

struct MP6F_ {
  float data[6];
};

struct MP3x3_ {
  float data[9];
};
struct MP3x6_ {
  float data[18];
};

struct MP3x3SF_ {
  float data[6];
};

struct MP6x6SF_ {
  float data[21];
};

struct MP6x6F_ {
  float data[36];
};

struct MP2x2SF_ {
  float data[3];
};

struct MP2x6_ {
  float data[12];
};

struct MP2F_ {
  float data[2];
};

struct MPTRK_ {
  MP6F_    par;
  MP6x6SF_ cov;
  MP1I_    q;
//  MP22I_   hitidx;
};

struct MPHIT_ {
  MP3F_    pos;
  MP3x3SF_ cov;
};


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

MPTRK* prepareTracks(ATRK inputtrk) {
  MPTRK* result;
  cudaMallocManaged((void**)&result,nevts*nb*sizeof(MPTRK));
  for (size_t ie=0;ie<nevts;++ie) {
    for (size_t ib=0;ib<nb;++ib) {
      for (size_t it=0;it<bsize;++it) {
        //par
        for (size_t ip=0;ip<6;++ip) {
          result[ib + nb*ie].par.data[it + ip*bsize] = (1+smear*randn(0,1))*inputtrk.par[ip];
        }
        //cov, scale by factor 100
        for (size_t ip=0;ip<21;++ip) {
          result[ib + nb*ie].cov.data[it + ip*bsize] = (1+smear*randn(0,1))*inputtrk.cov[ip]*100;
        }
        //q
        result[ib + nb*ie].q.data[it] = inputtrk.q;//can't really smear this or fit will be wrong
      }
    }
  }
  return result;
}

MPHIT* prepareHits(AHIT* inputhits) {
  MPHIT* result;
  cudaMallocManaged((void**)&result,nlayer*nevts*nb*sizeof(MPHIT));
  for (size_t lay=0;lay<nlayer;++lay) {

    struct AHIT inputhit = inputhits[lay]; 

    for (size_t ie=0;ie<nevts;++ie) {
      for (size_t ib=0;ib<nb;++ib) {
        for (size_t it=0;it<bsize;++it) {
          //pos
          for (size_t ip=0;ip<3;++ip) {
            result[lay+nlayer*(ib + nb*ie)].pos.data[it + ip*bsize] = (1+smear*randn(0,1))*inputhit.pos[ip];
          }
          //cov
          for (size_t ip=0;ip<6;++ip) {
            result[lay+nlayer*(ib + nb*ie)].cov.data[it + ip*bsize] = (1+smear*randn(0,1))*inputhit.cov[ip];
          }
        }
      }
    }
  }
  return result;
}


HOSTDEV MPTRK* bTk(MPTRK* tracks, size_t ev, size_t ib) {
  return &(tracks[ib + nb*ev]);
}

HOSTDEV const MPTRK* bTk(const MPTRK* tracks, size_t ev, size_t ib) {
  return &(tracks[ib + nb*ev]);
}


HOSTDEV int q(const MP1I* bq, size_t it){
  return (*bq).data[it];
}

HOSTDEV float par(const MP6F* bpars, size_t it, size_t ipar){
  return (*bpars).data[it + ipar*bsize];
}
HOSTDEV float x    (const MP6F* bpars, size_t it){ return par(bpars, it, 0); }
HOSTDEV float y    (const MP6F* bpars, size_t it){ return par(bpars, it, 1); }
HOSTDEV float z    (const MP6F* bpars, size_t it){ return par(bpars, it, 2); }
HOSTDEV float ipt  (const MP6F* bpars, size_t it){ return par(bpars, it, 3); }
HOSTDEV float phi  (const MP6F* bpars, size_t it){ return par(bpars, it, 4); }
HOSTDEV float theta(const MP6F* bpars, size_t it){ return par(bpars, it, 5); }

HOSTDEV float par(const MPTRK* btracks, size_t it, size_t ipar){
  return par(&(*btracks).par,it,ipar);
}
HOSTDEV float x    (const MPTRK* btracks, size_t it){ return par(btracks, it, 0); }
HOSTDEV float y    (const MPTRK* btracks, size_t it){ return par(btracks, it, 1); }
HOSTDEV float z    (const MPTRK* btracks, size_t it){ return par(btracks, it, 2); }
HOSTDEV float ipt  (const MPTRK* btracks, size_t it){ return par(btracks, it, 3); }
HOSTDEV float phi  (const MPTRK* btracks, size_t it){ return par(btracks, it, 4); }
HOSTDEV float theta(const MPTRK* btracks, size_t it){ return par(btracks, it, 5); }

HOSTDEV float par(const MPTRK* tracks, size_t ev, size_t tk, size_t ipar){
  size_t ib = tk/bsize;
  const MPTRK* btracks = bTk(tracks, ev, ib);
  size_t it = tk % bsize;
  return par(btracks, it, ipar);
}

HOSTDEV float x    (const MPTRK* tracks, size_t ev, size_t tk){ return par(tracks, ev, tk, 0); }
HOSTDEV float y    (const MPTRK* tracks, size_t ev, size_t tk){ return par(tracks, ev, tk, 1); }
HOSTDEV float z    (const MPTRK* tracks, size_t ev, size_t tk){ return par(tracks, ev, tk, 2); }
HOSTDEV float ipt  (const MPTRK* tracks, size_t ev, size_t tk){ return par(tracks, ev, tk, 3); }
HOSTDEV float phi  (const MPTRK* tracks, size_t ev, size_t tk){ return par(tracks, ev, tk, 4); }
HOSTDEV float theta(const MPTRK* tracks, size_t ev, size_t tk){ return par(tracks, ev, tk, 5); }

HOSTDEV void setpar(MP6F* bpars, size_t it, size_t ipar, float val){
  (*bpars).data[it + ipar*bsize] = val;
}
HOSTDEV void setx    (MP6F* bpars, size_t it, float val){ setpar(bpars, it, 0, val); }
HOSTDEV void sety    (MP6F* bpars, size_t it, float val){ setpar(bpars, it, 1, val); }
HOSTDEV void setz    (MP6F* bpars, size_t it, float val){ setpar(bpars, it, 2, val); }
HOSTDEV void setipt  (MP6F* bpars, size_t it, float val){ setpar(bpars, it, 3, val); }
HOSTDEV void setphi  (MP6F* bpars, size_t it, float val){ setpar(bpars, it, 4, val); }
HOSTDEV void settheta(MP6F* bpars, size_t it, float val){ setpar(bpars, it, 5, val); }

HOSTDEV void setpar(MPTRK* btracks, size_t it, size_t ipar, float val){
  setpar(&(*btracks).par,it,ipar,val);
}
HOSTDEV void setx    (MPTRK* btracks, size_t it, float val){ setpar(btracks, it, 0, val); }
HOSTDEV void sety    (MPTRK* btracks, size_t it, float val){ setpar(btracks, it, 1, val); }
HOSTDEV void setz    (MPTRK* btracks, size_t it, float val){ setpar(btracks, it, 2, val); }
HOSTDEV void setipt  (MPTRK* btracks, size_t it, float val){ setpar(btracks, it, 3, val); }
HOSTDEV void setphi  (MPTRK* btracks, size_t it, float val){ setpar(btracks, it, 4, val); }
HOSTDEV void settheta(MPTRK* btracks, size_t it, float val){ setpar(btracks, it, 5, val); }

HOSTDEV MPHIT* bHit(MPHIT* hits, size_t ev, size_t ib) {
  return &(hits[ib + nb*ev]);
}
HOSTDEV const MPHIT* bHit(const MPHIT* hits, size_t ev, size_t ib) {
  return &(hits[ib + nb*ev]);
}
HOSTDEV const MPHIT* bHit(const MPHIT* hits, size_t ev, size_t ib,int lay) {
  return &(hits[lay + (ib*nlayer) +(ev*nlayer*nb)]);
}

HOSTDEV float pos(const MP3F* hpos, size_t it, size_t ipar){
  return (*hpos).data[it + ipar*bsize];
}
HOSTDEV float x(const MP3F* hpos, size_t it)    { return pos(hpos, it, 0); }
HOSTDEV float y(const MP3F* hpos, size_t it)    { return pos(hpos, it, 1); }
HOSTDEV float z(const MP3F* hpos, size_t it)    { return pos(hpos, it, 2); }

HOSTDEV float pos(const MPHIT* hits, size_t it, size_t ipar){
  return pos(&(*hits).pos,it,ipar);
}
HOSTDEV float x(const MPHIT* hits, size_t it)    { return pos(hits, it, 0); }
HOSTDEV float y(const MPHIT* hits, size_t it)    { return pos(hits, it, 1); }
HOSTDEV float z(const MPHIT* hits, size_t it)    { return pos(hits, it, 2); }

HOSTDEV float pos(const MPHIT* hits, size_t ev, size_t tk, size_t ipar){
  size_t ib = tk/bsize;
  //[DEBUG by Seyong on Dec. 28, 2020] add 4th argument(nlayer-1) to bHit() below.
  const MPHIT* bhits = bHit(hits, ev, ib, nlayer-1);
  size_t it = tk % bsize;
  return pos(bhits,it,ipar);
}
HOSTDEV float x(const MPHIT* hits, size_t ev, size_t tk)    { return pos(hits, ev, tk, 0); }
HOSTDEV float y(const MPHIT* hits, size_t ev, size_t tk)    { return pos(hits, ev, tk, 1); }
HOSTDEV float z(const MPHIT* hits, size_t ev, size_t tk)    { return pos(hits, ev, tk, 2); }



#define N bsize
__forceinline__ __device__ void MultHelixPropEndcap(const MP6x6F_* A, const MP6x6SF_* B, MP6x6F_* C) {
  const float *a = A->data; //ASSUME_ALIGNED(a, 64);
  const float *b = B->data; //ASSUME_ALIGNED(b, 64);
  float *c = C->data;       //ASSUME_ALIGNED(c, 64);
  {
    c[ 0] = b[ 0] + a[ 2]*b[ 3] + a[ 3]*b[ 6] + a[ 4]*b[10] + a[ 5]*b[15];
    c[ 1] = b[ 1] + a[ 2]*b[ 4] + a[ 3]*b[ 7] + a[ 4]*b[11] + a[ 5]*b[16];
    c[ 2] = b[ 3] + a[ 2]*b[ 5] + a[ 3]*b[ 8] + a[ 4]*b[12] + a[ 5]*b[17];
    c[ 3] = b[ 6] + a[ 2]*b[ 8] + a[ 3]*b[ 9] + a[ 4]*b[13] + a[ 5]*b[18];
    c[ 4] = b[10] + a[ 2]*b[12] + a[ 3]*b[13] + a[ 4]*b[14] + a[ 5]*b[19];
    c[ 5] = b[15] + a[ 2]*b[17] + a[ 3]*b[18] + a[ 4]*b[19] + a[ 5]*b[20];
    c[ 6] = b[ 1] + a[ 8]*b[ 3] + a[ 9]*b[ 6] + a[10]*b[10] + a[11]*b[15];
    c[ 7] = b[ 2] + a[ 8]*b[ 4] + a[ 9]*b[ 7] + a[10]*b[11] + a[11]*b[16];
    c[ 8] = b[ 4] + a[ 8]*b[ 5] + a[ 9]*b[ 8] + a[10]*b[12] + a[11]*b[17];
    c[ 9] = b[ 7] + a[ 8]*b[ 8] + a[ 9]*b[ 9] + a[10]*b[13] + a[11]*b[18];
    c[10] = b[11] + a[ 8]*b[12] + a[ 9]*b[13] + a[10]*b[14] + a[11]*b[19];
    c[11] = b[16] + a[ 8]*b[17] + a[ 9]*b[18] + a[10]*b[19] + a[11]*b[20];
    c[12] = 0;
    c[13] = 0;
    c[14] = 0;
    c[15] = 0;
    c[16] = 0;
    c[17] = 0;
    c[18] = b[ 6];
    c[19] = b[ 7];
    c[20] = b[ 8];
    c[21] = b[ 9];
    c[22] = b[13];
    c[23] = b[18];
    c[24] = a[26]*b[ 3] + a[27]*b[ 6] + b[10] + a[29]*b[15];
    c[25] = a[26]*b[ 4] + a[27]*b[ 7] + b[11] + a[29]*b[16];
    c[26] = a[26]*b[ 5] + a[27]*b[ 8] + b[12] + a[29]*b[17];
    c[27] = a[26]*b[ 8] + a[27]*b[ 9] + b[13] + a[29]*b[18];
    c[28] = a[26]*b[12] + a[27]*b[13] + b[14] + a[29]*b[19];
    c[29] = a[26]*b[17] + a[27]*b[18] + b[19] + a[29]*b[20];
    c[30] = b[15];
    c[31] = b[16];
    c[32] = b[17];
    c[33] = b[18];
    c[34] = b[19];
    c[35] = b[20];
  }
}

__forceinline__ __device__ void MultHelixPropTranspEndcap(MP6x6F_* A, MP6x6F_* B, MP6x6SF_* C) {
  const float *a = A->data; //ASSUME_ALIGNED(a, 64);
  const float *b = B->data; //ASSUME_ALIGNED(b, 64);
  float *c = C->data;       //ASSUME_ALIGNED(c, 64);
  {
    c[ 0] = b[ 0] + b[ 2]*a[ 2] + b[ 3]*a[ 3] + b[ 4]*a[ 4] + b[ 5]*a[ 5];
    c[ 1] = b[ 6] + b[ 8]*a[ 2] + b[ 9]*a[ 3] + b[10]*a[ 4] + b[11]*a[ 5];
    c[ 2] = b[ 7] + b[ 8]*a[ 8] + b[ 9]*a[ 9] + b[10]*a[10] + b[11]*a[11];
    c[ 3] = b[12] + b[14]*a[ 2] + b[15]*a[ 3] + b[16]*a[ 4] + b[17]*a[ 5];
    c[ 4] = b[13] + b[14]*a[ 8] + b[15]*a[ 9] + b[16]*a[10] + b[17]*a[11];
    c[ 5] = 0;
    c[ 6] = b[18] + b[20]*a[ 2] + b[21]*a[ 3] + b[22]*a[ 4] + b[23]*a[ 5];
    c[ 7] = b[19] + b[20]*a[ 8] + b[21]*a[ 9] + b[22]*a[10] + b[23]*a[11];
    c[ 8] = 0;
    c[ 9] = b[21];
    c[10] = b[24] + b[26]*a[ 2] + b[27]*a[ 3] + b[28]*a[ 4] + b[29]*a[ 5];
    c[11] = b[25] + b[26]*a[ 8] + b[27]*a[ 9] + b[28]*a[10] + b[29]*a[11];
    c[12] = 0;
    c[13] = b[27];
    c[14] = b[26]*a[26] + b[27]*a[27] + b[28] + b[29]*a[29];
    c[15] = b[30] + b[32]*a[ 2] + b[33]*a[ 3] + b[34]*a[ 4] + b[35]*a[ 5];
    c[16] = b[31] + b[32]*a[ 8] + b[33]*a[ 9] + b[34]*a[10] + b[35]*a[11];
    c[17] = 0;
    c[18] = b[33];
    c[19] = b[32]*a[26] + b[33]*a[27] + b[34] + b[35]*a[29];
    c[20] = b[35];
  }
}

__forceinline__ __device__ void KalmanGainInv(const MP6x6SF_* A, const MP3x3SF_* B, MP3x3_* C) {
  // k = P Ht(HPHt + R)^-1
  // HpHt -> cov of x,y,z. take upper 3x3 matrix of P
  // This calculates the inverse of HpHt +R
  const float *a = A->data; //ASSUME_ALIGNED(a, 64);
  const float *b = B->data; //ASSUME_ALIGNED(b, 64);
  float *c = C->data;       //ASSUME_ALIGNED(c, 64);
  {
    double det =
      ((a[0]+b[0])*(((a[ 6]+b[ 3]) *(a[11]+b[5])) - ((a[7]+b[4]) *(a[7]+b[4])))) -
      ((a[1]+b[1])*(((a[ 1]+b[ 1]) *(a[11]+b[5])) - ((a[7]+b[4]) *(a[2]+b[2])))) +
      ((a[2]+b[2])*(((a[ 1]+b[ 1]) *(a[7]+b[4])) - ((a[2]+b[2]) *(a[6]+b[3]))));
    double invdet = 1.0/det;

    c[ 0] =  invdet*(((a[ 6]+b[ 3]) *(a[11]+b[5])) - ((a[7]+b[4]) *(a[7]+b[4])));
    c[ 1] =  -invdet*(((a[ 1]+b[ 1]) *(a[11]+b[5])) - ((a[2]+b[2]) *(a[7]+b[4])));
    c[ 2] =  invdet*(((a[ 1]+b[ 1]) *(a[7]+b[4])) - ((a[2]+b[2]) *(a[7]+b[4])));
    c[ 3] =  -invdet*(((a[ 1]+b[ 1]) *(a[11]+b[5])) - ((a[7]+b[4]) *(a[2]+b[2])));
    c[ 4] =  invdet*(((a[ 0]+b[ 0]) *(a[11]+b[5])) - ((a[2]+b[2]) *(a[2]+b[2])));
    c[ 5] =  -invdet*(((a[ 0]+b[ 0]) *(a[7]+b[4])) - ((a[2]+b[2]) *(a[1]+b[1])));
    c[ 6] =  invdet*(((a[ 1]+b[ 1]) *(a[7]+b[4])) - ((a[2]+b[2]) *(a[6]+b[3])));
    c[ 7] =  -invdet*(((a[ 0]+b[ 0]) *(a[7]+b[4])) - ((a[2]+b[2]) *(a[1]+b[1])));
    c[ 8] =  invdet*(((a[ 0]+b[ 0]) *(a[6]+b[3])) - ((a[1]+b[1]) *(a[1]+b[1])));
  }
}

__forceinline__ __device__ void KalmanGain(const MP6x6SF_* A, const MP3x3_* B, MP3x6_* C) {
  // k = P Ht(HPHt + R)^-1
  // HpHt -> cov of x,y,z. take upper 3x3 matrix of P
  // This calculates the kalman gain 
  const float *a = A->data; //ASSUME_ALIGNED(a, 64);
  const float *b = B->data; //ASSUME_ALIGNED(b, 64);
  float *c = C->data;       //ASSUME_ALIGNED(c, 64);
  {
    c[ 0] = a[0]*b[0] + a[1]*b[3] + a[2]*b[6];
    c[ 1] = a[0]*b[1] + a[1]*b[4] + a[2]*b[7];
    c[ 2] = a[0]*b[2] + a[1]*b[5] + a[2]*b[8];
    c[ 3] = a[1]*b[0] + a[6]*b[3] + a[7]*b[6];
    c[ 4] = a[1]*b[1] + a[6]*b[4] + a[7]*b[7];
    c[ 5] = a[1]*b[2] + a[6]*b[5] + a[7]*b[8];
    c[ 6] = a[2]*b[0] + a[7]*b[3] + a[11]*b[6];
    c[ 7] = a[2]*b[1] + a[7]*b[4] + a[11]*b[7];
    c[ 8] = a[2]*b[2] + a[7]*b[5] + a[11]*b[8];
    c[ 9] = a[3]*b[0] + a[8]*b[3] + a[12]*b[6];
    c[ 10] = a[3]*b[1] + a[8]*b[4] + a[12]*b[7];
    c[ 11] = a[3]*b[2] + a[8]*b[5] + a[12]*b[8];
    c[ 12] = a[4]*b[0] + a[9]*b[3] + a[13]*b[6];
    c[ 13] = a[4]*b[1] + a[9]*b[4] + a[13]*b[7];
    c[ 14] = a[4]*b[2] + a[9]*b[5] + a[13]*b[8];
    c[ 15] = a[5]*b[0] + a[10]*b[3] + a[14]*b[6];
    c[ 16] = a[5]*b[1] + a[10]*b[4] + a[14]*b[7];
    c[ 17] = a[5]*b[2] + a[10]*b[5] + a[14]*b[8];
  }
}

__forceinline__ __device__ void KalmanUpdate(MP6x6SF_* trkErr, MP6F_* inPar, const MP3x3SF_* hitErr, const MP3F_* msP){
  MP3x3_ inverse_temp;
  MP3x6_ kGain;
  MP6x6SF_ newErr;
  KalmanGainInv(trkErr,hitErr,&inverse_temp);
  KalmanGain(trkErr,&inverse_temp,&kGain);

  {
    float *inParData = inPar->data;
    float *trkErrData = trkErr->data;
    const float xin = inParData[iparX];
    const float yin = inParData[iparY];
    const float zin = inParData[iparZ];
    const float ptin = 1.0f/inParData[iparIpt]; // is this pt or ipt? 
    const float phiin = inParData[iparPhi];
    const float thetain = inParData[iparTheta];
    const float xout = msP->data[iparX];
    const float yout = msP->data[iparY];
    //const float zout = msP->data[iparZ];
  
    float xnew = xin + (kGain.data[0]*(xout-xin)) +(kGain.data[1]*(yout-yin));
    float ynew = yin + (kGain.data[3]*(xout-xin)) +(kGain.data[4]*(yout-yin));
    float znew = zin + (kGain.data[6]*(xout-xin)) +(kGain.data[7]*(yout-yin));
    float ptnew = ptin + (kGain.data[9]*(xout-xin)) +(kGain.data[10]*(yout-yin));
    float phinew = phiin + (kGain.data[12]*(xout-xin)) +(kGain.data[13]*(yout-yin));
    float thetanew = thetain + (kGain.data[15]*(xout-xin)) +(kGain.data[16]*(yout-yin));
  
    newErr.data[0] = trkErrData[0] - (kGain.data[0]*trkErrData[0]+kGain.data[1]*trkErrData[1]+kGain.data[2]*trkErrData[2]);
    newErr.data[1] = trkErrData[1] - (kGain.data[0]*trkErrData[1]+kGain.data[1]*trkErrData[6]+kGain.data[2]*trkErrData[7]);
    newErr.data[2] = trkErrData[2] - (kGain.data[0]*trkErrData[2]+kGain.data[1]*trkErrData[7]+kGain.data[2]*trkErrData[11]);
    newErr.data[3] = trkErrData[3] - (kGain.data[0]*trkErrData[3]+kGain.data[1]*trkErrData[8]+kGain.data[2]*trkErrData[12]);
    newErr.data[4] = trkErrData[4] - (kGain.data[0]*trkErrData[4]+kGain.data[1]*trkErrData[9]+kGain.data[2]*trkErrData[13]);
    newErr.data[5] = trkErrData[5] - (kGain.data[0]*trkErrData[5]+kGain.data[1]*trkErrData[10]+kGain.data[2]*trkErrData[14]);
  
    newErr.data[6] = trkErrData[6] - (kGain.data[3]*trkErrData[1]+kGain.data[4]*trkErrData[6]+kGain.data[5]*trkErrData[7]);
    newErr.data[7] = trkErrData[7] - (kGain.data[3]*trkErrData[2]+kGain.data[4]*trkErrData[7]+kGain.data[5]*trkErrData[11]);
    newErr.data[8] = trkErrData[8] - (kGain.data[3]*trkErrData[3]+kGain.data[4]*trkErrData[8]+kGain.data[5]*trkErrData[12]);
    newErr.data[9] = trkErrData[9] - (kGain.data[3]*trkErrData[4]+kGain.data[4]*trkErrData[9]+kGain.data[5]*trkErrData[13]);
    newErr.data[10] = trkErrData[10] - (kGain.data[3]*trkErrData[5]+kGain.data[4]*trkErrData[10]+kGain.data[5]*trkErrData[14]);
  
    newErr.data[11] = trkErrData[11] - (kGain.data[6]*trkErrData[2]+kGain.data[7]*trkErrData[7]+kGain.data[8]*trkErrData[11]);
    newErr.data[12] = trkErrData[12] - (kGain.data[6]*trkErrData[3]+kGain.data[7]*trkErrData[8]+kGain.data[8]*trkErrData[12]);
    newErr.data[13] = trkErrData[13] - (kGain.data[6]*trkErrData[4]+kGain.data[7]*trkErrData[9]+kGain.data[8]*trkErrData[13]);
    newErr.data[14] = trkErrData[14] - (kGain.data[6]*trkErrData[5]+kGain.data[7]*trkErrData[10]+kGain.data[8]*trkErrData[14]);
  
    newErr.data[15] = trkErrData[15] - (kGain.data[9]*trkErrData[3]+kGain.data[10]*trkErrData[8]+kGain.data[11]*trkErrData[12]);
    newErr.data[16] = trkErrData[16] - (kGain.data[9]*trkErrData[4]+kGain.data[10]*trkErrData[9]+kGain.data[11]*trkErrData[13]);
    newErr.data[17] = trkErrData[17] - (kGain.data[9]*trkErrData[5]+kGain.data[10]*trkErrData[10]+kGain.data[11]*trkErrData[14]);
  
    newErr.data[18] = trkErrData[18] - (kGain.data[12]*trkErrData[4]+kGain.data[13]*trkErrData[9]+kGain.data[14]*trkErrData[13]);
    newErr.data[19] = trkErrData[19] - (kGain.data[12]*trkErrData[5]+kGain.data[13]*trkErrData[10]+kGain.data[14]*trkErrData[14]);
  
    newErr.data[20] = trkErrData[20] - (kGain.data[15]*trkErrData[5]+kGain.data[16]*trkErrData[10]+kGain.data[17]*trkErrData[14]);
  
    inParData[iparX] = xnew;
    inParData[iparY] = ynew;
    inParData[iparZ] = znew;
    inParData[iparIpt] = ptnew;
    inParData[iparPhi] = phinew;
    inParData[iparTheta] = thetanew;
    #pragma unroll
    for (int i = 0; i < 21; i++){
      trkErrData[ i] = trkErrData[ i] - newErr.data[ i];
    }
  }
}

__forceinline__ __device__ void KalmanUpdate_v2(struct MP6x6SF_* trkErr, struct MP6F_* inPar, const struct MP3x3SF_* hitErr, const struct MP3F_* msP){
   struct MP2x2SF_ resErr_loc; 
   struct MP2x6_ kGain;
   struct MP2F_ res_loc;
   struct MP6x6SF_ newErr;

   float *inParData = inPar->data;
   float *trkErrData = trkErr->data;
   const float *hitErrData = hitErr->data;
   // AddIntoUpperLeft2x2(psErr, msErr, resErr);
   {
     resErr_loc.data[0] = trkErrData[0] + hitErrData[0];
     resErr_loc.data[1] = trkErrData[1] + hitErrData[1];
     resErr_loc.data[2] = trkErrData[2] + hitErrData[2];
   }

   // Matriplex::InvertCramerSym(resErr);
   {
     const double det = (double)resErr_loc.data[0] * resErr_loc.data[2] -
                        (double)resErr_loc.data[1] * resErr_loc.data[1];
     const float s   = 1.f / det;
     const float tmp = s * resErr_loc.data[2];
     resErr_loc.data[1] *= -s;
     resErr_loc.data[2]  = s * resErr_loc.data[0];
     resErr_loc.data[0]  = tmp;
   }

   // KalmanGain(psErr, resErr, K);
   {
      kGain.data[ 0] = trkErrData[ 0]*resErr_loc.data[ 0] + trkErrData[ 1]*resErr_loc.data[ 1];
      kGain.data[ 1] = trkErrData[ 0]*resErr_loc.data[ 1] + trkErrData[ 1]*resErr_loc.data[ 2];
      kGain.data[ 2] = trkErrData[ 1]*resErr_loc.data[ 0] + trkErrData[ 2]*resErr_loc.data[ 1];
      kGain.data[ 3] = trkErrData[ 1]*resErr_loc.data[ 1] + trkErrData[ 2]*resErr_loc.data[ 2];
      kGain.data[ 4] = trkErrData[ 3]*resErr_loc.data[ 0] + trkErrData[ 4]*resErr_loc.data[ 1];
      kGain.data[ 5] = trkErrData[ 3]*resErr_loc.data[ 1] + trkErrData[ 4]*resErr_loc.data[ 2];
      kGain.data[ 6] = trkErrData[ 6]*resErr_loc.data[ 0] + trkErrData[ 7]*resErr_loc.data[ 1];
      kGain.data[ 7] = trkErrData[ 6]*resErr_loc.data[ 1] + trkErrData[ 7]*resErr_loc.data[ 2];
      kGain.data[ 8] = trkErrData[10]*resErr_loc.data[ 0] + trkErrData[11]*resErr_loc.data[ 1];
      kGain.data[ 9] = trkErrData[10]*resErr_loc.data[ 1] + trkErrData[11]*resErr_loc.data[ 2];
      kGain.data[10] = trkErrData[15]*resErr_loc.data[ 0] + trkErrData[16]*resErr_loc.data[ 1];
      kGain.data[11] = trkErrData[15]*resErr_loc.data[ 1] + trkErrData[16]*resErr_loc.data[ 2];
   }

   // SubtractFirst2(msPar, psPar, res);
   // MultResidualsAdd(K, psPar, res, outPar);
   {
     const float *msPData = msP->data;
     res_loc.data[0] =  msPData[iparX] - inParData[iparX];
     res_loc.data[1] =  msPData[iparY] - inParData[iparY];

     inParData[iparX] = inParData[iparX] + kGain.data[ 0] * res_loc.data[ 0] + kGain.data[ 1] * res_loc.data[ 1];
     inParData[iparY] = inParData[iparY] + kGain.data[ 2] * res_loc.data[ 0] + kGain.data[ 3] * res_loc.data[ 1];
     inParData[iparZ] = inParData[iparZ] + kGain.data[ 4] * res_loc.data[ 0] + kGain.data[ 5] * res_loc.data[ 1];
     inParData[iparIpt] = inParData[iparIpt] + kGain.data[ 6] * res_loc.data[ 0] + kGain.data[ 7] * res_loc.data[ 1];
     inParData[iparPhi] = inParData[iparPhi] + kGain.data[ 8] * res_loc.data[ 0] + kGain.data[ 9] * res_loc.data[ 1];
     inParData[iparTheta] = inParData[iparTheta] + kGain.data[10] * res_loc.data[ 0] + kGain.data[11] * res_loc.data[ 1];
     //note: if ipt changes sign we should update the charge, or we should get rid of the charge altogether and just use the sign of ipt
   }

   // squashPhiMPlex(outPar,N_proc); // ensure phi is between |pi|
   // missing

   // KHC(K, psErr, outErr);
   // outErr.Subtract(psErr, outErr);
   {
      newErr.data[ 0] = kGain.data[ 0]*trkErrData[ 0] + kGain.data[ 1]*trkErrData[ 1];
      newErr.data[ 1] = kGain.data[ 2]*trkErrData[ 0] + kGain.data[ 3]*trkErrData[ 1];
      newErr.data[ 2] = kGain.data[ 2]*trkErrData[ 1] + kGain.data[ 3]*trkErrData[ 2];
      newErr.data[ 3] = kGain.data[ 4]*trkErrData[ 0] + kGain.data[ 5]*trkErrData[ 1];
      newErr.data[ 4] = kGain.data[ 4]*trkErrData[ 1] + kGain.data[ 5]*trkErrData[ 2];
      newErr.data[ 5] = kGain.data[ 4]*trkErrData[ 3] + kGain.data[ 5]*trkErrData[ 4];
      newErr.data[ 6] = kGain.data[ 6]*trkErrData[ 0] + kGain.data[ 7]*trkErrData[ 1];
      newErr.data[ 7] = kGain.data[ 6]*trkErrData[ 1] + kGain.data[ 7]*trkErrData[ 2];
      newErr.data[ 8] = kGain.data[ 6]*trkErrData[ 3] + kGain.data[ 7]*trkErrData[ 4];
      newErr.data[ 9] = kGain.data[ 6]*trkErrData[ 6] + kGain.data[ 7]*trkErrData[ 7];
      newErr.data[10] = kGain.data[ 8]*trkErrData[ 0] + kGain.data[ 9]*trkErrData[ 1];
      newErr.data[11] = kGain.data[ 8]*trkErrData[ 1] + kGain.data[ 9]*trkErrData[ 2];
      newErr.data[12] = kGain.data[ 8]*trkErrData[ 3] + kGain.data[ 9]*trkErrData[ 4];
      newErr.data[13] = kGain.data[ 8]*trkErrData[ 6] + kGain.data[ 9]*trkErrData[ 7];
      newErr.data[14] = kGain.data[ 8]*trkErrData[10] + kGain.data[ 9]*trkErrData[11];
      newErr.data[15] = kGain.data[10]*trkErrData[ 0] + kGain.data[11]*trkErrData[ 1];
      newErr.data[16] = kGain.data[10]*trkErrData[ 1] + kGain.data[11]*trkErrData[ 2];
      newErr.data[17] = kGain.data[10]*trkErrData[ 3] + kGain.data[11]*trkErrData[ 4];
      newErr.data[18] = kGain.data[10]*trkErrData[ 6] + kGain.data[11]*trkErrData[ 7];
      newErr.data[19] = kGain.data[10]*trkErrData[10] + kGain.data[11]*trkErrData[11];
      newErr.data[20] = kGain.data[10]*trkErrData[15] + kGain.data[11]*trkErrData[16];

      newErr.data[ 0] = trkErrData[ 0] - newErr.data[ 0];
      newErr.data[ 1] = trkErrData[ 1] - newErr.data[ 1];
      newErr.data[ 2] = trkErrData[ 2] - newErr.data[ 2];
      newErr.data[ 3] = trkErrData[ 3] - newErr.data[ 3];
      newErr.data[ 4] = trkErrData[ 4] - newErr.data[ 4];
      newErr.data[ 5] = trkErrData[ 5] - newErr.data[ 5];
      newErr.data[ 6] = trkErrData[ 6] - newErr.data[ 6];
      newErr.data[ 7] = trkErrData[ 7] - newErr.data[ 7];
      newErr.data[ 8] = trkErrData[ 8] - newErr.data[ 8];
      newErr.data[ 9] = trkErrData[ 9] - newErr.data[ 9];
      newErr.data[10] = trkErrData[10] - newErr.data[10];
      newErr.data[11] = trkErrData[11] - newErr.data[11];
      newErr.data[12] = trkErrData[12] - newErr.data[12];
      newErr.data[13] = trkErrData[13] - newErr.data[13];
      newErr.data[14] = trkErrData[14] - newErr.data[14];
      newErr.data[15] = trkErrData[15] - newErr.data[15];
      newErr.data[16] = trkErrData[16] - newErr.data[16];
      newErr.data[17] = trkErrData[17] - newErr.data[17];
      newErr.data[18] = trkErrData[18] - newErr.data[18];
      newErr.data[19] = trkErrData[19] - newErr.data[19];
      newErr.data[20] = trkErrData[20] - newErr.data[20];
   }

  {
    #pragma unroll
    for (int i = 0; i < 21; i++){
      trkErrData[ i] = trkErrData[ i] - newErr.data[ i];
    }
  }
}

__device__ __constant__ float kfact = 100./(-0.299792458*3.8112);
__device__ __forceinline__ void propagateToZ(const MP6x6SF_* inErr, const MP6F_* inPar, const MP1I_* inChg,const MP3F_* msP, 
			  MP6x6SF_* outErr, MP6F_* outPar) {
    struct MP6x6F_ errorProp, temp; 
  {
    const float *inParData = inPar->data;
    float *outParData = outPar->data;
    const float zout = msP->data[iparZ];
    const float k = inChg->data[0]*kfact;//*100/3.8;
    const float deltaZ = zout - inParData[iparZ];
    const float ipt_ = inParData[iparIpt];
    const float pt = 1.0f/ipt_;
    const float phi_ = inParData[iparPhi];
    const float cosP = cosf(phi_);
    const float sinP = sinf(phi_);
    const float theta_ = inParData[iparTheta];
    const float cosT = cosf(theta_);
    const float sinT = sinf(theta_);
    const float pxin = cosP*pt;
    const float pyin = sinP*pt;
    const float icosT = 1.0f/cosT;
    const float icosTk = icosT/k;
    const float alpha = deltaZ*sinT*ipt_*icosTk;
    const float sina = sinf(alpha); // this can be approximated;
    const float cosa = cosf(alpha); // this can be approximated;
    outParData[iparX] = inParData[iparX] + k*(pxin*sina - pyin*(1.0f-cosa));
    outParData[iparY] = inParData[iparY] + k*(pyin*sina + pxin*(1.0f-cosa));
    outParData[iparZ] = zout;
    outParData[iparIpt] = ipt_;
    outParData[iparPhi] = phi_+alpha;
    outParData[iparTheta] = theta_;
    
    const float sCosPsina = sinf(cosP*sina);
    const float cCosPsina = cosf(cosP*sina);
    
    //for (size_t i=0;i<6;++i) errorProp.data[PosInMtrx(i,i,6) + it] = 1.f;
    errorProp.data[PosInMtrx(0,0,6)] = 1.0f;
    errorProp.data[PosInMtrx(1,1,6)] = 1.0f;
    errorProp.data[PosInMtrx(2,2,6)] = 1.0f;
    errorProp.data[PosInMtrx(3,3,6)] = 1.0f;
    errorProp.data[PosInMtrx(4,4,6)] = 1.0f;
    errorProp.data[PosInMtrx(5,5,6)] = 1.0f;
    //[Dec. 21, 2022] Added to have the same pattern as the cudauvm version.
    errorProp.data[PosInMtrx(0,1,6)] = 0.0f;
    errorProp.data[PosInMtrx(0,2,6)] = cosP*sinT*(sinP*cosa*sCosPsina-cosa)*icosT;
    errorProp.data[PosInMtrx(0,3,6)] = cosP*sinT*deltaZ*cosa*(1.0f-sinP*sCosPsina)*(icosT*pt)-k*(cosP*sina-sinP*(1.0f-cCosPsina))*(pt*pt);
    errorProp.data[PosInMtrx(0,4,6)] = (k*pt)*(-sinP*sina+sinP*sinP*sina*sCosPsina-cosP*(1.0f-cCosPsina));
    errorProp.data[PosInMtrx(0,5,6)] = cosP*deltaZ*cosa*(1.0f-sinP*sCosPsina)*(icosT*icosT);
    errorProp.data[PosInMtrx(1,2,6)] = cosa*sinT*(cosP*cosP*sCosPsina-sinP)*icosT;
    errorProp.data[PosInMtrx(1,3,6)] = sinT*deltaZ*cosa*(cosP*cosP*sCosPsina+sinP)*(icosT*pt)-k*(sinP*sina+cosP*(1.0f-cCosPsina))*(pt*pt);
    errorProp.data[PosInMtrx(1,4,6)] = (k*pt)*(-sinP*(1.0f-cCosPsina)-sinP*cosP*sina*sCosPsina+cosP*sina);
    errorProp.data[PosInMtrx(1,5,6)] = deltaZ*cosa*(cosP*cosP*sCosPsina+sinP)*(icosT*icosT);
    errorProp.data[PosInMtrx(4,2,6)] = -ipt_*sinT*(icosTk);
    errorProp.data[PosInMtrx(4,3,6)] = sinT*deltaZ*(icosTk);
    errorProp.data[PosInMtrx(4,5,6)] = ipt_*deltaZ*(icosT*icosTk);
  }
  MultHelixPropEndcap(&errorProp, inErr, &temp);
  MultHelixPropTranspEndcap(&errorProp, &temp, outErr);
}

__device__ __constant__ int ie_range = (int) nevts/num_streams; 
__device__ __constant__ int ie_rangeR = (int) nevts%num_streams; 
__global__ void GPUsequence(MPTRK* trk, MPHIT* hit, MPTRK* outtrk, const int stream){
  for (int ti = blockIdx.x; ti<ie_range*nb; ti+=gridDim.x){
      struct MPTRK_ obtracks;
      struct MPTRK_ btracks;
      float *dstPtr = btracks.par.data;
      float *srcPtr = trk[ti].par.data;
      loadData(dstPtr,srcPtr,threadIdx.x,6);
      dstPtr = btracks.cov.data;
      srcPtr = trk[ti].cov.data;
      loadData(dstPtr,srcPtr,threadIdx.x,21);
      int *dstPtrI = btracks.q.data;
      int *srcPtrI = trk[ti].q.data;
      loadData(dstPtrI,srcPtrI,threadIdx.x,1);
      obtracks = btracks;

#pragma unroll
      for (int layer=0;layer<nlayer;++layer){	
        struct MPHIT_ bhits;
        float *dstPtr2 = bhits.pos.data;
        float *srcPtr2 = hit[layer+ti*nlayer].pos.data;
        loadData(dstPtr2,srcPtr2,threadIdx.x,3);
        dstPtr2 = bhits.cov.data;
        srcPtr2 = hit[layer+ti*nlayer].cov.data;
        loadData(dstPtr2,srcPtr2,threadIdx.x,6);
     
        propagateToZ(&(obtracks.cov), &(obtracks.par), &(obtracks.q), &(bhits.pos), 
                     &(obtracks.cov), &(obtracks.par));
        //KalmanUpdate(&(obtracks.cov),&(obtracks.par),&(bhits.cov),&(bhits.pos));
        KalmanUpdate_v2(&(obtracks.cov),&(obtracks.par),&(bhits.cov),&(bhits.pos));
      }
      float *dstPtr2 = outtrk[ti].par.data;
      float *srcPtr2 = obtracks.par.data;
      saveData(dstPtr2,srcPtr2,threadIdx.x,6);
      dstPtr2 = outtrk[ti].cov.data;
      srcPtr2 = obtracks.cov.data;
      saveData(dstPtr2,srcPtr2,threadIdx.x,21);
      int *dstPtrI2 = outtrk[ti].q.data;
      int *srcPtrI2 = obtracks.q.data;
      saveData(dstPtrI2,srcPtrI2,threadIdx.x,1);
  }
}

__global__ void GPUsequenceR(MPTRK* trk, MPHIT* hit, MPTRK* outtrk, const int stream){
  for (int ti = blockIdx.x; ti<ie_rangeR*nb; ti+=gridDim.x){
      struct MPTRK_ obtracks;
      struct MPTRK_ btracks;
      float *dstPtr = btracks.par.data;
      float *srcPtr = trk[ti].par.data;
      loadData(dstPtr,srcPtr,threadIdx.x,6);
      dstPtr = btracks.cov.data;
      srcPtr = trk[ti].cov.data;
      loadData(dstPtr,srcPtr,threadIdx.x,21);
      int *dstPtrI = btracks.q.data;
      int *srcPtrI = trk[ti].q.data;
      loadData(dstPtrI,srcPtrI,threadIdx.x,1);
      obtracks = btracks;

#pragma unroll
      for (int layer=0;layer<nlayer;++layer){	
        struct MPHIT_ bhits;
        float *dstPtr2 = bhits.pos.data;
        float *srcPtr2 = hit[layer+ti*nlayer].pos.data;
        loadData(dstPtr2,srcPtr2,threadIdx.x,3);
        dstPtr2 = bhits.cov.data;
        srcPtr2 = hit[layer+ti*nlayer].cov.data;
        loadData(dstPtr2,srcPtr2,threadIdx.x,6);
     
        propagateToZ(&(obtracks.cov), &(obtracks.par), &(obtracks.q), &(bhits.pos), 
                     &(obtracks.cov), &(obtracks.par));
        //KalmanUpdate(&(obtracks.cov),&(obtracks.par),&(bhits.cov),&(bhits.pos));
        KalmanUpdate_v2(&(obtracks.cov),&(obtracks.par),&(bhits.cov),&(bhits.pos));
      }
      float *dstPtr2 = outtrk[ti].par.data;
      float *srcPtr2 = obtracks.par.data;
      saveData(dstPtr2,srcPtr2,threadIdx.x,6);
      dstPtr2 = outtrk[ti].cov.data;
      srcPtr2 = obtracks.cov.data;
      saveData(dstPtr2,srcPtr2,threadIdx.x,21);
      int *dstPtrI2 = outtrk[ti].q.data;
      int *srcPtrI2 = obtracks.q.data;
      saveData(dstPtrI2,srcPtrI2,threadIdx.x,1);
  }
}

void prefetch_device(MPTRK* trk, MPHIT* hit, cudaStream_t* streams, int stream_chunk, int stream_remainder, int device) {
    for (int s = 0; s<num_streams;s++){
#ifdef USE_ASYNC
      cudaMemPrefetchAsync(trk+(s*stream_chunk),stream_chunk*sizeof(MPTRK), device,streams[s]);
#else
      cudaMemPrefetchAsync(trk+(s*stream_chunk),stream_chunk*sizeof(MPTRK), device,0);
#endif
      
#ifdef USE_ASYNC
      cudaMemPrefetchAsync(hit+(s*stream_chunk*nlayer),nlayer*stream_chunk*sizeof(MPHIT), device,streams[s]);
#else
      cudaMemPrefetchAsync(hit+(s*stream_chunk*nlayer),nlayer*stream_chunk*sizeof(MPHIT), device,0);
#endif
    }  
    if(stream_remainder != 0){
#ifdef USE_ASYNC
      cudaMemPrefetchAsync(trk+(num_streams*stream_chunk),stream_remainder*sizeof(MPTRK), device,streams[num_streams]);
#else
      cudaMemPrefetchAsync(trk+(num_streams*stream_chunk),stream_remainder*sizeof(MPTRK), device,0);
#endif
      
#ifdef USE_ASYNC
      cudaMemPrefetchAsync(hit+(num_streams*stream_chunk*nlayer),nlayer*stream_remainder*sizeof(MPHIT), device,streams[num_streams]);
#else
      cudaMemPrefetchAsync(hit+(num_streams*stream_chunk*nlayer),nlayer*stream_remainder*sizeof(MPHIT), device,0);
#endif
    }
}

void prefetch_host(MPTRK* outtrk, cudaStream_t* streams, int stream_chunk, int stream_remainder) {
    for (int s = 0; s<num_streams;s++){
#ifdef USE_ASYNC
      cudaMemPrefetchAsync(outtrk+(s*stream_chunk),stream_chunk*sizeof(MPTRK), cudaCpuDeviceId,streams[s]);
#else
      cudaMemPrefetchAsync(outtrk+(s*stream_chunk),stream_chunk*sizeof(MPTRK), cudaCpuDeviceId,0);
#endif
    }
    if(stream_remainder != 0){
#ifdef USE_ASYNC
      cudaMemPrefetchAsync(outtrk+(num_streams*stream_chunk),stream_remainder*sizeof(MPTRK), cudaCpuDeviceId,streams[num_streams]);
#else
      cudaMemPrefetchAsync(outtrk+(num_streams*stream_chunk),stream_remainder*sizeof(MPTRK), cudaCpuDeviceId,0);
#endif
    }
}

int main (int argc, char* argv[]) {

#ifdef USE_ASYNC
  printf("RUNNING CUDA Async Version!!\n");
#else
  printf("RUNNING CUDA Sync Version!!\n");
#endif
#ifdef include_data
  printf("Measure Both Memory Transfer Times and Compute Times!\n");
#else
  printf("Measure Compute Times Only!\n");
#endif

#include "input_track.h"

   struct AHIT inputhits[26] = {inputhit25,inputhit24,inputhit23,inputhit22,inputhit21,inputhit20,inputhit19,inputhit18,inputhit17,
				inputhit16,inputhit15,inputhit14,inputhit13,inputhit12,inputhit11,inputhit10,inputhit09,inputhit08,
				inputhit07,inputhit06,inputhit05,inputhit04,inputhit03,inputhit02,inputhit01,inputhit00};

   printf("track in pos: x=%f, y=%f, z=%f, r=%f, pt=%f, phi=%f, theta=%f \n", inputtrk.par[0], inputtrk.par[1], inputtrk.par[2],
	  sqrtf(inputtrk.par[0]*inputtrk.par[0] + inputtrk.par[1]*inputtrk.par[1]),
	  1./inputtrk.par[3], inputtrk.par[4], inputtrk.par[5]);

   printf("track in cov: %.2e, %.2e, %.2e \n", inputtrk.cov[SymOffsets66(PosInMtrx(0,0,6))],
                                               inputtrk.cov[SymOffsets66(PosInMtrx(1,1,6))],
	                                       inputtrk.cov[SymOffsets66(PosInMtrx(2,2,6))]);
   for (size_t lay=0; lay<nlayer; lay++){
     printf("hit in layer=%lu, pos: x=%f, y=%f, z=%f, r=%f \n", lay, inputhits[lay].pos[0], inputhits[lay].pos[1], inputhits[lay].pos[2], sqrtf(inputhits[lay].pos[0]*inputhits[lay].pos[0] + inputhits[lay].pos[1]*inputhits[lay].pos[1]));
   }

   printf("produce nevts=%i ntrks=%i smearing by=%f \n", nevts, ntrks, smear);
   printf("NITER=%d\n", NITER);
 
  long setup_start, setup_stop;
  struct timeval timecheck;

  gettimeofday(&timecheck, NULL);
  setup_start = (long)timecheck.tv_sec * 1000 + (long)timecheck.tv_usec / 1000;      
#ifdef FIXED_RSEED
  //[DEBUG by Seyong on Dec. 28, 2020] add an explicit srand(1) call to generate fixed inputs for better debugging.
  srand(1);
#endif
//  cudaDeviceSetCacheConfig(cudaFuncCachePreferShared);
//  cudaFuncSetCacheConfig(GPUsequence,cudaFuncCachePreferL1);
//  cudaFuncSetCacheConfig(GPUsequenceR,cudaFuncCachePreferL1);
  MPTRK* trk = prepareTracks(inputtrk);
  MPHIT* hit = prepareHits(inputhits);
  MPTRK* outtrk;
  cudaMallocManaged((void**)&outtrk,nevts*nb*sizeof(MPTRK)); 
  dim3 grid(blockspergrid,1,1);
  dim3 block(threadsperblockx,threadsperblocky,1); 
  int device = -1;
  cudaGetDevice(&device);
  int stream_chunk = ((int)(nevts/num_streams))*nb;//*sizeof(MPTRK);
  int stream_remainder = ((int)(nevts%num_streams))*nb;//*sizeof(MPTRK);
  int stream_range;
  if (stream_remainder == 0){ stream_range =num_streams;}
  else{stream_range = num_streams+1;}
  cudaStream_t streams[stream_range];
  for (int s = 0; s<stream_range;s++){
    //cudaStreamCreateWithFlags(&streams[s],cudaStreamNonBlocking);
    cudaStreamCreate(&streams[s]);
  }
#ifndef include_data
	prefetch_device(trk, hit, streams, stream_chunk, stream_remainder, device);
#ifdef USE_ASYNC
    cudaDeviceSynchronize(); 
#endif
#endif

  gettimeofday(&timecheck, NULL);
  setup_stop = (long)timecheck.tv_sec * 1000 + (long)timecheck.tv_usec / 1000;

  printf("done preparing!\n");

  printf("Size of struct MPTRK trk[] = %ld\n", nevts*nb*sizeof(struct MPTRK));
  printf("Size of struct MPTRK outtrk[] = %ld\n", nevts*nb*sizeof(struct MPTRK));
  printf("Size of struct struct MPHIT hit[] = %ld\n", nevts*nb*sizeof(struct MPHIT));
  
  auto wall_start = std::chrono::high_resolution_clock::now();

  int itr;
  for(itr=0; itr<NITER; itr++){
#ifdef include_data
	prefetch_device(trk, hit, streams, stream_chunk, stream_remainder, device);
#endif

    for (int s = 0; s<num_streams;++s){
      //printf("stream = %d, grid (%d, %d, %d), block(%d, %d, %d), stream_chunk = %d\n",s, grid.x, grid.y, grid.z, block.x, block.y, block.z, stream_chunk);
#ifdef USE_ASYNC
  	  GPUsequence<<<grid,block,0,streams[s]>>>(trk+(s*stream_chunk),hit+(s*stream_chunk*nlayer),outtrk+(s*stream_chunk),s);
#else
  	  GPUsequence<<<grid,block,0,0>>>(trk+(s*stream_chunk),hit+(s*stream_chunk*nlayer),outtrk+(s*stream_chunk),s);
#endif
    }  
    if(stream_remainder != 0){
#ifdef USE_ASYNC
  	  GPUsequenceR<<<grid,block,0,streams[num_streams]>>>(trk+(num_streams*stream_chunk),hit+(num_streams*stream_chunk*nlayer),outtrk+(num_streams*stream_chunk),num_streams);
#else
  	  GPUsequenceR<<<grid,block,0,0>>>(trk+(num_streams*stream_chunk),hit+(num_streams*stream_chunk*nlayer),outtrk+(num_streams*stream_chunk),num_streams);
#endif
    }
#ifdef include_data
	prefetch_host(outtrk, streams, stream_chunk, stream_remainder);
#endif
  } //end itr loop
  
#ifdef USE_ASYNC
	cudaDeviceSynchronize(); 
#endif
  auto wall_stop = std::chrono::high_resolution_clock::now();
#ifndef include_data
	prefetch_host(outtrk, streams, stream_chunk, stream_remainder);
#ifdef USE_ASYNC
    cudaDeviceSynchronize(); 
#endif
#endif

  for (int s = 0; s<stream_range;s++){
    cudaStreamDestroy(streams[s]);
  }
 
   auto wall_diff = wall_stop - wall_start;
   auto wall_time = static_cast<double>(std::chrono::duration_cast<std::chrono::microseconds>(wall_diff).count()) / 1e6;
   printf("setup time time=%f (s)\n", (setup_stop-setup_start)*0.001);
   printf("done ntracks=%i tot time=%f (s) time/trk=%e (s)\n", nevts*ntrks*int(NITER), wall_time, wall_time/(nevts*ntrks*int(NITER)));
   printf("formatted %i %i %i %i %i %f 0 %f %i\n",int(NITER),nevts, ntrks, bsize, nb, wall_time, (setup_stop-setup_start)*0.001, num_streams);
#ifdef DUMP_OUTPUT
   FILE *fp_x;
   FILE *fp_y;
   FILE *fp_z;
   fp_x = fopen("output_x.txt", "w");
   fp_y = fopen("output_y.txt", "w");
   fp_z = fopen("output_z.txt", "w");
#endif

   int nnans = 0, nfail = 0;
   double avgx = 0, avgy = 0, avgz = 0;
   double avgpt = 0, avgphi = 0, avgtheta = 0;
   double avgdx = 0, avgdy = 0, avgdz = 0;
   for (size_t ie=0;ie<nevts;++ie) {
     for (size_t it=0;it<ntrks;++it) {
       float x_ = x(outtrk,ie,it);
       float y_ = y(outtrk,ie,it);
       float z_ = z(outtrk,ie,it);
       float pt_ = 1./ipt(outtrk,ie,it);
       float phi_ = phi(outtrk,ie,it);
       float theta_ = theta(outtrk,ie,it);
       float hx_ = x(hit,ie,it);
       float hy_ = y(hit,ie,it);
       float hz_ = z(hit,ie,it);
       float hr_ = sqrtf(hx_*hx_ + hy_*hy_);
       if (isnan(x_) ||
	   isnan(y_) ||
	   isnan(z_) ||
	   isnan(pt_) ||
	   isnan(phi_) ||
	   isnan(theta_)
	   ) {
	 nnans++;
	 continue;
       }
       if (fabs( (x_-hx_)/hx_ )>1. ||
           fabs( (y_-hy_)/hy_ )>1. ||
           fabs( (z_-hz_)/hz_ )>1. ||
           fabs( (pt_-12.)/12.)>1.
           ) {
	 nfail++;
	 continue;
       }
#ifdef DUMP_OUTPUT
       fprintf(fp_x, "%f\n", x_);
       fprintf(fp_y, "%f\n", y_);
       fprintf(fp_z, "%f\n", z_);
#endif
       avgpt += pt_;
       avgphi += phi_;
       avgtheta += theta_;
       avgx += x_;
       avgy += y_;
       avgz += z_;
       avgdx += (x_-hx_)/x_;
       avgdy += (y_-hy_)/y_;
       avgdz += (z_-hz_)/z_;
     }
   }
#ifdef DUMP_OUTPUT
   fclose(fp_x);
   fclose(fp_y);
   fclose(fp_z);
   fp_x = fopen("input_x.txt", "w");
   fp_y = fopen("input_y.txt", "w");
   fp_z = fopen("input_z.txt", "w");
#endif
   avgpt = avgpt/double(nevts*ntrks);
   avgphi = avgphi/double(nevts*ntrks);
   avgtheta = avgtheta/double(nevts*ntrks);
   avgx = avgx/double(nevts*ntrks);
   avgy = avgy/double(nevts*ntrks);
   avgz = avgz/double(nevts*ntrks);
   avgdx = avgdx/double(nevts*ntrks);
   avgdy = avgdy/double(nevts*ntrks);
   avgdz = avgdz/double(nevts*ntrks);

   double stdx = 0, stdy = 0, stdz = 0;
   double stddx = 0, stddy = 0, stddz = 0;
   for (size_t ie=0;ie<nevts;++ie) {
     for (size_t it=0;it<ntrks;++it) {
       float x_ = x(outtrk,ie,it);
       float y_ = y(outtrk,ie,it);
       float z_ = z(outtrk,ie,it);
       float hx_ = x(hit,ie,it);
       float hy_ = y(hit,ie,it);
       float hz_ = z(hit,ie,it);
       float pt_ = 1./ipt(outtrk,ie,it);
       float hr_ = sqrtf(hx_*hx_ + hy_*hy_);
       if (isnan(x_) ||
	   isnan(y_) ||
	   isnan(z_)
	   ) {
	 continue;
       }
       if (fabs( (x_-hx_)/hx_ )>1. ||
           fabs( (y_-hy_)/hy_ )>1. ||
           fabs( (z_-hz_)/hz_ )>1. ||
           fabs( (pt_-12.)/12.)>1.
           ) {
         continue;
       }
       stdx += (x_-avgx)*(x_-avgx);
       stdy += (y_-avgy)*(y_-avgy);
       stdz += (z_-avgz)*(z_-avgz);
       stddx += ((x_-hx_)/x_-avgdx)*((x_-hx_)/x_-avgdx);
       stddy += ((y_-hy_)/y_-avgdy)*((y_-hy_)/y_-avgdy);
       stddz += ((z_-hz_)/z_-avgdz)*((z_-hz_)/z_-avgdz);
#ifdef DUMP_OUTPUT
       x_ = x(trk,ie,it);
       y_ = y(trk,ie,it);
       z_ = z(trk,ie,it);
       fprintf(fp_x, "%f\n", x_);
       fprintf(fp_y, "%f\n", y_);
       fprintf(fp_z, "%f\n", z_);
#endif
     }
   }
#ifdef DUMP_OUTPUT
   fclose(fp_x);
   fclose(fp_y);
   fclose(fp_z);
#endif

   stdx = sqrtf(stdx/double(nevts*ntrks));
   stdy = sqrtf(stdy/double(nevts*ntrks));
   stdz = sqrtf(stdz/double(nevts*ntrks));
   stddx = sqrtf(stddx/double(nevts*ntrks));
   stddy = sqrtf(stddy/double(nevts*ntrks));
   stddz = sqrtf(stddz/double(nevts*ntrks));

   printf("track x avg=%f std/avg=%f\n", avgx, fabs(stdx/avgx));
   printf("track y avg=%f std/avg=%f\n", avgy, fabs(stdy/avgy));
   printf("track z avg=%f std/avg=%f\n", avgz, fabs(stdz/avgz));
   printf("track dx/x avg=%f std=%f\n", avgdx, stddx);
   printf("track dy/y avg=%f std=%f\n", avgdy, stddy);
   printf("track dz/z avg=%f std=%f\n", avgdz, stddz);
   printf("track pt avg=%f\n", avgpt);
   printf("track phi avg=%f\n", avgphi);
   printf("track theta avg=%f\n", avgtheta);
   printf("number of tracks with nans=%i\n", nnans);
   printf("number of tracks failed=%i\n", nfail);
	
   //free(trk);
   //free(hit);
   //free(outtrk);
   cudaFree(trk);
   cudaFree(hit);
   cudaFree(outtrk);
   
return 0;
}

