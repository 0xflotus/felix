import fbuild
from fbuild.functools import call
from fbuild.path import Path
from fbuild.record import Record
from fbuild.builders.file import copy

import buildsystem

# ------------------------------------------------------------------------------

def build_runtime(host_phase, target_phase):
    path = Path('src/gc')

    buildsystem.copy_hpps_to_rtl(target_phase.ctx,
        target_phase.ctx.buildroot / 'config/target/flx_gc_config.hpp',
        path / 'flx_gc.hpp',
        path / 'flx_judy_scanner.hpp',
        path / 'flx_collector.hpp',
        path / 'flx_gc_private.hpp',
        path / 'flx_ts_collector.hpp',
    )

    dst = 'lib/rtl/flx_gc'
    srcs = [copy(ctx=target_phase.ctx, src=f, dst=target_phase.ctx.buildroot / f) for f in Path.glob(path / '*.cpp')]
    includes = [
        target_phase.ctx.buildroot / 'config/target',
        target_phase.ctx.buildroot / 'lib/rtl',
        'src/rtl',
        'src/pthread',
        'src/exceptions',
        'src/judy/src',
    ]
    macros = ['BUILD_FLX_GC']
    libs = [
        call('buildsystem.judy.build_runtime', host_phase, target_phase),
        call('buildsystem.flx_exceptions.build_runtime', target_phase),
        call('buildsystem.flx_pthread.build_runtime', target_phase),
    ]

    return Record(
        static=buildsystem.build_cxx_static_lib(target_phase, dst, srcs,
            includes=includes,
            macros=macros,
            libs=[lib.static for lib in libs]),
        shared=buildsystem.build_cxx_shared_lib(target_phase, dst, srcs,
            includes=includes,
            macros=macros,
            libs=[lib.shared for lib in libs]))
