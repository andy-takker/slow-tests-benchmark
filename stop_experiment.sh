#!/usr/bin/env bash
# Cleanly stop ALL benchmark processes. The driver -> xdist_arm.sh -> pytest tree
# does NOT die when you kill only the driver (different command lines), which
# previously left an orphaned xdist_arm.sh running concurrently with a fresh
# launch. Always tear down with this script: kill leaves-first, then containers.
echo "stopping pytest workers…";   pkill -9 -f "pytest ./tests" 2>/dev/null
echo "stopping xdist_arm.sh…";      pkill -9 -f "xdist_arm.sh" 2>/dev/null
echo "stopping driver…";            pkill -9 -f "run_full_experiment.sh" 2>/dev/null
echo "stopping caffeinate…";        pkill -9 -f "caffeinate -dimsu bash run_full_experiment.sh" 2>/dev/null
sleep 2
echo "removing bench containers…";  docker rm -f lms-bench-pg lms-bench-redis 2>/dev/null
echo "survivors (should be empty):"
pgrep -fl "xdist_arm.sh|run_full_experiment.sh|pytest ./tests" || echo "  clean"
