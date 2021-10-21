#!/usr/bin/perl
use strict;
use warnings;

#use C::DynaLib qw(DeclareSub PTR_TYPE);
use DynaLoader;
use Config;
use Carp::Always;
use Data::Dump;
$|++;

sub DeclareXSub {
    my %FARPROC;
    $FARPROC{namespace} = $_[0];
    $FARPROC{lib}       = DynaLoader::dl_load_file( ( split( "!", $_[1] ) )[0] ) if $_[1] =~ m/\!/;
    $FARPROC{procptr}
        = defined( $FARPROC{lib} ) ?
        DynaLoader::dl_find_symbol( $FARPROC{lib}, ( split( "!", $_[1] ) )[1] ) :
        $_[1];
    return if !defined( $FARPROC{procptr} );
    $FARPROC{args} = $_[2];
    $FARPROC{rtn}  = $_[3] // '';
    if ( $^O =~ /win32/i ) {
        $FARPROC{conv}
            = defined( $_[4] ) ? $_[4] : "s";    # default calling convention: Win32  __stdcall
    }
    else {
        $FARPROC{conv}
            = defined( $_[4] ) ? $_[4] : "c";    # default calling convention: UNIX   __cdecl
    }
    my $stackIN = '';
    my @stridx;
    my @bytype;
    my $bytspushed = 0;
    my $asmcode = "\x90";     # machine code starts , this can also be \xcc -user breakpoint
    my @Args    = split( ",", $FARPROC{args} );
    @Args = reverse @Args;    # pushing order last args first

    foreach my $arg (@Args) {
        $stackIN .= "\x68" . pack( "I", 0 );    # 4 byte push
        $stackIN .= "\x68" . pack( "I", 0 )
            if ( $arg =~ m/d|q/i );             # another 4 byte push for doubles,quads
        push( @stridx, length($stackIN) - 4 + 1 ) if $arg !~ m/d|q/i;
        push( @stridx, length($stackIN) - 9 + 1 ) if $arg =~ m/d|q/i;
        push( @bytype, "byval" )                  if $arg =~ m/v|l|i|c|d|q/i;
        push( @bytype, "byref" )                  if $arg =~ m/p|r/i;           # 32 bit pointers
        $bytspushed += 4;                           # 4 byte aligned
        $bytspushed += 4 if ( $arg =~ m/d|q/i );    # another 4 for doubles or quads
    }
    $FARPROC{sindex}   = \@stridx;
    $FARPROC{types}    = \@bytype;
    $FARPROC{stklen}   = $bytspushed;
    $FARPROC{edi}      = "null";                       # 4 bytes long !!! ,how convenient
    $FARPROC{esi}      = "null";
    $FARPROC{RetEAX}   = "null";                       # usual return register
    $FARPROC{RetEDX}   = "null";
    $FARPROC{Ret64bit} = "nullnull";                   # save double or quad returns
    $FARPROC{stackOUT} = "\x00" x $bytspushed;
    $asmcode .= "$stackIN";
    $asmcode .= "\xb8" . CInt( $FARPROC{procptr} );    # mov eax, $procptr
    $asmcode .= "\xFF\xd0";                            # call eax  => CALL THE PROCEDURE

    # --- save return values info into Perl Strings, including the stack:
    # - some calls return values back to the stack, overwriting the original args
    $asmcode .= "\xdd\x1d" . CPtr( $FARPROC{Ret64bit} )
        if $FARPROC{rtn} =~ m/d/i;    # fstp qword [$FARPROC{Ret64bit}]
    $asmcode .= "\xa3" . CPtr( $FARPROC{RetEAX} );                  # mov [$FARPROC{RetEAX}], eax
    $asmcode .= "\x89\x15" . CPtr( $FARPROC{RetEDX} );              # mov [$FARPROC{RetEDX}], edx
    $asmcode .= "\x89\x35" . CPtr( $FARPROC{esi} );                 # mov [$FARPROC{esi}], esi
    $asmcode .= "\x89\x3d" . CPtr( $FARPROC{edi} );                 # mov [$FARPROC{edi}], edi
    $asmcode .= "\x8d\xb4\x24"       if $FARPROC{conv} =~ m/s/i;    #
    $asmcode .= CInt( -$bytspushed ) if $FARPROC{conv} =~ m/s/i;    # lea   esi,[esp-$bytspushed]
    $asmcode .= "\x89\xe6"           if $FARPROC{conv} =~ m/c/i;    # mov   esi,esp
    $asmcode .= "\xbf" . CPtr( $FARPROC{stackOUT} );    # mov edi, [$FARPROC{stackOUT}]
    $asmcode .= "\xb9" . CInt($bytspushed);             # mov ecx,$bytspushed
    $asmcode .= "\xfc";                                 # cld
    $asmcode .= "\xf3\xa4";                             # rep movsb [edi],[esi] => copy the stack
    $asmcode .= "\x8b\x3d" . CPtr( $FARPROC{edi} );     # mov edi,[$FARPROC{edi}]
    $asmcode .= "\x8b\x35" . CPtr( $FARPROC{esi} );     # mov esi,[$FARPROC{esi}]
    $asmcode .= "\x81\xc4" . CInt($bytspushed)
        if $FARPROC{conv} =~ m/c/i;                     # add esp,$bytspushed : __cdecl
    $asmcode .= "\xc3";                                 # ret  __stdcall or __cdecl
    $FARPROC{ASM} = $asmcode;
    $FARPROC{coderef}
        = DynaLoader::dl_install_xsub( $FARPROC{namespace}, SVPtr( $FARPROC{ASM} ), __FILE__ );
    $FARPROC{Call} = sub {
        my @templates = reverse split( ",", $FARPROC{args} );
        my @args      = reverse @_;                             # parameters get pushed last first;

        # --- edit the machine language pushes with @args ---
        for ( my $index = 0; $index < scalar( @{ $FARPROC{sindex} } ); ++$index ) {
            my @a = split( ":", $args[$index] ) if $args[$index] =~ m/\:/;
            if ( $templates[$index] eq "ss" ) { $args[$index] = $a[0] << 16 + $a[1]; }
            if ( $templates[$index] eq "cccc" ) {
                $args[$index] = $a[0] << 24 + $a[1] << 16 + $a[2] << 8 + $a[3];
            }
            if ( $templates[$index] eq "ccc" ) { $args[$index] = $a[0] << 16 + $a[1] << 8 + $a[2]; }
            if ( $templates[$index] eq "cc" )  { $args[$index] = $a[0] << 8 + $a[1]; }
            if ( $templates[$index] eq "scc" ) { $args[$index] = $a[0] << 16 + $a[1] << 8 + $a[2]; }
            if ( $templates[$index] eq "ccs" ) {
                $args[$index] = $a[0] << 24 + $a[1] << 16 + $a[2];
            }
            if ( $templates[$index] eq "sc" ) { $args[$index] = $a[0] << 16 + $a[1]; }
            if ( $templates[$index] eq "cs" ) { $args[$index] = $a[0] << 16 + $a[1]; }
            if ( $templates[$index] =~ m/d|q/i ) {
                $args[$index] = pack( "d", $args[$index] ) if $templates[$index] =~ m/d/i;
                my $Quad = $args[$index] if $templates[$index] =~ m/q/i;
                substr(
                    $FARPROC{ASM}, $FARPROC{sindex}->[$index] + 5,
                    4,             substr( $args[$index], 0, 4 )
                ) if $templates[$index] =~ m/d/i;
                substr( $FARPROC{ASM}, $FARPROC{sindex}->[$index],
                    4, substr( $args[$index], 4, 4 ) )
                    if $templates[$index] =~ m/d/i;
                substr( $FARPROC{ASM}, $FARPROC{sindex}->[$index] + 5, 4, substr( $Quad, 0, 4 ) )
                    if $templates[$index] =~ m/q/i;
                substr( $FARPROC{ASM}, $FARPROC{sindex}->[$index], 4, substr( $Quad, 4, 4 ) )
                    if $templates[$index] =~ m/q/i;
            }
            else {
                substr( $FARPROC{ASM}, $FARPROC{sindex}->[$index], 4, CInt( $args[$index] ) )
                    if $FARPROC{types}->[$index] eq "byval";
            }
            substr( $FARPROC{ASM}, $FARPROC{sindex}->[$index], 4, CPtr( $args[$index] ) )
                if $FARPROC{types}->[$index] eq "byref";
        }
        my $ret = &{ $FARPROC{coderef} };    # Invoke it
        return $ret;    # usually EAX==return value - not as reliabe as $FARPROC{RetEAX}
    };
    return \%FARPROC;  # make an object out of a hash( has 1 XSUB, 1 sub, 2 arrays, several scalars)
}

