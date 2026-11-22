#!/usr/bin/env python3
"""Renames the gs_light_* meta keys in baked lightmaps (Godot RSCC/zstd binary .res) to gs_light_*,
byte for byte otherwise: a headless re-save would drop the Texture2DArray data.
Usage: tools/rename_bake_meta.py <game>/lightmaps/*.res"""
import struct,subprocess,sys
def unpack(path):
    f=open(path,'rb').read()
    assert f[:4]==b'RSCC'
    mode,bs,total=struct.unpack('<III',f[4:16]); assert mode==2
    n=(total+bs-1)//bs
    sizes=struct.unpack('<%dI'%n,f[16:16+4*n]); p=16+4*n; out=b''
    for s in sizes:
        out+=subprocess.run(['zstd','-dq','-c'],input=f[p:p+s],capture_output=True,check=True).stdout; p+=s
    assert len(out)==total and f[p:p+4]==b'RSCC', (len(out),total)
    return out,bs
def pack(data,bs):
    blocks=[subprocess.run(['zstd','-q','-c','-3','--no-check'],input=data[i:i+bs],capture_output=True,check=True).stdout for i in range(0,len(data),bs)]
    return b'RSCC'+struct.pack('<III',2,bs,len(data))+struct.pack('<%dI'%len(blocks),*[len(b) for b in blocks])+b''.join(blocks)+b'RSCC'
def rename_strings(d, mapping):
    u32=lambda p: struct.unpack_from('<I',d,p)[0]
    p=20; tl=u32(p); p+=4+tl          # header u32 x5, type string
    imp_pos=p; p+=8; flags=u32(p); p+=4
    if flags&2: p+=8
    if flags&4: l=u32(p); p+=4+l
    p+=44
    out=bytearray(d[:p]); n=u32(p); out+=d[p:p+4]; p+=4; delta=0; changed=0
    for _ in range(n):
        l=u32(p); s=d[p+4:p+4+l]; p+=4+l
        name=s[:-1].decode()
        if name in mapping:
            name=mapping[name]; changed+=1
        b=name.encode()+b'\0'; delta+=len(b)-l
        out+=struct.pack('<I',len(b))+b
    ne=u32(p); out+=d[p:p+4]; p+=4
    for _ in range(ne):
        for _k in range(2):
            l=u32(p); out+=d[p:p+4+l]; p+=4+l
        if flags&2: out+=d[p:p+8]; p+=8
    ni=u32(p); out+=d[p:p+4]; p+=4
    for _ in range(ni):
        l=u32(p); out+=d[p:p+4+l]; p+=4+l
        off=struct.unpack_from('<Q',d,p)[0]; out+=struct.pack('<Q',off+delta); p+=8
    out+=d[p:]
    imp=struct.unpack_from('<Q',d,imp_pos)[0]
    if imp: struct.pack_into('<Q',out,imp_pos,imp+delta)
    return bytes(out),changed

M = {'metadata/gs_light_fingerprint': 'metadata/gs_light_fingerprint', 'metadata/gs_light_components': 'metadata/gs_light_components', 'metadata/gs_light_out': 'metadata/gs_light_out'}

if __name__ == '__main__':
    for path in sys.argv[1:]:
        d, bs = unpack(path)
        new, c = rename_strings(d, M)
        if c:
            open(path, 'wb').write(pack(new, bs))
        print(path, c, 'renamed')
