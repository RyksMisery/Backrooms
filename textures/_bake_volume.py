#!/usr/bin/env python3
"""Запекает объём (микрорельеф ткани) прямо в albedo floor1.png.
Albedo-only, seamless (все фильтры периодические через FFT / np.roll),
чтобы не трогать normal/ARM и не ловить VK_ERROR_DEVICE_LOST.

Параметры подобраны мягко: ковёр остаётся плоским по силуэту,
но получает тактильную глубину нитей.
"""
import numpy as np
from PIL import Image

SRC = "floor1_orig.png"      # исходник (бэкап оригинала)
DST = "floor1.png"           # то, что грузит toggle T

# --- ручки объёма ---
LOCAL_CONTRAST = 1.0         # усиление высокочастотного плетения (1 = без изм.)
DETAIL_SIGMA   = 3.2         # радиус разделения база/детали, px (крупнее = меньше алиасинга)
FINE_KILL      = 0.0         # сглаживание самой мелкой частоты, px (гасит шиммер вдалеке)
AO_STRENGTH    = 0.0         # мягкое затемнение впадин (fake AO)
AO_SIGMA       = 7.0         # масштаб впадин для AO, px
LIGHT_STRENGTH = 0.0         # направленный микрорельеф (fake normal-bake)
LIGHT_DIR      = (-0.6, -0.8)# направление света в UV (нормируется)
HEIGHT_SIGMA   = 2.0         # сглаживание карты высот перед взятием градиента
KEEP_MEAN      = True        # сохранить средний тон (не темнить/светлить общий tint)

CLASSIC        = "floor.png" # классическая карта, к её цвету тянем
TINT_TOWARD    = 0.5         # 0 = цвет floor1, 1 = цвет floor.png; 0.5 = промежуточный


def srgb_to_lin(x):
    return np.where(x <= 0.04045, x / 12.92, ((x + 0.055) / 1.055) ** 2.4)

def lin_to_srgb(x):
    x = np.clip(x, 0.0, 1.0)
    return np.where(x <= 0.0031308, x * 12.92, 1.055 * x ** (1 / 2.4) - 0.055)


def gauss_periodic(img, sigma):
    """Периодическое гауссово размытие через FFT -> seamless."""
    if sigma <= 0:
        return img.copy()
    h, w = img.shape
    fy = np.fft.fftfreq(h)[:, None]
    fx = np.fft.fftfreq(w)[None, :]
    # гаусс в частотной области
    k = np.exp(-2.0 * (np.pi * sigma) ** 2 * (fx ** 2 + fy ** 2))
    return np.real(np.fft.ifft2(np.fft.fft2(img) * k))


def main():
    im = Image.open(SRC).convert("RGBA")
    arr = np.asarray(im).astype(np.float64) / 255.0
    rgb = arr[..., :3]
    alpha = arr[..., 3:4]

    lin = srgb_to_lin(rgb)
    lum = lin @ np.array([0.2126, 0.7152, 0.0722])

    # 1) локальный контраст плетения (детали относительно базы)
    base = gauss_periodic(lum, DETAIL_SIGMA)
    detail = lum - base
    lum_lc = base + detail * LOCAL_CONTRAST

    # 2) fake AO: затемняем то, что ниже локального среднего в среднем масштабе
    ao_base = gauss_periodic(lum_lc, AO_SIGMA)
    cavity = np.clip(ao_base - lum_lc, 0.0, None)   # >0 во впадинах
    cavity /= (cavity.std() + 1e-6)
    ao = 1.0 - AO_STRENGTH * np.clip(cavity * 0.5, 0.0, 1.0)

    # 3) направленный микрорельеф: свет по градиенту карты высот
    height = gauss_periodic(lum_lc, HEIGHT_SIGMA)
    gx = (np.roll(height, -1, axis=1) - np.roll(height, 1, axis=1)) * 0.5
    gy = (np.roll(height, -1, axis=0) - np.roll(height, 1, axis=0)) * 0.5
    ln = np.array(LIGHT_DIR, dtype=np.float64)
    ln /= (np.linalg.norm(ln) + 1e-9)
    relief = gx * ln[0] + gy * ln[1]
    relief /= (np.abs(relief).std() + 1e-6)
    light = 1.0 + LIGHT_STRENGTH * np.clip(relief * 0.4, -1.0, 1.0)

    shade = ao * light
    # band-limit добавленную тень: гасим субпиксельную частоту -> нет шиммера вдалеке
    shade = gauss_periodic(shade, FINE_KILL)
    shade = shade[..., None]

    out_lin = lin * shade

    # целевой средний тон: между floor1 и классикой (в linear)
    classic_lin = srgb_to_lin(np.asarray(
        Image.open(CLASSIC).convert("RGB")).astype(np.float64) / 255.0)
    for c in range(3):
        src_m = lin[..., c].mean()
        cls_m = classic_lin[..., c].mean()
        target = (1.0 - TINT_TOWARD) * src_m + TINT_TOWARD * cls_m
        cur = out_lin[..., c].mean()
        if cur > 1e-6:
            out_lin[..., c] *= (target / cur)

    out = lin_to_srgb(out_lin)
    out = np.concatenate([out, alpha], axis=-1)
    Image.fromarray((out * 255.0 + 0.5).astype(np.uint8), "RGBA").save(DST)
    print("saved", DST)


if __name__ == "__main__":
    main()