sub SVPtr {
    return unpack( "I", pack( "p", $_[0] ) );
}

sub CInt {
    return pack( "i", $_[0] );
}

sub CPtr {
    return pack( "p", $_[0] );
}
#####################################3
#my ( $call_argv_ref, $get_context_ref, $Tstack_sp_ptr_ref, $ptrptrargs );

use File::Basename;

push @DynaLoader::dl_library_path, dirname($^X) ;  # ActiveState's Win32 perl dll location
my $perldll;
($perldll = $Config{libperl}) =~ s/\.lib/\.$Config{so}/i;
$perldll = DynaLoader::dl_findfile($perldll);
my $perlAPI =  DynaLoader::dl_load_file($perldll);
my $call_argv_ref = DynaLoader::dl_find_symbol($perlAPI,"Perl_call_argv");  # embed.h
my $get_context_ref = DynaLoader::dl_find_symbol($perlAPI,"Perl_get_context");
my $Tstack_sp_ptr_ref = DynaLoader::dl_find_symbol($perlAPI,"Perl_Istack_sp_ptr"); # perlapi.h
if (!$Tstack_sp_ptr_ref){$Tstack_sp_ptr_ref = DynaLoader::dl_find_symbol($perlAPI,"Perl_Tstack_sp_ptr");}
#####
my$arg1="Assembly";
my$arg2="Callback",
my$arg3="To";
my$arg4="Perl";
my $ptrptrargs = pack("PPPPI",$arg1,$arg2,$arg3,$arg4,0);
my $cbname      = __PACKAGE__ . "::" . "asm2perl";
my $cb_asm2perl = "\x90" .                           #
    "\x68" .
    pack( "I", $call_argv_ref ) .    # push [Perl_call_argv()]  PUSH POINTERS TO PERL XS FUNCTIONS
    "\x68" . pack( "I", $get_context_ref ) .      # push [Perl_get_context()]
    "\x68" . pack( "I", $Tstack_sp_ptr_ref ) .    # push [Perl_(T|I)stack_sp_ptr()]
    "\x55" .                                      # push ebp
    "\x89\xE5" .                                  # mov ebp,esp   use ebp to access XS

    # ----------------- dSP; MACRO starts -------------------
    "\xff\x55\x08" .    # call dword ptr [ebp+8] => call Perl_get_context()
    "\x50" .            # push eax
    "\xff\x55\x04" .    # call dword ptr [ebp+4] => call Perl_Tstack_sp_ptr()
    "\x59" .            # pop  ecx
    "\x8B\x00" .        # mov  eax,dword ptr [eax]
    "\x89\x45\xec" .    # mov  dword ptr [sp],eax  => local copy of SP

    # -------------- perl_call_argv("callbackname",G_DISCARD,char **args) -----
    "\x68" . pack( "P", $ptrptrargs ) .    # push char **args
    "\x68\x02\x00\x00\x00" .               # push G_DISCARD
    "\x68" . pack( "p", $cbname ) .        # push ptr to name of perl subroutine
    "\xff\x55\x08" .                       # call Perl_get_context()
    "\x50" .                               # push eax
    "\xff\x55\x0c" .                       # call perl_call_argv:   call dword ptr [ebp+0x0c]
    "\x83\xc4\x10" .                       # add esp,10  CDECL call we maintain stack
    "\x89\xec" .                           # mov esp,ebp
    "\x5D" .                               # pop ebp
    "\x83\xc4\x0c" .                       # add esp,0c
    "\xc3";                                # ret
