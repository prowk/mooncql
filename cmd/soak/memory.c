#include <stdint.h>
#ifdef _WIN32
#include <windows.h>
#include <psapi.h>
#pragma comment(lib, "psapi.lib")
static int64_t memory_field(int private_memory) {
  PROCESS_MEMORY_COUNTERS_EX memory;
  if (!GetProcessMemoryInfo(GetCurrentProcess(), (PROCESS_MEMORY_COUNTERS *)&memory, sizeof(memory))) return -1;
  return (int64_t)(private_memory ? memory.PrivateUsage : memory.WorkingSetSize);
}
#else
#include <stdio.h>
#include <string.h>
static int64_t memory_field(int private_memory) {
  FILE *file = fopen("/proc/self/status", "r");
  if (!file) return -1;
  char line[256];
  long long value = -1;
  const char *field = private_memory ? "VmData:" : "VmRSS:";
  while (fgets(line, sizeof(line), file)) {
    if (strncmp(line, field, strlen(field)) == 0) {
      if (sscanf(line + strlen(field), "%lld", &value) != 1) value = -1;
      break;
    }
  }
  fclose(file);
  return value < 0 ? -1 : (int64_t)value * 1024;
}
#endif

int64_t prowk_mooncql_soak_rss(void) { return memory_field(0); }
int64_t prowk_mooncql_soak_private(void) { return memory_field(1); }
