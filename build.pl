#!/usr/bin/env PLENV_VERSION=5.8.9 perl
use strict;
use File::pushd;
use File::Find;

sub generate_file {
    my($base, $target, $fatpack, $shebang_replace) = @_;

    open my $in,  "<", $base or die $!;
    open my $out, ">", "$target.tmp" or die $!;

    print STDERR "Generating $target from $base\n";

    while (<$in>) {
        next if /Auto-removed/;
        s|^#!/usr/bin/env perl|$shebang_replace| if $shebang_replace;
        s/DEVELOPERS:.*/DO NOT EDIT -- this is an auto generated file/;
        s/.*__FATPACK__/$fatpack/;
        print $out $_;
    }

    close $out;

    unlink $target;
    rename "$target.tmp", $target;
}

system('fatpack trace bin/task');
system('fatpack tree $(fatpack packlists-for $(cat fatpacker.trace))');

# add some stuff to the fatlib to get Moo to fatpack
system('fatpack tree $(fatpack packlists-for strictures.pm Moo.pm parent.pm)');
if ($] < 5.010) {
    system('fatpack tree $(fatpack packlists-for Algorithm/C3.pm Class/C3.pm MRO/Compat.pm)');
}

my $fatpack = `fatpack file bin/task`;

mkdir ".build", 0777;
system qw(cp -r fatlib lib .build/);

my $fatpack_compact = do {
    my $dir = pushd '.build';

    my @files;
    my $want = sub {
        push @files, $_ if /\.pm$/;
    };

    find({ wanted => $want, no_chdir => 1 }, "fatlib", "lib");
    system 'perlstrip', '--cache', '-v', @files;

    `fatpack file`;
};

generate_file('bin/task', "task", $fatpack_compact);
chmod 0755, "task";