print ">>> internal XSUB\'s(ASM routine) call/callback test  <<<\n";
print "---Perl calls assembly calls back to Perl test:\n";
warn 0x00000000558d91a0;

my $cbtest = DeclareXSub( __PACKAGE__ . "::cbtest", SVPtr($cb_asm2perl), '' );
#$cbtest->{Call}();
cbtest();

sub asm2perl {
    my $lastcaller = ( caller(1) )[3];
    print "called from ", $lastcaller . "(\@_ = ", join( " ", @_ ), ")\n";
}

__END__
use strict;
use warnings;
use experimental 'signatures';
use HTTP::Tiny;
use Path::Tiny qw[path];
use Archive::Extract;
#
use ExtUtils::CBuilder;
#
use Config;
use Module::Build::Tiny;
#
use Carp::Always;
use Alien::gmake;
#
$|++;
#
#$ENV{TSDL2} = './temp/';
#
my $basedir  = Path::Tiny->cwd;    #->child('sdl_libs');
my $tempdir  = $ENV{TSDL2} ? $basedir->child( $ENV{TSDL2} ) : Path::Tiny->tempdir();
my $sharedir = $basedir->child('share');

#`rm -rf $sharedir`;
#
my $quiet = $ENV{QSDL2} // 0;
#
#die $sharedir;
#
my @libraries   = qw[SDL2 SDL2_image SDL2_mixer SDL2_ttf  SDL2_gfx];
my %libversions = (                                                    # Allow custom lib versions
    SDL2       => $ENV{VSDL2}       // '2.0.16',
    SDL2_mixer => $ENV{VSDL2_mixer} // '2.0.4',
    SDL2_ttf   => $ENV{VSDL2_ttf}   // '2.0.15',
    SDL2_image => $ENV{VSDL2_image} // '2.0.5',
    SDL2_gfx   => $ENV{VSDL2_gfx}   // '1.0.4'
);
my %sdl2_urls = (
    SDL2       => 'https://www.libsdl.org/release/SDL2-%s%s',
    SDL2_mixer => 'https://www.libsdl.org/projects/SDL_mixer/release/SDL2_mixer-%s%s',
    SDL2_ttf   => 'https://www.libsdl.org/projects/SDL_ttf/release/SDL2_ttf-%s%s',
    SDL2_image => 'https://www.libsdl.org/projects/SDL_image/release/SDL2_image-%s%s',
    SDL2_gfx   => 'https://github.com/a-hurst/sdl2gfx-builds/releases/download/%s/SDL2_gfx-%s%s'
);
my %override_urls = (    # Allow custom download URLs for libs (github releases, tags, etc.)
    ( defined $ENV{DSDL2}       ? ( SDL2       => $ENV{DSDL2} )       : () ),
    ( defined $ENV{DSDL2_mixer} ? ( SDL2_mixer => $ENV{DSDL2_mixer} ) : () ),
    ( defined $ENV{DSDL2_ttf}   ? ( SDL2_ttf   => $ENV{DSDL2_ttf} )   : () ),
    ( defined $ENV{DSDL2_image} ? ( SDL2_image => $ENV{DSDL2_image} ) : () ),
    ( defined $ENV{DSDL2_gfx}   ? ( SDL2_gfx   => $ENV{DSDL2_gfx} )   : () ),
    libwebp => 'http://storage.googleapis.com/downloads.webmproject.org/releases/webp/%s.tar.gz'
);
#
my ( $cflags, $lflags )
    = $sharedir->child('config.ini')->is_file ?
    $sharedir->child('config.ini')->lines( { chomp => 1, count => 2 } ) :
    ();
