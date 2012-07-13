from itertools import chain
from optparse import make_option

import fbuild
import fbuild.db
from fbuild.functools import call
from fbuild.path import Path
from fbuild.record import Record

import buildsystem
from buildsystem.config import config_call

# ------------------------------------------------------------------------------

def pre_options(parser):
    group = parser.add_option_group('config options')
    group.add_options((
        make_option('--prefix',
            default='/usr/local',
            help='specify the install location (default /usr/local)'),
        make_option('--bindir',
            default=None,
            help='specify the binary install location (default $PREFIX/bin)'),
        make_option('--libdir',
            default=None,
            help='specify the library install location (default $PREFIX/lib)'),
        make_option('-I', '--include',
            dest='includes',
            default=[],
            action='append',
            help='Add this path to the c header search path for all phases'),
        make_option('-L', '--library-path',
            dest='libpaths',
            default=[],
            action='append',
            help='Add this path to the c library search path for all phases'),
        make_option('--c-flag',
            dest='c_flags',
            default=[],
            action='append',
            help='Add this flag to the c compiler'),
        make_option('-g', '--debug',
            default=False,
            action='store_true',
            help='enable debugging for all phases'),
        make_option('--skip-tests',
            default=False,
            action='store_true',
            help='skip running tests'),
    ))

    group = parser.add_option_group('build phase options')
    group.add_options((
        make_option('--build-platform',
            help='specify the build phase platform'),
        make_option('--build-cc',
            help='specify the build phase c compiler'),
        make_option('--build-cxx',
            help='specify the build phase c++ compiler'),
        make_option('--build-include',
            dest='build_includes',
            default=[],
            action='append',
            help='Add this path to the c header search path for the build ' \
                    'phase'),
        make_option('--build-library-path',
            dest='build_libpaths',
            default=[],
            action='append',
            help='Add this path to the c library search path for the build ' \
                    'phase'),
        make_option('--build-c-flag',
            dest='build_c_flags',
            default=[],
            action='append',
            help='Add this flag to the c compiler for the build phase'),
        make_option('--build-c-debug',
            default=False,
            action='store_true',
            help='turn on c/c++ build phase debugging'),
    ))

    group = parser.add_option_group('host phase options')
    group.add_options((
        make_option('--host-platform',
            help='specify the host phase platform'),
        make_option('--host-cc',
            help='specify the host phase c compiler'),
        make_option('--host-cxx',
            help='specify the host phase c++ compiler'),
        make_option('--host-include',
            dest='host_includes',
            default=[],
            action='append',
            help='Add this path to the c header search path for the host ' \
                    'phase'),
        make_option('--host-library-path',
            dest='host_libpaths',
            default=[],
            action='append',
            help='Add this path to the c library search path for the host ' \
                    'phase'),
        make_option('--host-c-flag',
            dest='host_c_flags',
            default=[],
            action='append',
            help='Add this flag to the c compiler for the host phase'),
        make_option('--host-c-debug',
            default=False,
            action='store_true',
            help='turn on c/c++ host phase debugging'),
        make_option('--host-ocaml-debug',
            default=False,
            action='store_true',
            help='turn on ocaml debugging'),
        make_option('--host-ocamlc',
            help='specify the ocaml bytecode compiler'),
        make_option('--host-ocamlopt',
            help='specify the ocaml native compiler'),
        make_option('--host-ocamllex',
            help='specify the ocaml lexer'),
        make_option('--host-llvm-config',
            help='specify the llvm-config script'),
    ))

    group = parser.add_option_group('target phase options')
    group.add_options((
        make_option('--target-platform',
            help='specify the target phase platform'),
        make_option('--target-cc',
            help='specify the target phase c compiler'),
        make_option('--target-cxx',
            help='specify the target phase c++ compiler'),
        make_option('--target-include',
            dest='target_includes',
            default=[],
            action='append',
            help='Add this path to the c header search path for the target ' \
                    'phase'),
        make_option('--target-library-path',
            dest='target_libpaths',
            default=[],
            action='append',
            help='Add this path to the c library search path for the target ' \
                    'phase'),
        make_option('--target-c-debug',
            default=False,
            action='store_true',
            help='turn on c/c++ target phase debugging'),
        make_option('--target-c-flag',
            dest='target_c_flags',
            default=[],
            action='append',
            help='Add this flag to the c compiler for the target phase'),
        make_option('--target-sdl-config',
            help='specify the sdl-config script'),
    ))

