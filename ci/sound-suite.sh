#!/bin/bash
# The GCRY_SOUND=1 profile smoke and correctness suite, as `test (x86_64)`
# runs them on Linux. Bash, so the same script serves macOS and Git Bash on
# Windows.
set -e
mkdir -p bin
b() { crystal build -Dgc_none "$@" --error-trace; }
b samples/sound_profile.cr -o bin/sound_profile
./bin/sound_profile
GCRY_SOUND=1 ./bin/sound_profile
GCRY_SOUND=1 GCRY_SCRUB_FIBERS=1 ./bin/sound_profile
b -Dgcry_block_headers samples/sound_profile.cr -o bin/sound_profile_hdr
GCRY_SOUND=1 GCRY_NURSERY=262144 ./bin/sound_profile_hdr
b samples/stress.cr -o bin/stress
b samples/json_churn.cr -o bin/json_churn
b samples/alloc.cr -o bin/alloc
b bench/pattern_fuzz.cr -o bin/pattern_fuzz
b bench/thread_storm.cr -o bin/thread_storm
b bench/finalizer_complex.cr -o bin/finalizer_complex
b -Dgcry_block_headers bench/nursery_headers.cr -o bin/nursery_headers
b bench/stw_mt_property_test.cr -o bin/stw_mt_property_test
export GCRY_STW_WATCHDOG_MS=10000
GCRY_SOUND=1 ./bin/stress 300
GCRY_SOUND=1 ./bin/json_churn 800
GCRY_SOUND=1 ./bin/alloc 500
GCRY_SOUND=1 ./bin/pattern_fuzz --seed=1 --phases=20 --objects-per-phase=1000
GCRY_SOUND=1 ./bin/thread_storm --iterations=100 --workers=4
GCRY_SOUND=1 ./bin/finalizer_complex
GCRY_SOUND=1 ./bin/nursery_headers
GCRY_SOUND=1 ./bin/stw_mt_property_test --seed=1 --iterations=50 --workers=2,4
GCRY_SOUND=1 GCRY_STRESS=1 GCRY_STRESS_EVERY=32 ./bin/stress 100
GCRY_SOUND=1 GCRY_DISABLE_LAYOUT=1 ./bin/json_churn 800
GCRY_SOUND=1 GCRY_DISABLE_LAYOUT=1 ./bin/pattern_fuzz --seed=2 --phases=20 --objects-per-phase=1000
echo "sound suite: ok"