#
sub SDL_Build () {

    #buildDLLs($^O) if !$sharedir->is_dir;    #$ARGV[0]//'build' eq 'build';
    Module::Build::Tiny::Build();
}

sub SDL_Build_PL {
    my $meta = Module::Build::Tiny::get_meta();
    printf "Creating new 'Build' script for '%s' version '%s'\n", $meta->name, $meta->version;

    #my $dir = $meta->name eq 'Module-Build-Tiny' ? "use lib 'lib';" : '"./";';
    Module::Build::Tiny::write_file( 'Build',
        "#!perl\nuse lib '.';\nuse builder::SDL2;\nbuilder::SDL2::SDL_Build();\n" );
    Module::Build::Tiny::make_executable('Build');
    my @env
        = defined $ENV{PERL_MB_OPT} ? Module::Build::Tiny::split_like_shell( $ENV{PERL_MB_OPT} ) :
        ();
    Module::Build::Tiny::write_file( '_build_params',
        Module::Build::Tiny::encode_json( [ \@env, \@ARGV ] ) );
    $meta->save(@$_) for ['MYMETA.json'], [ 'MYMETA.yml' => { version => 1.4 } ];
}

sub buildDLLs ($platform_name) {
    for my $d ( $tempdir, $sharedir ) {

        #$d->remove_tree( { safe => 0, verbose => 1 } );
        $d->mkpath( { verbose => 1 } );
    }
    if ( 'MSWin32' eq $platform_name ) {
        my $x64  = $Config{archname} =~ /^MSWin32-x64/ && $Config{ptrsize} == 8;
        my $http = HTTP::Tiny->new;
        for my $lib (@libraries) {

            # Download zip archive containing library
            my $libversion = $libversions{$lib};
            my $liburl     = sprintf $sdl2_urls{$lib},
                $lib eq 'SDL2_gfx' ?
                ( $libversion, $libversion, $x64 ? '-win32-x64.zip' : '-win32-x86.zip' ) :
                ( 'devel-' . $libversion, '-mingw.tar.gz' );
            printf 'Downloading %s %s... ', $lib, $libversion;
            my $sourcepath
                = fetch_source( $liburl, $tempdir->child( Path::Tiny->new($liburl)->basename ) );
            if ($sourcepath) {
                if ( $sourcepath->child('Makefile')->is_file ) {
                    my $orig_path = Path::Tiny->cwd->absolute;
                    chdir $sourcepath;
                    system Alien::gmake->exe, 'install-package',
                        'arch=' . ( 0 && $x64 ? 'i686-w64-mingw32' : 'x86_64-w64-mingw32' ),
                        'prefix=' . $sharedir->absolute->stringify;
                    chdir $orig_path;
                }
            }
            else {
                die 'oops!';
            }
        }
        $cflags
            = ( $x64 ? '-m64' : '-m32' ) .
            ' -Dmain=SDL_main -I' . $sharedir->child( 'include', 'SDL2' )->absolute .
            ' -I' . $sharedir->child('include')->absolute;
        $lflags = ( $x64 ? '-m64' : '-m32' ) .
            ' -lmingw32 -lSDL2main -lSDL2 -mwindows -L' . $sharedir->child('lib')->absolute;

#' -Wl,--dynamicbase -Wl,--nxcompat -lm -ldinput8 -ldxguid -ldxerr8 -luser32 -lgdi32 -lwinmm -limm32 -lole32 -loleaut32 -lshell32 -lsetupapi -lversion -luuid ';
# TODO: store in config file:
# cflags = '-I'
#ld flags = '-lmingw32 -lSDL2main -lSDL2 -ggdb3 -O0 --std=c99 -lSDL2_image -lm  -Wall'
    }
    else {
        my $suffix = '.tar.gz';    # source code

        # Set required environment variables for custom prefix
        my %buildenv      = %ENV;
        my $pkgconfig_dir = $sharedir->child( 'lib', 'pkgconfig' );
        my $builtlib_dir  = $sharedir->child('lib');
        my $include_dir   = $sharedir->child('include');
        #
        $buildenv{PKG_CONFIG_PATH} .= $pkgconfig_dir->absolute;
        $buildenv{LD_LIBRARY_PATH} .= $builtlib_dir->absolute;
        $buildenv{LDFLAGS}         .= '-L' . $builtlib_dir->absolute;
        $buildenv{CPPFLAGS}
            .= '-I' . $include_dir->absolute . ' -I' . $include_dir->parent->absolute;
        #
        my $x64 = $Config{archname} =~ /^MSWin32-x64/ && $Config{ptrsize} == 8;
        #
        my $outdir = $sharedir->child('download');    #Path::Tiny->tempdir;
        $sdl2_urls{SDL2_gfx} = 'http://www.ferzkopp.net/Software/SDL2_gfx/SDL2_gfx-%s%s';
        for my $lib (@libraries) {
            my $libversion = $libversions{$lib};
            printf 'Downloading %s %s... ', $lib, $libversion;
            my $liburl    = $override_urls{$lib} // sprintf $sdl2_urls{$lib}, $libversion, $suffix;
            my $libfolder = $lib . '-' . $libversion;
            my $sourcepath
                = fetch_source( $liburl, $tempdir->child( Path::Tiny->new($liburl)->basename ) );
            if ( !$sourcepath ) {
                die 'something went wrong!';
            }

            # Check for any external dependencies and set correct build order
            my @dependencies;
            my @ignore = (
                'libvorbisidec'    # only needed for special non-standard builds
            );
            my @build_first = qw[zlib harfbuzz];
            my @build_last  = qw[libvorbis opusfile flac];
            my $ext_dir     = $sourcepath->child('external');
            if ( $ext_dir->is_dir ) {
                my @dep_dirs = $ext_dir->children();
                my ( @deps_first, @deps, @deps_last );
                for my $dep ( grep { $_->is_dir } @dep_dirs ) {
                    my $dep_path = $ext_dir->child($dep);
                    next if !$dep_path->is_dir;
                    my ( $depname, $depversion ) = split '-', $dep->basename;
                    next if grep { $_ eq $depname } @ignore;
                    if ( grep { $_ eq $depname } @build_first ) {
                        push @deps_first, $dep;
                    }
                    elsif ( grep { $_ eq $depname } @build_last ) {
                        push @deps_last, $dep;
                    }
                    else { push @deps, $dep }
                }
                @dependencies = ( @deps_first, @deps, @deps_last );
            }

            # Build any external dependencies
            my %extra_args
                = ( opusfile => ['--disable-http'], freetype => ['--enable-freetype-config'] );
            for my $dep (@dependencies) {
                my ( $depname, $depversion ) = split '-', $dep;
                my $dep_path = $ext_dir->child($dep);
                if ( defined $override_urls{$depname} ) {
                    printf "======= Downloading alternate source for %s =======\n", $dep;
                    my $liburl = sprintf $override_urls{$depname}, $dep;
                    path($dep_path)->move( $dep_path . '_bad' );
                    $dep_path
                        = fetch_source( $liburl,
                        $ext_dir->child( Path::Tiny->new($liburl)->basename ),
                        );
                }
                printf "======= Compiling %s dependency %s =======\n", $lib, $dep;
                my $xtra_args;
                if ( grep { $_ eq $depname } keys %extra_args ) {
                    $xtra_args = $extra_args{$depname};
                }
                die 'Error building ' . $dep
                    unless make_install_lib( $dep_path, $sharedir, \%buildenv, $xtra_args );
                printf "\n======= %s built sucessfully =======\n", $dep;
            }

            # Build the library
            printf "======= Compiling %s %s =======\n", $lib, $libversion;
            my $xtra_args = ();
            $xtra_args = [ '--with-ft-prefix=' . $sharedir->absolute ] if $lib eq 'SDL2_ttf';
            die 'Error building ' . $lib
                unless make_install_lib( $sourcepath, $sharedir, \%buildenv, $xtra_args );
            printf "\n======= %s %s built sucessfully =======\n", $lib, $libversion;
            chdir $basedir->absolute;
        }

        # TODO: store in config file
        #chdir $basedir->child('share', 'bin');
        #warn `./sdl2_config --prefix=%s --cflags`;
        #warn `./sdl2_config --prefix=%s --libs`;
        chdir $sharedir->child( 'lib', 'pkgconfig' );
        $ENV{PKG_CONFIG_PATH} .= $sharedir->child( 'lib', 'pkgconfig' )->absolute;
        $cflags = `pkg-config sdl2.pc SDL2_gfx.pc SDL2_image.pc SDL2_mixer.pc SDL2_ttf.pc --cflags`;
        chomp $cflags;
        $lflags = `pkg-config sdl2.pc SDL2_gfx.pc SDL2_image.pc SDL2_mixer.pc SDL2_ttf.pc --libs`;
        chomp $lflags;
        chdir $basedir->absolute;
    }
    $sharedir->child('config.ini')->spew_raw("$cflags\n$lflags");
}

