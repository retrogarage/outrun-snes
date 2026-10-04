; Global variable declarations shared across modules (SA-1 side)
.ifndef GLOBALS_INC
GLOBALS_INC = 1

.globalzp frame_count, nmi_flag, frame_ready, joy_cur, joy_prev, joy_new
.globalzp tmp0, tmp1, tmp2, tmp3, tmp4, tmp5, tmp6, tmp7, ptr0, ptr1, ptr2
.global GameMain, WaitFrame, WaitNmi, ProfMark, FrameReady, WaitSwap, GetFrame

.endif
