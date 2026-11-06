"""Verify or explicitly download the pinned bilingual model; no cloud inference."""
from pathlib import Path
import argparse, hashlib, json, urllib.request

FILES={
 'encoder.int8.onnx':('encoder-epoch-99-avg-1.int8.onnx','8fa764187a261844f859d7143ebaa563af5d10adfece4c18a8f414c88cba2a9b'),
 'decoder.onnx':('decoder-epoch-99-avg-1.onnx','2e3b5ec371f8899ee6acd829fd753ba45772df57a91bdf37cde3136354e7db7d'),
 'joiner.onnx':('joiner-epoch-99-avg-1.int8.onnx','1ed689c5ed19dbaa725d9d191bb4822b5f4855a39e1ffd28cbc1f340d25b2ee0'),
 'tokens.txt':('tokens.txt','a8e0e4ec53810e433789b54a5c0134a7eaa2ffca595a6334d54c00da858841d3'),
}
parser=argparse.ArgumentParser()
parser.add_argument('directory',type=Path)
parser.add_argument('--download',action='store_true',help='explicitly download from the configured HTTPS source')
parser.add_argument('--base-url',default='https://www.modelscope.cn/models/pkufool/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20/resolve/master/')
args=parser.parse_args()
if not args.base_url.startswith('https://'):parser.error('HTTPS model source required')
args.directory.mkdir(parents=True,exist_ok=True)
for name,(upstream,expected) in FILES.items():
    target=args.directory/name
    if args.download and not target.exists():
        temporary=target.with_suffix(target.suffix+'.partial')
        with urllib.request.urlopen(args.base_url.rstrip('/')+'/'+upstream,timeout=60) as response,temporary.open('wb') as output:
            while chunk:=response.read(1024*1024):output.write(chunk)
        if hashlib.file_digest(temporary.open('rb'),'sha256').hexdigest()!=expected:
            temporary.unlink();raise SystemExit('checksum_mismatch:'+name)
        temporary.replace(target)
    if not target.exists():raise SystemExit('missing:'+name+'; supply licensed local files or use --download')
    with target.open('rb') as stream:actual=hashlib.file_digest(stream,'sha256').hexdigest()
    if actual!=expected:raise SystemExit('checksum_mismatch:'+name)
    print(json.dumps({'file':name,'sha256':actual,'verified':True}))
