#!/usr/bin/env python3
"""Tiny distribution-aware training run, for proving the pipeline end to end.

Deliberately trivial: synthetic data, a two-layer model, a few hundred steps. It
exists to answer "did the job reach a GPU, did every rank start, did exactly one
checkpoint get written" - not to learn anything.

Runs unchanged in all four shapes:

    python smoke_train.py                      # CPU or 1 GPU
    torchrun --nproc_per_node=4 smoke_train.py # 4 GPUs, one node
    srun torchrun ... smoke_train.py           # multi-node
    expanse.sh launch examples/smoke_train.py --gpus 2 --partition gpu-debug -t 00:15:00

It is also the worked example for reference/distributed.md: sampler sharding,
loss reduced across ranks, rank 0 alone writing output.
"""
import argparse
import json
import os
import time

import torch
import torch.distributed as dist
import torch.nn as nn
from torch.nn.parallel import DistributedDataParallel
from torch.utils.data import DataLoader, DistributedSampler, TensorDataset


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--samples", type=int, default=20000)
    p.add_argument("--dim", type=int, default=128)
    p.add_argument("--batch-size", type=int, default=64, help="per device")
    p.add_argument("--epochs", type=int, default=3)
    p.add_argument("--lr", type=float, default=1e-3)
    p.add_argument("--out", default="outputs/smoke")
    return p.parse_args()


def setup():
    """Join the process group when launched under torchrun, else run alone."""
    world = int(os.environ.get("WORLD_SIZE", 1))
    rank = int(os.environ.get("RANK", 0))
    local_rank = int(os.environ.get("LOCAL_RANK", 0))
    if world > 1:
        backend = "nccl" if torch.cuda.is_available() else "gloo"
        dist.init_process_group(backend=backend)
    if torch.cuda.is_available():
        torch.cuda.set_device(local_rank)
        device = torch.device("cuda", local_rank)
    else:
        device = torch.device("cpu")
    return rank, world, local_rank, device


def is_main(rank):
    return rank == 0


def log(rank, msg):
    # Every rank reports once at startup so a missing rank is obvious; after that
    # only rank 0 speaks, or the log is N-way interleaved noise.
    print(f"[rank {rank}] {msg}", flush=True)


def main():
    args = parse_args()
    rank, world, local_rank, device = setup()

    log(rank, f"world={world} device={device} "
              f"gpu={torch.cuda.get_device_name(local_rank) if torch.cuda.is_available() else 'none'}")

    torch.manual_seed(0)  # identical init on every rank

    x = torch.randn(args.samples, args.dim)
    w = torch.randn(args.dim, 1)
    y = (x @ w).squeeze(1) + 0.1 * torch.randn(args.samples)
    dataset = TensorDataset(x, y)

    # Each rank must see a different slice, or you are training N times on the
    # same data and calling it distributed.
    sampler = DistributedSampler(dataset, shuffle=True) if world > 1 else None
    loader = DataLoader(
        dataset,
        batch_size=args.batch_size,
        shuffle=(sampler is None),
        sampler=sampler,
        num_workers=min(4, (os.cpu_count() or 2) // max(world, 1)),
        pin_memory=torch.cuda.is_available(),
        drop_last=True,
    )

    model = nn.Sequential(
        nn.Linear(args.dim, 256), nn.ReLU(), nn.Linear(256, 1)
    ).to(device)
    if world > 1:
        model = DistributedDataParallel(
            model, device_ids=[local_rank] if torch.cuda.is_available() else None
        )

    opt = torch.optim.AdamW(model.parameters(), lr=args.lr)
    loss_fn = nn.MSELoss()

    started = time.time()
    history = []
    for epoch in range(args.epochs):
        if sampler is not None:
            sampler.set_epoch(epoch)  # or every rank reshuffles identically
        model.train()
        total, count = 0.0, 0
        for xb, yb in loader:
            xb, yb = xb.to(device, non_blocking=True), yb.to(device, non_blocking=True)
            loss = loss_fn(model(xb).squeeze(1), yb)
            opt.zero_grad(set_to_none=True)
            loss.backward()
            opt.step()
            total += loss.item() * xb.size(0)
            count += xb.size(0)

        # A per-rank average is one shard's number, not the epoch's.
        stats = torch.tensor([total, float(count)], device=device)
        if world > 1:
            dist.all_reduce(stats, op=dist.ReduceOp.SUM)
        epoch_loss = (stats[0] / stats[1]).item()
        history.append({"epoch": epoch, "loss": epoch_loss})
        if is_main(rank):
            log(rank, f"epoch {epoch} loss {epoch_loss:.4f}")

    if world > 1:
        dist.barrier()

    # Exactly one writer, and the unwrapped model, not the DDP shell.
    if is_main(rank):
        os.makedirs(args.out, exist_ok=True)
        to_save = model.module if isinstance(model, DistributedDataParallel) else model
        torch.save(to_save.state_dict(), os.path.join(args.out, "model.pt"))
        summary = {
            "world_size": world,
            "device": str(device),
            "epochs": args.epochs,
            "final_loss": history[-1]["loss"],
            "seconds": round(time.time() - started, 1),
            "history": history,
        }
        with open(os.path.join(args.out, "summary.json"), "w") as f:
            json.dump(summary, f, indent=2)
        log(rank, f"wrote {args.out}/model.pt and summary.json in {summary['seconds']}s")

    if world > 1:
        dist.destroy_process_group()


if __name__ == "__main__":
    main()
