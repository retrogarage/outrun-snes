"""Python reference model of the OutRun road generator (sub CPU program).

Faithful port of the logic (as reverse engineered in Cannonball's oroad.cpp)
so the SNES implementation can be validated against it. Integer widths are
emulated with helpers where the original relies on 16/32-bit wraparound.
"""
from orroms import Roms

def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v

def u16(v):
    return v & 0xFFFF

def s32(v):
    v &= 0xFFFFFFFF
    return v - 0x100000000 if v & 0x80000000 else v

def cdiv(a, b):
    """C-style truncating division."""
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b >= 0) else -q

def isqrt(n):
    import math
    return math.isqrt(n) if n > 0 else 0

# ROM addresses (US Rev B)
ROAD_DATA_LOOKUP = 0x1224      # rom1: stage path pointers
ROAD_HEIGHT_LOOKUP = 0x220A    # rom1: height segment pointers
ROAD_DATA_SPLIT = 0x3A33E
ROAD_DATA_BONUS = 0x3ACA0
ROAD_BGCOLOR = 0x109EE
ROAD_SEG_TABLE = 0xE528        # rom0: per-stage level data
ROAD_SEG_TABLE_END = 0xE514
ROAD_SEG_TABLE_SPLIT = 0x1DFA4
SPRITE_MASTER_TABLE = 0x1A43C
PAL_SKY_TABLE = 0x17590
PAL_GND_TABLE = 0x17350

STAGE_MAPPING_USA = [
    0x3C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x1E, 0x3B, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x20, 0x2F, 0x2A, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x2D, 0x35, 0x33, 0x21, 0x00, 0x00, 0x00, 0x00,
    0x32, 0x23, 0x38, 0x22, 0x26, 0x00, 0x00, 0x00,
]
STAGE_ORDER = [0, 0x8, 0x9, 0x10, 0x11, 0x12, 0x18, 0x19, 0x1A, 0x1B, 0x20, 0x21, 0x22, 0x23, 0x24]


class Level:
    pass


