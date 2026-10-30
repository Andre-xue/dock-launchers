#!/usr/bin/env python3
import os, sys, subprocess, tempfile, shutil
from PIL import Image, ImageDraw, ImageFilter
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_console_icon as mc

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICON_DIR = os.path.join(ROOT, 'resources/icons')
ORIG_DIR = os.path.join(ICON_DIR, 'original')
EMOJI_FONT = '/System/Library/Fonts/Apple Color Emoji.ttc'

SPECS = [
    ('工作组', '工作', (255, 205, 150), (255, 120, 70), '💼'),
    ('聊天组', '聊天', (180, 255, 210), (80, 195, 255), '💬'),
    ('外网组', '外网', (150, 215, 255), (60, 110, 240), '🌐'),
    ('影音组', '影音', (255, 190, 220), (255, 85, 150), '🎬'),
    ('Ai组', 'Ai', (215, 190, 255), (125, 90, 235), '🧠'),
    ('Docker组', 'Docker', (150, 240, 255), (0, 160, 220), '🐳'),
    ('工具组', '工具', (225, 232, 242), (125, 140, 160), '🔧'),
]

def emoji_image(ch, size=150):
    f = None
    for s in (160, 137, 96, 64):
        try:
            f = __import__('PIL.ImageFont', fromlist=['truetype']).truetype(EMOJI_FONT, s)
            break
        except Exception:
            continue
    im = Image.new('RGBA', (size*2, size*2), (0,0,0,0))
    d = ImageDraw.Draw(im)
    d.text((size//2, size//2), ch, font=f, embedded_color=True)
    bb = im.getbbox()
    if bb:
        im = im.crop(bb)
    im.thumbnail((size, size), Image.LANCZOS)
    return im

def add_badge(icon, ch):
    S = icon.size[0]
    badge_r = 96
    cx, cy = S - 140, 140
    badge = Image.new('RGBA', (S,S), (0,0,0,0))
    d = ImageDraw.Draw(badge)
    # 阴影
    sh = Image.new('RGBA', (S,S), (0,0,0,0))
    ImageDraw.Draw(sh).ellipse([cx-badge_r+4, cy-badge_r+14, cx+badge_r+4, cy+badge_r+14], fill=(10,16,34,110))
    sh = sh.filter(ImageFilter.GaussianBlur(18))
    badge = Image.alpha_composite(badge, sh)
    d = ImageDraw.Draw(badge)
    d.ellipse([cx-badge_r, cy-badge_r, cx+badge_r, cy+badge_r], fill=(255,255,255,226), outline=(255,255,255,255), width=4)
    icon = Image.alpha_composite(icon, badge)
    em = emoji_image(ch, 150)
    icon.alpha_composite(em, dest=(cx - em.size[0]//2, cy - em.size[1]//2))
    return icon

def main():
    os.makedirs(ORIG_DIR, exist_ok=True)
    base = mc.remove_green_badge(mc.load_base())
    previews = []
    for icns, short, top, bottom, ch in SPECS:
        icon = mc.make_icon(base, top, bottom)
        icon = add_badge(icon, ch)
        dst = os.path.join(ICON_DIR, icns + '.icns')
        orig = os.path.join(ORIG_DIR, icns + '.icns')
        if os.path.exists(dst) and not os.path.exists(orig):
            shutil.copy2(dst, orig)
        iconset = tempfile.mkdtemp(suffix='.iconset')
        for sz in [16,32,64,128,256,512,1024]:
            icon.resize((sz,sz), Image.LANCZOS).save(os.path.join(iconset, f'icon_{sz}x{sz}.png'))
            if sz <= 512:
                icon.resize((sz*2,sz*2), Image.LANCZOS).save(os.path.join(iconset, f'icon_{sz}x{sz}@2x.png'))
        subprocess.run(['iconutil','-c','icns',iconset,'-o',dst], check=True)
        previews.append((short, icon.resize((256,256), Image.LANCZOS)))
        print('wrote', dst)
    # 拼预览图
    sheet = Image.new('RGBA', (256*len(previews), 300), (250,251,253,255))
    for i, (name, im) in enumerate(previews):
        sheet.alpha_composite(im, dest=(i*256, 20))
    sheet.save(os.path.join(ICON_DIR, '组图标预览.png'))
    print('preview written')

if __name__ == '__main__':
    main()
