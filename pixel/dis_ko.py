import sys
from elftools.elf.elffile import ELFFile
from capstone import *
f=ELFFile(open(sys.argv[1],'rb'))
sec=f.get_section(9); data=sec.data()
syms={s.name:(s['st_value'],s['st_size']) for s in f.get_section_by_name('.symtab').iter_symbols() if s['st_info']['type']=='STT_FUNC'}
# relocation names for the section
rel={}
for rs in f.iter_sections():
    if rs.name.startswith('.rela') and rs['sh_info']==9:
        st=f.get_section(rs['sh_link'])
        for r in rs.iter_relocations():
            s=st.get_symbol(r['r_info_sym']); rel[r['r_offset']]=s.name or ('sec%d'%s['st_shndx'])+'+'+hex(r['r_addend'])
md=Cs(CS_ARCH_ARM64,CS_MODE_ARM)
for name in sys.argv[2:]:
    a,sz=syms[name]; print('==',name,hex(a),sz)
    for i in md.disasm(data[a:a+sz],a):
        r=rel.get(i.address,'')
        print('%x: %-8s %s %s'%(i.address,i.mnemonic,i.op_str,('  ; '+r) if r else ''))
