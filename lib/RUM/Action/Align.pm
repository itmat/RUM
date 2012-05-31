package RUM::Action::Align;

=head1 NAME

RUM::Action::Align - Align reads using the RUM Pipeline.

=head1 DESCRIPTION

This action is the one that actually runs the RUM Pipeline.

=cut

use strict;
use warnings;
use autodie;

use Getopt::Long qw(:config pass_through);
use File::Path qw(mkpath);
use Text::Wrap qw(wrap fill);
use Carp;
use Data::Dumper;
use RUM::Action::Clean;

use RUM::Directives;
use RUM::Logging;
use RUM::Workflows;
use RUM::Usage;
use RUM::Pipeline;
use RUM::Common qw(format_large_int);
use RUM::Lock;

use base 'RUM::Base';

our $log = RUM::Logging->get_logger;
our $LOGO;

$SIG{INT} = $SIG{TERM} = sub {
    my $msg = "Caught SIGTERM, removing lock.";
    warn $msg;
    $log->info($msg);
    RUM::Lock->release;
    exit 1;
};

=head1 METHODS

=over 4

=cut

=item run

The top-level function in this class. Parses the command-line options,
checks the configuration and warns the user if it's invalid, does some
setup tasks, then runs the pipeline.

=cut

sub run {
    my ($class) = @_;
    my $self = $class->new;
    $self->get_options();
    my $c = $self->config;
    my $d = $self->directives;
    $self->check_config;        
    $self->check_gamma;
    $self->setup;
    $self->get_lock;
    $self->show_logo;
    
    my $platform = $self->platform;
    my $platform_name = $c->platform;
    my $local = $platform_name =~ /Local/;
    
    if ( !$c->genome_size && ($local || $d->parent )) {
        $c->set('genome_size', $self->genome_size);
    }

    if ($local) {
        $self->check_ram;
    }
    else {
        $self->say(
            "You are running this job on a $platform_name cluster. ",
            "I am going to assume each node has sufficient RAM for this. ",
            "If you are running a mammalian genome then you should have at ",
            "least 6 Gigs per node");
    }

    $self->config->save unless $d->child;
    $self->dump_config;

    if ( !$local && ! ( $d->parent || $d->child ) ) {
        $self->logsay("Submitting tasks and exiting");
        $platform->start_parent;
        return;
    }
    my $dir = $self->config->output_dir;
    $self->say(
        "If this is a big job, you should keep an eye on the rum_errors*.log",
        "files in the output directory. If all goes well they should be empty.",
        "You can also run \"$0 status -o $dir\" to check the status of the job.");

    if ($d->preprocess || $d->all) {
        $platform->preprocess;
    }

    $self->_show_match_length;
    $self->_check_read_lengths;

    if ($d->process || $d->all) {
        $platform->process($self->{chunk});
    }
    if ($d->postprocess || $d->all) {
        $platform->postprocess;
        $self->_final_check;
    }
    RUM::Lock->release;
}

sub _check_read_lengths {
    my ($self) = @_;
    my $c = $self->config;
    my $rl = $c->read_length;
    my $fixed = ! $c->variable_length_reads;

    if ( $fixed && $rl < 55 && !$c->nu_limit) {
        $self->say;
        $self->logsay(
            "WARNING: You have pretty short reads ($rl bases). If ",
            "you have a large genome such as mouse or human then the files of ",
            "ambiguous mappers could grow very large. In this case it's",
            "recommended to run with the --limit-bowtie-nu option. You can ",
            "watch the files that start with 'X' and 'Y' and see if they are ",
            "growing larger than 10 gigabytes per million reads at which ",
            "point you might want to use --limit-nu");
    }

}

