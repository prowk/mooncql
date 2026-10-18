#ifndef _WIN32
#define _POSIX_C_SOURCE 200809L
#endif
#include <stdint.h>
#ifdef _WIN32
#include <windows.h>
#include <psapi.h>
#pragma comment(lib, "psapi.lib")
#else
#include <time.h>
#include <sys/resource.h>
#endif

int64_t prowk_mooncql_bench_now_ns(void) {
#ifdef _WIN32
  LARGE_INTEGER value, frequency;
  QueryPerformanceCounter(&value);
  QueryPerformanceFrequency(&frequency);
  /* 分开整数秒与余数，避免计数器乘十亿时溢出。 */
  return (value.QuadPart / frequency.QuadPart) * INT64_C(1000000000)
    + (int64_t)((long double)(value.QuadPart % frequency.QuadPart)
      * 1000000000.0L / (long double)frequency.QuadPart);
#else
  struct timespec value;
  clock_gettime(CLOCK_MONOTONIC, &value);
  return (int64_t)value.tv_sec * INT64_C(1000000000) + value.tv_nsec;
#endif
}

int64_t prowk_mooncql_bench_cpu_ns(void) {
#ifdef _WIN32
  FILETIME creation, exit_time, kernel, user;
  GetProcessTimes(GetCurrentProcess(), &creation, &exit_time, &kernel, &user);
  uint64_t kernel_ticks = ((uint64_t)kernel.dwHighDateTime << 32) | kernel.dwLowDateTime;
  uint64_t user_ticks = ((uint64_t)user.dwHighDateTime << 32) | user.dwLowDateTime;
  return (int64_t)(kernel_ticks + user_ticks) * 100;
#else
  struct timespec value;
  clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value);
  return (int64_t)value.tv_sec * INT64_C(1000000000) + value.tv_nsec;
#endif
}

int64_t prowk_mooncql_bench_peak_bytes(void) {
#ifdef _WIN32
  PROCESS_MEMORY_COUNTERS memory;
  if (!GetProcessMemoryInfo(GetCurrentProcess(), &memory, sizeof(memory))) return -1;
  return (int64_t)memory.PeakWorkingSetSize;
#else
  struct rusage usage;
  if (getrusage(RUSAGE_SELF, &usage) != 0) return -1;
#ifdef __APPLE__
  return (int64_t)usage.ru_maxrss;
#else
  return (int64_t)usage.ru_maxrss * 1024;
#endif
#endif
}
