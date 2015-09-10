package File::Create::Layout;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;
use Log::Any::IfLOG '$log';

use File::chdir;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(
                       create_files_using_layout
               );

our %SPEC;

my %arg_layout = (
    layout => {
        summary => 'Layout',
        description => <<'_',

See the module documentation for the format/specification of layout.

_
        schema => 'str*',
        req => 1,
        pos => 0,
    },
);

sub _decode_json {
    state $json = do {
        require JSON;
        JSON->new->allow_nonref;
    };
    $json->decode(shift);
}

sub _parse_layout {
    my $layout = shift;

    my @indents;
    my @res;
    my $linum = 0;
    my $prev_is_dir = 0;
    for my $line (split /^/, $layout) {
        chomp $line;
        my $orig_line = $line;

        $linum++;
        next if $line =~ /\A\s*\z/;
        next if $line =~ /\A\s*#/;

        $line =~ s/\A(\s*)//;
        my $cur_indent = $1;
        die "(layout):$linum: Tabs are not allowed: $orig_line"
            if $cur_indent =~ /\t/;

        $cur_indent = length($cur_indent);

        if (!@indents) {
            push @indents, $cur_indent;
        }

        if ($cur_indent > $indents[-1]) {
            # indent is deeper than previous spec-line, we require that the
            # previous spec-line is directory
            die "(layout):$linum: More indented than previous spec-line, but ".
                "previous spec-line is not a directory: $orig_line"
                unless $prev_is_dir;
            push @indents, $cur_indent;
        } elsif ($cur_indent < $indents[-1]) {
            # indent is shallower than previous spec-line, find previous level
            my $found;
            for my $i (reverse 0..$#indents) {
                if ($cur_indent == $indents[$i]) {
                    $found++;
                    splice @indents, $i;
                    last;
                }
            }
            die "(layout):$linum: Invalid indent, must return to one of ".
                "previous levels' indent: $orig_line" unless $found;
        }

        # parse filename
        my $name;
        if ($line =~ /\A"/) {
            $line =~ s#\A(".*?(?<!\\)(?:\\\\)*")##
                or die "(layout):$linum: Invalid quoted filename: $orig_line";
            $name = $1;
            eval { $name = _decode_json($name) };
            die "(layout):$linum: Invalid JSON string in filename: $@: $1"
                if $@;
        } else {
            $line =~ s!\A([^\s\(/]*)!!;
            $name = $1;
        }
        die "(layout):$linum: Filename cannot be empty: $orig_line"
            unless length($name);
        die "(layout):$linum: Filename cannot contain slashes: $orig_line"
            if $name =~ m!/!;
        die "(layout):$linum: Filename cannot be . or ..: $orig_line"
            if $name =~ m!\A\.\.?\z!;

        my $is_dir;
        if ($line =~ s!\A/!!) {
            $is_dir = 1;
        } else {
            $is_dir = 0;
        }

        my ($orig_perm, $perm, $user, $group);
        if ($line =~ /\A\(/) {
            $line =~ s/\A\((?:([^,]*),([^,]*),)?([0-7]{3,4})\)//
                or die "(layout):$linum: Invalid syntax in permission/owner: $orig_line";
            $user  = $1;
            $group = $2;
            $orig_perm = $3;
            $perm  = oct($3);
        }

        my $sym_target;
        if ($line =~ s/\s+->\s*//) {
            die "(layout):$linum: Symlink cannot be a directory: $orig_line"
                if $is_dir;
            # parse symlink target
            if ($line =~ /\A"/) {
                $line =~ s#\A(".*?(?<!\\)(?:\\\\)*")##
                    or die "(layout):$linum: Invalid quoted symlink target: $orig_line";
                $sym_target = $1;
                eval { $sym_target = _decode_json($sym_target) };
                die "(layout):$linum: Invalid JSON string in symlink target: $@: $1"
                    if $@;
            } else {
                $line =~ s!\A([^\s]*)!!;
                $sym_target = $1;
            }
            die "(layout):$linum: Symlink target cannot be empty: $orig_line"
                unless length($sym_target);
        }

        my $extras;
        if ($line =~ s/\s+(\S.*)//) {
            $extras = $1;
            eval { $extras = _decode_json("{$extras}") };
            die "(layout):$linum: Invalid unquoted JSON hash in extras: $@: $extras"
                if $@;
            if (defined $extras->{content}) {
                die "(layout):$linum: Directory must not have 'content': $@: $orig_line"
                    if $is_dir;
            }
        }

        push @res, {
            name       => $name,
            is_dir     => $is_dir,
            is_symlink => defined($sym_target) ? 1:0,
            (symlink_target => $sym_target) x !!(defined $sym_target),
            level      => $#indents >= 0 ? $#indents : 0,
            _linum     => $linum,
            perm       => $perm,
            perm_octal => $orig_perm,
            user       => $user,
            group      => $group,
            (content    => $extras->{content}) x !!(defined $extras->{content}),
        };

        $prev_is_dir = $is_dir;
    }

    \@res;
}

$SPEC{create_files_using_layout} = {
    v => 1.1,
    summary => 'Create files/directories according to a layout',
    description => <<'_',

This routine can be used to quickly create several files/directories according
to a layout which you specify. The layout uses a few simple rules and common
conventions usually found in Linux/Unix environment.

You can use this routine e.g. in a test script.

_
    args => {
        %arg_layout,
        prefix => {
            summary => 'Root directory to create the files/directories in',
            description => <<'_',

Directory must already exist.

If unspecified, will simply create starting from current directory.

_
            schema => 'str*',
        },
    },
};
sub create_files_using_layout {
    require File::chown;

    my %args = @_;

    my $parse_res;
    eval { $parse_res = _parse_layout($args{layout}) };
    return [400, "Syntax error in layout: $@"] if $@;

    my $prefix = $args{prefix};
    local $CWD = $prefix // $CWD;
    $prefix //= ".";

    my $prev_level;
    my @dirs;
    for my $e (@$parse_res) {
        my $p = $prefix . join("", map {"/$_"} @dirs);

        if (defined $prev_level) {
            if ($e->{level} > $prev_level) {
                $log->tracef("chdir %s ...", $dirs[-1]);
                eval { $CWD = $dirs[-1] };
                return [500, "Can't chdir to $p/$e->{name}: $!"] if $@;
            } elsif ($e->{level} < $prev_level) {
                my $dir = join("/", (("..") x ($prev_level - $e->{level})));
                $log->tracef("chdir %s ...", $dir);
                eval { $CWD = $dir };
                return [500, "Can't chdir back to $dir: $!"]
                    if $@;
            }
        }

        $log->tracef("Creating %s/%s%s ...",
                     $p, $e->{name}, $e->{is_dir} ? "/":"");
        if ($e->{is_dir}) {
            do {
                if (defined $e->{perm}) {
                    mkdir($e->{name}, $e->{perm});
                } else {
                    mkdir($e->{name});
                }
            } or return [500, "Can't create directory $p/$e->{name}: $!"];
            $dirs[$e->{level}] = $e->{name};
        } elsif ($e->{is_symlink}) {
            symlink($e->{symlink_target}, $e->{name})
                or return [500, "Can't create symlink $p/$e->{name} -> ".
                           "$e->{symlink_target}: $!"];
        } else {
            open my($fh), ">", $e->{name}
                or return [500, "Can't create file $p/$e->{name}: $!"];
            if (defined $e->{content}) {
                print $fh $e->{content}
                    or return [500, "Can't write content to file ".
                               "$p/$e->{name}: $!"];
            }
            if (defined $e->{perm}) {
                chmod($e->{perm}, $e->{name})
                    or return [500, "Can't chmod file $p/$e->{name}: $!"];
            }
        }

        if (defined($e->{user}) || defined($e->{group})) {
            my %opts;
            $opts{deref} = 0 if $e->{is_symlink};
            File::chown::chown(\%opts, $e->{user}, $e->{group}, $e->{name})
                  or return [500, "Can't chown file $p/$e->{name}: $!"];
        }

        $prev_level = $e->{level};
    }

    [200, "OK"];
}

$SPEC{check_layout} = {
    v => 1.1,
    summary => 'Check whether layout has syntax errors',
    args => {
        %arg_layout,
    },
};
sub check_layout {
    my %args = @_;

    eval { _parse_layout($args{layout}) };
    my $err = $@;
    [200, "OK", $err ? 0:1, {'func.error' => $err}];
}

1;
# ABSTRACT: Quickly create files/directories according to a layout

=head1 SYNOPSIS

 use File::Create::Layout qw(create_files_using_layout);

 my $res = create_files_using_layout(layout => <<'EOL');
 file1.txt
 file2(0600)
 file3.txt(0644) "content":"hello, world\n"
 dir1/
   file1
   file2
   file3

 dir2/(root,bin,0600)
   # some comment
   file1
   dir3/
     anotherfile.txt "content":"secret"
   file2
 EOL


=head1 DESCRIPTION

B<EARLY DEVELOPMENT. MORE OPTIONS WILL BE AVAILABLE (E.G. DRY-RUN, CHECKING A
LAYOUT AGAINST FILESYSTEM, VARIOUS ERROR HANDLING OPTIONS).>


=head1 LAYOUT SPECIFICATION

Layout is a text document containing zero or more lines. Each line is either a
file/directory specification line, a blank line, or a comment line.

Comment line starts with zero or more whitespaces, a C<#> (hash) character, and
zero or more non-newline characters as the comment's content.

The simplest specification line contains just the name of a file or directory.
To specify a directory, you need to add C</> (slash) immediately after the name:

 # a file
 foo.txt

 # a directory
 bar/

 # another directory
 baz.txt/

To specify filename containing special characters, like C<#>, you can quote the
file using double quotes:

 "#tmpname#"
 "filename containing \"quotes\""

The string will be parsed as a JSON string.

B<Permission and ownership.> Immediately after the filename or directory name,
you can specify permission mode, as well as ownership (owner user/group):

 # specify permission mode, both are identical
 file.txt(0600)
 file2.txt(600)

 # specify owner as well as user+group
 dir1/(ujang,admin,0700)

B<Symlink.> To create a symlink, add C<< -> >> (arrow) followed by the symlink
target. Like filename, symlink target can be an unquoted sequence of
non-whitespace characters, or a quoted JSON string if you want to have
whitespace or other special characters:

 symlink1 -> ../target
 symlink2 -> "/home/ujang/My Documents"

B<File content.> An unquoted JSON hash (object) can be added in the end,
prefixed by at least one whitespace to specify extra stuffs, including file
content. By unquoted, it means that the enclosing curly braces C<< { .. } >> is
not written:

 file.txt "content":"This is line 1\nThis is line 2\n"
 file2.txt(0660)      "content":"secret","foo":"bar","mtime":1441853999

B<Putting files/directories in a subdirectory.> Indentation (only spaces, tabs
are not allowed) is used for this:

 dir1/
   file1-inside-dir1
   file2-inside-dir1
   dir2/
     file3-inside-dir2
     file4-inside-dir2
   another-file-inside-dir1
 file5-in-top-level
 file6
