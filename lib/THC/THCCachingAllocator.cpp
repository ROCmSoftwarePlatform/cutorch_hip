#include "THCCachingAllocator.h"

#include <hip/hip_runtime_api.h>

#include <GGL/grid_launch.hpp>

#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <unordered_map>

//
// Yet another caching allocator for CUDA device allocations.
//
// - Allocations are associated with a stream. Once freed, blocks can be
//   re-allocated on the same stream, but not on any other stream.
// - The allocator attempts to find the smallest cached block that will fit the
//   requested size. If the block is larger than the requested size, it may be
//   split. If no block is found, the allocator will delegate to hipMalloc.
// - If the hipMalloc fails, the allocator will free all cached blocks that
//   are not split and retry the allocation.
// - Large (>1MB) and small allocation requestss are handled separately. Large
//   allocation requests can be filled by a hipMalloc call of the exact size.
//   Small requests will allocate and split a 1MB buffer, if necessary.
//
// With this allocator, allocations and frees should logically be considered
// "usages" of the memory segment associated with streams, just like kernel
// launches. The programmer must insert the proper synchronization if memory
// segments are used from multiple streams.
//


namespace {

const size_t kRoundSmall = 512;     // round up small allocs to 512 bytes
const size_t kRoundLarge = 131072;  // round up large allocs to 128 KiB
const size_t kSmallAlloc = 1048576; // largest "small" allocation is 1 MiB

struct Block {
  int           device;     // gpu
  hipStream_t  stream;     // allocation stream
  size_t        size;       // block size in bytes
  char*         ptr;        // memory address
  bool          allocated;  // in-use flag
  Block*        prev;       // prev block if split from a larger allocation
  Block*        next;       // next block if split from a larger allocation

  Block(int device, hipStream_t stream, size_t size, char* ptr=NULL) :
      device(device), stream(stream), size(size), ptr(ptr), allocated(0),
      prev(NULL), next(NULL) { }
};

static bool BlockComparator(const Block* a, const Block* b)
{
  if (a->device != b->device) {
    return a->device < b->device;
  }
  if (a->stream != b->stream) {
    return (uintptr_t)a->stream < (uintptr_t)b->stream;
  }
  if (a->size != b->size) {
    return a->size < b->size;
  }
  return (uintptr_t)a->ptr < (uintptr_t)b->ptr;
}

} // namespace

struct THCCachingAllocator
{
  typedef bool (*Comparison)(const Block*, const Block*);
  typedef std::set<Block*, Comparison> FreeBlocks;

  // lock around malloc and free
  std::mutex mutex;

  // cached blocks larger than 1 MB
  FreeBlocks large_blocks;

  // cached blocks 1 MB or smaller
  FreeBlocks small_blocks;

  // allocated blocks by device pointer
  std::unordered_map<void*, Block*> allocated_blocks;

  THCCachingAllocator() :
      large_blocks(BlockComparator),
      small_blocks(BlockComparator) {}

  /** allocates a block which is safe to use from the provided stream */
  hipError_t malloc(void** devPtr, size_t size, hipStream_t stream)
  {
    std::lock_guard<std::mutex> lock(mutex);

    int device;
    hipError_t err = hipGetDevice(&device);
    if (err != hipSuccess) {
      return err;
    }

    size = round_size(size);
    bool small = size <= kSmallAlloc;

    Block search_key(device, stream, size);
    auto& free_blocks = small ? large_blocks : small_blocks;

    Block* block = NULL;
    Block* remaining = NULL;

    auto it = free_blocks.lower_bound(&search_key);
    if (it != free_blocks.end() && (*it)->device == device && (*it)->stream == stream) {
      block = *it;
      free_blocks.erase(it);
    } else {
      void* ptr;
      size_t alloc_size = small ? kSmallAlloc : size;
      hipError_t err = hip_malloc_retry(device, &ptr, alloc_size);
      if (err != hipSuccess) {
        return err;
      }
      block = new Block(device, stream, alloc_size, (char*)ptr);
    }

    if (block->size - size >= (small ? kRoundSmall : kSmallAlloc + 1)) {
      remaining = block;

      block = new Block(device, stream, size, block->ptr);
      block->prev = remaining->prev;
      if (block->prev) {
        block->prev->next = block;
      }
      block->next = remaining;

      remaining->prev = block;
      remaining->ptr += size;
      remaining->size -= size;
      free_blocks.insert(remaining);
    }

    block->allocated = true;
    allocated_blocks[block->ptr] = block;

    *devPtr = (void*)block->ptr;
    return hipSuccess;
  }

