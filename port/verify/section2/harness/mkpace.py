import re,struct,sys
pc=sys.argv[3] if len(sys.argv)>3 else '017118'
out=open(sys.argv[2],'wb')
for l in open(sys.argv[1],errors='replace'):
    m=re.match(r'\[f(\d+) v(\d+)\] BP '+pc,l)
    if m: out.write(struct.pack('<I',int(m.group(1))*313+int(m.group(2))))
