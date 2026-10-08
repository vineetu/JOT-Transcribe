"""Pick e5's search cut-offs on a public benchmark (MIRACL reranking, dev).

Jot's shipped Gemma cut-offs (list 0.35, Ask Jot 0.30) were chosen to keep
correct matches in non-English languages. We carry that operating point over:
score both models on the same queries, measure Gemma's recall of relevant
passages at 0.35 / 0.30, then pick the e5 threshold with the same recall, and
compare how many unrelated passages each lets through at that point.

Negatives: (a) hard = judged non-relevant passages from the same query's
candidate list, (b) easy = relevant passages of *other* queries (an unrelated
recording). No owner data is used.
"""
import os, random, sys, json
import numpy as np, pandas as pd, coremltools as ct
from huggingface_hub import hf_hub_download
from transformers import AutoTokenizer
from tokenizers import Tokenizer

random.seed(7)
LANGS = ["en", "es", "fr", "de", "ru", "fi", "ja", "zh", "ko", "ar", "hi"]
NQ = int(os.environ.get("NQ", 30))
DS = "mteb/MIRACLReranking"

E5 = ct.models.MLModel("e5-small-256-int8.mlpackage", compute_units=ct.ComputeUnit.ALL)
E5TOK = AutoTokenizer.from_pretrained("intfloat/multilingual-e5-small")
GDIR = os.path.expanduser("~/Library/Application Support/Jot/Models/EmbeddingGemma/embeddinggemma-300m")
GEM = ct.models.CompiledMLModel(f"{GDIR}/encoder.mlmodelc", compute_units=ct.ComputeUnit.ALL)
GTOK = Tokenizer.from_file(f"{GDIR}/hf_model/tokenizer.json")


def e5(text, role):
    e = E5TOK([("query: " if role == "q" else "passage: ") + text], padding="max_length",
              max_length=256, truncation=True, return_tensors="np")
    return E5.predict({"input_ids": e["input_ids"].astype(np.int32),
                       "attention_mask": e["attention_mask"].astype(np.int32)})["embedding"][0]


def gemma(text, role):
    pre = "task: search result | query: " if role == "q" else "title: none | text: "
    ids = GTOK.encode(pre + text).ids[:128]
    n = len(ids)
    pad = GTOK.token_to_id("<pad>") or 0
    inp = np.array([ids + [pad] * (128 - n)], dtype=np.int32)
    mask = np.array([[1.0] * n + [0.0] * (128 - n)], dtype=np.float16)
    v = np.array(GEM.predict({"input_ids": inp, "attention_mask": mask})["embedding"][0][:256], dtype=np.float32)
    return v / np.linalg.norm(v)


def load(lang, part):
    return pd.read_parquet(hf_hub_download(DS, f"{lang}-{part}/dev-00000-of-00001.parquet", repo_type="dataset"))


rows = {"e5": {"pos": [], "hard": [], "easy": [], "lang": []}, "gemma": {"pos": [], "hard": [], "easy": [], "lang": []}}
for lang in LANGS:
    q = load(lang, "queries"); qr = load(lang, "qrels"); tr = load(lang, "top_ranked"); co = load(lang, "corpus")
    text = dict(zip(co["_id"] if "_id" in co else co["id"], (co.get("title", "").astype(str) + " " + co["text"].astype(str)).str.strip()))
    qid_col = "query-id" if "query-id" in qr else "query_id"
    did_col = "corpus-id" if "corpus-id" in qr else "corpus_id"
    rel = qr[qr["score"] > 0].groupby(qid_col)[did_col].apply(list).to_dict()
    cand = dict(zip(tr["query-id" if "query-id" in tr else "query_id"], tr["corpus-ids" if "corpus-ids" in tr else "corpus_ids"]))
    qtext = dict(zip(q["_id"] if "_id" in q else q["id"], q["text"]))
    qids = [k for k in qtext if k in rel and k in cand][:NQ]
    for i, qid in enumerate(qids):
        pos = [d for d in rel[qid] if d in text][:2]
        hard = [d for d in cand[qid] if d not in rel[qid] and d in text][:3]
        other = qids[(i + 7) % len(qids)]
        easy = [d for d in rel.get(other, []) if d in text][:1]
        if not pos:
            continue
        for name, f in (("e5", e5), ("gemma", gemma)):
            qv = f(qtext[qid], "q")
            for bucket, ids in (("pos", pos), ("hard", hard), ("easy", easy)):
                for d in ids:
                    rows[name][bucket].append((lang, float(qv @ f(text[d], "d"))))
    print(f"{lang}: {len(qids)} queries", file=sys.stderr)


def recall(xs, t): return float(np.mean([s >= t for _, s in xs]))


import json as _json
_json.dump(rows, open("scores.json", "w"))


out = {}
for name in ("gemma", "e5"):
    r = rows[name]
    out[name] = {b: np.array([s for _, s in r[b]]) for b in ("pos", "hard", "easy")}
    print(f"\n{name}: pos n={len(r['pos'])} median={np.median(out[name]['pos']):.3f}  "
          f"hard median={np.median(out[name]['hard']):.3f}  easy median={np.median(out[name]['easy']):.3f}")

for gname, gt in (("list", 0.35), ("ask", 0.30)):
    target = recall(rows["gemma"]["pos"], gt)
    grid = np.arange(0.40, 0.95, 0.005)
    best = max([t for t in grid if recall(rows["e5"]["pos"], t) >= target] or [grid[0]])
    print(f"\n[{gname}] gemma@{gt}: recall={target:.3f} hard-pass={recall(rows['gemma']['hard'], gt):.3f} easy-pass={recall(rows['gemma']['easy'], gt):.3f}")
    print(f"[{gname}] e5@{best:.3f}: recall={recall(rows['e5']['pos'], best):.3f} hard-pass={recall(rows['e5']['hard'], best):.3f} easy-pass={recall(rows['e5']['easy'], best):.3f}")
    for lang in LANGS:
        gp = [s for l, s in rows["gemma"]["pos"] if l == lang]; ep = [s for l, s in rows["e5"]["pos"] if l == lang]
        print(f"    {lang}: gemma recall {np.mean([s >= gt for s in gp]):.2f}  e5 recall {np.mean([s >= best for s in ep]):.2f}")

# Ranking quality independent of thresholds: does a relevant passage outscore the query's hard negatives?
for name in ("gemma", "e5"):
    print(f"{name}: mean pos {out[name]['pos'].mean():.3f} vs hard {out[name]['hard'].mean():.3f} vs easy {out[name]['easy'].mean():.3f}")