sub _show_match_length {
    my ($self) = @_;
    my $c = $self->config;
    my $match_length_cutoff;
    my $rl = $c->read_length;
    if ( ! $c->min_length && !$c->variable_length_reads) {
        if ($rl < 80) {
            $match_length_cutoff ||= 35;
        } else {
            $match_length_cutoff ||= 50;
        }
        if($match_length_cutoff >= .8 * $rl) {
            $match_length_cutoff = int(.6 * $rl);
        }
    } else {
	$match_length_cutoff = $c->min_length;
    }
    
    if ($match_length_cutoff) {
        $self->logsay(
            "*** Note: I am going to report alignments of length ",
            "$match_length_cutoff. If you want to change the minimum size of ",
            "alignments reported, use the --min-length option");
    }
}


=item get_options

Parse @ARGV and build a RUM::Config from it. Also set some flags in
$self->{directives} based on some boolean options.

=cut

sub get_options {
    my ($self) = @_;

    my $quiet;
    Getopt::Long::Configure(qw(no_ignore_case));

    my $d = $self->{directives} = RUM::Directives->new;

    my $usage = RUM::Usage->new('action' => 'align');

    GetOptions(

        # Advanced (user shouldn't run these)
        "child"        => sub { $d->set_child },
        "parent"       => sub { $d->set_parent },
        "lock=s"         => \(my $lock),

        # Options controlling which portions of the pipeline to run.
        "preprocess"   => sub { $d->set_preprocess;  $d->unset_all; },
        "process"      => sub { $d->set_process;     $d->unset_all; },
        "postprocess"  => sub { $d->set_postprocess; $d->unset_all; },
        "chunk=s"      => \(my $chunk),

        "no-clean" => sub { $d->set_no_clean },

        # Options typically entered by a user to define a job.
        "config=s"    => \(my $rum_config_file),
        "output|o=s"  => \(my $output_dir),
        "name=s"      => \(my $name),
        "chunks=s"    => \(my $num_chunks),
        "qsub"        => \(my $qsub),
        "platform=s"  => \(my $platform),

        # Advanced options
        "alt-genes=s"      => \(my $alt_genes),
        "alt-quants=s"     => \(my $alt_quant),
        "blat-only"        => \(my $blat_only),
        "count-mismatches" => \(my $count_mismatches),
        "dna"              => \(my $dna),
        "genome-only"      => \(my $genome_only),
        "junctions"        => \(my $junctions),
        "limit-bowtie-nu"  => \(my $limit_bowtie_nu),
        "limit-nu=s"       => \(my $nu_limit),
        "max-insertions-per-read=s" => \(my $max_insertions),
        "min-identity"              => \(my $min_identity),
        "min-length=s"              => \(my $min_length),
        "preserve-names"            => \(my $preserve_names),
        "quals-file|qual-file=s"    => \(my $quals_file),
        "quantify"                  => \(my $quantify),
        "ram=s"    => \(my $ram),
        "read-lengths=s" => \(my $read_lengths),
        "strand-specific" => \(my $strand_specific),
        "variable-length-reads" => \(my $variable_length_reads),

        # Options for blat
        "minIdentity|blat-min-identity=s" => \(my $blat_min_identity),
        "tileSize|blat-tile-size=s"       => \(my $blat_tile_size),
        "stepSize|blat-step-size=s"       => \(my $blat_step_size),
        "repMatch|blat-rep-match=s"       => \(my $blat_rep_match),
        "maxIntron|blat-max-intron=s"     => \(my $blat_max_intron),

        "force|f"   => \(my $force),
        "quiet|q"   => sub { $log->less_logging(1); $quiet = 1; },
        "verbose|v" => sub { $log->more_logging(1) },
        "help|h" => sub { $usage->help }
    );

    my @reads;

    while (local $_ = shift @ARGV) {
        if (/^-/) {
            $usage->bad("Unrecognized option $_");
        }
        else {
            push @reads, File::Spec->rel2abs($_);
        }
    }

    $output_dir or $usage->bad(
        "The --output or -o option is required for \"rum_runner align\"");

    if ($lock) {
        $log->info("Got lock argument ($lock)");
        $RUM::Lock::FILE = $lock;
    }

    my $dir = $output_dir;
    $ENV{RUM_OUTPUT_DIR} = $dir;
    my $c = $dir ? RUM::Config->load($dir) : undef;
    !$c or ref($c) =~ /RUM::Config/ or confess("Not a config: $c");
    my $did_load;
    if ($c) {
        $self->logsay("Using settings found in " . $c->settings_filename);
        $did_load = 1;
    }
    else {
        $c = RUM::Config->new unless $c;
        $c->set('output_dir', File::Spec->rel2abs($dir));
    }

    ref($c) =~ /RUM::Config/ or confess("Not a config: $c");

    # If a chunk is specified, that implies that the user wants to do
    # the 'processing' phase, so unset preprocess and postprocess
    if ($chunk) {
        $usage->bad("Can't use --preprocess with --chunk")
              if $d->preprocess;
        $usage->bad("Can't use --postprocess with --chunk")
              if $d->postprocess;
        $d->unset_all;
        $d->set_process;
    }

    my $did_set;

    my $set = sub { 
        my ($k, $v) = @_;
        return unless defined $v;
        my $existing = $c->get($k);
        if (defined($existing) && $existing ne $v) {
            $did_set = 1;
            $log->info("Changing $k from $existing to $v");
        }
        
        $c->set($k, $v);
    };

    $platform = 'SGE' if $qsub;

    $alt_genes = File::Spec->rel2abs($alt_genes) if $alt_genes;
    $alt_quant = File::Spec->rel2abs($alt_quant) if $alt_quant;
    $rum_config_file = File::Spec->rel2abs($rum_config_file) if $rum_config_file;

    $self->{chunk} = $chunk;

    $set->('alt_genes', $alt_genes);
    $set->('alt_quant_model', $alt_quant);
    $set->('bowtie_nu_limit', 100) if $limit_bowtie_nu;
    $set->('blat_min_identity', $blat_min_identity);
    $set->('blat_tile_size', $blat_tile_size);
    $set->('blat_step_size', $blat_step_size);
    $set->('blat_rep_match', $blat_rep_match);
    $set->('blat_max_intron', $blat_max_intron);
    $set->('blat_only', $blat_only);
    $set->('count_mismatches', $count_mismatches);
    $set->('dna', $dna);
    $set->('genome_only', $genome_only);
    $set->('junctions', $junctions);
    $set->('max_insertions', $max_insertions),
    $set->('min_identity', $min_identity);
    $set->('min_length', $min_length);
    $set->('name', $name);
    $set->('nu_limit', $nu_limit);
    $set->('num_chunks',  $num_chunks);
    $set->('platform', $platform);
    $set->('preserve_names', $preserve_names);
    $set->('quantify', $quantify);
    $set->('ram', $ram);
    $set->('reads', @reads ? [@reads] : undef) if @reads && @reads ne @{ $c->reads || [] };
    $set->('rum_config_file', $rum_config_file);
    $set->('strand_specific', $strand_specific);
    $set->('user_quals', $quals_file);
    $set->('variable_length_reads', $variable_length_reads);

    if ($did_set && $did_load && !$force && !$d->child) {
        die("I found job settings in " . $c->settings_filename . ", but you specified different settings on the command line. I won't run without the --force flag. If you want to use the saved settings, please don't provide any extra options on the command line. If you need to change the settings, please either delete " . $c->settings_filename . " or run again with --force.");
    }

    $self->{config} = $c;
    $usage->check;
}


