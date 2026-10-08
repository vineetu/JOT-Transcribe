"""Trial: convert intfloat/multilingual-e5-small to Core ML and check parity.

Model = XLM-R encoder + attention-masked mean pooling + L2 normalise, so the
Core ML output is the final 384-d unit vector. Fixed sequence length (pad to
SEQ) keeps it ANE-friendly. Compares Core ML (fp16) against PyTorch (fp32).
"""
import sys, time
import numpy as np
import torch
import coremltools as ct
from transformers import AutoModel, AutoTokenizer

REPO = "intfloat/multilingual-e5-small"
SEQ = int(sys.argv[1]) if len(sys.argv) > 1 else 256
OUT = f"e5-small-{SEQ}.mlpackage"

tok = AutoTokenizer.from_pretrained(REPO)
base = AutoModel.from_pretrained(REPO, torch_dtype=torch.float32, attn_implementation="eager").eval()


class Embedder(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, input_ids, attention_mask):
        # Additive mask built here with -1e4, not float32.min: the library's
        # mask overflows to -inf/NaN once the model runs in fp16.
        emb = self.m.embeddings(input_ids=input_ids)
        ext = (1.0 - attention_mask[:, None, None, :].to(emb.dtype)) * -1e4
        h = self.m.encoder(emb, attention_mask=ext).last_hidden_state
        mask = attention_mask.unsqueeze(-1).to(h.dtype)
        pooled = (h * mask).sum(1) / mask.sum(1).clamp(min=1e-6)
        return torch.nn.functional.normalize(pooled, dim=-1)


model = Embedder(base).eval()
ex = tok(["query: hello"], padding="max_length", max_length=SEQ, truncation=True, return_tensors="pt")
with torch.no_grad():
    traced = torch.jit.trace(model, (ex["input_ids"], ex["attention_mask"]), strict=False)

ml = ct.convert(
    traced,
    inputs=[
        ct.TensorType(name="input_ids", shape=(1, SEQ), dtype=np.int32),
        ct.TensorType(name="attention_mask", shape=(1, SEQ), dtype=np.int32),
    ],
    outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
    minimum_deployment_target=ct.target.macOS15,
    compute_precision=ct.precision.FLOAT16,
)
ml.short_description = "multilingual-e5-small (MIT) sentence embedding, mean-pooled + L2-normalised, 384-d"
ml.save(OUT)

texts = [
    "query: when is the dentist appointment",
    "passage: I booked a teeth cleaning for Tuesday at three.",
    "passage: The quarterly budget review moved to Thursday.",
    "query: réunion budget trimestrielle",
    "passage: 来週の会議は木曜日に変更されました。",
    "passage: " + "long transcript sentence. " * 200,
]
cm = ct.models.MLModel(OUT, compute_units=ct.ComputeUnit.ALL)
worst = 1.0
pt_vecs, cm_vecs = [], []
for t in texts:
    e = tok([t], padding="max_length", max_length=SEQ, truncation=True, return_tensors="pt")
    with torch.no_grad():
        p = model(e["input_ids"], e["attention_mask"]).numpy()[0]
    t0 = time.perf_counter()
    c = cm.predict({"input_ids": e["input_ids"].numpy().astype(np.int32),
                    "attention_mask": e["attention_mask"].numpy().astype(np.int32)})["embedding"][0]
    ms = (time.perf_counter() - t0) * 1000
    cos = float(np.dot(p, c) / (np.linalg.norm(p) * np.linalg.norm(c)))
    worst = min(worst, cos)
    pt_vecs.append(p); cm_vecs.append(c)
    print(f"cos(pt,coreml)={cos:.5f}  {ms:6.1f} ms  {t[:50]!r}")

P, C = np.array(pt_vecs), np.array(cm_vecs)
print("pt  query0 vs passages:", np.round(P[0] @ P[1:3].T, 4))
print("cml query0 vs passages:", np.round(C[0] @ C[1:3].T, 4))
print("pt  query3 vs passages:", np.round(P[3] @ P[1:3].T, 4))
print("cml query3 vs passages:", np.round(C[3] @ C[1:3].T, 4))
print(f"WORST cos = {worst:.5f}  -> {'OK' if worst > 0.999 else 'CHECK'}")
