#!/usr/bin/env python3
"""Paired bootstrap (over held-out tiles) of fine-tuned vs baseline. python -I 07_compare.py <data_dir>"""
import sys, json, numpy as np
D = sys.argv[1]
B = json.load(open(f'{D}/runs/eval_baseline.json')); F = json.load(open(f'{D}/runs/eval_finetuned.json'))
assert B['test_tiles'] == F['test_tiles']
def f1(a):
    tp_p, n_p, tp_r, n_r = a.sum(0); P = tp_p / max(n_p, 1); R = tp_r / max(n_r, 1); return P, R, 2 * P * R / max(P + R, 1e-9)
rng = np.random.default_rng(0); out = {}
for name in ('thr_0.5', 'thr_val_best'):
    a = np.array(B['test'][name]['per_tile']); b = np.array(F['test'][name]['per_tile']); d = []; dr = []; dp = []
    for _ in range(2000):
        ix = rng.integers(0, len(a), len(a)); fa, fb = f1(a[ix]), f1(b[ix]); d.append(fb[2] - fa[2]); dr.append(fb[1] - fa[1]); dp.append(fb[0] - fa[0])
    out[name] = dict(base=dict(zip('PRF', map(float, f1(a)))), ft=dict(zip('PRF', map(float, f1(b)))), thr_base=B['test'][name]['thr'], thr_ft=F['test'][name]['thr'],
                     dF1=[float(np.mean(d)), float(np.percentile(d, 2.5)), float(np.percentile(d, 97.5))],
                     dR=[float(np.mean(dr)), float(np.percentile(dr, 2.5)), float(np.percentile(dr, 97.5))],
                     dP=[float(np.mean(dp)), float(np.percentile(dp, 2.5)), float(np.percentile(dp, 97.5))],
                     groups={k: dict(base=B['test'][name]['groups'][k], ft=F['test'][name]['groups'][k]) for k in B['test'][name]['groups']})
json.dump(out, open(f'{D}/runs/compare.json', 'w'), indent=1)
for name, o in out.items():
    print(name, 'base', {k: round(v, 3) for k, v in o['base'].items()}, 'ft', {k: round(v, 3) for k, v in o['ft'].items()}, 'dF1 mean/CI', [round(x, 3) for x in o['dF1']])
    for k, g in o['groups'].items(): print('  ', k, g['base']['n_tiles'], 'F1 %.2f -> %.2f  R %.2f -> %.2f  P %.2f -> %.2f' % (g['base']['F1'], g['ft']['F1'], g['base']['R'], g['ft']['R'], g['base']['P'], g['ft']['P']))
