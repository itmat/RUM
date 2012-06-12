package RUM::TestUtils;

use strict;
no warnings;

=head1 NAME

RUM::TestUtils - Functions used by tests

=head1 SYNOPSIS

  use RUM::TestUtils qw(:all);

  # Make sure there are no diffs between two files
  no_diffs("got.tab", "expected.tab", "I got what I expected");

=head1 DESCRIPTION

=head1 Subroutines

=over 4

=cut

use Carp;
use Test::More;
use Exporter qw(import);
use File::Spec;
use FindBin qw($Bin);
use File::Temp;

use RUM::Sort qw(by_chromosome);
use RUM::Common qw(shell is_on_cluster);
use RUM::Repository qw(download);

our @EXPORT = qw(temp_filename no_diffs $INPUT_DIR $EXPECTED_DIR
                 $INDEX_CONFIG $SHARED_INPUT_DIR is_sorted_by_location same_line_count
                 $RUM_HOME $GENE_INFO $INDEX_DIR same_contents_sorted);
our @EXPORT_OK = qw(no_diffs is_sorted_by_location same_contents_sorted);
our %EXPORT_TAGS = (
    all => [@EXPORT_OK]);

FindBin->again();

our $PROGRAM_NAME = do {
    local $_ = $0;
    s/^.*\///;
    s/\..*$//;
    s/^\d\d-//;
    $_;
};


# Build some paths that tests might need
our $RUM_HOME = $Bin;
$RUM_HOME =~ s/\/t(\/integration)?(\/)?$//;
our $RUM_BIN      = "$RUM_HOME/bin";
our $RUM_CONF     = "$RUM_HOME/conf";
our $RUM_INDEXES  = "$RUM_HOME/indexes";

our $INDEX_DIR    = "$RUM_INDEXES/Arabidopsis";
our $INDEX_CONFIG = "$INDEX_DIR/rum_index.conf";
our $GENOME_FA    = "$INDEX_DIR/Arabidopsis_thaliana_TAIR10_genome_one-line-seqs.fa";
our $GENE_INFO    = "$INDEX_DIR/Arabidopsis_thaliana_TAIR10_ensembl_gene_info.txt";
our $SHARED_INPUT_DIR = "$RUM_HOME/t/data/shared";
our $INPUT_DIR        = "$RUM_HOME/t/data/$PROGRAM_NAME";
our $EXPECTED_DIR      = "$RUM_HOME/t/expected/$PROGRAM_NAME";

=item no_diffs(FILE1, FILE2, NAME)

Uses Test::More to assert that there are no differences between the
two files.

=cut

sub no_diffs {
    my ($file1, $file2, $name, $options) = @_;
    $options ||= "";
    my $diffs = `diff $options $file2 $file1 > foo`;
    my $status = $? >> 8;
    ok($status == 0, $name);
}

sub same_contents_sorted {
    my ($got_filename, $exp_filename, $name) = @_;
    open my $got, "<", $got_filename;
    open my $exp, "<", $exp_filename;

    my @got = sort (<$got>);
    my @exp = sort (<$exp>);

    is_deeply(\@got, \@exp, $name)
}

=item line_count($filename)

Returns the number of lines in $filename.

=cut

sub line_count {
    my ($filename) = @_;
    open my $in, "<", $filename or die "Can't open $filename for reading: $!";
    my $count = 0;
    while (defined(<$in>)) {
        $count++;
    }
    return $count;
}

=item same_line_count(FILE1, FILE2, NAME)

Uses Test::More to assert that the two files have the same number of
lines.

=cut

sub same_line_count {
    my ($file1, $file2, $name) = @_;
    is(line_count($file1), line_count($file2), $name);
}

=item is_sorted_by_location(FILENAME)

Asserts that the given RUM file is sorted by location.

=cut

sub is_sorted_by_location {
    my ($filename) = @_;
    my $it = my $iter = RUM::RUMIO->new(-file => $filename)->aln_iterator;

    my @recs;

    while (my $rec = $iter->next_val) {
        my %rec = (
            chr => $rec->chromosome,
            start => $rec->start,
            end => $rec->end
        );
        push @recs, \%rec;
    }

    my @sorted = sort {
        by_chromosome($a->{chr}, $b->{chr}) || $a->{start} <=> $b->{start} || $a->{end} <=> $b->{end};
    } @recs;

    is_deeply(\@recs, \@sorted, "Sorted by location");
}

=item temp_filename(%options)

Return a temporary filename using File::Temp with some sensible
defaults for a test script. 

=over 4

=item B<DIR>

The directory to store the temp file. Defaults to $Bin/tmp.

=item B<UNLINK>

Whether to unlink the file upon exit. Defaults to 1.

=item B<TEMPLATE>

The template for the filename. Defaults to a template that includes
the name of the calling function.

=back

=cut

sub temp_filename {
    my (%options) = @_;
    mkdir "$Bin/tmp";
    $options{DIR}      = "$Bin/tmp" unless exists $options{DIR};
    $options{UNLINK}   = 1        unless exists $options{UNLINK};
    $options{TEMPLATE} = "XXXXXX" unless exists $options{TEMPLATE};
    File::Temp->new(%options);
}

=item make_paths RUN_NAME

Recursively make all the paths required for the given test run name,
unless $DRY_RUN is set.

=cut

sub make_paths {
    my (@paths) = @_;

    for my $path (@paths) {
        
        if (-e $path) {
            diag "$path exists; not creating it";
        }
        else {
            print "mkdir -p $path\n";
            mkpath($path) or die "Can't make path $path: $!";
        }

    }
}

=back

=head1 AUTHOR

Mike DeLaurentis (delaurentis@gmail.com)

=head1 COPYRIGHT

Copyright University of Pennsylvania, 2012

=cut
