import itertools
import math
import sys

import numpy
import imageio
import fontconfig

from systemd.daemon import notify
from PIL import Image, ImageDraw, ImageFont

PREBUFFER = 10
WIDTH = 640
HEIGHT = 480
DURATION = 500
FONT_FAMILY = 'Inconsolata'
TEXT = sys.argv[1]

template = Image.new('RGB', (WIDTH, HEIGHT))

grad_start = [255, 0, 0]
grad_end = [0, 0, 255]

halfway = min(WIDTH, HEIGHT) / 4
midx, midy = WIDTH / 2, HEIGHT / 2

draw = ImageDraw.Draw(template)
fonts = fontconfig.query(family=FONT_FAMILY, lang='en')
ttf_fonts = [fonts[i].file for i in range(len(fonts))
             if fonts[i].fontformat == 'TrueType']
font = ImageFont.truetype(ttf_fonts[0], int(HEIGHT / 8))
fwidth, fheight = draw.textsize(TEXT, font=font)
draw.text((midx - fwidth / 2, midy - fheight / 2), TEXT, font=font,
          fill=(255, 255, 255))

indices = set()

for x in range(WIDTH):
    for y in range(HEIGHT):
        dist_center = math.sqrt((x - midx) ** 2 + (y - midy) ** 2)
        if halfway * 0.9 < dist_center < halfway * 1.1:
            indices.add((x, y))

image = numpy.array(template)

camvid = imageio.get_writer(
    '/dev/video0', format='FFMPEG', mode='I', fps=1,
    input_params=['-re'], output_params=['-f', 'v4l2'],
    pixelformat='yuv420p', codec='rawvideo'
)

try:
    for frame in itertools.cycle(range(DURATION)):
        for x, y in indices:
            angle = abs(math.atan2(y - midy, x - midx) / math.pi)
            angle = 1.0 - (angle + frame / DURATION) % 1.0

            red = grad_end[0] * angle + grad_start[0] * (1.0 - angle)
            green = grad_end[1] * angle + grad_start[1] * (1.0 - angle)
            blue = grad_end[2] * angle + grad_start[2] * (1.0 - angle)
            image[y, x] = (int(red), int(green), int(blue))

        camvid.append_data(image)

        if PREBUFFER is not None:
            PREBUFFER -= 1
            if PREBUFFER == 0:
                notify('READY=1', True)
                PREBUFFER = None
finally:
    camvid.close()
