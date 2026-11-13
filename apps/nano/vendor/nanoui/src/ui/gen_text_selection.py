"""Generate the checked-in Unicode 17.0.0 selection tables (offline inputs).
Inputs are the official UCD GraphemeBreakProperty, emoji-data,
DerivedCoreProperties and UnicodeData files. No locale or regex dependency.
"""
from pathlib import Path
import shutil
import argparse
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('ucd_dir', type=Path, help='Directory containing the five pinned Unicode 17 UCD files')
args = parser.parse_args()
src = args.ucd_dir
out = Path(__file__).resolve().parent
def merge(items):
 items=sorted(items)
 result=[]
 for a,b,p in items:
  if result and a==result[-1][1]+1 and p==result[-1][2]: result[-1]=(result[-1][0],b,p)
  else:result.append((a,b,p))
 return result

def ranges(file,select):
 result=[]
 for line in (src/file).read_text().splitlines():
  line=line.split('#')[0].strip()
  if not line:continue
  fields=[p.strip() for p in line.split(';')]
  prop=select(fields)
  if prop is None:continue
  ab=fields[0].split('..');a=int(ab[0],16);b=int(ab[-1],16)
  result.append((a,b,prop))
 return merge(result)

gcb=ranges('GraphemeBreakProperty.txt',lambda f: None if f[1] in ['LV','LVT'] else f[1].lower())
ep=ranges('emoji-data.txt',lambda f: 'true' if f[1]=='Extended_Pictographic' else None)
incb=ranges('DerivedCoreProperties.txt',lambda f:f[2].lower() if f[1]=='InCB' else None)
words=[];pending=None
for line in (src/'UnicodeData.txt').read_text().splitlines():
 f=line.split(';'); cp=int(f[0],16)
 if f[1].endswith(', First>'):pending=cp;continue
 if f[1].endswith(', Last>'):
  if f[2][0] in 'LN':words.append((pending,cp,'true'))
  pending=None
 elif f[2][0] in 'LN':words.append((cp,cp,'true'))
words=merge(words)
text='''//! Generated from Unicode 17.0.0 UCD, not platform/locale heuristics.
//! https://www.unicode.org/Public/17.0.0/ucd/auxiliary/GraphemeBreakProperty.txt
//! https://www.unicode.org/Public/17.0.0/ucd/emoji/emoji-data.txt
//! https://www.unicode.org/Public/17.0.0/ucd/DerivedCoreProperties.txt (InCB)
//! https://www.unicode.org/Public/17.0.0/ucd/UnicodeData.txt (letters/numbers)
//! Unicode data license: ../../third_party/licenses/Unicode-3.0.txt.
//! Hangul LV/LVT syllables are classified algorithmically by the caller.
pub const Break = enum { other, cr, lf, control, extend, zwj, regional_indicator, prepend, spacingmark, l, v, t, lv, lvt };
pub const Indic = enum { none, consonant, extend, linker };
fn Range(comptime T: type) type { return struct { first: u21, last: u21, value: T }; }
pub fn lookup(comptime T: type, table: []const Range(T), cp: u21, fallback: T) T {
    var lo: usize = 0;
    var hi = table.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = table[mid];
        if (cp < r.first) hi = mid else if (cp > r.last) lo = mid + 1 else return r.value;
    }
    return fallback;
}
'''
for name,kind,items in [('breaks','Break',gcb),('pictographic','bool',ep),('indic','Indic',incb),('words','bool',words)]:
 text+=f'pub const {name} = [_]Range({kind}){{\n'
 for a,b,p in items:text+=f'    .{{ .first = 0x{a:X}, .last = 0x{b:X}, .value = {p if kind=="bool" else "."+p} }},\n'
 text+='};\n'
(out/'text_selection_data.zig').write_text(text)
shutil.copyfile(src/'GraphemeBreakTest.txt',out/'grapheme_break_test.txt')
print('Generated tables:',len(gcb),len(ep),len(incb),len(words),len(text),'bytes')
