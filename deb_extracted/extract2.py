import tarfile, os
extract_dir = r'G:\ipsw\ipsw\dylib\deb_extracted'
for f in os.listdir(extract_dir):
    if f.endswith('.tar.gz'):
        path = os.path.join(extract_dir, f)
        with tarfile.open(path, 'r:gz') as tar:
            tar.extractall(path=extract_dir)
            print(f'Extracted {path}:')
            for m in tar.getmembers():
                print(f'  {m.name} ({m.size} bytes)')