def post_options(options, args):
    options.prefix = Path(options.prefix)
    options.bindir = Path(
        options.prefix / 'bin' if options.bindir is None else options.bindir)
    options.libdir = Path(
        options.prefix / 'lib' if options.libdir is None else options.libdir)

    if options.debug:
        options.buildroot = Path(options.buildroot, 'debug')
    else:
        options.buildroot = Path(options.buildroot, 'release')

    return options, args

# ------------------------------------------------------------------------------

def make_c_builder(ctx, *args, includes=[], libpaths=[], flags=[], **kwargs):
    flags = list(chain(ctx.options.c_flags, flags))

    kwargs['platform_options'] = [
        # GRRR .. for clang
        ({'darwin'},
            {'warnings': ['all', 'fatal-errors', 
                'no-constant-logical-operand',
                'no-array-bounds',
                ],
            'flags': ['-fno-common'] + flags,
            'optimize_flags': ['-O3', '-fomit-frame-pointer']}),
        ({'posix'},
            {'warnings': ['all', 'fatal-errors'],
            'flags': ['-fno-common'] + flags,
            'optimize_flags': ['-O3', '-fomit-frame-pointer']}),
        ({'windows'}, {
            'flags': ['/GR', '/MD', '/EHs', '/wd4291'] + flags,
            'optimize_flags': ['/Ox']}),
    ]
    kwargs['includes'] = list(chain(ctx.options.includes, includes))
    kwargs['libpaths'] = list(chain(ctx.options.libpaths, libpaths))

    return Record(
        static=call('fbuild.builders.c.guess_static', ctx, *args, **kwargs),
        shared=call('fbuild.builders.c.guess_shared', ctx, *args, **kwargs))

def make_cxx_builder(ctx, *args, includes=[], libpaths=[], flags=[], **kwargs):
    flags = list(chain(ctx.options.c_flags, flags))

    kwargs['platform_options'] = [
        # GRRR .. for clang++
        ({'darwin'}, {
            'warnings': ['all', 'fatal-errors', 
                'no-invalid-offsetof', 
                'no-bitwise-op-parentheses',
                'no-parentheses-equality',
                'no-return-stack-address',
                'no-tautological-compare',
                'no-return-type-c-linkage',
                ],
            'flags': ['-fno-common'] + flags,
            'optimize_flags': ['-O3', '-fomit-frame-pointer']}),
        ({'posix'}, {
            'warnings': ['all', 'fatal-errors', 'no-invalid-offsetof'],
            'flags': ['-fno-common'] + flags,
            'optimize_flags': ['-O3', '-fomit-frame-pointer']}),
        ({'windows'}, {
            'flags': ['/GR', '/MD', '/EHs', '/wd4291'] + flags,
            'optimize_flags': ['/Ox']}),
    ]
    kwargs['includes'] = list(chain(ctx.options.includes, includes))
    kwargs['libpaths'] = list(chain(ctx.options.libpaths, libpaths))

    return Record(
        static=call('fbuild.builders.cxx.guess_static', ctx, *args, **kwargs),
        shared=call('fbuild.builders.cxx.guess_shared', ctx, *args, **kwargs))

