#!/usr/bin/env bash
# Interactive Expanse sessions. Run these THROUGH the shared connection, from a
# terminal a human is watching - they hold a live shell, so an agent should
# prefer batch jobs (sbatch) instead.
#
#   ssh expanse       then paste one of the commands below
#
# Debug GPU session (30 min cap, fast to schedule, max 2 GPUs):
#
#   srun --partition=gpu-debug --pty --account=<ACCOUNT> \
#        --nodes=1 --ntasks-per-node=10 --gpus=1 --mem=96G \
#        -t 00:30:00 --wait=0 --export=ALL /bin/bash
#
# Longer shared GPU session (up to 48 h, may queue):
#
#   srun --partition=gpu-shared --pty --account=<ACCOUNT> \
#        --nodes=1 --ntasks-per-node=10 --gpus=1 --mem=92G \
#        -t 02:00:00 --wait=0 --export=ALL /bin/bash
#
# H100 session on the AI resource (note the h100: prefix):
#
#   srun --partition=nairr-gpu-shared --pty --account=<ACCOUNT> \
#        --nodes=1 --ntasks-per-node=18 --gpus=h100:1 --mem=240G \
#        -t 02:00:00 --wait=0 --export=ALL /bin/bash
#
# CPU debug session (30 min cap):
#
#   srun --partition=debug --pty --account=<ACCOUNT> \
#        --nodes=1 --ntasks-per-node=4 --mem=8G \
#        -t 00:30:00 --wait=0 --export=ALL /bin/bash
#
# Compile inside an interactive session, not on the login node: login nodes have
# different hardware from the batch nodes.
echo "This file is documentation. Copy one of the srun commands above." >&2
