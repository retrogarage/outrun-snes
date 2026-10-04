"""S-DSP voice model for building instruments: BRR playback with the DSP's
gaussian interpolation, its frequency response (for pre-emphasis) and the
pre-emphasis filters themselves.

The gaussian table is the DSP's (fullsnes / blargg's SPC_DSP).  The response
of the interpolation depends only on f / R (R = the sample's playback rate),
so a sample stored for a given rate can be pre-compensated once for every
pitch it is played at."""
import numpy as np
import brr

_G = None


def gauss_table():
    """the DSP's 512-entry gaussian table (generated like the hardware ROM)"""
    global _G
    if _G is None:
        # values from the DSP ROM (symmetric half, 256 entries each side)
        _G = np.array(GAUSS, dtype=np.int64)
    return _G


def interp(x, pitch, n_out, start_pos=0):
    """play the 15-bit samples x (numpy int array, already looped / long
    enough) at `pitch` (4096 = 1.0) with gaussian interpolation; returns
    n_out float samples (15-bit scale)"""
    g = gauss_table()
    pos = start_pos + np.arange(n_out, dtype=np.int64) * pitch
    i = pos >> 12
    f = (pos >> 4) & 0xFF
    m = i + 3 < len(x)
    i = i[m]; f = f[m]
    s = np.asarray(x, dtype=np.int64)
    o = (g[255 - f] * s[i] >> 11) + (g[511 - f] * s[i + 1] >> 11) + (g[256 + f] * s[i + 2] >> 11)
    o = o + (g[f] * s[i + 3] >> 11)
    out = np.zeros(n_out)
    out[:len(o)] = o
    return out


_RESP = None


def response():
    """(nu, gain) of the gaussian interpolation for nu = f / R in 0..0.5"""
    global _RESP
    if _RESP is None:
        nus = np.linspace(0.0, 0.5, 51)
        gains = []
        n = 6000
        t = np.arange(n)
        for nu in nus:
            if nu == 0:
                gains.append(1.0)
                continue
            x = (12000 * np.sin(2 * np.pi * nu * t + 0.3)).astype(np.int64)
            y = interp(x, 3001, int((n - 8) * 4096 / 3001))[16:-16]
            gains.append(np.sqrt(2 * np.mean(y ** 2)) / 12000.0)
        _RESP = (nus, np.array(gains))
    return _RESP


def emphasis_gain(nu, cap_db=12.0):
    """inverse of the interpolation response at nu = f / R (capped)"""
    nus, gains = response()
    g = np.interp(np.minimum(np.abs(nu), 0.5), nus, gains)
    return np.minimum(1.0 / np.maximum(g, 1e-3), 10 ** (cap_db / 20.0))


def emphasize_periodic(y, cap_db=12.0):
    """pre-emphasis of one loop (periodic signal)"""
    n = len(y)
    Y = np.fft.rfft(y)
    nu = np.arange(len(Y)) / float(n)
    return np.fft.irfft(Y * emphasis_gain(nu, cap_db), n)


