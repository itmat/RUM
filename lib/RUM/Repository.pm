package RUM::Repository;

=head1 NAME

RUM::Repository - Models a local repository of RUM indexes

=head1 SYNOPSIS

  use RUM::Repository;

  my $repo = RUM::Repository->new();

  # Get the root, config, and indexes directories for this repo.
  my $root    = $repo->root_dir;
  my $conf    = $repo->conf_dir;
  my $indexes = $repo->indexes_dir;

  # Download the organisms.txt file for this repo
  $repo->fetch_organisms_file;

  # Get a list of available organisms
  $repo->organisms;

  # Get a list of organisms whose build name, common name, or latin
  # name match a pattern.
  my @hg19 = $repo->find_indexes("hg19");
  my @rat = $repo->find_indexes("rat");
  my @homosapiens = $repo->find_indexes("homo sapiens");

=cut

use strict;
no warnings;

use FindBin qw($Bin);
use RUM::Repository::IndexSpec;
use RUM::ConfigFile;
use Carp;
use File::Spec;
use Exporter qw(import);
FindBin->again;

our @EXPORT_OK = qw(download);

our $ORGANISMS_URL = "http://itmat.rum.s3.amazonaws.com/organisms.txt";

# Maps os name to bin tarball name
our %BIN_TARBALL_MAP = (
    darwin => "bin_mac1.5.tar",
    linux  => "bin_linux64.tar"
);

our $BIN_TARBALL_URL_PREFIX = "http://itmat.rum.s3.amazonaws.com";

=head1 DESCRIPTION

=head2 Constructor

=over 4

=item $repo->new(%options)

Create a new repository. You can use %options to configure the
locations of the directories, but this is not necessary. It will
default to using the index and conf directories relative to the
location of the executable. The following keys are allowable for options:

=over 4

=item B<root_dir>

Use this directory as the root. If B<conf_dir> or B<indexes_dir> are
not supplied, I'll use "$ROOT/conf" and "$ROOT/indexes".

=item B<conf_dir>

Put put the configuration files in this directory.

=item B<indexes_dir>

Put the index files in this directory.

=item B<organisms_file>

Put the organisms file here.

=back

=back

=cut

sub new {
    my ($class, %options) = @_;

    my %self;

    $self{root_dir}       = delete $options{root_dir};    
    $self{conf_dir}       = delete $options{conf_dir};
    $self{indexes_dir}    = delete $options{indexes_dir};
    $self{bin_dir}        = delete $options{bin_dir};
    $self{organisms_file} = delete $options{organisms_file};

    my @extra = keys %options;
    croak "Unrecognized options to $class->new: @extra" if @extra;
    
    $self{root_dir}       ||= "$Bin/..";
    $self{conf_dir}       ||= "$self{root_dir}/conf";
    $self{indexes_dir}    ||= "$self{root_dir}/indexes";
    $self{bin_dir}        ||= "$self{root_dir}/bin";
    $self{organisms_file} ||= "$self{conf_dir}/organisms.txt";
    
    return bless \%self, $class;
}

=head2 Accessors

=over 4

=item $self->root_dir

=item $self->conf_dir

=item $self->indexes_dir

=item $self->bin_dir

=item $self->organisms_file

=back

=cut

sub root_dir       { $_[0]->{root_dir} }
sub conf_dir       { $_[0]->{conf_dir} }
sub indexes_dir    { $_[0]->{indexes_dir} }
sub bin_dir        { $_[0]->{bin_dir} }
sub organisms_file { $_[0]->{organisms_file} }

=head2 Querying and Modifying the Repository

=over 4

=item $self->fetch_binaries

Download the binary dependencies (blat, bowtie, mdust).

=cut

sub fetch_binaries {
    my ($self) = @_;
    $self->mkdirs;
    my $bin_tarball = $BIN_TARBALL_MAP{$^O}
        or croak "I don't have a binary tarball for this operating system ($^O)";
    my $url = "$BIN_TARBALL_URL_PREFIX/$bin_tarball";
    my $bin_dir = $self->bin_dir;
    my $local = "$bin_dir/$bin_tarball";
    download($url, $local);
    system("tar -C $bin_dir --strip-components 1 -xf $local") == 0
        or croak "Can't unpack $local";
    unlink $local;
}

=item $self->fetch_organisms_file

Download the organisms file

=cut

sub fetch_organisms_file {
    my ($self) = @_;
    $self->mkdirs;
    my $file = $self->organisms_file;
    download($ORGANISMS_URL, $file);
    return $self;
}

=item $self->indexes

Get a list of available indexes (RUM::Repository::IndexSpec
objects). You can optionally provide a 'pattern' option that will
cause the results to be filtered to include only indexes whose build
name, common name, or latin name match the specified pattern.

  # Get all indexes
  $self->indexes;

  # Should return the mouse index
  $self->indexes(pattern => qr/mm9/);

  # Should return any 'human' indexes
  $self->indexes(pattern => qr/human/);

=cut

sub indexes {
    my ($self, %query) = @_;
    my $filename = $self->organisms_file;
    open my $orgs, "<", $filename
        or croak "Can't open $filename for reading: $!";
    my @orgs = RUM::Repository::IndexSpec->parse($orgs);

    if ($query{pattern}) {
        my $re = qr/$query{pattern}/i;

        return grep {
            $_->common =~ /$re/ || $_->build =~ /$re/ || $_->latin =~ /$re/
        } @orgs;
    }

    return @orgs;
}