class Track:
    def __init__(self, R: Roms):
        self.R = R
        self.levels = []
        for i in range(15):
            off = STAGE_MAPPING_USA[STAGE_ORDER[i]] << 2
            stage_adr = R.r32(R.rom0, ROAD_SEG_TABLE + off)
            L = self._setup_level(stage_adr)
            L.path = R.r32(R.rom1, ROAD_DATA_LOOKUP + off)
            L.stage_id = STAGE_ORDER[i]
            L.internal = STAGE_MAPPING_USA[STAGE_ORDER[i]]
            self.levels.append(L)
        self.split = self._setup_section(ROAD_SEG_TABLE_SPLIT)
        self.split.path = ROAD_DATA_SPLIT
        self.ends = []
        for i in range(5):
            a = R.r32(R.rom0, ROAD_SEG_TABLE_END + i * 4)
            L = self._setup_section(a)
            L.path = ROAD_DATA_BONUS
            self.ends.append(L)

    def _setup_level(self, a):
        R = self.R
        L = Level()
        L.pal_sky = R.r16(R.rom0, R.r32(R.rom0, a + 0))
        ad = R.r32(R.rom0, a + 4)
        L.stripe_centre = (R.r32(R.rom0, ad), R.r32(R.rom0, ad + 4))
        ad = R.r32(R.rom0, a + 8)
        L.stripe = (R.r32(R.rom0, ad), R.r32(R.rom0, ad + 4))
        ad = R.r32(R.rom0, a + 12)
        L.side = (R.r32(R.rom0, ad), R.r32(R.rom0, ad + 4))
        ad = R.r32(R.rom0, a + 16)
        L.road = (R.r32(R.rom0, ad), R.r32(R.rom0, ad + 4))
        L.pal_gnd = R.r16(R.rom0, R.r32(R.rom0, a + 20))
        L.curve = R.r32(R.rom0, a + 24)
        L.width_height = R.r32(R.rom0, a + 28)
        L.scenery = R.r32(R.rom0, a + 32)
        return L

    def _setup_section(self, a):
        R = self.R
        L = Level()
        L.curve = R.r32(R.rom0, a + 0)
        L.width_height = R.r32(R.rom0, a + 4)
        L.scenery = R.r32(R.rom0, a + 8)
        return L

    def stage_offset_to_level(self, sid):
        return [0, 1, 3, 6, 10][sid // 8] + (sid & 7)


class Road:
    ROAD_OFF, ROAD_R0, ROAD_R1, ROAD_BOTH_P0, ROAD_BOTH_P1, ROAD_BOTH_P0_INV, ROAD_BOTH_P1_INV, ROAD_R0_SPLIT, ROAD_R1_SPLIT = range(9)

    def __init__(self, R: Roms, T: Track):
        self.R = R
        self.T = T
        self.road_pos = 0
        self.road_pos_old = 0
        self.road_pos_change = 0
        self.pos_fine = 0
        self.pos_fine_old = 0
        self.pos_fine_diff = 0
        self.road_ctrl = self.ROAD_BOTH_P0
        self.road_width = 0
        self.road_width_bak = 0
        self.car_x_bak = 0
        self.camera_x_off = 0
        self.horizon_base = 0
        self.horizon_set = 0
        self.horizon_offset = 0
        self.horizon_y2 = 0
        self.tilemap_h_target = 0
        self.height_lookup = 0
        self.height_lookup_wrk = 0
        self.height_ctrl = 0
        self.height_ctrl2 = 0
        self.height_start = 0
        self.height_end = 0
        self.height_index = 0
        self.height_inc = 0
        self.height_step = 0
        self.height_addr = 0
        self.height_final = 0
        self.height_delay = 0
        self.step_adjust = 0
        self.do_height_inc = 0
        self.elevation = 0
        self.up_mult = 0
        self.down_mult = 0
        self.horizon_mod = 0
        self.road_x = [0] * 0x200
        self.road0_h = [0] * 0x200
        self.road1_h = [0] * 0x200
        self.road_unk = [0] * 0x200
        self.road_y = [0] * 0x1000
        self.road_p0 = 0
        self.road_p1 = 0x400
        self.road_p2 = 0x800
        self.road_p3 = 0xC00
        self.path = T.levels[0].path
        # hardware road ram (road0 lines, road1 lines) as output by blit
        self.hw_lines = [0x800] * 224
        self.section_lengths = [0] * 7

    # ---------------- path reading ----------------
    def readPath(self, a):
        return self.R.s16(self.R.rom1, self.path + a)

    def hread16(self, a):
        return self.R.s16(self.R.rom1, a)

    def hread8(self, a):
        return self.R.rom1[a]

    def heightmap_entry(self, n):
        return self.R.r32(self.R.rom1, ROAD_HEIGHT_LOOKUP + n * 4)

    # ---------------- main ----------------
    def tick(self):
        self.rotate_values()
        self.setup_road_x()
        self.setup_road_y()
        self.set_road_y()
        self.set_horizon_y()
        self.do_road_data()
        self.blit_roads()

    def rotate_values(self):
        p0 = self.road_p0
        self.road_p0 = self.road_p1
        self.road_p1 = self.road_p2
        self.road_p2 = self.road_p3
        self.road_p3 = p0
        self.road_pos_change = (self.road_pos >> 16) - self.road_pos_old
        self.road_pos_old = self.road_pos >> 16

    def setup_road_x(self):
        if self.road_pos_change != 0:
            addr = (self.road_pos >> 16) << 2
            self.set_tilemap_x(addr)
            self.setup_x_data(addr)
        self.setup_hscroll()

    def setup_x_data(self, addr):
        rp = self.readPath
        x = s16(rp(addr) + rp(addr + 4))
        y = s16(rp(addr + 2) + rp(addr + 6))
        distance = u16(isqrt(x * x + y * y))
        curve_x_dist = s16(cdiv(x << 14, distance))
        curve_y_dist = s16(cdiv(y << 14, distance))
        for i in range(0x80):
            self.road_x[i] = 0x3210
        curve_x_total = 0
        curve_y_total = 0
        curve_start = 0
        curve_inc_old = 0
        scanline = 0x37E // 2
        for i in range(0x21):
            x_next = rp(addr) + rp(addr + 4)
            y_next = rp(addr + 2) + rp(addr + 6)
            addr += 8
            curve_x_total += x_next
            curve_y_total += y_next
            curve_inc, curve_end = self.create_curve(curve_x_total, curve_y_total, curve_x_dist, curve_y_dist)
            curve_steps = s16(curve_end - curve_start)
            if curve_steps < 0:
                return
            if curve_steps == 0:
                continue
            xinc = cdiv(curve_inc - curve_inc_old, curve_steps)
            xx = curve_inc_old
            pos = curve_start
            while pos <= curve_end:
                xx = s16(xx + xinc)
                if xx < -0x3200 or xx > 0x3200:
                    return
                self.road_x[scanline] = xx
                scanline -= 1
                if scanline < 0:
                    return
                pos += 1
            curve_inc_old = curve_inc
            curve_start = curve_end

    def create_curve(self, cxt, cyt, cxd, cyd):
        d0 = ((cxt >> 5) * cyd) - ((cyt >> 5) * cxd)
        d2 = ((cxt >> 5) * cxd) + ((cyt >> 5) * cyd)
        d0 = s32(d0)
        d2 = s32(d2) >> 7
        d1 = (d2 >> 7) + 0x410
        curve_inc = s16(cdiv(d0, d1))
        curve_end = s16(cdiv(d2, d1) * 4)
        return curve_inc, curve_end

    def set_tilemap_x(self, addr):
        rp = self.readPath
        x = s16(rp(addr) + rp(addr + 4) + rp(addr + 8) + rp(addr + 12))
        y = s16(rp(addr + 2) + rp(addr + 6) + rp(addr + 10) + rp(addr + 14))
        xa, ya = abs(x), abs(y)
        if ya > xa:
            scroll_x = cdiv(0x100 * x, y)
        else:
            scroll_x = cdiv(-0x100 * y, x) if x != 0 else 0
        if x > 0:
            scroll_x += 0x200
        elif x < 0:
            scroll_x += 0x600
        elif y >= 0:
            scroll_x += 0x200
        else:
            scroll_x += 0x600
        if ya > xa:
            if x * y >= 0:
                scroll_x -= 0x200
            else:
                scroll_x += 0x200
        self.tilemap_h_target = s16(scroll_x)

    def setup_hscroll(self):
        rc = self.road_ctrl
        if rc == self.ROAD_OFF:
            return
        if rc in (self.ROAD_R0, self.ROAD_R0_SPLIT):
            self.do_road_offset(self.road0_h, -self.road_width_bak, False)
        elif rc == self.ROAD_R1:
            self.do_road_offset(self.road1_h, self.road_width_bak, False)
        elif rc in (self.ROAD_BOTH_P0, self.ROAD_BOTH_P1):
            self.do_road_offset(self.road0_h, -self.road_width_bak, False)
            self.do_road_offset(self.road1_h, self.road_width_bak, False)
        elif rc in (self.ROAD_BOTH_P0_INV, self.ROAD_BOTH_P1_INV):
            self.do_road_offset(self.road0_h, -self.road_width_bak, False)
            self.do_road_offset(self.road1_h, self.road_width_bak, True)
        elif rc == self.ROAD_R1_SPLIT:
            self.do_road_offset(self.road1_h, self.road_width_bak, True)

    def do_road_offset(self, dst, width, invert):
        car_offset = self.car_x_bak + width + self.camera_x_off
        src = self.road_x
        if car_offset != 0:
            car_offset = s32(car_offset << 7)
            scanline_inc = 0
            for i in range(0x200):
                h = s16(scanline_inc >> 16)
                if src[i] == 0x3210:
                    h = 0
                x_off = s16(src[i]) >> 6
                h = h - x_off if invert else h + x_off
                dst[i] = s16(h)
                scanline_inc = s32(scanline_inc + car_offset)
            return
        for i in range(0x200):
            v = s16(src[i])
            dst[i] = s16((-v) >> 6) if invert else (v >> 6)

    # ---------------- heights ----------------
    def setup_road_y(self):
        self.pos_fine_diff = s16(self.pos_fine - self.pos_fine_old)
        self.pos_fine_old = self.pos_fine
        if not self.horizon_set:
            self.horizon_base = 0x240
            self.horizon_set = 1
        hc = self.height_ctrl
        if hc == 0:
            self.height_lookup = 0
            self.init_height_seg()
        elif hc == 1:
            self.init_height_seg()
        elif hc == 2:
            self.do_elevation()
        elif hc == 3:
            self.do_elevation_delay()
        elif hc == 4:
            self.do_elevation_mixed()
        elif hc == 5:
            self.do_horizon_adjust()

    def init_height_seg(self):
        self.height_index = 0
        self.height_inc = 0
        self.elevation = 0
        self.height_step = 1
        self.height_lookup_wrk = self.height_lookup
        h = self.heightmap_entry(self.height_lookup_wrk)
        self.height_ctrl2 = self.hread8(h); h += 1
        self.step_adjust = self.hread8(h); h += 1
        c = self.height_ctrl2
        if c == 0:
            self.down_mult = self.R.s8(self.R.rom1, h); h += 1
            self.up_mult = self.R.s8(self.R.rom1, h); h += 1
            self.height_addr = h
            self.height_ctrl = 2
            self.do_elevation()
        elif c in (1, 2):
            self.height_delay = self.hread16(h); h += 2
            self.height_addr = h
            self.do_height_inc = 1
            self.height_inc = 0
            self.height_end = 0x100
            self.height_ctrl = 3
            self.do_elevation_delay()
        elif c == 3:
            self.height_delay = self.hread16(h); h += 2
            self.height_addr = h
            self.do_height_inc = 1
            self.height_inc = 0
            self.height_ctrl = 4
            self.do_elevation_mixed()
        elif c == 4:
            self.height_addr = h
            self.horizon_mod = self.hread16(h) - self.horizon_base
            self.height_ctrl = 5
            self.do_horizon_adjust()

    def do_elevation(self):
        self.height_step = u16(self.height_step + self.pos_fine_diff * 12)
        d3 = self.step_adjust
        if self.elevation == 1:
            d3 = u16(d3 * self.up_mult)
        elif self.elevation == -1:
            d3 = u16(d3 * self.down_mult)
        d1 = self.height_step // d3 if d3 else 0xFF
        if d1 > 0xFF:
            d1 = 0xFF
        d1 += 0x100
        self.height_start = d1
        self.height_end = d1
        self.height_index += self.height_inc
        self.height_inc = 0
        if self.height_start == 0x1FF:
            self.height_step = 1
            self.height_inc = 1
            self.elevation = 0
            return
        if self.height_lookup == 0 or self.height_lookup_wrk != 0:
            return
        self.height_ctrl = 1

    def do_elevation_delay(self):
        d1 = s16(self.pos_fine_diff * 12)
        self.height_index += self.height_inc
        self.height_inc = 0
        if self.height_index == 0 or self.do_height_inc == 0:
            self.height_step = u16(self.height_step + d1)
            d1 = self.height_step // self.step_adjust
            if d1 > 0xFF:
                d1 = 0xFF
            self.height_start = d1
            if self.height_start > 0xFE:
                self.height_start = 0xFF
                self.height_step = 1
                self.height_inc = 1
                self.elevation = 0
            if self.height_index != 0:
                d1 = 0xFF - self.height_start
            self.height_start = d1 + 0x100
        else:
            self.height_delay = s16(self.height_delay - cdiv(d1, self.step_adjust))
            self.height_start = 0x1FF
            if self.height_delay < 0:
                self.do_height_inc = 0

    def do_elevation_mixed(self):
        d1 = u16(self.pos_fine_diff * 12)
        self.height_index += self.height_inc
        self.height_inc = 0
        if self.height_index >= 6:
            d3 = self.step_adjust
            if self.do_height_inc != 0:
                self.height_delay = s16(self.height_delay - d1 // d3)
                self.height_start = 0x1FF
                self.height_end = 0x100
                if self.height_delay < 0:
                    self.height_addr += 12
                    self.do_height_inc = 0
            else:
                self.height_step = u16(self.height_step + d1)
                d1 = self.height_step // d3
                if d1 > 0xFF:
                    d1 = 0xFF
                self.height_start = 0x1FF - d1
                if self.height_start != 0x100:
                    return
                self.height_step = 1
                self.height_inc = 1
                self.elevation = 0
        else:
            self.height_step = u16(self.height_step + d1)
            d1 = self.height_step // 4
            if d1 > 0xFF:
                d1 = 0xFF
            d1 += 0x100
            self.height_start = d1
            self.height_end = d1
            if self.height_start < 0x1FF:
                return
            self.height_start = 0x1FF
            self.height_end = 0x1FF
            self.height_step = 1
            self.height_inc = 1
            self.elevation = 0

    def do_horizon_adjust(self):
        self.height_step = u16(self.height_step + self.pos_fine_diff * 12)
        d1 = self.height_step // self.step_adjust
        if d1 > 0xFF:
            d1 = 0xFF
        d1 += 0x100
        self.height_start = d1
        self.height_end = d1

    def set_road_y(self):
        if self.height_ctrl2 in (0, 1, 2, 3):
            self.set_y_interpolate()
        elif self.height_ctrl2 == 4:
            self.set_y_horizon()

    def set_y_interpolate(self):
        sl = self.section_lengths
        d2 = self.height_end
        d1 = 0x1FF - d2
        sl[0] = d1
        d2 >>= 1
        sl[1] = d2
        d3 = 0x200 - d1 - d2
        sl[3] = d3
        d3 >>= 1
        sl[2] = d3
        sl[3] -= d3
        d3 = sl[3]; sl[4] = d3; d3 >>= 1; sl[3] = d3; sl[4] -= d3
        d3 = sl[4]; sl[5] = d3; d3 >>= 1; sl[4] = d3; sl[5] -= d3
        d3 = sl[5]; sl[6] = d3; d3 >>= 1; sl[5] = d3; sl[6] -= d3
        self.length_offset = 0
        self.a1_lookup = self.height_index * 2 + self.height_addr
        self.y_addr = 0x200 + self.road_p1
        self.a3_o = 0
        self.road_unk[self.a3_o] = 0x1FF; self.a3_o += 1
        self.road_unk[self.a3_o] = 0; self.a3_o += 1
        self.counter = 0
        nh = self.hread16(self.a1_lookup)
        self.height_final = (nh * (self.height_start - 0x100)) >> 4
        horizon_copy = (self.horizon_base + self.horizon_offset) << 4
        if self.height_ctrl2 == 2:
            horizon_copy += self.height_final
        self.change_per_entry = horizon_copy
        self.scanline = 0x200
        self.total_height = 0
        self.set_y_2044()

    def set_y_2044(self):
        # iterative version of the recursive original
        while True:
            if self.change_per_entry > 0x10000:
                self.change_per_entry = 0x10000
            self.d5_o = self.change_per_entry
            section_length = s16(self.section_lengths[self.length_offset] - 1)
            self.length_offset += 1
            self.scanline -= section_length
            if section_length >= 0:
                for i in range(section_length + 1):
                    self.total_height = s32(self.total_height + self.change_per_entry)
                    self.y_addr -= 1
                    self.road_y[self.y_addr] = s16((s32(self.total_height << 4)) >> 16)
            self.counter += 1
            if self.counter != 7:
                # read_next_height -> set_elevation -> loops back to set_y_2044
                self.read_next_height()
                continue
            self.road_unk[self.a3_o] = 0
            y = self.hread16(self.a1_lookup)
            if y != -1:
                return
            if self.height_lookup == self.height_lookup_wrk:
                self.height_lookup = 0
            self.height_ctrl = 1
            return

    def read_next_height(self):
        c = self.height_ctrl2
        if c == 1:
            self.change_per_entry += self.height_final
            self.set_elevation()
            return
        if c == 2:
            self.set_elevation()
            return
        if c == 3 and self.height_index >= 6:
            self.change_per_entry += self.height_final
            self.set_elevation()
            return
        self.change_per_entry = (self.hread16(self.a1_lookup) << 4)
        self.a1_lookup += 2
        self.change_per_entry += self.d5_o
        if self.counter != 1:
            self.set_elevation()
            return
        self.change_per_entry -= self.height_final
        horizon_shift = (self.horizon_base + self.horizon_offset) << 4
        if horizon_shift == self.change_per_entry:
            pass
        elif self.change_per_entry > horizon_shift:
            self.elevation = 1
        else:
            self.elevation = -1
        self.set_elevation()

    def set_elevation(self):
        self.d5_o -= self.change_per_entry
        if self.d5_o == 0:
            return
        if self.d5_o < 0:
            self.d5_o = -self.d5_o
        self.road_unk[self.a3_o] = self.scanline; self.a3_o += 1
        th = abs(self.total_height) << 4
        self.road_unk[self.a3_o] = s16(th >> 16); self.a3_o += 1

    def set_y_horizon(self):
        a0 = 0x200 + self.road_p1
        d1 = (self.horizon_mod * (self.height_start - 0x100)) >> 4
        d2 = ((self.horizon_base + self.horizon_offset) << 4) + d1
        total = 0
        for i in range(0x200):
            total = (total + d2) & 0xFFFFFFFF
            d0 = ((total << 4) & 0xFFFFFFFF) >> 16
            a0 -= 1
            self.road_y[a0] = s16(d0)
        self.road_unk[0] = 0
        if self.height_start != 0x1FF:
            return
        self.horizon_base = self.hread16(self.height_addr)
        if self.height_lookup == self.height_lookup_wrk:
            self.height_lookup = 0
        self.height_ctrl = 1

    def set_horizon_y(self):
        ry = self.road_y
        road_int = 0
        base = self.road_p1
        while True:
            d0 = s16(self.road_unk[road_int])
            if d0 == 0:
                break
            d7 = d0 >> 3
            d6 = d7 + d0 - 0x1FF
            if d6 > 0:
                d7 += d7
                d7 -= d6
                d7 >>= 1
                d0 = 0x1FF - d7
            d6 = d7 >> 1
            if d6 <= 2:
                break
            d1 = d0 - d6
            d2 = d0
            d3 = d0 + d6
            d4 = d0 + d7
            d0 -= d7
            d5 = d0
            a2 = base + d5
            d0 = ry[base + d0]
            d1 = ry[base + d1]
            d2 = ry[base + d2]
            d3 = ry[base + d3]
            d4 = ry[base + d4]
            d5 = d0
            d2l = s32((d2 + d0 + d4) * 0x5555) >> 16
            d1l = s32((d1 + d0 + s16(d2l)) * 0x5555) >> 16
            d3l = s32((d3 + d4 + s16(d2l)) * 0x5555) >> 16
            d0 = s16(d0 - s16(d1l))
            d1l = s16(d1l - s16(d2l))
            d2l = s16(d2l - s16(d3l))
            d3l = s16(d3l - d4)
            d0 = s16(cdiv(d0 << 2, d6))
            d1 = s16(cdiv(d1l << 2, d6))
            d2 = s16(cdiv(d2l << 2, d6))
            d3 = s16(cdiv(d3l << 2, d6))
            d5 = s16(d5 << 2)
            d6 -= 1
            for dd in (d0, d1, d2, d3):
                for i in range(d6 + 1):
                    ry[a2] = s16(d5) >> 2
                    a2 += 1
                    d5 = s16(d5 - dd)
            road_int += 2
        y_pos = ry[self.road_p3] >> 4
        self.horizon_y2 = -y_pos + 224

    def do_road_data(self):
        ry = self.road_y
        addr_dst = 0x400 + self.road_p1
        addr_src = 0x200 + self.road_p1
        addr_pri = 0x280 + self.road_p1
        rom_line_select = 0x1FF
        addr_src -= 1
        src_this = ry[addr_src] >> 4
        src_next = 0
        write_priority = 0
        addr_dst -= 1
        ry[addr_dst] = rom_line_select
        scanline = 254
        while True:
            rom_line_select -= 1
            if rom_line_select <= 0:
                break
            addr_src -= 1
            src_next = ry[addr_src] >> 4
            if src_this < src_next:
                scanline -= 1
                if scanline <= 0:
                    ry[addr_pri] = 0; ry[addr_pri + 1] = 0
                    return
                src_this = src_next
                addr_dst -= 1
                ry[addr_dst] = rom_line_select
                write_priority = -1
            elif src_this == src_next:
                continue
            elif write_priority == -1:
                ry[addr_pri] = rom_line_select; addr_pri += 1
                ry[addr_pri] = src_this; addr_pri += 1
                write_priority = 0
        if rom_line_select <= 0:
            SOLID = 0x800
            TRANSP = 0x3F | SOLID
            d7 = 255 - src_next - scanline
            if d7 < 0:
                d7 = SOLID
            elif d7 > 0x3F:
                while scanline > 0:
                    scanline -= 1
                    addr_dst -= 1
                    ry[addr_dst] = TRANSP
                ry[addr_pri] = 0; ry[addr_pri + 1] = 0
                return
            else:
                d7 |= SOLID
            while True:
                addr_dst -= 1
                ry[addr_dst] = d7
                scanline -= 1
                if scanline < 0:
                    ry[addr_pri] = 0; ry[addr_pri + 1] = 0
                    return
                addr_dst -= 1
                ry[addr_dst] = d7
                scanline -= 1
                if scanline < 0:
                    ry[addr_pri] = 0; ry[addr_pri + 1] = 0
                    return
                d7 += 1
                if d7 > TRANSP:
                    break
            while scanline > 0:
                scanline -= 1
                addr_dst -= 1
                ry[addr_dst] = TRANSP
        ry[addr_pri] = 0; ry[addr_pri + 1] = 0

    def blit_roads(self):
        # 224 lines of road data from road_y[0x400+p2 - 224 .. 0x400+p2)
        a2 = 0x400 + self.road_p2
        out = [0] * 224
        for i in range(224):
            a2 -= 1
            out[223 - i] = self.road_y[a2]
        self.hw_lines = out

    # hscroll as written to hardware for line index
    def hscroll0(self, idx):
        return u16(-self.road0_h[idx] + 0x654)

    def hscroll1(self, idx):
        return u16(-self.road1_h[idx] + 0x654)


def stripe_color(R, pos_fine, idx):
    return R.r16(R.rom1, ROAD_BGCOLOR + ((pos_fine & 0x1F) << 10) + idx * 2)