=item check_config

Check my RUM::Config for errors. Calls RUM::Usage->bad (which exits)
if there are any errors.

=cut

sub check_config {
    my ($self) = @_;

    my $usage = RUM::Usage->new(action => 'align');

    my $c = $self->config;
    $c->output_dir or $usage->bad(
        "Please specify an output directory with --output or -o");
    
    # Job name
    if ($c->name) {
        length($c->name) <= 250 or $usage->bad(
            "The name must be less than 250 characters");
        $c->set('name', fix_name($c->name));
    }
    else {
        $usage->bad("Please specify a name with --name");
    }

    $c->rum_config_file or $usage->bad(
        "Please specify a rum config file with --config");
    $c->load_rum_config_file if $c->rum_config_file;

    my $reads = $c->reads;


    if ($reads) {
        @$reads == 1 || @$reads == 2 or $usage->bad(
            "Please provide one or two read files. You provided " .
                join(", ", @$reads));
    }
    else {
        $usage->bad("Please provide one or two read files.");
    }


    if ($reads && @$reads == 2) {
        $reads->[0] ne $reads->[1] or $usage->bad(
        "You specified the same file for the forward and reverse reads, ".
            "must be an error");

        $c->max_insertions <= 1 or $usage->bad(
            "For paired-end data, you cannot set --max-insertions-per-read".
                " to be greater than 1.");
    }

    if (defined($c->user_quals)) {
        $c->quals_file =~ /\// or $usage->bad(
            "do not specify -quals file with a full path, ".
                "put it in the '". $c->output_dir."' directory.");
    }

    $c->min_identity =~ /^\d+$/ && $c->min_identity <= 100 or $usage->bad(
        "--min-identity must be an integer between zero and 100. You
        have given '".$c->min_identity."'.");


    if (defined($c->min_length)) {
        $c->min_length =~ /^\d+$/ && $c->min_length >= 10 or $usage->bad(
            "--min-length must be an integer >= 10. You have given '".
                $c->min_length."'.");
    }
    
    if (defined($c->nu_limit)) {
        $c->nu_limit =~ /^\d+$/ && $c->nu_limit > 0 or $usage->bad(
            "--limit-nu must be an integer greater than zero. You have given '".
                $c->nu_limit."'.");
    }

    $c->preserve_names && $c->variable_length_reads and $usage->bad(
        "Cannot use both --preserve-names and --variable-read-lengths at ".
            "the same time. Sorry, we will fix this eventually.");

    local $_ = $c->blat_min_identity;
    /^\d+$/ && $_ <= 100 or $usage->bad(
        "--blat-min-identity or --minIdentity must be an integer between ".
            "0 and 100.");


    $usage->check;
    
    if ($c->alt_genes) {
        -r $c->alt_genes or die
            "Can't read from alt gene file ".$c->alt_genes.": $!";
    }

    if ($c->alt_quant_model) {
        -r $c->alt_quant_model or die
            "Can't read from ".$c->alt_quant_model.": $!";
    }

    for my $fname (@{ $reads || [] }) {
        -r $fname or die "Can't read from read file $fname";
    }
    
}