def config_build(ctx):
    ctx.logger.log('configuring build phase', color='cyan')

    platform = call('fbuild.builders.platform.guess_platform', ctx,
        ctx.options.build_platform)

    return Record(
        ctx=ctx,
        platform=platform,
        c=make_c_builder(ctx, ctx.options.build_cc,
            platform=platform,
            debug=ctx.options.debug or ctx.options.build_c_debug,
            optimize=not (ctx.options.debug or ctx.options.build_c_debug),
            includes=ctx.options.build_includes,
            libpaths=ctx.options.build_libpaths,
            flags=ctx.options.build_c_flags),
        cxx=make_cxx_builder(ctx, ctx.options.build_cxx,
            platform=platform,
            debug=ctx.options.debug or ctx.options.build_c_debug,
            optimize=not (ctx.options.debug or ctx.options.build_c_debug),
            includes=ctx.options.build_includes,
            libpaths=ctx.options.build_libpaths,
            flags=ctx.options.build_c_flags))

def config_host(ctx, build):
    ctx.logger.log('configuring host phase', color='cyan')

    platform = call('fbuild.builders.platform.guess_platform', ctx,
        ctx.options.build_platform)

    if platform == build.platform:
        ctx.logger.log("using build's c and cxx compiler", color='cyan')
        phase = build
    else:
        phase = Record(
            ctx=ctx,
            platform=platform,
            c=make_c_builder(ctx, fbuild.builders.host_cc,
                platform=platform,
                debug=ctx.options.debug or ctx.options.host_c_debug,
                optimize=not (ctx.options.debug or ctx.options.host_c_debug),
                includes=ctx.options.host_includes,
                libpaths=ctx.options.host_libpaths,
                flags=ctx.options.host_c_flags),
            cxx=make_cxx_builder(ctx, fbuild.buildesr.host_cxx,
                platform=platform,
                debug=ctx.options.debug or ctx.options.host_c_debug,
                optimize=not (ctx.options.debug or ctx.options.host_c_debug),
                includes=ctx.options.host_includes,
                libpaths=ctx.options.host_libpaths,
                flags=ctx.options.host_c_flags))

    phase.ocaml = call('fbuild.builders.ocaml.Ocaml', ctx,
        debug=ctx.options.debug or ctx.options.host_ocaml_debug,
        ocamlc=ctx.options.host_ocamlc,
        ocamlopt=ctx.options.host_ocamlopt,
        flags=['-w', 'yzex', '-warn-error', 'FDPSU'],
        requires_at_least_version=(3, 11))

    phase.ocamllex = call('fbuild.builders.ocaml.Ocamllex', ctx,
        ctx.options.host_ocamllex)

    # we prefer the native ocaml as it's much faster
    if hasattr(phase.ocaml, 'ocamlopt'):
        phase.ocaml = phase.ocaml.ocamlopt
    else:
        phase.ocaml = phase.ocaml.ocamlc

    # We optionally support llvm
    try:
        llvm_config = call('fbuild.builders.llvm.LlvmConfig', ctx,
            ctx.options.host_llvm_config,
            requires_at_least_version=(2, 7))
    except fbuild.ConfigFailed:
        phase.llvm_config = None
    else:
        if llvm_config.ocaml_libdir().exists():
            #phase.llvm_config = llvm_config
            phase.llvm_config = None
        else:
            phase.llvm_config = None

    return phase

def config_target(ctx, host):
    ctx.logger.log('configuring target phase', color='cyan')

    platform = call('fbuild.builders.platform.guess_platform', ctx,
        ctx.options.target_platform)

    if platform == host.platform:
        ctx.logger.log("using host's c and cxx compiler", color='cyan')
        phase = host
    else:
        phase = Record(
            ctx=ctx,
            platform=platform,
            c=make_c_builder(ctx, ctx.options.target_cc,
                platform=platform,
                debug=ctx.options.debug or ctx.options.target_c_debug,
                optimize=not (ctx.options.debug or ctx.options.target_c_debug),
                includes=ctx.options.target_includes,
                libpaths=ctx.options.target_libpaths,
                flags=ctx.options.target_c_flags),
            cxx=make_cxx_builder(ctx, ctx.options.target_cxx,
                platform=platform,
                debug=ctx.options.debug or ctx.options.target_c_debug,
                optimize=not(ctx.options.debug or ctx.options.target_c_debug),
                includes=ctx.options.target_includes,
                libpaths=ctx.options.target_libpaths,
                flags=ctx.options.target_c_flags))

    # We optionally support sdl
    try:
        phase.sdl_config = call('fbuild.builders.sdl.SDLConfig', ctx,
            ctx.options.target_sdl_config,
            requires_at_least_version=(1, 3))
    except fbuild.ConfigFailed:
        phase.sdl_config = None

    return phase