  hipError_t free(void* ptr)
  {
    std::lock_guard<std::mutex> lock(mutex);
    if (!ptr) {
      return hipSuccess;
    }

    auto it = allocated_blocks.find(ptr);
    if (it == allocated_blocks.end()) {
      return hipErrorInvalidDevicePointer;
    }

    Block* block = it->second;
    allocated_blocks.erase(it);

    bool small = block->size <= kSmallAlloc;
    auto& free_blocks = small ? large_blocks : small_blocks;
    try_merge_blocks(block, block->prev, free_blocks);
    try_merge_blocks(block, block->next, free_blocks);

    block->allocated = false;
    free_blocks.insert(block);

    return hipSuccess;
  }

  /** returns cached blocks to the system allocator */
  hipError_t emptyCache()
  {
    std::lock_guard<std::mutex> lock(mutex);
    hipError_t err = free_blocks(large_blocks, large_blocks.begin(), large_blocks.end());
    if (err != hipSuccess) {
      return err;
    }
    err = free_blocks(small_blocks, small_blocks.begin(), small_blocks.end());
    if (err != hipSuccess) {
      return err;
    }
    return hipSuccess;
  }

  /** combine previously split blocks */
  void try_merge_blocks(Block* dst, Block* src, FreeBlocks& free_blocks)
  {
    if (!src || src->allocated) {
      return;
    }
    if (dst->prev == src) {
      dst->ptr = src->ptr;
      dst->prev = src->prev;
      if (dst->prev) {
        dst->prev->next = dst;
      }
    } else {
      dst->next = src->next;
      if (dst->next) {
        dst->next->prev = dst;
      }
    }
    dst->size += src->size;
    free_blocks.erase(src);
    delete src;
  }

  size_t round_size(size_t size)
  {
    if (size < kRoundSmall) {
      size = kRoundSmall;
    } else if (size < kSmallAlloc) {
      size += kRoundSmall - 1 - (size - 1) % kRoundSmall;
    } else {
      size += kRoundLarge - 1 - (size - 1) % kRoundLarge;
    }
    return size;
  }

  hipError_t hip_malloc_retry(int device, void** devPtr, size_t size)
  {
    // Try hipMalloc. If hipMalloc fails, frees all non-split cached blocks
    // and retries.
    hipError_t err = hipMalloc(devPtr, size);
    if (err != hipSuccess) {
      hipGetLastError();
      err = free_cached_blocks(device);
      if (err != hipSuccess) {
        return err;
      }
      err = hipMalloc(devPtr, size);
      if (err != hipSuccess) {
        return err;
      }
    }
    return hipSuccess;
  }

  hipError_t free_cached_blocks(int device)
  {
    // Free all non-split cached blocks on device
    Block lower_bound(device, NULL, 0);
    Block upper_bound(device + 1, NULL, 0);

    hipError_t err = free_blocks(
        large_blocks,
        large_blocks.lower_bound(&lower_bound),
        large_blocks.lower_bound(&upper_bound));
    if (err != hipSuccess) {
      return err;
    }
    err = free_blocks(
        small_blocks,
        small_blocks.lower_bound(&lower_bound),
        small_blocks.lower_bound(&upper_bound));
    return err;
  }

  hipError_t free_blocks(FreeBlocks& blocks, FreeBlocks::iterator it, FreeBlocks::iterator end)
  {
    // Frees all non-split blocks between `it` and `end`
    while (it != end) {
      Block* block = *it;
      if (!block->prev && !block->next) {
        hipError_t err = hipFree((void*)block->ptr);
        if (err != hipSuccess) {
          return err;
        }
        auto cur = it;
        ++it;
        blocks.erase(cur);
        delete block;
      } else {
        ++it;
      }
    }
    return hipSuccess;
  }
};

static hipError_t THCCachingAllocator_malloc(void* ctx, void** ptr, size_t size, hipStream_t stream)
{
  THCCachingAllocator* a = (THCCachingAllocator*) ctx;
  return a->malloc(ptr, size, stream);
}

static hipError_t THCCachingAllocator_free(void* ctx, void* ptr)
{
  THCCachingAllocator* a = (THCCachingAllocator*) ctx;
  return a->free(ptr);
}

static hipError_t THCCachingAllocator_emptyCache(void* ctx)
{
  THCCachingAllocator* a = (THCCachingAllocator*) ctx;
  return a->emptyCache();
}

static THCCachingAllocator caching_allocator;
static THCDeviceAllocator device_allocator = {
  &THCCachingAllocator_malloc,
  NULL,
  &THCCachingAllocator_free,
  &THCCachingAllocator_emptyCache,
  &caching_allocator
};

THC_API THCDeviceAllocator* THCCachingAllocator_get(void)
{
  return &device_allocator;
}
