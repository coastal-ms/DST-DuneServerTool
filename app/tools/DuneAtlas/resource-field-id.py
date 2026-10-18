"""Match the installed build's ResourceFieldSubsystem persistence coordinate key.

Verified from the read-only SaveDirtyFields machine-code path and all 45 saved
Deep Desert records, including two harvested fields. Keep IDs as strings.
"""
import math

def field_id(location):
    x,y,z=location
    if not all(math.isfinite(v) and abs(v)<1e8 for v in (x,y,z)):
        raise ValueError('Invalid field coordinates')
    # x86 vcvtsd2si uses nearest-even; masks/shifts mirror the native code.
    a=((round(2*x+.5)&0xffffffff)>>1)&0xfffff
    b=(round(2*y+.5)<<20)&0x1ffffe00000
    c=(round(2*z+.5)&0x1ffffe)<<41
    return str(a|b|c|((x<0)<<20)|((y<0)<<41)|((z<0)<<62))
