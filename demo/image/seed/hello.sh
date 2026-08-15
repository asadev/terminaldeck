#!/bin/bash
# A script that is here to be run, edited and re-run, so that "this is a real
# machine" is something a visitor proves to themselves rather than reads.
echo "Hello from $(hostname), running $(uname -sr)."
echo "The time here is $(date -u '+%H:%M:%S UTC') and this shell is pid $$."