# ------------------------------------------------------------------------------

@fbuild.db.caches
def prefix(ctx):
    prefix = Path(ctx.options.prefix)
    ctx.logger.check('install prefix', prefix, color='cyan')

    return prefix

@fbuild.db.caches
def src_dir(ctx):
    return Path(__file__).parent

# ------------------------------------------------------------------------------

@fbuild.target.register()
def configure(ctx):
    """Configure Felix."""

    build = config_build(ctx)
    host = config_host(ctx, build)
    target = config_target(ctx, host)

    # Make sure the config directories exist.
    (ctx.buildroot / 'config/build').makedirs()
    (ctx.buildroot / 'config/host').makedirs()
    (ctx.buildroot / 'config/target').makedirs()

    # copy the config directory for initial config
    # this will be overwritten by subsequent steps if
    # necessary
    #
    buildsystem.copy_dir_to(ctx, ctx.buildroot, 'src/config',
        pattern='*.fpc')
    # most of these ones are actually platform independent
    # just do the windows EXTERN to dllexport mapping
    # which is controlled by compile time switches anyhow
    # should probably move these out of config directory
    # they're put in config in case there really are any
    # platform mods.
    buildsystem.copy_to(ctx, ctx.buildroot/'config/target',
        Path('src/config/target/*.hpp').glob())

    # this is a hack: assume we're running on Unix.
    # later when Erick figures out how to fix this
    # we'd copy the win32 subdirectory entries instead
    if "posix" in target.platform:
      print("COPYING POSIX RESOURCE DATABASE")
      buildsystem.copy_to(ctx,
          ctx.buildroot / 'config', Path('src/config/unix/*.fpc').glob())

    # enable this on win32 **instead** of the above to copy fpc files 
    if "windows" in target.platform:
      print("COPYING WIN32 RESOURCE DATABASE")
      buildsystem.copy_to(ctx,
          ctx.buildroot / 'config', Path('src/config/win32/*.fpc').glob())

    # enable this on solaris to clobber any fpc files 
    # where the generic unix ones are inadequate
    #buildsystem.copy_to(ctx,
    #    ctx.buildroot / 'config', Path('src/config/solaris/*.fpc').glob())

    # enable this on osx to clobber any fpc files 
    # where the generic unix ones are inadequate
    if 'macosx' in target.platform:
        buildsystem.copy_to(ctx,
            ctx.buildroot / 'config', Path('src/config/macosx/*.fpc').glob())

    # extract the configuration
    iscr = call('buildsystem.iscr.Iscr', ctx)

    # convert the config into something iscr can use
    call('buildsystem.iscr.config_iscr_config', ctx, build, host, target)

    # re-extract packages if any of them changed
    ctx.scheduler.map(iscr, (src_dir(ctx)/'lpsrc/*.pak').glob())

    # overwrite or add *.fpc files to the config directory
    call('buildsystem.post_config.copy_user_fpcs', ctx)

    # make Felix representation of whole build config
    call('buildsystem.show_build_config.build',ctx)

    return Record(build=build, host=host, target=target), iscr

# ------------------------------------------------------------------------------

