# Making a single-GPU script use multiple GPUs

This skill will not rewrite your training code. Converting to distributed
training changes what the model learns, not just how fast it runs, and a silent
automated rewrite is the wrong way to make that change. What follows is the
decision order, and the checklist to apply once you have decided.

## Before converting anything: check you are actually GPU-bound

Most "slow" training on Expanse is not compute-bound. Run one short job and look:

```bash
nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv -l 10
```

- **Utilization pinned near 100%** - you are compute-bound. More GPUs will help.
- **Utilization sawtoothing between 0 and 90%** - you are dataloader-bound. More
  GPUs will help far less than expected, and may not help at all.

If you are dataloader-bound, the cheap fixes come first, and none of them touch
your training loop:

1. Raise `--cpus` and set `num_workers` to match (`--cpus 10` per GPU is the
   generated default; use `num_workers=8`, `pin_memory=True`, `persistent_workers=True`).
2. Unpack the dataset onto node-local NVMe at job start rather than reading many
   small files off Lustre.
3. Raise the batch size until GPU memory is nearly full, and enable mixed
   precision (`bf16` on H100, `fp16` or `bf16` on V100).

Mixed precision plus a full batch often gets 2-4x on one GPU, which is
comparable to naive 4-GPU scaling, at zero risk to correctness.

## Then pick a route

In increasing order of effort and risk:

| Route | Code change | Use when |
|---|---|---|
| **HuggingFace `Trainer`** | Replace your loop with `Trainer` | You are training a transformer or embedding model. It handles DDP entirely; you launch with `torchrun` and change nothing else |
| **`accelerate`** | ~5 lines | You want to keep your own training loop |
| **Lightning** | Restructure into a `LightningModule` | You are starting fresh or already use it |
| **Raw `torch.distributed` DDP** | ~20 lines, several sharp edges | You need control the others do not give |

For embedding and sentence-transformer work, `Trainer` (or
`SentenceTransformerTrainer` in sentence-transformers v3+) is almost always the
right answer. It is less code than raw DDP and it is already tested.

## The `accelerate` route, concretely

```python
from accelerate import Accelerator

accelerator = Accelerator()                      # 1
model, optimizer, dataloader = accelerator.prepare(model, optimizer, dataloader)  # 2

for batch in dataloader:
    loss = model(**batch).loss
    accelerator.backward(loss)                   # 3  instead of loss.backward()
    optimizer.step(); optimizer.zero_grad()

accelerator.wait_for_everyone()                  # 4
if accelerator.is_main_process:                  # 5
    accelerator.unwrap_model(model).save_pretrained(out_dir)
```

Remove any `model.to(device)` and `batch.to(device)` calls; `prepare` owns device
placement. Then run it with `--launcher accelerate` or `--launcher torchrun`.

## Checklist for any route

Miss one of these and the job runs, reports plausible numbers, and is wrong:

- **Sampler.** Each rank must see a different slice. `DistributedSampler`, and
  call `sampler.set_epoch(epoch)` every epoch or all ranks reshuffle identically.
- **Effective batch size.** With N GPUs it is `per_device_batch x N`. Your
  learning rate was tuned for the old value; scale it or lower the per-device
  batch.
- **Saving.** Only rank 0 writes checkpoints, and it must save
  `model.module.state_dict()` (or the unwrapped model), not the DDP wrapper.
- **Logging.** Only rank 0 prints and reports metrics, or your log is N-way
  interleaved noise.
- **Metrics.** Validation loss and accuracy must be reduced across ranks, or you
  are reporting one shard's number as the whole.
- **Seeds.** Same model init across ranks, different data order per rank.
- **`init_process_group` and cleanup.** Raw DDP only; `Trainer` and `accelerate`
  do it for you.

## The trap specific to embedding training

Contrastive losses that use in-batch negatives - `MultipleNegativesRankingLoss`,
InfoNCE, most retrieval and sentence-embedding objectives - get their training
signal from the *other examples in the same batch*.

Under plain DDP each rank computes its loss on its own local batch only. Four
GPUs with a per-device batch of 32 gives you four independent 32-way contrastive
problems, **not** one 128-way problem. In-batch negatives are the main driver of
embedding quality, so this quietly produces a *worse* model than the single-GPU
run it replaced, while the loss curve looks fine.

Fixes:

- Gather embeddings across ranks before computing the loss (`all_gather` with
  gradients, or GradCache). sentence-transformers v3+ and most modern retrieval
  training code already do this - check before assuming.
- Or keep the global batch identical to the single-GPU batch you tuned, and treat
  the extra GPUs as a way to fit a larger batch rather than to go faster.

Verify empirically: train the same data on 1 GPU and on N, and compare retrieval
metrics, not loss. If N-GPU is worse, this is why.

## Validate cheaply before spending the allocation

```bash
expanse.sh launch ./train.py --partition gpu-debug --gpus 2 --time 00:20:00 \
    --args "--epochs 1 --max-steps 50"
```

Twenty minutes on the debug queue is enough to prove the ranks start, the
rendezvous completes, checkpoints are written once rather than N times, and the
loss looks sane. Do that before committing a six-hour four-GPU run.
