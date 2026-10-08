import numpy as np, coremltools as ct, coremltools.optimize as cto, torch
from transformers import AutoModel, AutoTokenizer
m = ct.models.MLModel("e5-small-256.mlpackage")
cfg = cto.coreml.OptimizationConfig(global_config=cto.coreml.OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8", granularity="per_channel"))
q = cto.coreml.linear_quantize_weights(m, cfg); q.save("e5-small-256-int8.mlpackage")
tok = AutoTokenizer.from_pretrained("intfloat/multilingual-e5-small")
ref = ct.models.MLModel("e5-small-256.mlpackage"); qm = ct.models.MLModel("e5-small-256-int8.mlpackage")
texts=["query: when is the dentist appointment","passage: I booked a teeth cleaning for Tuesday at three.","passage: The quarterly budget review moved to Thursday.","query: réunion budget trimestrielle","passage: 来週の会議は木曜日に変更されました。"]
V=[];W=[]
for t in texts:
    e=tok([t],padding="max_length",max_length=256,truncation=True,return_tensors="np")
    i={"input_ids":e["input_ids"].astype(np.int32),"attention_mask":e["attention_mask"].astype(np.int32)}
    a=ref.predict(i)["embedding"][0]; b=qm.predict(i)["embedding"][0]; V.append(a); W.append(b)
    print(f"cos(fp16,int8)={float(a@b/np.linalg.norm(a)/np.linalg.norm(b)):.5f} {t[:40]!r}")
V=np.array(V);W=np.array(W)
print("fp16 q0:",np.round(V[0]@V[1:3].T,4),"int8 q0:",np.round(W[0]@W[1:3].T,4))
print("fp16 q3:",np.round(V[3]@V[1:3].T,4),"int8 q3:",np.round(W[3]@W[1:3].T,4))
