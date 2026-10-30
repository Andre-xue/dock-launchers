#!/usr/bin/env python3
from PIL import Image, ImageDraw, ImageFilter, ImageFont
import numpy as np, sys
S = 2048
out = sys.argv[1] if len(sys.argv) > 1 else '/tmp/DL_icon.png'

shape = Image.new('L', (S, S), 0)
ImageDraw.Draw(shape).rounded_rectangle([0, 0, S-1, S-1], radius=int(S*0.225), fill=255)

# frosted glass base
base = Image.new('RGBA', (S, S), (214, 226, 239, 218))
rng = np.random.default_rng(7)
noise = (rng.normal(0, 6, (S//4, S//4))).astype(np.float32)
noise = Image.fromarray(((noise + 128).clip(0, 255)).astype(np.uint8), 'L').resize((S, S), Image.BILINEAR)
n = np.array(noise, dtype=np.int16); b = np.array(base, dtype=np.int16)
for c in range(3):
    b[:, :, c] = np.clip(b[:, :, c] + (n - 128), 0, 255)
base = Image.fromarray(b.astype(np.uint8), 'RGBA')
gloss = Image.new('RGBA', (S, S), (0, 0, 0, 0))
ImageDraw.Draw(gloss).ellipse([-S*0.3, -S*0.55, S*1.3, S*0.52], fill=(255, 255, 255, 55))
base.alpha_composite(gloss.filter(ImageFilter.GaussianBlur(S*0.06)))
IMG = Image.new('RGBA', (S, S), (0, 0, 0, 0))
IMG.paste(base, (0, 0), shape)

# vivid rainbow, moved down and inset from edges
rainbow = [(255, 45, 85), (255, 140, 0), (255, 214, 10), (48, 209, 88),
           (0, 205, 200), (10, 132, 255), (94, 92, 230), (191, 90, 242)]
arc = Image.new('RGBA', (S, S), (0, 0, 0, 0))
ad = ImageDraw.Draw(arc)
box = [S*0.18, S*0.085, S*0.82, S*0.245]
w = int(S*0.018)
for i, c in enumerate(rainbow):
    pad = i * w * 0.55
    ad.arc([box[0]-pad, box[1]-pad, box[2]+pad, box[3]+pad], 202, 338, fill=c+(235,), width=w)
IMG.alpha_composite(arc.filter(ImageFilter.GaussianBlur(S*0.0015)))

cx, cy = S*0.5, S*0.47
R = S*0.265
sh = Image.new('RGBA', (S, S), (0, 0, 0, 0))
ImageDraw.Draw(sh).ellipse([cx-R, cy-R+S*0.03, cx+R, cy+R+S*0.035], fill=(30, 50, 80, 100))
IMG.alpha_composite(sh.filter(ImageFilter.GaussianBlur(S*0.025)))

glass = Image.new('RGBA', (S, S), (0, 0, 0, 0))
gld = ImageDraw.Draw(glass)
gld.ellipse([cx-R, cy-R, cx+R, cy+R], fill=(255, 255, 255, 40), outline=(255, 255, 255, 145), width=int(S*0.006))
gl2 = Image.new('RGBA', (S, S), (0, 0, 0, 0))
ImageDraw.Draw(gl2).ellipse([cx-R*0.9, cy-R*1.02, cx+R*0.9, cy+R*0.15], fill=(255, 255, 255, 52))
gl2 = gl2.filter(ImageFilter.GaussianBlur(S*0.02))
clip = Image.new('L', (S, S), 0)
ImageDraw.Draw(clip).ellipse([cx-R, cy-R, cx+R, cy+R], fill=255)
glass.alpha_composite(Image.composite(gl2, Image.new('RGBA', (S, S), (0, 0, 0, 0)), clip))
IMG.alpha_composite(glass)

# DL rainbow text
font = ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial Bold.ttf', int(S*0.305))
txt = 'DL'
dummy = ImageDraw.Draw(Image.new('RGBA', (1, 1)))
bbox = dummy.textbbox((0, 0), txt, font=font)
tw = bbox[2] - bbox[0]; th = bbox[3] - bbox[1]
tx = int(cx - tw/2 - bbox[0]); ty = int(cy - th/2 - bbox[1])
gf = Image.new('RGBA', (S, S), (0, 0, 0, 0)); gd = ImageDraw.Draw(gf)
cs = np.array(rainbow, float)
for x in range(S):
    f = min(1, max(0, (x - tx) / max(1, tw))) * (len(rainbow) - 1)
    i0 = int(np.floor(f)); i1 = min(i0 + 1, len(rainbow) - 1); fr = f - i0
    c = tuple((cs[i0]*(1-fr) + cs[i1]*fr).astype(int))
    gd.line([(x, 0), (x, S)], fill=c+(255,))
mask = Image.new('L', (S, S), 0)
ImageDraw.Draw(mask).text((tx, ty), txt, font=font, fill=255)
shadow = Image.new('RGBA', (S, S), (0, 0, 0, 0))
ImageDraw.Draw(shadow).text((tx+int(S*0.004), ty+int(S*0.006)), txt, font=font, fill=(20, 35, 60, 80))
IMG.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(S*0.006)))
outline = Image.new('RGBA', (S, S), (0, 0, 0, 0))
ImageDraw.Draw(outline).text((tx, ty), txt, font=font, fill=(255, 255, 255, 120),
                             stroke_width=int(S*0.003), stroke_fill=(255, 255, 255, 120))
IMG.alpha_composite(Image.composite(outline, Image.new('RGBA', (S, S), (0, 0, 0, 0)), clip))
tm = Image.composite(gf, Image.new('RGBA', (S, S), (0, 0, 0, 0)), mask)
tm = Image.composite(tm, Image.new('RGBA', (S, S), (0, 0, 0, 0)), clip)
IMG.alpha_composite(tm)

rim = Image.new('RGBA', (S, S), (0, 0, 0, 0))
ImageDraw.Draw(rim).ellipse([cx-R+S*0.003, cy-R+S*0.003, cx+R-S*0.003, cy+R-S*0.003],
                            outline=(255, 255, 255, 95), width=int(S*0.003))
IMG.alpha_composite(rim.filter(ImageFilter.GaussianBlur(S*0.002)))

# dock dots
sx0, sx1 = S*0.25, S*0.75
sy0, sy1 = S*0.79, S*0.875
shelf = Image.new('RGBA', (S, S), (0, 0, 0, 0))
sdd = ImageDraw.Draw(shelf)
sdd.rounded_rectangle([sx0, sy0, sx1, sy1], radius=int((sy1-sy0)/2), fill=(255, 255, 255, 80),
                      outline=(255, 255, 255, 150), width=int(S*0.004))
dots = [(255, 59, 48), (255, 204, 0), (52, 199, 89), (0, 122, 255), (175, 82, 222)]
w = (sx1-sx0)/len(dots)
for i, c in enumerate(dots):
    ccx = sx0 + w*(i + 0.5); ccy = (sy0+sy1)/2; rr = (sy1-sy0)*0.27
    sdd.ellipse([ccx-rr, ccy-rr, ccx+rr, ccy+rr], fill=c+(255,))
IMG.alpha_composite(shelf)

rim2 = Image.new('RGBA', (S, S), (0, 0, 0, 0))
ImageDraw.Draw(rim2).rounded_rectangle([S*0.006, S*0.006, S*0.994, S*0.994], radius=int(S*0.223),
                                       outline=(255, 255, 255, 120), width=int(S*0.007))
IMG.alpha_composite(rim2.filter(ImageFilter.GaussianBlur(S*0.0025)))
IMG = IMG.resize((1024, 1024), Image.LANCZOS)
IMG.save(out)
print('icon saved', out)