def build(ctx):
    """Compile Felix."""

    # configure the phases
    phases, iscr = configure(ctx)

    # --------------------------------------------------------------------------
    # Compile the compiler.

    compilers = call('buildsystem.flx_compiler.build_flx_drivers', ctx,
        phases.host)

    # --------------------------------------------------------------------------
    # Compile the runtime dependencies.

    call('buildsystem.judy.build_runtime', phases.host, phases.target)
    call('buildsystem.tre.build_runtime', phases.target)
    call('buildsystem.re2.build_runtime', phases.target)
    call('buildsystem.flx_glob.build_runtime', phases.host, phases.target)
    call('buildsystem.sqlite3.build_runtime', phases.host, phases.target)

    # --------------------------------------------------------------------------
    # Build the standard library.

    # copy files into the library
    buildsystem.copy_dir_to(ctx, ctx.buildroot, 'src/lib',
        pattern='*.{flx,flxh,files,html,sql,css,js,py,png}')
    
    # copy extra files for web
    #buildsystem.copy_dir_to(ctx, ctx.buildroot+'/lib/web', 'src/lib/web',
    #    pattern='*')
    #buildsystem.copy_dir_to(ctx, ctx.buildroot+'/lib/db', 'src/lib/db',
    #    pattern='*')
    #buildsystem.copy_dir_to(ctx, ctx.buildroot+'/lib/codec', 'src/lib/codec',
    #    pattern='*')
    #buildsystem.copy_dir_to(ctx, ctx.buildroot+'/lib/web', 'src/lib/io',
    #    pattern='*')
    #buildsystem.copy_dir_to(ctx, ctx.buildroot+'/lib/web', 'src/lib/collection',
    #    pattern='*')

    # copy tools
    buildsystem.copy_dir_to(ctx, ctx.buildroot, 'src/tools',
        pattern='*.flx{,h}')

    buildsystem.copy_dir_to(ctx, ctx.buildroot, 'src/wiki',
        pattern='*.*')

    for module in (
            'flx_stdlib',
            'bindings'):
        call('buildsystem.' + module + '.build_flx', phases.target)

    # --------------------------------------------------------------------------
    # Compile the runtime drivers.

    drivers = call('buildsystem.flx_drivers.build', phases.host, phases.target)

    # --------------------------------------------------------------------------
    # Compile the builder.

    flx_builder = call('buildsystem.flx.build', ctx,
        compilers.flxg, phases.target.cxx.static, drivers)

    flx_pkgconfig = call('buildsystem.flx.build_flx_pkgconfig',
        phases.host, phases.target, flx_builder)
    flx = call('buildsystem.flx.build_flx', phases.host, phases.target, flx_builder)

    # --------------------------------------------------------------------------
    # now, try building a file

    felix = call('fbuild.builders.felix.Felix', ctx,
        exe=ctx.buildroot / 'bin/flx',
        debug=ctx.options.debug,
        flags=['--test=' + ctx.buildroot])

    # --------------------------------------------------------------------------
    # build support tools
    # 
    # C tools
    #
    if 'windows' not in phases.target.platform:
      mk_daemon = call('buildsystem.mk_daemon.build', phases.target)
      timeout = call('buildsystem.timeout.build', phases.target)
    sqlite3_shell = call('buildsystem.sqlite3_shell.build', phases.target)

    # --------------------------------------------------------------------------
    # build support tools
    # 
    # Felix tools
    #
    call('buildsystem.tools.build', phases.target, felix)

    return phases, iscr, felix

# ------------------------------------------------------------------------------

@fbuild.target.register()
def doc(ctx):
    """Build the Felix documentation."""

    phases, iscr, felix = build(ctx)

    # copy documentation into target
    ctx.logger.log('building documentation', color='cyan')
    buildsystem.copy_dir_to(ctx, ctx.buildroot/'web', Path('src')/'wiki'/'html'/'images')
    # copy website index
    buildsystem.copy_to(ctx, ctx.buildroot, Path('src/*.html').glob())

    # copy website
    buildsystem.copy_dir_to(ctx, ctx.buildroot, Path('src')/'web')
    # copy wiki site files
    buildsystem.copy_dir_to(ctx, ctx.buildroot/'web', Path('src')/'wiki'/'html'/'css')

    buildsystem.copy_dir_to(ctx, ctx.buildroot/'web', Path('src')/'wiki'/'html'/'CodeMirror')
    buildsystem.copy_dir_to(ctx, ctx.buildroot/'web', Path('src')/'wiki'/'templates')

    # copy the entire src directory so the user can browse it not actually used
    # in the build process
    buildsystem.copy_dir_to(ctx, ctx.buildroot, 'src',
        pattern='*.{ml,mli,c,cc,cpp,h,hpp,flx,flxh}')

    # copy the entire test directory so the user can browse it
    buildsystem.copy_dir_to(ctx, ctx.buildroot, 'test',
        pattern='*.{flx,expect}')

    # copy the entire tut examples directory so the user can browse it
    buildsystem.copy_dir_to(ctx, ctx.buildroot, 'tut',
        pattern='*.{flx,expect}')

    # copy docs
    buildsystem.copy_to(ctx,
        ctx.buildroot / 'doc',
        Path('src/doc/*.fdoc').glob())

