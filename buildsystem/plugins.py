
import fbuild
import fbuild.builders.file
import os
from fbuild.path import Path
from fbuild.builders.file import copy

# ------------------------------------------------------------------------------

def build(phase, felix):
    print ("BUILDING PLUGINS")
    for f in Path.glob('src/lib/plugins/*'):
      copy(ctx=phase.ctx, src=f, dst=phase.ctx.buildroot / 'share'/f[4:]) 
    plugins = [
      "ocaml2html",
      "py2html",
      "fdoc2html",
      "flx2html",
      "cpp2html",
      "fpc2html",
      "fdoc_slideshow",
      "fdoc_paragraph",
      "fdoc_heading",
      "fdoc_fileseq",
      "fdoc_scanner",
      "fdoc_button",
      "toolchain_clang_osx",
      "toolchain_clang_linux",
      "toolchain_gcc_osx",
      "toolchain_gcc_linux",
      ]
    for base in plugins:
      shlib = felix.compile(phase.ctx.buildroot/('share/lib/plugins/'+base+'.flx'))
      fbuild.builders.file.copy(phase.ctx, shlib, 'host/lib')
      #os.unlink(shlib)

