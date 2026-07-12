/*
 * mayhem/fuzz_vdex.c — in-process libFuzzer harness for vdexExtractor.
 *
 * The upstream Mayhem target ran the CLI (`/vdexExtractor -i @@`): an uninstrumented,
 * fork/exec, file-input binary that mmaps the input and drives the VDEX parser +
 * unquickening/de-odex backend. That raw file-input target yields ~0 edges (the fuzzed
 * code isn't instrumented and each iteration is a fresh process). This harness preserves
 * the SAME code path — it reproduces vdexExtractor.c's per-file loop
 * (vdexApi_initEnv -> dumpHeaderInfo -> dumpDepsInfo -> process) over the fuzz input, but
 * in-process against the ASan/UBSan-instrumented library, so Mayhem sees real coverage.
 *
 * Fidelity: the CLI mmaps the file PROT_READ|PROT_WRITE, MAP_PRIVATE. We reproduce that
 * exactly with an anonymous MAP_PRIVATE mapping sized to the input, so reads past the
 * input but within the last page read as zero (matching a real short file mmap) and reads
 * past the mapping fault — a genuine over-read in the parser is a real, catchable defect,
 * not a harness artifact.
 *
 * exitWrapper: the CLI's l_FATAL path (invalid input, CHECK failures) calls exitWrapper()
 * to terminate the process. That is the tool's INTENTIONAL rejection of malformed input,
 * not a memory-safety bug, so we longjmp back and move to the next input instead of
 * aborting the fuzzer. Real memory defects surface as SIGSEGV / ASan / UBSan reports.
 */
#include <setjmp.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "../src/common.h"
#include "../src/dex.h"
#include "../src/log.h"
#include "../src/vdex_api.h"

/* vdexExtractor is a one-shot CLI: it parses a file and exits without freeing its
 * allocations (process teardown reclaims them). In libFuzzer's persistent process those
 * intentional process-lifetime allocations look like leaks and make LSan unusable, so we
 * disable ONLY leak detection while keeping ASan's heap/OOB checks and UBSan fully on. */
const char *__asan_default_options(void) { return "detect_leaks=0"; }

static jmp_buf g_return;

void exitWrapper(int status) {
  (void)status;
  longjmp(g_return, 1);
}

static const char *kOutDir = "/tmp/vdex_fuzz_out";

int LLVMFuzzerInitialize(int *argc, char ***argv) {
  (void)argc;
  (void)argv;
  /* Silence the tool's logging so fuzzing isn't throttled by stdout/stderr writes. */
  log_setMinLevel(l_FATAL);
  mkdir(kOutDir, 0755);
  return 0;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  if (size == 0) {
    return 0;
  }

  /* Reproduce the CLI's PROT_READ|PROT_WRITE MAP_PRIVATE mapping semantics. */
  void *map = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (map == MAP_FAILED) {
    return 0;
  }
  memcpy(map, data, size);
  const u1 *buf = (const u1 *)map;

  runArgs_t runArgs = {
    .outputDir = (char *)kOutDir,
    .fileOverride = true,
    .unquicken = true,
    .enableDisassembler = false,
    .ignoreCrc = true,
    .dumpDeps = true,
    .newCrcFile = NULL,
    .getApi = false,
  };

  vdex_api_env_t vdex;
  memset(&vdex, 0, sizeof(vdex));

  if (setjmp(g_return) == 0) {
    if (vdexApi_initEnv(buf, &vdex)) {
      vdex.dumpHeaderInfo(buf);
      vdex.dumpDepsInfo(buf);
      vdex.process("/tmp/vdex_fuzz_out/input.vdex", buf, size, &runArgs);
    }
  }

  munmap(map, size);
  return 0;
}