=item $repo->install_index($index, $callback)

Install the given index. F<index> must be a
RUM::Repository::IndexSpec.  If $callback is provided it must be a
CODE ref, and it will be called for each URL we download. It's called
before the download begins with with ("start", $url), after the
download complets with ("end", $url).

=cut

sub install_index {
    my ($self, $index, $callback) = @_;
    $self->mkdirs;
    for my $url ($index->urls) {
        $callback->("start", $url) if $callback;
        my $filename = $self->index_filename($url);
        download($url, $filename);
        if ($self->is_config_filename($filename)) {
            open my $in, "<", $filename 
                or croak "Can't open config file $filename for reading: $!";
            my $config = RUM::ConfigFile->parse($in, quiet => 1);
            close $in;
            $config->make_absolute($self->root_dir);
            open my $out, ">", $filename 
                or croak "Can't open config file $filename for writing: $!";
            print $out $config->to_str;
            close $out;
        }
        if ($filename =~ /.gz$/) {
            system("gunzip -f $filename") == 0 
                or die "Couldn't unzip $filename: $!";
        }
        $callback->("end", $url) if $callback;
    }
}

=item $repo->remove_index($index, $callback)

Removes the given index. F<index> must be a
RUM::Repository::IndexSpec.  If $callback is provided it must be a
CODE ref, and it will be called for each file we remove. It's called
before the remove begins with with ("start", $filename), after the
download completes with ("end", $filename).

=cut

sub remove_index {
    my ($self, $index, $callback) = @_;
    for my $url ($index->urls) {
     
        my $filename = $self->index_filename($url);
        if (-e $filename) {
            $callback->("start", $filename) if $callback;
            unlink $filename or croak "rm $filename: $!";
            $callback->("end", $filename) if $callback;
        }
    }
}


=item $repo->index_filename($url) 

Return the local filename for the given URL.

=cut

sub index_filename {
    my ($self, $url) = @_;
    my ($vol, $dir, $file) = File::Spec->splitpath($url);
    my $subdir = $self->is_config_filename($file)
        ? $self->conf_dir : $self->indexes_dir;
    return File::Spec->catdir($subdir, $file);
}

=item $repo->is_config_filename($filename)

Return true if the given $filename seems to be a configuration file
(rum.config_*), false otherwise.

=cut

sub is_config_filename {
    my ($self, $filename) = @_;
    my ($vol, $dir, $file) = File::Spec->splitpath($filename);
    return $file =~ /^rum.config/;
}

=item $repo->local_filenames($index)

Return all the local filenames for the given index.

=cut

sub local_filenames {
    my ($self, $index) = @_;
    return map { $self->index_filename($_) } $index->urls;
}

=item $repo->config_filename($index)

Return the configuration file name for the given index.

=cut

sub config_filename {
    my ($self, $index) = @_;
    my @filenames = $self->local_filenames($index);
    my @conf_filenames = grep { $self->is_config_filename($_) } @filenames;
    croak "I can't find exactly one index filename in @conf_filenames"
        unless @conf_filenames == 1;
    return $conf_filenames[0];
}

=item $repo->genome_fasta_filename($index)

Return the genome fasta file name for the given index.

=cut

sub genome_fasta_filename {
    my ($self, $index) = @_;
    my @filenames = grep { 
        /genome_one-line-seqs.fa/ 
    } $self->local_filenames($index);
    croak "I can't find exactly one genome fasta filename"
        unless @filenames == 1;
    $filenames[0] =~ s/\.gz$//;

    return $filenames[0];
}

=item $repo->has_index($index)

Return a true value if the index exists in this repository, false otherwise.

=cut

sub has_index {
    my ($self, $index) = @_;
    my @files = map { $self->index_filename($_) } $index->urls;
    for (@files) {
        s/\.gz$//;
    }
    my @missing = grep { not -e } @files;
    return !@missing;
}

=item $repo->mkdirs()

Make any directories the repository needs.

=cut

sub mkdirs {
    my ($self) = @_;
    my @dirs = ($self->root_dir,
                $self->conf_dir,
                $self->indexes_dir,
                $self->bin_dir);
    for my $dir (@dirs) {
        unless (-d $dir) {
            mkdir $dir or croak "mkdir $dir: $!";
        }
    }
}

=item $repo->setup()

Make any directories that need to be created, and download the
organisms.txt file if necessary.

=cut

sub setup {
    my ($self) = @_;
    $self->mkdirs();
    $self->fetch_organisms_file() unless -e $self->organisms_file();
    return $self;
}

=item download($url, $local)

Attempt to download the file from the given $url to the given $local
path.

=cut

sub download {
    my ($url, $local) = @_;
    my $cmd;

    if (system("which wget > /dev/null") == 0) {
        $cmd = "wget -q -O $local $url";
    }
    elsif (system("which curl > /dev/null") == 0) {
        $cmd = "curl -s -o $local $url";
    }
    elsif (system("which ftp > /dev/null") == 0) {
        $cmd = "ftp -o $local $url";
    }
    else {
        croak "I can't find ftp, wget, or curl on your path; ".
            "please install one of those programs.";
    }
    system($cmd) == 0 or croak "Error running $cmd: $!";
}

=back

=head1 AUTHOR

Mike DeLaurentis (delaurentis@gmail.com)

=head1 COPYRIGHT

Copyright 2012 University of Pennsylvania

=cut

1;
