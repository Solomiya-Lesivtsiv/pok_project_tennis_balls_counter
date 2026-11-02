"""
Перетворення запису тепловізора (режим 1280x512 YUYV з v4l2-ctl) у кадри PNG.

Формат кадру (визначено аналізом):
  кожен рядок = 2560 байт, дві половини по 1280 байт:
    одна половина -> 640 пікселів "сирих" 16-бітних даних (старший байт першим)
    інша половина -> 640 пікселів сірого зображення YUYV (яскравість Y, колір = 128)
  порядок половин буває різним, скрипт визначає його для кожного кадру сам.
  повний кадр = 640x512 сіре зображення + 640x512 сирі дані.

Запуск (у папці, де лежить запис):
    python convert_raw.py wide.raw                 # кожен кадр
    python convert_raw.py rec1.raw --every 5       # кожен 5-й кадр (для датасету)
    python convert_raw.py rec1.raw --every 5 --out rec1_frames
    python convert_raw.py rec1.raw --every 5 --flip 180   # якщо камера стоїть догори дриґом
    python convert_raw.py rec1.raw --skip 10 --no-raw     # пропустити перші 10 кадрів, без raw16

Результат (у папці --out, за замовчуванням <ім'я_файлу>_frames):
    y8/frame_00000.png      сіре 8-бітне зображення 640x512 (для датасету й розмітки)
    raw16/frame_00000.png   сирі 16-бітні дані 640x512 (16-бітний PNG, на майбутнє).
                            У звичайних переглядачах виглядають ЧОРНИМИ — це нормально:
                            значення ~250 з 65535. Для перегляду є preview.png.
    preview.png             перший кадр: зліва Y8, справа сирі дані з розтягнутим контрастом
"""

import argparse
import os

import cv2
import numpy as np

W_IMG, H_IMG = 640, 512                 # розмір справжнього зображення
ROW_BYTES = W_IMG * 2 * 2               # 2560 байт у рядку (два блоки по 1280)
FRAME_BYTES = ROW_BYTES * H_IMG         # 1 310 720 байт на кадр


def split_frame(frame):
    """
    Повертає (y8, raw16, uv, swapped).
    Камера інколи віддає кадр, де половини рядка поміняні місцями,
    тому половину із зображенням визначаємо автоматично: у неї всі байти кольору = 128.
    """
    rows = frame.reshape(H_IMG, ROW_BYTES)
    a = rows[:, :ROW_BYTES // 2]
    b = rows[:, ROW_BYTES // 2:]
    swapped = np.mean(a[:, 1::2] == 128) > np.mean(b[:, 1::2] == 128)
    yuv, raw = (a, b) if swapped else (b, a)
    raw16 = np.ascontiguousarray(raw).view(">u2").astype(np.uint16)
    y8 = np.ascontiguousarray(yuv[:, 0::2])
    uv = yuv[:, 1::2]
    return y8, raw16, uv, swapped


def orient(img, flip):
    if flip == "180":
        return cv2.rotate(img, cv2.ROTATE_180)
    if flip == "v":
        return cv2.flip(img, 0)
    if flip == "h":
        return cv2.flip(img, 1)
    return img


def stretch(img, lo=1.0, hi=99.0):
    img = img.astype(np.float32)
    a, b = np.percentile(img, lo), np.percentile(img, hi)
    if b <= a:
        b = a + 1.0
    return (np.clip((img - a) / (b - a), 0, 1) * 255).astype(np.uint8)


def main():
    ap = argparse.ArgumentParser(description="Запис тепловізора 1280x512 -> PNG-кадри")
    ap.add_argument("raw", help="файл запису з v4l2-ctl (режим width=1280,height=512)")
    ap.add_argument("--every", type=int, default=1, help="зберігати кожен N-й кадр (за замовч. 1)")
    ap.add_argument("--out", default=None, help="папка для результату")
    ap.add_argument("--skip", type=int, default=0,
                    help="пропустити перші N кадрів (на початку запису камера віддає старі кадри)")
    ap.add_argument("--no-raw", action="store_true", help="не зберігати raw16 (економія місця)")
    ap.add_argument("--flip", default="none", choices=["none", "180", "v", "h"],
                    help="поворот кадру: 180 = перевернути, v = дзеркально по вертикалі, "
                         "h = по горизонталі (за замовч. none)")
    args = ap.parse_args()

    data = np.fromfile(args.raw, dtype=np.uint8)
    n = data.size // FRAME_BYTES
    if n == 0:
        print(f"У файлі {data.size} байт — менше одного кадру ({FRAME_BYTES}). "
              f"Перевірте, що запис зроблено з width=1280,height=512.")
        return
    if data.size % FRAME_BYTES:
        print(f"Увага: зайві {data.size % FRAME_BYTES} байт у кінці — можливо, запис обірвався.")

    out = args.out or os.path.splitext(os.path.basename(args.raw))[0] + "_frames"
    os.makedirs(os.path.join(out, "y8"), exist_ok=True)
    if not args.no_raw:
        os.makedirs(os.path.join(out, "raw16"), exist_ok=True)

    # Перевірка формату на першому кадрі
    first = min(args.skip, n - 1)
    y8, raw16, uv, sw = split_frame(data[first * FRAME_BYTES:(first + 1) * FRAME_BYTES])
    y8, raw16 = orient(y8, args.flip), orient(raw16, args.flip)
    uv_ok = np.mean(uv == 128)
    print(f"Кадрів у файлі: {n}, пропускаю перші {first}, зберігаю кожен {args.every}-й -> {out}")
    print(f"Перевірка формату: байти кольору = 128 у {uv_ok * 100:.1f}% пікселів "
          f"(має бути ~100%)")
    print(f"  Y8:    min={y8.min()} max={y8.max()} mean={y8.mean():.1f}")
    print(f"  raw16: min={raw16.min()} max={raw16.max()} mean={raw16.mean():.1f}")
    if uv_ok < 0.95:
        print("  УВАГА: схоже, формат інший, ніж очікувалось. Скиньте цей вивід.")

    preview = np.hstack([y8, stretch(raw16)])
    cv2.imwrite(os.path.join(out, "preview.png"), preview)

    saved = swapped_count = 0
    for i in range(first, n, args.every):
        y8, raw16, _, sw = split_frame(data[i * FRAME_BYTES:(i + 1) * FRAME_BYTES])
        y8, raw16 = orient(y8, args.flip), orient(raw16, args.flip)
        swapped_count += int(sw)
        name = f"frame_{i:05d}.png"
        cv2.imwrite(os.path.join(out, "y8", name), y8)
        if not args.no_raw:
            cv2.imwrite(os.path.join(out, "raw16", name), raw16)
        saved += 1

    print(f"Готово: збережено {saved} кадрів "
          f"(з них {swapped_count} мали переставлені половини, виправлено автоматично).")
    print(f"Перший кадр для перевірки: {out}/preview.png")


if __name__ == "__main__":
    main()