=item get_lock

Attempts to get a lock on the $output_dir/.rum/lock file. Dies with a
warning message if the lock is held by someone else. Otherwise returns
normally, and RUM::Lock::FILE will be set to the filename.

=cut

sub get_lock {
    my ($self) = @_;
    return if $self->directives->parent || $self->directives->child;
    my $c = $self->config;
    my $dir = $c->output_dir;
    my $lock = $c->lock_file;
    $log->info("Acquiring lock");
    RUM::Lock->acquire($lock) or die
          "It seems like rum_runner may already be running in $dir. You can try running \"$0 kill\" to stop it. If you #are sure there's nothing running in $dir, remove $lock and try again.\n";
}

=item setup

Creates the output directory and .rum subdirectory.

=cut

sub setup {
    my ($self) = @_;
    my $output_dir = $self->config->output_dir;
    my $c = $self->config;
    my @dirs = (
        $c->output_dir,
        $c->output_dir . "/.rum",
        $c->chunk_dir
    );
    for my $dir (@dirs) {
        unless (-d $dir) {
            mkpath($dir) or die "mkdir $dir: $!";
        }
    }
}

=item show_logo

Print out the RUM logo.

=cut

sub show_logo {
    my ($self) = @_;
    my $msg = <<EOF;

RUM Version $RUM::Pipeline::VERSION

$LOGO
EOF
    $self->say($msg);

}

