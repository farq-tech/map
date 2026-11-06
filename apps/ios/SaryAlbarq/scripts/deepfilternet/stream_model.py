"""Stateful chunk wrapper around the official DeepFilterNet3 modules: fixed P+C input frames
(P = 6 context frames from the previous chunk), GRU states in/out, exact to the full-clip model."""
import torch
from torch import nn

P = 6

def split_gru(g: nn.GRU):
    """nn.GRU(num_layers=n) → n single-layer GRUs (same weights), friendlier to Core ML."""
    out = nn.ModuleList()
    for l in range(g.num_layers):
        s = nn.GRU(g.hidden_size if l else g.input_size, g.hidden_size, 1, batch_first=True)
        for n in ["weight_ih", "weight_hh", "bias_ih", "bias_hh"]:
            getattr(s, n + "_l0").data.copy_(getattr(g, f"{n}_l{l}").data)
        out.append(s)
    return out

class SG(nn.Module):  # SqueezedGRU_S with explicit per-layer states
    def __init__(s, m):
        super().__init__(); s.lin_in, s.lin_out, s.skip = m.linear_in, m.linear_out, m.gru_skip
        s.grus = split_gru(m.gru)
    def forward(s, inp, hs):
        x = s.lin_in(inp); new = []
        for g, h in zip(s.grus, hs):
            x, h2 = g(x, h); new.append(h2)
        x = s.lin_out(x)
        if s.skip is not None: x = x + s.skip(inp)
        return x, new

class Stream(nn.Module):
    def __init__(s, m, C=100):
        super().__init__()
        s.C = C
        s.enc, s.erb_dec, s.df_dec = m.enc, m.erb_dec, m.df_dec
        s.enc_gru = SG(m.enc.emb_gru); s.erb_gru = SG(m.erb_dec.emb_gru); s.df_gru = SG(m.df_dec.df_gru)

    def forward(s, feat_erb, feat_spec, h_enc, h_erb, h_df, ctx_valid):
        # feat_erb [1,1,P+C,32]; feat_spec [1,2,P+C,96]; h_enc [1,1,256]; h_erb/h_df [2,1,256]; ctx_valid [1]
        E = s.enc
        e0 = E.erb_conv0(feat_erb)[:, :, P:]
        e1 = E.erb_conv1(e0); e2 = E.erb_conv2(e1); e3 = E.erb_conv3(e2)
        c0f = E.df_conv0(feat_spec)
        c0 = c0f[:, :, P:]
        c1 = E.df_conv1(c0)
        cemb = E.df_fc_emb(c1.permute(0, 2, 3, 1).flatten(2))
        emb = E.combine(e3.permute(0, 2, 3, 1).flatten(2), cemb)
        emb, he = s.enc_gru(emb, [h_enc])
        # ERB decoder
        D = s.erb_dec
        b, t, f8 = 1, s.C, 8
        x, hr = s.erb_gru(emb, [h_erb[0:1], h_erb[1:2]])
        x = x.view(b, t, f8, -1).permute(0, 3, 1, 2)
        y3 = D.convt3(D.conv3p(e3) + x)
        y2 = D.convt2(D.conv2p(e2) + y3)
        y1 = D.convt1(D.conv1p(e1) + y2)
        mask = D.conv0_out(D.conv0p(e0) + y1)
        # DF decoder (df_convp looks 4 frames back into c0: previous chunk, or zeros at the start)
        F = s.df_dec
        c, hd = s.df_gru(emb, [h_df[0:1], h_df[1:2]])
        if F.df_skip is not None: c = c + F.df_skip(emb)
        ctx = c0f[:, :, P - 4:P] * ctx_valid.view(1, 1, 1, 1)
        cp = F.df_convp(torch.cat([ctx, c0], 2))[:, :, 4:].permute(0, 2, 3, 1)
        coefs = F.df_out(c).view(b, t, F.df_bins, F.df_out_ch) + cp
        return mask, coefs, he[0], torch.cat(hr, 0), torch.cat(hd, 0)
