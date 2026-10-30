#!/usr/bin/env python3
import os, subprocess, tempfile
from PIL import Image, ImageDraw, ImageFilter, ImageChops, ImageEnhance
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASE_ICNS = os.path.join(ROOT, 'resources/icons/聊天组.icns')

def load_base():
    tmp = tempfile.mktemp(suffix='.png')
    subprocess.run(['sips', '-s', 'format', 'png', '--resampleHeightWidth', '1024', '1024', BASE_ICNS, '--out', tmp],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    im = Image.open(tmp).convert('RGB')
    os.unlink(tmp)
    return im

def remove_green_badge(im):
    arr = np.array(im).astype(np.int16)
    r, g, b = arr[...,0], arr[...,1], arr[...,2]
    mask = (g > r + 12) & (g > b + 12) & (g > 110)
    # 限定右上角区域，避免误伤角色
    yy, xx = np.mgrid[0:1024, 0:1024]
    mask &= (xx > 640) & (yy < 360)
    mask = np.array(Image.fromarray((mask*255).astype(np.uint8)).filter(ImageFilter.MaxFilter(9))) > 0
    out = np.array(im).astype(np.uint8).copy()
    # 按行左右最近有效像素线性插值
    for y in range(mask.shape[0]):
        row_mask = mask[y]
        if not row_mask.any():
            continue
        xs = np.where(~row_mask)[0]
        if len(xs) == 0:
            continue
        for x in np.where(row_mask)[0]:
            left = x
            while left > 0 and row_mask[left]:
                left -= 1
            right = x
            while right < 1023 and row_mask[right]:
                right += 1
            c1 = out[y, left].astype(np.float32)
            c2 = out[y, right].astype(np.float32)
            t = 0.5 if right == left else (x - left) / (right - left)
            out[y, x] = (c1 * (1 - t) + c2 * t).astype(np.uint8)
    res = Image.fromarray(out)
    # 轻微模糊修补区域并融合
    blur = res.filter(ImageFilter.GaussianBlur(6))
    m = Image.fromarray((mask*255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(5))
    return Image.composite(blur, res, m)

def rounded_mask(size, radius):
    m = Image.new('L', (size, size), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([0,0,size-1,size-1], radius=radius, fill=255)
    return m

def vgrad(size, top, bottom):
    arr = np.zeros((size,size,3), np.uint8)
    for y in range(size):
        t = y/(size-1)
        arr[y,:,:] = [int(top[i]*(1-t)+bottom[i]*t) for i in range(3)]
    return Image.fromarray(arr)

def make_icon(base, top=(214, 228, 255), bottom=(108, 132, 206)):
    S = 1024
    # 底板：蓝紫渐变
    bg = vgrad(S, top, bottom)
    # 液态色斑
    blobs = Image.new('RGB', (S,S), (0,0,0))
    bd = ImageDraw.Draw(blobs)
    bd.ellipse([-180, 120, 520, 820], fill=(90, 200, 255))
    bd.ellipse([520, -160, 1180, 460], fill=(170, 150, 255))
    bd.ellipse([420, 520, 1100, 1160], fill=(120, 255, 230))
    blobs = blobs.filter(ImageFilter.GaussianBlur(170))
    bg = ImageChops.screen(bg, blobs.point(lambda v: int(v*0.75)))
    # 液态玻璃内层
    glass = Image.new('RGBA', (S,S), (0,0,0,0))
    gd = ImageDraw.Draw(glass)
    gd.rounded_rectangle([34,34,S-35,S-35], radius=218, fill=(255,255,255,36),
                         outline=(255,255,255,120), width=3)
    gd.rounded_rectangle([62,62,S-63,S-63], radius=190, outline=(255,255,255,60), width=2)
    # 高光斜带
    streak = Image.new('RGBA', (S,S), (0,0,0,0))
    sd = ImageDraw.Draw(streak)
    sd.polygon([(40,380),(40,520),(620,40),(420,40)], fill=(255,255,255,46))
    sd.polygon([(300,984),(460,984),(984,470),(984,300)], fill=(255,255,255,26))
    streak = streak.filter(ImageFilter.GaussianBlur(26))
    glass = Image.alpha_composite(glass, streak)
    bg = Image.alpha_composite(bg.convert('RGBA'), glass)
    glow = Image.new('RGBA', (S,S), (0,0,0,0))
    gd2 = ImageDraw.Draw(glow)
    gd2.ellipse([96,110,S-96,S-70], fill=(120,200,255,90))
    glow = glow.filter(ImageFilter.GaussianBlur(95))
    bg = Image.alpha_composite(bg, glow)

    # 角色：圆形白盘
    disc_size = 820
    char = base.copy().resize((disc_size, disc_size), Image.LANCZOS)
    # 只取白色圆盘范围
    dm = Image.new('L', (disc_size, disc_size), 0)
    dd = ImageDraw.Draw(dm)
    inset = 70
    dd.ellipse([inset, inset, disc_size-inset, disc_size-inset], fill=255)
    dm = dm.filter(ImageFilter.GaussianBlur(3))
    # 角色增强：饱和/对比
    char = ImageEnhance.Color(char).enhance(1.10)
    char = ImageEnhance.Contrast(char).enhance(1.06)
    disc = char.convert('RGBA')
    disc.putalpha(dm)
    # 3D 阴影（对齐到圆盘位置）
    off = ((S-disc_size)//2, (S-disc_size)//2 + 18)
    shadow = Image.new('RGBA', (S,S), (0,0,0,0))
    sh = disc.split()[3].point(lambda a: int(a*0.34))
    shimg = Image.new('RGBA', (S,S), (0,0,0,0))
    shimg.paste((10,16,34,255), off, sh)
    shimg = shimg.filter(ImageFilter.GaussianBlur(26))
    shadow = ImageChops.offset(shimg, 0, 18)
    # 盘底暗部 + 顶部高光（3D）
    disc_rgba = disc.copy()
    px = disc_size
    shade = Image.new('RGBA', (px,px), (0,0,0,0))
    sdw = ImageDraw.Draw(shade)
    sdw.ellipse([inset, inset, px-inset, px-inset], fill=(6,10,24,0))
    # 底部渐变暗
    bot = Image.new('L', (px,px), 0)
    bd2 = ImageDraw.Draw(bot)
    for y in range(int(px*0.55), px):
        ratio = max(0.0, (y-px*0.55)/(px*0.45))
        a = int(46 * ratio**1.8)
        bd2.rectangle([0,y,px,y+1], fill=a)
    dark = Image.new('RGBA', (px,px), (5,10,28,255))
    dark.putalpha(bot)
    disc_rgba = Image.alpha_composite(disc_rgba, Image.composite(dark, Image.new('RGBA',(px,px),(0,0,0,0)), dm))
    # 球面暗角（增强 3D）
    px2 = disc_size
    yy, xx = np.mgrid[0:px2, 0:px2]
    cx, cy, rad = px2/2.0, px2/2.0, px2/2.0 - inset
    dist = np.sqrt((xx-cx)**2 + (yy-cy)**2) / rad
    v = np.clip((dist - 0.52) / 0.48, 0, 1) ** 1.7
    vig = Image.new('RGBA', (px2,px2), (7,12,30,255))
    vig.putalpha(Image.fromarray((v*120).astype(np.uint8)))
    disc_rgba = Image.alpha_composite(disc_rgba, Image.composite(vig, Image.new('RGBA',(px2,px2),(0,0,0,0)), dm))
    # 顶部玻璃反光
    gloss = Image.new('RGBA', (px,px), (0,0,0,0))
    gl = ImageDraw.Draw(gloss)
    gl.ellipse([inset+40, inset+10, px-inset-60, int(px*0.42)], fill=(255,255,255,96))
    gloss = gloss.filter(ImageFilter.GaussianBlur(28))
    gloss.putalpha(Image.composite(gloss.split()[3], Image.new('L',(px,px),0), dm))
    disc_rgba = Image.alpha_composite(disc_rgba, gloss)
    # 边缘高光
    rim = Image.new('RGBA', (px,px), (0,0,0,0))
    rd = ImageDraw.Draw(rim)
    rd.ellipse([inset, inset, px-inset, px-inset], outline=(255,255,255,200), width=7)
    rim = rim.filter(ImageFilter.GaussianBlur(1.6))
    disc_rgba = Image.alpha_composite(disc_rgba, rim)

    canvas = Image.new('RGBA', (S,S), (0,0,0,0))
    canvas = Image.alpha_composite(canvas, bg)
    # 放阴影与圆盘
    canvas = Image.alpha_composite(canvas, shadow)
    canvas.alpha_composite(disc_rgba, dest=off)

    # 外层圆角蒙版
    canvas.putalpha(ImageChops.multiply(canvas.split()[3], rounded_mask(S, 230)))
    return canvas

def main():
    base = remove_green_badge(load_base())
    icon = make_icon(base)
    iconset = tempfile.mkdtemp(suffix='.iconset')
    for sz in [16,32,64,128,256,512,1024]:
        icon.resize((sz,sz), Image.LANCZOS).save(os.path.join(iconset, f'icon_{sz}x{sz}.png'))
        if sz <= 512:
            icon.resize((sz*2,sz*2), Image.LANCZOS).save(os.path.join(iconset, f'icon_{sz}x{sz}@2x.png'))
    out = os.path.join(ROOT, 'resources/icons/控制台.icns')
    subprocess.run(['iconutil','-c','icns',iconset,'-o',out], check=True)
    preview = os.path.join(ROOT, 'resources/icons/控制台-preview.png')
    icon.resize((512,512), Image.LANCZOS).save(preview)
    icon.resize((44,44), Image.LANCZOS).save(os.path.join(ROOT, 'resources/icons/控制台-menubar.png'))
    print('wrote', out, preview)

if __name__ == '__main__':
    main()
