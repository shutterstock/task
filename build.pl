#!/usr/bin/env PLENV_VERSION=5.8.9 perl
use strict;
use File::pushd;
use File::Find;
use Module::CoreList qw(is_core);

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

sub pm_to_mod {
    local $_ = shift;
    s!/!::!g;
    s/\.pm$//;
    $_
}

system('fatpack trace bin/task');
system('fatpack packlists-for $(cat fatpacker.trace) >> packlists');

# add some stuff to the fatlib to get Moo to fatpack
system('fatpack packlists-for strictures.pm Moo.pm parent.pm >> packlists');
if ($] < 5.010) {
    system('fatpack packlists-for Algorithm/C3.pm Class/C3.pm MRO/Compat.pm >> packlists');
}

open my $packlists, '<', 'packlists' or die "$! opening packlists";
chomp (my @packlists = <$packlists>);
{
    local @ARGV = @packlists;
    local $^I = "";
    while (<>) {
        next if /\.pod$/;
        next if /\.so$/;
        next if is_core(pm_to_mod($_));
        print;
    }
}

system('fatpack tree $(cat packlists)');
system('cp -r lib/* fatlib');

mkdir ".build", 0777;

system qw(cp -r fatlib .build/);

my $fatpack = do {
    my $dir = pushd '.build';

    my @files;
    my $want = sub {
        push @files, $_ if /\.pm$/;
    };

    find({ wanted => $want, no_chdir => 1 }, "fatlib", "lib");
    system 'perlstrip', '--cache', '-v', @files;

    `fatpack file`;
};

=end 

=cut

generate_file('bin/task', "task", $fatpack);
chmod 0755, "task";