=item fix_name

Remove unwanted characters from the name.

=cut

sub fix_name {
    local $_ = shift;

    my $name_o = $_;
    s/\s+/_/g;
    s/^[^a-zA-Z0-9_.-]//;
    s/[^a-zA-Z0-9_.-]$//g;
    s/[^a-zA-Z0-9_.-]/_/g;
    
    return $_;
}

=item check_gamma

Die if we seem to be running on gamma.

=cut

sub check_gamma {
    my ($self) = @_;
    my $host = `hostname`;
    if ($host =~ /login.genomics.upenn.edu/ && !$self->config->platform eq 'Local') {
        die("you cannot run RUM on the PGFI cluster without using the --qsub option.");
    }
}

=item dump_config

Dump the configuration file to the log.

=cut

sub dump_config {
    my ($self) = @_;
    $log->debug("-" x 40);
    $log->debug("Job configuration");
    $log->debug("RUM Version: $RUM::Pipeline::VERSION");
    
    for my $key ($self->config->properties) {
        my $val = $self->config->get($key);
        next unless defined $val;
        $val = Data::Dumper->new([$val])->Indent(0)->Dump if ref($val);
        $log->debug("$key: $val");
    }
    $log->debug("-" x 40);
}

=item genome_size

Return an estimate of the size of the genome.

=cut

sub genome_size {
    my ($self) = @_;

    $self->logsay("Determining the size of your genome.");

    my $c = $self->config;
    my $genome_blat = $c->genome_fa;

    my $gs1 = -s $genome_blat;
    my $gs2 = 0;
    my $gs3 = 0;

    open my $in, "<", $genome_blat;

    local $_;
    while (defined($_ = <$in>)) {
        next unless /^>/;
        $gs2 += length;
        $gs3 += 1;
    }

    return $gs1 - $gs2 - $gs3;
}

=item check_ram

Make sure there seems to be enough ram, based on the size of the
genome.

=cut

sub check_ram {

    my ($self) = @_;

    my $c = $self->config;

    return if $c->ram_ok || $c->ram;

    if (!$c->ram) {
        $self->say("I'm going to try to figure out how much RAM ",
                   "you have. If you see some error messages here, ",
                   " don't worry, these are harmless.");
        my $available = $self->available_ram;
        $c->set('ram', $available);
    }

    my $genome_size = $c->genome_size;
    my $gs4 = &format_large_int($genome_size);
    my $gsz = $genome_size / 1000000000;
    my $min_ram = int($gsz * 1.67)+1;
    
    $self->say();

    my $totalram = $c->ram;
    my $RAMperchunk;
    my $ram;

    # We couldn't figure out RAM, warn user.
    if ($totalram) {
        $RAMperchunk = $totalram / ($c->num_chunks||1);
    } else {
        warn("Warning: I could not determine how much RAM you " ,
             "have.  If you have less than $min_ram gigs per ",
             "chunk this might not work. I'm going to ",
             "proceed with fingers crossed.\n");
        $ram = $min_ram;      
    }
    
    if ($totalram) {

        if($RAMperchunk >= $min_ram) {
            $self->logsay(sprintf(
                "It seems like you have %.2f Gb of RAM on ".
                "your machine. Unless you have too much other stuff ".
                "running, RAM should not be a problem.", $totalram));
        } else {
            $self->logsay(
                "Warning: you have only $RAMperchunk Gb of RAM ",
                "per chunk.  Based on the size of your genome ",
                "you will probably need more like $min_ram Gb ",
                "per chunk. Anyway I can try and see what ",
                "happens.");
            print("Do you really want me to proceed?  Enter 'Y' or 'N': ");
            local $_ = <STDIN>;
            if(/^n$/i) {
                exit();
            }
        }
        $self->say();
        $ram = $min_ram;
        if($ram < 6 && $ram < $RAMperchunk) {
            $ram = $RAMperchunk;
            if($ram > 6) {
                $ram = 6;
            }
        }

        $c->set('ram', $ram);
        $c->set('ram_ok', 1);

        $c->save;
        # sleep($PAUSE_TIME);
    }

}

