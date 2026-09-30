import numpy as np, sys
import os; exec(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'wavstat.py')).read().split('args = ')[0])
for d in sys.argv[1:]:
    a,r=load(d); x=np.abs(a).max(axis=1)[int(3.2*r):]
    z=(x<1e-7).astype(int); edges=np.diff(np.concatenate([[0],z,[0]]))
    st=np.nonzero(edges==1)[0]; en=np.nonzero(edges==-1)[0]; L=en-st
    big=L[L>=48]
    print(d,'silent gaps >=1ms after 3.2s:',len(big),'total %.0f ms'%(big.sum()/r*1000))
