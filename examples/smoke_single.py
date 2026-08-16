#!/usr/bin/env python3
"""An ordinary single-process training script, with no distribution awareness.

This is here on purpose. It is what most training code looks like before anyone
thinks about multiple GPUs, and it is what the multi-GPU safety check exists to
catch:

    expanse.sh wrap examples/smoke_single.py --gpus 1   # fine
    expanse.sh wrap examples/smoke_single.py --gpus 4   # refused, with an explanation

Compare with smoke_train.py, which is the same job written to be launched once
per GPU.
"""
import argparse
import os

import torch
import torch.nn as nn
from torch.utils.data import DataLoader, TensorDataset

p = argparse.ArgumentParser()
p.add_argument("--samples", type=int, default=20000)
p.add_argument("--dim", type=int, default=128)
p.add_argument("--batch-size", type=int, default=64)
p.add_argument("--epochs", type=int, default=3)
p.add_argument("--out", default="outputs/single")
args = p.parse_args()

device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
print(f"device={device}", flush=True)

torch.manual_seed(0)
x = torch.randn(args.samples, args.dim)
w = torch.randn(args.dim, 1)
y = (x @ w).squeeze(1) + 0.1 * torch.randn(args.samples)
loader = DataLoader(TensorDataset(x, y), batch_size=args.batch_size, shuffle=True)

model = nn.Sequential(nn.Linear(args.dim, 256), nn.ReLU(), nn.Linear(256, 1)).to(device)
opt = torch.optim.AdamW(model.parameters(), lr=1e-3)
loss_fn = nn.MSELoss()

for epoch in range(args.epochs):
    total, count = 0.0, 0
    for xb, yb in loader:
        xb, yb = xb.to(device), yb.to(device)
        loss = loss_fn(model(xb).squeeze(1), yb)
        opt.zero_grad(set_to_none=True)
        loss.backward()
        opt.step()
        total += loss.item() * xb.size(0)
        count += xb.size(0)
    print(f"epoch {epoch} loss {total / count:.4f}", flush=True)

os.makedirs(args.out, exist_ok=True)
torch.save(model.state_dict(), os.path.join(args.out, "model.pt"))
print(f"wrote {args.out}/model.pt", flush=True)
