# flipper-accountdb.awk - per-entry 3-way merge of the account databases, run by
# migrate-profile as: awk -v LF=<list-fields> -f this base ours theirs
#
# Account databases (passwd/shadow/group/gshadow + backups) are keyed by the first field, not by
# line order, so a text merge conflicts on every epoch bump and could duplicate entries. Merge them
# per entry instead: an account the user did not touch follows the new base (apt replay is the
# authority for service accounts), an account the user added or changed rides along from src, and
# group/gshadow memberships are set-merged. Deterministic, never conflicts.
#
# LF: comma-separated field numbers holding member lists (group=4, gshadow=3,4).
BEGIN { FS=":"; nlf=split(LF,_l,","); for(i=1;i<=nlf;i++) islist[_l[i]+0]=1; fidx=0 }
FNR==1 { fidx++ }
{
    if ($0=="") next
    k=$1
    if      (fidx==1) { Bl[k]=$0; hB[k]=1 }
    else if (fidx==2) { Ol[k]=$0; hO[k]=1; if(!(k in os)){ os[k]=1; oord[++no]=k } }
    else              { Tl[k]=$0; hT[k]=1; if(!(k in ts)){ ts[k]=1; tord[++nt]=k } }
}
END {
    for (i=1;i<=no;i++) put(oord[i])
    for (i=1;i<=nt;i++) if (!(tord[i] in os)) put(tord[i])
}
function put(k,   line) { line=decide(k); if (line!="") print line }
function decide(k,   ib,io,it) {
    ib=(k in hB); io=(k in hO); it=(k in hT)
    if (!io && !it) return ""
    if ( io && !it) { if (ib && Ol[k]==Bl[k]) return ""; return Ol[k] }
    if (!io &&  it) { if (ib && Tl[k]==Bl[k]) return ""; return Tl[k] }
    if (LF!="") return mergerec(k, ib)
    if (Ol[k]==Tl[k]) return Ol[k]
    if (!ib)          return Ol[k]
    if (Tl[k]==Bl[k]) return Ol[k]
    if (Ol[k]==Bl[k]) return Tl[k]
    return Tl[k]
}
function mergerec(k, ib,   nb,no2,nt2,fb,fo,ft,fi,res) {
    nb  = ib ? split(Bl[k], fb, ":") : 0
    no2 =      split(Ol[k], fo, ":")
    nt2 =      split(Tl[k], ft, ":")
    for (fi=1; fi<=no2; fi++)
        rf[fi] = (fi in islist) ? merge_members(fi, ib, fb, fo, ft, nb, no2, nt2) : fo[fi]
    res=rf[1]; for(fi=2;fi<=no2;fi++) res=res ":" rf[fi]
    delete rf
    return res
}
function merge_members(fi, ib, fb, fo, ft, nb, no2, nt2,   i,m,res) {
    delete inB; delete inO; delete inT; delete ordm; delete ordseen; nord=0
    if (ib && nb >=fi) mark(fb[fi], inB)
    if (      no2>=fi) mark(fo[fi], inO)
    if (      nt2>=fi) mark(ft[fi], inT)
    if (      no2>=fi) order(fo[fi])
    if (      nt2>=fi) order(ft[fi])
    if (ib && nb >=fi) order(fb[fi])
    res=""
    for (i=1;i<=nord;i++) {
        m=ordm[i]
        if ((m in inB) && !(m in inO)) continue
        if ((m in inB) && !(m in inT)) continue
        res = (res=="") ? m : res "," m
    }
    return res
}
function mark(s, arr,   n,a,i) { n=split(s,a,","); for(i=1;i<=n;i++) if(a[i]!="") arr[a[i]]=1 }
function order(s,   n,a,i)     { n=split(s,a,","); for(i=1;i<=n;i++) if(a[i]!="" && !(a[i] in ordseen)){ ordseen[a[i]]=1; ordm[++nord]=a[i] } }