sub make_install_lib ( $src_path, $prefix, $buildenv, $extra_args = () ) {
    my $orig_path = Path::Tiny->cwd->absolute;
    local %ENV = %$buildenv;
    chdir $src_path;
    my $success = 0;
    for my $cmd (
        [ './configure', ( $quiet ? '--silent' : () ), '--prefix=' . $prefix ],
        [ Alien::gmake->exe, ( $quiet ? '--silent' : () ), '-j10' ],
        [ Alien::gmake->exe, ( $quiet ? '--silent' : () ), 'install' ]
    ) {
        if ( $cmd->[0] eq './configure' && $extra_args ) {
            push @$cmd, @$extra_args;
        }
        $success = 1 if system(@$cmd) == 0;
        if ( $? == -1 ) {
            print "failed to execute: $!\n";
            last;
        }
        elsif ( $? & 127 ) {
            printf "child died with signal %d, %s coredump\n", ( $? & 127 ),
                ( $? & 128 ) ? 'with' : 'without';
            last;
        }
        else {
            printf "child exited with value %d\n", $? >> 8;
        }
    }
    chdir $orig_path;
    return $success;
}

sub fetch_source ( $liburl, $outfile ) {
    CORE::state $http //= HTTP::Tiny->new();

    #printf '%s => %s ... ', $liburl, $outfile;
    $outfile->parent->mkpath;
    my $response = $http->mirror( $liburl, $outfile, {} );
    if ( $response->{success} ) {    #ddx $response;
        CORE::say 'okay';
        my $outdir = $outfile->parent

            #->child(
            #		$outfile->basename('.tar.gz', '.zip'))
            ;
        printf 'Extracting to %s... ', $outdir;
        my $ae = Archive::Extract->new( archive => $outfile );
        if ( $ae->extract( to => $outdir ) ) {
            CORE::say 'okay';
            return Path::Tiny->new( $ae->extract_path );
        }
        else {
            CORE::say 'oops!';
        }
    }
    else {
        CORE::say 'oops!';
        ddx $response;
    }
}