# ------------------------------------------------------------------------------

@fbuild.target.register()
def test(ctx):
    """Run the felix tests and other commands."""

    # Make sure we're built.
    phases, iscr, felix = build(ctx)

    from buildsystem.flx import test_flx, compile_flx

    failed = []

    def test(src):
        try:
            passed = test_flx(phases.target, felix, src)
        except fbuild.ConfigFailed as e:
            ctx.logger.log(str(e))
            passed = False
        return src, passed

    def test_compile(src):
        try:
            passed = compile_flx(phases.target, felix, src)
        except fbuild.ConfigFailed as e:
            ctx.logger.log(str(e))
            passed = False
        return src, passed

    # Run the dynamic loading tests first
    ctx.logger.log("\nRunning dynamic loading tests\n", color='red')
    try:
        lib1 = felix.compile('test/regress/drt/lib1.flx', static=False)
        lib2 = felix.compile('test/regress/drt/lib2.flx', static=False)
        print("lib1="+lib1)
        print("lib2="+lib2)
    except fbuild.ExecutionError as e:
        ctx.logger.log(e, verbose=1)
    else:
        if not test_flx(phases.target, felix, 'test/regress/drt/main1.flx',
                env={'lib1': lib1, 'lib2': lib2}):
            failed.append('test/regress/drt/main1.flx')

    srcs = [
      # CORE
      ('regress_rt' , Path.globall('test/regress/rt/*.flx')),
      ('regress_nd' , Path.globall('test/regress/nd/*.flx')),
      ('regress_stl' , Path.globall('test/regress/stl/*.flx')),

      ('tut_embedding' , Path.globall('tut/embedding/*.flx')),
      ('tut_migration', Path.globall('tut/migration/*.flx')),
      ('tut_tutorial', Path.globall('tut/tutorial/*.flx')),

      ('collection' , Path.globall('test/collection/*.flx')),
      #('drivers' , Path.globall('test/drivers/*.flx')),
      ('glob' , Path.globall('test/glob/*.flx')),
      ('judy' , Path.globall('test/judy/*.flx')),
      ('sqlite3' , Path.globall('test/sqlite/*.flx')),
      ('pthread' , Path.globall('test/pthread/*.flx')),
      ('stdlib' , Path.globall('test/stdlib/*.flx')),
      ('tre' , Path.globall('test/tre/*.flx')),
      ('web' , Path.globall('test/web/*.flx',exclude=['test/web/xml2-*.flx'])),

      # ASYNC I/O
      ('faio',Path.globall('test/faio/*.flx',exclude=['test/faio/posix-*.flx','test/faio/win-*.flx'])),
      ]

    gmp_h = config_call(
        'fbuild.config.c.gmp.gmp_h', 
        phases.target.platform,
        phases.target.c.static).header
    if gmp_h: ctx.logger.log("gmp supported",color='green')
    else: ctx.logger.log("gmp NOT supported",color='red')

    mman_h = config_call(
        'fbuild.config.c.posix04.sys_mman_h', 
        phases.target.platform,
        phases.target.c.static).header
    if mman_h: ctx.logger.log("mmap supported",color='green')
    else: ctx.logger.log("mmap NOT supported",color='red')

    libxml2_libxml_xmlexports_h = config_call(
        'fbuild.config.c.xml2.libxml2_libxml_xmlexports_h', 
        phases.target.platform,
        phases.target.c.static).header
    if libxml2_libxml_xmlexports_h: ctx.logger.log("libxml2 supported",color='green')
    else: ctx.logger.log("libxml2 NOT supported",color='red')

    zmq_h = config_call(
        'fbuild.config.c.zmq.zmq_h', 
        phases.target.platform,
        phases.target.c.static).header
    if zmq_h: ctx.logger.log("zmq supported",color='green')
    else: ctx.logger.log("zmq NOT supported",color='red')

    osrcs = [
      # EXTERNAL LIBS
      ('windows' in phases.target.platform,'faio_win', Path.globall('test/faio/win-*.flx')),
      ('posix' in phases.target.platform, 'faio_posix', Path.globall('test/faio/posix-*.flx')),
      (gmp_h,'gmp', Path.globall('test/gmp/*.flx')),
      (mman_h,'mmap', Path.globall('test/mmap/*.flx')),
      (libxml2_libxml_xmlexports_h,'xml2', Path.globall('test/web/xml2-*flx')),
      ]

    osrcs_compileonly = [
      (zmq_h,'zmq', Path.globall('test/zmq/*.flx')),
    ]
    #--------------------------------
    ctx.logger.log("\nRunning core tests\n", color='cyan')
    for name,paths in srcs:
      failed_srcs = []
      ctx.logger.log("Running test "+name, color='cyan')
      for src, passed in phases.target.ctx.scheduler.map(
          test,
          sorted(paths, reverse=True)):
        if not passed:
          failed_srcs.append(src)
          failed.append(src)

      if failed_srcs:
        ctx.logger.log('\nOf '+str (len (paths))+' tests')
        ctx.logger.log('\nThe following tests failed:')
        for src in failed_srcs:
          ctx.logger.log('  %s' % src, color='yellow')
      else:
        ctx.logger.log('All ' + str (len (paths))+' tests passed', color='cyan')

    ctx.logger.log("\nRunning optional tests\n", color='cyan')
    for flag,name,paths in osrcs:
      if flag:
        failed_srcs = []
        ctx.logger.log("Running test "+name, color='cyan')
        for src, passed in phases.target.ctx.scheduler.map(
            test,
            sorted(paths, reverse=True)):
          if not passed:
            failed_srcs.append(src)
            failed.append(src)

        if failed_srcs:
          ctx.logger.log('\nOf '+str (len (paths))+' tests')
          ctx.logger.log('\nThe following tests failed:')
          for src in failed_srcs:
            ctx.logger.log('  %s' % src, color='yellow')
        else:
          ctx.logger.log('All ' + str (len (paths))+' tests passed', color='cyan')
      else:
        ctx.logger.log("SKIPPING test "+name+" resource not availabe", color='red')

    ctx.logger.log("\nRunning optional compiler only tests\n", color='cyan')
    for flag,name,paths in osrcs_compileonly:
      if flag:
        failed_srcs = []
        ctx.logger.log("Compiling test "+name, color='cyan')
        for src, passed in phases.target.ctx.scheduler.map(
            test_compile,
            sorted(paths, reverse=True)):
          if not passed:
            failed_srcs.append(src)
            failed.append(src)

        if failed_srcs:
          ctx.logger.log('\nOf '+str (len (paths))+' tests')
          ctx.logger.log('\nThe following tests failed:')
          for src in failed_srcs:
            ctx.logger.log('  %s' % src, color='yellow')
        else:
          ctx.logger.log('All ' + str (len (paths))+' tests passed', color='cyan')
      else:
        ctx.logger.log("SKIPPING test "+name+" resource not availabe", color='red')


    if failed:
        ctx.logger.log('\n======================================')
        ctx.logger.log('\nThe following tests failed:')
        for src in failed:
            ctx.logger.log('  %s' % src, color='yellow')

