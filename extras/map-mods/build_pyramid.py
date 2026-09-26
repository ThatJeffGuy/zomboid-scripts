"""Cut the site's Evolved map art into a B42 world-map image pyramid (zevolved.pyramid.zip).
Format (from the game's own media/maps/Muldraugh, KY/pyramid.zip + zombie.worldMap.ImagePyramid):
  pyramid.txt: VERSION=1 / bounds=<minX minY maxX maxY in squares> / imageSize=<w h in px>
  <z>/tile<col>x<row>.png  256x256 tiles, level z = image scaled by 1/2^z, until one tile remains.
The site frame maps pixel (X,Y) at S=3 to world (321 + X*11.67/3, 384 + Y*11.67/3)."""
import io, math, sys, zipfile
from PIL import Image
SRC, OUT, MODE = sys.argv[1], sys.argv[2], (sys.argv[3] if len(sys.argv) > 3 else 'rgb')
OX, OY, TPP, S = 321, 384, 11.67, 3
im = Image.open(SRC).convert('RGBA'); W, H = im.size
minx, miny = OX, OY
maxx = OX + round(W * TPP / S); maxy = OY + round(H * TPP / S)
T = 256
def enc(tile):
    b = io.BytesIO()
    if MODE == 'pal':
        rgb = tile.convert('RGB').quantize(256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.FLOYDSTEINBERG)
        a = tile.getchannel('A')
        if a.getextrema()[0] < 255:          # partial edge tile: keep transparency
            rgb = tile.quantize(256, method=Image.Quantize.FASTOCTREE)
        rgb.save(b, 'PNG', optimize=True)
    else:
        tile.save(b, 'PNG', optimize=True)
    return b.getvalue()
n = 0
with zipfile.ZipFile(OUT, 'w', zipfile.ZIP_STORED) as z:
    z.writestr('pyramid.txt', f'VERSION=1\nbounds={minx} {miny} {maxx} {maxy}\nimageSize={W} {H}')
    lvl, zlev = im, 0
    while True:
        cols, rows = math.ceil(lvl.width / T), math.ceil(lvl.height / T)
        for c in range(cols):
            for r in range(rows):
                tile = Image.new('RGBA', (T, T), (0, 0, 0, 0))
                tile.paste(lvl.crop((c*T, r*T, min((c+1)*T, lvl.width), min((r+1)*T, lvl.height))), (0, 0))
                z.writestr(f'{zlev}/tile{c}x{r}.png', enc(tile)); n += 1
        if cols == 1 and rows == 1: break
        zlev += 1
        lvl = im.resize((max(1, W >> zlev), max(1, H >> zlev)), Image.LANCZOS)
print(f'{OUT}: bounds {minx} {miny} {maxx} {maxy}, image {W}x{H}, levels 0-{zlev}, {n} tiles')