def emphasis_fir(taps=31, cap_db=12.0):
    """linear-phase FIR approximating the pre-emphasis (frequency sampling)"""
    nfft = 512
    nu = np.arange(nfft // 2 + 1) / float(nfft)
    h = np.fft.irfft(emphasis_gain(nu, cap_db), nfft)
    h = np.roll(h, taps // 2)[:taps] * np.hanning(taps + 2)[1:-1]
    return h


def emphasize(x, cap_db=12.0):
    """pre-emphasis of a one-shot sample (FIR, same length)"""
    h = emphasis_fir(cap_db=cap_db)
    return np.convolve(np.asarray(x, dtype=float), h, mode='same')


def brr_loop_samples(data, loop_off, n_needed):
    """decode BRR bytes (with its loop) into at least n_needed samples"""
    s = brr.decode(data)
    if loop_off is None:
        out = list(s)
        out += [0] * max(0, n_needed - len(out))
        return np.array(out[:max(n_needed, len(s))], dtype=np.int64)
    ls = loop_off // 9 * 16
    out = list(s)
    # the loop restarts the decoder with the previous samples of the loop end
    loop = brr.decode(data[loop_off:], s[-1], s[-2])
    while len(out) < n_needed:
        out += loop
    return np.array(out, dtype=np.int64)


# DSP gaussian table (512 entries)
GAUSS = [
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2,
    2, 2, 3, 3, 3, 3, 3, 4, 4, 4, 4, 4, 5, 5, 5, 5,
    6, 6, 6, 6, 7, 7, 7, 8, 8, 8, 9, 9, 9, 10, 10, 10,
    11, 11, 11, 12, 12, 13, 13, 14, 14, 15, 15, 15, 16, 16, 17, 17,
    18, 19, 19, 20, 20, 21, 21, 22, 23, 23, 24, 24, 25, 26, 27, 27,
    28, 29, 29, 30, 31, 32, 32, 33, 34, 35, 36, 36, 37, 38, 39, 40,
    41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56,
    58, 59, 60, 61, 62, 64, 65, 66, 67, 69, 70, 71, 73, 74, 76, 77,
    78, 80, 81, 83, 84, 86, 87, 89, 90, 92, 94, 95, 97, 99, 100, 102,
    104, 106, 107, 109, 111, 113, 115, 117, 118, 120, 122, 124, 126, 128, 130, 132,
    134, 137, 139, 141, 143, 145, 147, 150, 152, 154, 156, 159, 161, 163, 166, 168,
    171, 173, 175, 178, 180, 183, 186, 188, 191, 193, 196, 199, 201, 204, 207, 210,
    212, 215, 218, 221, 224, 227, 230, 233, 236, 239, 242, 245, 248, 251, 254, 257,
    260, 263, 267, 270, 273, 276, 280, 283, 286, 290, 293, 297, 300, 304, 307, 311,
    314, 318, 321, 325, 328, 332, 336, 339, 343, 347, 351, 354, 358, 362, 366, 370,
    374, 378, 381, 385, 389, 393, 397, 401, 405, 410, 414, 418, 422, 426, 430, 434,
    439, 443, 447, 451, 456, 460, 464, 469, 473, 477, 482, 486, 491, 495, 499, 504,
    508, 513, 517, 522, 527, 531, 536, 540, 545, 550, 554, 559, 563, 568, 573, 577,
    582, 587, 592, 596, 601, 606, 611, 615, 620, 625, 630, 635, 640, 644, 649, 654,
    659, 664, 669, 674, 678, 683, 688, 693, 698, 703, 708, 713, 718, 723, 728, 732,
    737, 742, 747, 752, 757, 762, 767, 772, 777, 782, 787, 792, 797, 802, 806, 811,
    816, 821, 826, 831, 836, 841, 846, 851, 855, 860, 865, 870, 875, 880, 884, 889,
    894, 899, 904, 908, 913, 918, 923, 927, 932, 937, 941, 946, 951, 955, 960, 965,
    969, 974, 978, 983, 988, 992, 997, 1001, 1005, 1010, 1014, 1019, 1023, 1027, 1032, 1036,
    1040, 1045, 1049, 1053, 1057, 1061, 1066, 1070, 1074, 1078, 1082, 1086, 1090, 1094, 1098, 1102,
    1106, 1109, 1113, 1117, 1121, 1125, 1128, 1132, 1136, 1139, 1143, 1146, 1150, 1153, 1157, 1160,
    1164, 1167, 1170, 1174, 1177, 1180, 1183, 1186, 1190, 1193, 1196, 1199, 1202, 1205, 1207, 1210,
    1213, 1216, 1219, 1221, 1224, 1227, 1229, 1232, 1234, 1237, 1239, 1241, 1244, 1246, 1248, 1251,
    1253, 1255, 1257, 1259, 1261, 1263, 1265, 1267, 1269, 1270, 1272, 1274, 1275, 1277, 1279, 1280,
    1282, 1283, 1284, 1286, 1287, 1288, 1290, 1291, 1292, 1293, 1294, 1295, 1296, 1297, 1297, 1298,
    1299, 1300, 1300, 1301, 1302, 1302, 1303, 1303, 1303, 1304, 1304, 1304, 1304, 1304, 1305, 1305,
]