# ------------------------------------------------------------------------------

@fbuild.target.register()
def speed(ctx):
    """Run the Felix performance tests."""

    # Make sure we're built.
    phases, iscr, felix = build(ctx)

    call('buildsystem.speed.run_tests', phases.target, felix)

# ------------------------------------------------------------------------------

@fbuild.target.register()
def install_lib(ctx, phases):
    """Install the Felix libraries into the lib directory."""

    # --------------------------------------------------------------------------
    # Install the libraries.

    from buildsystem.version import flx_version
    installdir = ctx.options.libdir / 'felix/felix-{}'.format(flx_version)

    ctx.logger.check(' * installing libraries into', installdir,
        color='cyan')

    if installdir.exists():
        raise fbuild.Error(
            'install directory {} already exists!'.format(installdir))

    (ctx.buildroot / 'bin').copytree(installdir / 'bin')
    (ctx.buildroot / 'lib').copytree(installdir / 'lib')
    (ctx.buildroot / 'config').copytree(installdir / 'config')

# ------------------------------------------------------------------------------

@fbuild.target.register()
def install_bin(ctx, phases):
    """Install the Felix binaries into the default bin directory."""

    ctx.logger.check(' * installing binaries into', ctx.options.bindir,
        color='cyan')

    if not ctx.options.bindir.exists():
        ctx.options.bindir.makedirs()

    if "windows" in phases.target.platform:

      #Windows binaries.

      (ctx.buildroot / 'bin/flx.exe').copy(ctx.options.bindir)
      (ctx.buildroot / 'bin/flx_ls.exe').copy(ctx.options.bindir)
      (ctx.buildroot / 'bin/flx_cp.exe').copy(ctx.options.bindir)
      (ctx.buildroot / 'bin/webserver.exe').copy(ctx.options.bindir)

      #These targets are not produced for "windows" in
      #phases.target.platform at this time.

      #(ctx.buildroot / 'bin/mk_daemon.exe').copy(ctx.options.bindir)
      #(ctx.buildroot / 'bin/timeout.exe').copy(ctx.options.bindir)

      #These exectuables I take to be webserver plugins. I assume this
      #step is not necessary on Linux due to the use of rpath?

      (ctx.buildroot / 'shlib/cpp2html.dll').copy(ctx.options.bindir)
      (ctx.buildroot / 'shlib/fdoc2html.dll').copy(ctx.options.bindir)
      (ctx.buildroot / 'shlib/flx2html.dll').copy(ctx.options.bindir)
      (ctx.buildroot / 'shlib/fpc2html.dll').copy(ctx.options.bindir)
      (ctx.buildroot / 'shlib/ocaml2html.dll').copy(ctx.options.bindir)
      (ctx.buildroot / 'shlib/py2html.dll').copy(ctx.options.bindir)

    else:

      #Binaries for all platforms not Windows.

      (ctx.buildroot / 'bin/flx').copy(ctx.options.bindir)
      (ctx.buildroot / 'bin/flx_ls').copy(ctx.options.bindir)
      (ctx.buildroot / 'bin/flx_cp').copy(ctx.options.bindir)
      (ctx.buildroot / 'bin/mk_daemon').copy(ctx.options.bindir)
      (ctx.buildroot / 'bin/timeout').copy(ctx.options.bindir)
      (ctx.buildroot / 'bin/webserver').copy(ctx.options.bindir)

# ------------------------------------------------------------------------------

@fbuild.target.register()
def install(ctx):
    """Install Felix."""

    # Make sure we're built.
    phases, iscr, felix = build(ctx)

    install_lib(ctx, phases)
    install_bin(ctx, phases)

# ------------------------------------------------------------------------------

@fbuild.target.register()
def dist(ctx):
    """Creates tarball and zip distribution files."""

    phases, iscr = configure(ctx)
    from buildsystem.version import flx_version

    # Find the git executable.
    git = fbuild.builders.find_program(ctx, ['git'])

    # Grab our revision name from git.
    flx_version = ctx.execute([git, 'describe'], quieter=1)[0].decode().strip()

    ctx.logger.log('Packing Source as Version: %s' % flx_version)

    call('buildsystem.dist.dist_tar', ctx, git, flx_version)
    call('buildsystem.dist.dist_zip', ctx, git, flx_version)