sub build_thread_wrapper {
    my $c = Path::Tiny->cwd->child('thread_wrapper.c');
    $c->spew_raw( <<'END');
#include <SDL.h>
#include <stdio.h>

#define SCREEN_WIDTH 640
#define SCREEN_HEIGHT 480

int window( const char * title ) {
  SDL_Window* window = NULL;
  SDL_Surface* screenSurface = NULL;
  if (SDL_Init(SDL_INIT_VIDEO) < 0) {
    fprintf(stderr, "could not initialize sdl2: %s\n", SDL_GetError());
    return 1;
  }
  window = SDL_CreateWindow(
			    title,
			    SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED,
			    SCREEN_WIDTH, SCREEN_HEIGHT,
			    SDL_WINDOW_SHOWN
			    );
  if (window == NULL) {
    fprintf(stderr, "could not create window: %s\n", SDL_GetError());
    return 1;
  }
  screenSurface = SDL_GetWindowSurface(window);
  SDL_FillRect(screenSurface, NULL, SDL_MapRGB(screenSurface->format, 0xFF, 0xFF, 0xFF));
  SDL_UpdateWindowSurface(window);
  SDL_Delay(2000);
  SDL_DestroyWindow(window);
  SDL_Quit();
  return 0;
}
END
    use FFI::Build;
    my $build = FFI::Build->new(
        'thread_wrapper',
        cflags => $cflags,
        dir    => $sharedir->child('lib')->absolute->stringify,

        # export # TODO
        libs    => $lflags,
        source  => [ $c->absolute->stringify ],
        verbose => $quiet ? 0 : 2
    );

    # $lib is an instance of FFI::Build::File::Library
    my $lib = $build->build;

    #my $ffi = FFI::Platypus->new( api => 1 );
    # The filename will be platform dependant, but something like libfrooble.so or frooble.dll
    #$ffi->lib( $lib->path );
    warn $lib;
    return $lib;

=cut
    my $b = ExtUtils::CBuilder->new();
    $b->link(
        module_name => 'thread_wrapper',
        objects     => [
            $b->compile(
                source               => $c->absolute->stringify,
                extra_compiler_flags => $cflags,
                'C++'                => 1,
            )
        ],
        extra_compiler_flags => $lflags
    );

    #warn '$lib_file: ' . $lib_file;

=cut

}
warn buildDLLs($^O);
use Data::Dump;
ddx build_thread_wrapper();
if ( $^O eq 'MSWin32' ) {
    eval 'use Win32::API';
    warn $sharedir->child( 'bin', 'SDL2_ttf.dll' )->absolute->stringify;
	my $function
        = Win32::API::More->new( $sharedir->child( 'bin', 'SDL2_ttf.dll' )->absolute->stringify,
        , 'int TTF_Init( )' );
    die "Error: " . ( Win32::FormatMessage( Win32::GetLastError() ) ) if !$function;
    use Data::Dump;
    ddx $function;
    ddx $function->Call();
}
