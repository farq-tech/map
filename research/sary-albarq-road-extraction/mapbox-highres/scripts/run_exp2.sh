#!/bin/sh
# Experiment 2: 3 spatial-holdout folds (600 steps each) + zero-shot baselines on the same held-out sectors.
set -e; cd "$(dirname "$0")"
for f in middle north south; do python3 sam_finetune.py $f 600; python3 sam_finetune.py $f 0 zeroshot; done
