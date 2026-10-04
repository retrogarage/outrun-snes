; Road engine interface (oroad.s exact road engine + roadcompat.s)
.ifndef ROAD_INC
ROAD_INC = 1

.global road_pos, road_pos_old, pos_fine, road_ctrl, road_width, road_width_bak
.global car_x_bak, camera_x_off, horizon_base, horizon_offset, horizon_set
.global tilemap_h_target, height_lookup, horizon_y2, horizon_y_bak, pos_fine_diff
.global road_load_split, road_load_end, road_p0, road_p1, road_p2, road_p3
.global rd_colph, rd_hwctl, ORoadInit, ORoadTick
.global road_top, sky_d7, scan_rom, knots, knot_n, sg_n, segs
.global RoadInitSection, RoadTick, RoadLineParams, RoadReset, RoadScan
.global gnd_pal, lb_ofs
.global FsValue, RoadCurveAt, RoadH0At, RoadH1At, RoadYAt, RoadBuildLUT
.globalzp rz0

.endif
