#!/usr/bin/env python3
"""Round 2: v1 vs v2 on the same held-out tiles; seed noise floor; human_heldout cards. python -I 14_compare_round2.py <data_dir>"""
import sys, json, numpy as np
D = sys.argv[1]; R = f'{D}/runs_round2'
E = {t: json.load(open(f'{R}/{t}_eval.json')) for t in ('v1_s1', 'v2_s1', 'v1_s2', 'v2_s2')}
def f1(a):
    tp_p, n_p, tp_r, n_r = a.sum(0); P = tp_p / max(n_p, 1); Rr = tp_r / max(n_r, 1); return P, Rr, 2 * P * Rr / max(P + Rr, 1e-9)
rng = np.random.default_rng(0); out = {}
for thr in ('thr_0.5', 'thr_val_best'):
    A = {t: np.array(E[t]['test'][thr]['per_tile']) for t in E}; n = len(A['v1_s1']); ix = [rng.integers(0, n, n) for _ in range(2000)]
    o = {t: dict(zip('PRF', map(float, f1(A[t]))), thr=E[t]['test'][thr]['thr']) for t in A}
    def diff(x, y): d = [f1(y[i])[2] - f1(x[i])[2] for i in ix]; return [float(f1(y)[2] - f1(x)[2]), float(np.percentile(d, 2.5)), float(np.percentile(d, 97.5))]
    o['dF1_v2_minus_v1_seed1'] = diff(A['v1_s1'], A['v2_s1']); o['dF1_v2_minus_v1_seed2'] = diff(A['v1_s2'], A['v2_s2'])
    o['dF1_seed_noise_v1_s2_minus_v1_s1'] = diff(A['v1_s1'], A['v1_s2']); o['dF1_seed_noise_v2_s2_minus_v2_s1'] = diff(A['v2_s1'], A['v2_s2'])
    o['dF1_pooled'] = diff(A['v1_s1'] + A['v1_s2'], A['v2_s1'] + A['v2_s2'])
    out[thr] = o
H = {}
def wil(k, n, z=1.96):
    if n == 0: return [0, 1]
    p = k / n; d = 1 + z * z / n; c = p + z * z / (2 * n); h = z * (p * (1 - p) / n + z * z / (4 * n * n)) ** .5; return [round((c - h) / d, 3), round((c + h) / d, 3)]
for t in E:
    h = E[t]['human_heldout']; hp = sum(x['pos_hit'] for x in h); np_ = sum(x['pos_px'] for x in h); hn = sum(x['neg_hit'] for x in h); nn = sum(x['neg_px'] for x in h)
    H[t] = dict(tiles=len(h), human_pos_recall=round(hp / max(np_, 1), 3), pos_px=np_, human_pos_recall_wilson_px=wil(hp, np_), neg_px_covered=round(hn / max(nn, 1), 3), neg_px=nn)
out['human_heldout'] = H; json.dump(out, open(f'{R}/compare_round2.json', 'w'), indent=1)
for thr, o in out.items():
    if thr == 'human_heldout': continue
    print(thr, {t: tuple(round(o[t][k], 3) for k in 'PRF') for t in ('v1_s1', 'v2_s1', 'v1_s2', 'v2_s2')})
    for k in o:
        if k.startswith('dF1'): print('  ', k, [round(x, 3) for x in o[k]])
print(json.dumps(H, indent=1))
