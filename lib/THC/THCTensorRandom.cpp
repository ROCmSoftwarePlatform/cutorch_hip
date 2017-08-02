#include "THCTensorRandom.h"

#include <random>
#ifdef CURAND_PATH
#include <curand.h>
#else
#include <hiprng.h>
#endif


void initializeGenerator(THCState *state, Generator* gen);
void createGeneratorState(THCState *state, Generator* gen, unsigned long long seed);


/* Frees memory allocated during setup. */
void destroyGenerator(THCState *state, Generator* gen)
{
  if (gen->gen_states)
  {
    THCudaCheck(THCudaFree(state, gen->gen_states));
    gen->gen_states = NULL;
  }
  if (gen->kernel_params)
  {
    THCudaCheck(THCudaFree(state, gen->kernel_params));
    gen->kernel_params = NULL;
  }
}

static unsigned long long createSeed(std::random_device& rd)
{
  // limit to 53 bits to ensure unique representation in double
  unsigned long long seed = (((unsigned long long)rd()) << 32) + rd();
  return seed & 0x1FFFFFFFFFFFFF;
}

/* Initialize generator array (must be called before any other function) */
void THCRandom_init(THCState* state, int devices, int current_device)
{
  THCRNGState* rng_state = THCState_getRngState(state);
  rng_state->num_devices = devices;
  rng_state->gen = (Generator*)malloc(rng_state->num_devices * sizeof(Generator));
  std::random_device rd;
  for (int i = 0; i < rng_state->num_devices; ++i)
  {
    rng_state->gen[i].initf = 0;
    rng_state->gen[i].initial_seed = createSeed(rd);
    rng_state->gen[i].gen_states = NULL;
    rng_state->gen[i].kernel_params = NULL;
  }
}

/* Destroy generators and free memory */
void THCRandom_shutdown(THCState* state)
{
  THCRNGState* rng_state = THCState_getRngState(state);
  if (rng_state->gen == NULL) return;
  for (int i = 0; i < rng_state->num_devices; ++i)
  {
    destroyGenerator(state, &rng_state->gen[i]);
  }
  free(rng_state->gen);
  rng_state->gen = NULL;
}

/* Get the generator for the current device, but does not initialize the state */
static Generator* THCRandom_rawGenerator(THCState* state)
{
  THCRNGState* rng_state = THCState_getRngState(state);
  int device;
  THCudaCheck(hipGetDevice(&device));
  if (device >= rng_state->num_devices) THError("Invalid device index.");
  return &rng_state->gen[device];
}

/* Get the generator for the current device and initializes it if necessary */
Generator* THCRandom_getGenerator(THCState* state)
{
  Generator* gen = THCRandom_rawGenerator(state);
  if (gen->initf == 0)
  {
    initializeGenerator(state, gen);
    createGeneratorState(state, gen, gen->initial_seed);
    gen->initf = 1;
  }
  return gen;
}

#ifdef CURAND_PATH
struct curandStateMtgp32* THCRandom_generatorStates(struct THCState* state)
#else
hiprngStateMtgp32* THCRandom_generatorStates(struct THCState* state)
#endif
{
#ifdef CURAND_PATH
  return THCRandom_getGenerator(state)->gen_states;
#else
  return THCRandom_getGenerator(state)->gen_states;
#endif
}

/* Random seed */
unsigned long long THCRandom_seed(THCState* state)
{
  std::random_device rd;
  unsigned long long s = createSeed(rd);
  THCRandom_manualSeed(state, s);
  return s;
}

unsigned long long THCRandom_seedAll(THCState* state)
{
  std::random_device rd;
  unsigned long long s = createSeed(rd);
  THCRandom_manualSeedAll(state, s);
  return s;
}

/* Manually set the seed */
void THCRandom_manualSeed(THCState* state, unsigned long long seed)
{
  Generator* gen = THCRandom_rawGenerator(state);
  gen->initial_seed = seed;
  if (gen->initf) {
    createGeneratorState(state, gen, seed);
  }
}

void THCRandom_manualSeedAll(THCState* state, unsigned long long seed)
{
  THCRNGState* rng_state = THCState_getRngState(state);
  int currentDevice;
  THCudaCheck(hipGetDevice(&currentDevice));
  for (int i = 0; i < rng_state->num_devices; ++i) {
    THCudaCheck(hipSetDevice(i));
    THCRandom_manualSeed(state, seed);
  }
  THCudaCheck(hipSetDevice(currentDevice));
}

/* Get the initial seed */
unsigned long long THCRandom_initialSeed(THCState* state)
{
  return THCRandom_getGenerator(state)->initial_seed;
}