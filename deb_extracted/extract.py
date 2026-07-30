import struct, os
with open(r'G:\ipsw\ipsw\dylib\hezi-groupsend.deb', 'rb') as f:
    data = f.read()
pos = 8
while pos < len(data):
    name = data[pos:pos+16].rstrip(b' ').rstrip(b'/').decode('ascii', errors='replace')
    size = int(data[pos+48:pos+58].strip())
    pos += 60
    if name and size > 0:
        fdata = data[pos:pos+size]
        outpath = os.path.join(r'G:\ipsw\ipsw\dylib\deb_extracted', name.replace('/','_'))
        with open(outpath, 'wb') as out: out.write(fdata)
        print(f'{name}: {size} bytes')
    pos += size
    if pos % 2: pos += 1
    if pos >= len(data): break