=item available_ram

Attempt to figure out how much ram is available, and return it.

=cut

sub available_ram {

    my ($self) = @_;

    my $c = $self->config;

    return $c->ram if $c->ram;

    local $_;

    # this should work on linux
    $_ = `free -g 2>/dev/null`; 
    if (/Mem:\s+(\d+)/s) {
        return $1;
    }

    # this should work on freeBSD
    $_ = `grep memory /var/run/dmesg.boot 2>/dev/null`;
    if (/avail memory = (\d+)/) {
        return int($1 / 1000000000);
    }

    # this should work on a mac
    $_ = `top -l 1 | grep free`;
    if (/(\d+)(.)\s+used, (\d+)(.) free/) {
        my $used = $1;
        my $type1 = $2;
        my $free = $3;
        my $type2 = $4;
        if($type1 eq "K" || $type1 eq "k") {
            $used = int($used / 1000000);
        }
        if($type2 eq "K" || $type2 eq "k") {
            $free = int($free / 1000000);
        }
        if($type1 eq "M" || $type1 eq "m") {
            $used = int($used / 1000);
        }
        if($type2 eq "M" || $type2 eq "m") {
            $free = int($free / 1000);
        }
        return $used + $free;
    }
    return 0;
}

$LOGO = <<'EOF';
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
                 _   _   _   _   _   _    _
               // \// \// \// \// \// \/
              //\_//\_//\_//\_//\_//\_//
        o_O__O_ o
       | ====== |       .-----------.
       `--------'       |||||||||||||
        || ~~ ||        |-----------|
        || ~~ ||        | .-------. |
        ||----||        ! | UPENN | !
       //      \\        \`-------'/
      // /!  !\ \\        \_  O  _/
     !!__________!!         \   /
     ||  ~~~~~~  ||          `-'
     || _        ||
     |||_|| ||\/|||
     ||| \|_||  |||
     ||          ||
     ||  ~~~~~~  ||
     ||__________||
.----|||        |||------------------.
     ||\\      //||                 /|
     |============|                //
     `------------'               //
---------------------------------'/
---------------------------------'
  ____________________________________________________________
- The RNA-Seq Unified Mapper (RUM) Pipeline has been initiated -
  ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
EOF

1;

sub _all_files_end_with_newlines {
    my ($self, $file) = @_;
    my $c = $self->config;

    my @files = qw(
                      RUM_Unique
                      RUM_NU
                      RUM_Unique.cov
                      RUM_NU.cov
                      RUM.sam
                      
              );

    if ($c->should_quantify) {
        push @files, "feature_quantifications_" . $c->name;
    }
    if ($c->should_do_junctions) {
        push @files, ('junctions_all.rum',
                      'junctions_all.bed',
                      'junctions_high-quality.bed');
    }

    my $result = 1;
    
    for $file (@files) {
        my $file = $self->config->in_output_dir($file);
        my $tail = `tail $file`;
        
        unless ($tail =~ /\n$/) {
            $log->error("RUM_Unique does not end with a newline, that probably means it is incomplete.");
            $result = 0;
        }
    }
    if ($result) {
        $log->info("All files end with a newline, that's good");
    }
    return $result;
}

sub _final_check {
    my ($self) = @_;
    my $ok = 1;
    
    $self->say();
    $self->logsay("Checking for errors");
    $self->logsay("-------------------");

    $ok = $self->_chunk_error_logs_are_empty && $ok;
    $ok = $self->_all_files_end_with_newlines && $ok;

    if ($ok) {
        $self->logsay("No errors. Very good!");
        unless ($self->directives->no_clean) {
            $self->logsay("Cleaning up.");
            RUM::Action::Clean->new($self->config)->clean;
        }
    }
}


=back
