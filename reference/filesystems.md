# Storage on Expanse

| Filesystem | Path | Size | Lifetime | Use for |
|---|---|---|---|---|
| Home | `/home/$USER` | 100 GB | Backed up, 8-week rolling | Source code, scripts, small configs |
| Lustre scratch | `/expanse/lustre/scratch/$USER/temp_project` | large | **Purged 90 days after creation** | Job working directory, data, outputs, caches |
| Lustre projects | `/expanse/lustre/projects/<alloc>` | per allocation | Purged 90 days after the allocation expires | Data shared with your project team |
| Node-local NVMe | `/scratch/$USER/job_$SLURM_JOB_ID` | 1 TB (CPU), 1.6 TB (V100), 3.2 TB (large-shared), 6.4 TB (H100) | Deleted when the job ends | Fastest I/O: temp files, shards, `$TMPDIR` |
| Ceph object store | S3 interface | up to 3 PB | persistent | Cloud-style object access |

Neither Lustre filesystem is backed up, and neither is an archive. Pull anything
you need to keep back to your own machine.

## Hard rules

- **Do not run jobs from `/home`.** The vendor guide is explicit: home is not set
  up for high-performance throughput, and a training job hammering it degrades
  the login environment for everyone.
- Point every cache at Lustre or node-local NVMe. Left alone, pip, conda,
  HuggingFace and PyTorch all write into `/home` and will blow the 100 GB quota:

  ```bash
  export HF_HOME="$RUN_DIR/cache/huggingface"
  export TORCH_HOME="$RUN_DIR/cache/torch"
  export PIP_CACHE_DIR="$RUN_DIR/cache/pip"
  export CONDA_PKGS_DIRS="$RUN_DIR/cache/conda"
  export TMPDIR="/scratch/$USER/job_$SLURM_JOB_ID"
  ```

- Lustre hates many small files. Stage a dataset as a few large archives, unpack
  onto node-local NVMe at job start, and write checkpoints back to Lustre
  periodically rather than every step.
- Anything on node-local NVMe is gone the moment the job ends. Copy results out
  before the script exits, including on failure (`trap ... EXIT`).

## Layout this skill uses

```
/home/$USER/expanse-agent/<project>/                     code   (expanse.sh push-code)
/expanse/lustre/scratch/$USER/temp_project/<project>/    run dir (expanse.sh push)
    logs/     SLURM stdout and stderr
    cache/    HF, torch, pip caches
    outputs/  results to pull back
```

`<project>` comes from `EXPANSE_PROJECT` in your config, so two pieces of work
never collide in the same directory.

## Moving data

Small to medium, through the shared session:

```bash
scripts/expanse.sh push ./data           # local -> run dir
scripts/expanse.sh push-code ./src       # local -> home
scripts/expanse.sh pull outputs ./results
```

These use `rsync -az`, so they resume and skip unchanged files.

Large transfers (hundreds of GB and up) should use Globus rather than the login
nodes, which are explicitly not meant to be primary data transfer hosts. Globus
collections:

- **SDSC HPC - Expanse Lustre**, mount `/expanse/lustre/scratch` shown as `/scratch/...`
- **SDSC HPC - Projects**, mount `/expanse/lustre/projects` shown as `/projects/...`

Check your quota and usage:

```bash
du -sh /home/$USER
lfs quota -h -u $USER /expanse/lustre/scratch
```
