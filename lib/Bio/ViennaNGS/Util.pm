# -*-CPerl-*-
# Last changed Time-stamp: <2017-06-10 19:12:00 michl>

package Bio::ViennaNGS::Util;

use Bio::ViennaNGS;
use Exporter;
use strict;
use warnings;
use Data::Dumper;
use File::Basename qw(fileparse basename);
use IPC::Cmd qw(can_run run);
use Path::Class qw(dir file);
use File::Path qw(make_path remove_tree);
use Math::Round;
use Carp;
use Env qw(HOME);
use version; our $VERSION = version->declare("$Bio::ViennaNGS::VERSION");

our @ISA = qw(Exporter);
our @EXPORT = ();

our @EXPORT_OK = qw ( bed_or_bam2bw sortbed bed2bigBed unique_array
		      kmer_enrichment fetch_chrom_sizes mkdircheck rmdircheck);


#^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^#
#^^^^^^^^^^ Variables ^^^^^^^^^^^#
#^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^#

my %unique = ();

#^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^#
#^^^^^^^^^^^ Subroutines ^^^^^^^^^^#
#^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^#

sub bed_or_bam2bw {
  my ($type,$infile,$chromsizes,$strand,$dest,$want_norm,$size,$scale,$log) = @_;
  my ($fn_bg_tmp,$fn_bg,$fn_bw,$fn,$bn,$path,$ext,$cmd);
  my @processed_files = ();
  my $factor = 1.;
  my $this_function = (caller(0))[3];

  croak "ERROR [$this_function] \$type is '$type', however it is expected to be either 'bam' or 'bed'\n"
    unless ($type eq "bam") || ($type eq "bed");

  my $genomeCoverageBed = can_run('genomeCoverageBed') or
    croak "ERROR [$this_function] genomeCoverageBed utility not found";
  my $bedGraphToBigWig = can_run('bedGraphToBigWig') or
    croak "ERROR [$this_function] bedGraphToBigWig utility not found";
  my $awk = can_run('awk') or
    croak "ERROR [$this_function] awk utility not found";

  if(defined $log){
    open(LOG, ">>", $log) or croak $!;
    print LOG "LOG [$this_function] \$infile: $infile\n";
    print LOG "LOG [$this_function] \$dest: $dest\n";
    print LOG "LOG [$this_function] \$chromsizes: $chromsizes\n";
  }

  croak "ERROR [$this_function] Cannot find $infile\n"
    unless (-e $infile);
  croak "ERROR [$this_function] $dest does not exist\n"
    unless (-d $dest);
  croak "ERROR [$this_function] Cannot find $chromsizes\n"
      unless (-e $chromsizes);

  if ($want_norm == 1){
    $factor = $scale/$size;
    print LOG "LOG [$this_function] normalization: $factor = ($scale/$size)\n"
      if(defined $log);
  }

  if ($type eq "bam"){$ext = ".bam";}
  else{$ext = ".bed";}
  $bn = basename($infile,$ext);
  $fn = fileparse($infile);

  $fn_bg_tmp  = file($dest,$fn.".tmp.bg");
  $fn_bg      = file($dest,$bn.".bg");
  if($strand eq "+"){
    $fn_bw  = file($dest,$bn.".pos.bw");
  }
  else {
    $fn_bw  = file($dest,$bn.".neg.bw");
  }

  $cmd = "$genomeCoverageBed -bg -scale $factor -split ";
  if ($type eq "bed"){ $cmd .= "-i $infile -g $chromsizes"; } # chrom.sizes only required for processing BED
  else { $cmd .= "-ibam $infile "; }
  $cmd .= " > $fn_bg_tmp";

  if($strand eq "-"){
    $cmd .= " && cat $fn_bg_tmp | $awk \'{ \$4 = - \$4 ; print \$0 }\' > $fn_bg";
  }
  else{
    $fn_bg = $fn_bg_tmp;
  }
  $cmd .= " && $bedGraphToBigWig $fn_bg $chromsizes $fn_bw";

  if (defined $log){ print LOG "LOG [$this_function] $cmd\n";}

  my( $success, $error_message, $full_buf, $stdout_buf, $stderr_buf ) =
    run( command => $cmd, verbose => 0 );

  if( !$success ) {
    print STDERR "ERROR [$this_function] External command call unsuccessful\n";
    print STDERR "ERROR: this is what the command printed:\n";
    print join "", @$full_buf;
    croak $!;
  }
  if (defined $log){ close(LOG); }

  unlink ($fn_bg_tmp);
  unlink ($fn_bg);
  return $fn_bw;
}

sub bed2bigBed {
  my ($infile,$chromsizes,$dest,$log) = @_;
  my ($bn,$path,$ext,$cmd,$outfile);
  my $this_function = (caller(0))[3];
  my $bed2bigBed = can_run('bedToBigBed') or
    croak "ERROR [$this_function] bedToBigBed utility not found";

  if (defined $log){
    open(LOG, ">>", $log) or croak $!;
    print LOG "LOG [$this_function] \$infile: $infile -- \$chromsizes: $chromsizes --\$dest: $dest\n";
  }

  croak "ERROR [$this_function] Cannot find $infile"
    unless (-e $infile);
  croak "ERROR [$this_function] Cannot find $chromsizes"
    unless (-e $chromsizes);
  croak "ERROR [$this_function] $dest does not exist"
    unless (-d $dest);

  # .bed6 .bed12 extensions are replaced by .bb
  ($bn,$path,$ext) = fileparse($infile, qr /\.bed[126]?/);
  $outfile = file($dest, "$bn.bb");

  $cmd = "$bed2bigBed $infile -extraIndex=name -tab $chromsizes $outfile";
  if (defined $log){ print LOG "LOG [$this_function] $cmd\n"; }
  my( $success, $error_message, $full_buf, $stdout_buf, $stderr_buf ) =
    run( command => $cmd, verbose => 0 );

  if( !$success ) {
    print STDERR "ERROR [$this_function] Call to $bed2bigBed unsuccessful\n";
    print STDERR "ERROR: this is what the command printed:\n";
    print join "", @$full_buf;
    croak $!;
  }

  if (defined $log){ close(LOG); }

  return $outfile;
}

sub sortbed {
  my ($infile,$dest,$outfile,$rm_orig,$log) = @_;
  my ($cmd,$out);
  my $this_function = (caller(0))[3];
  my $bedtools = can_run('bedtools') or
    croak "ERROR [$this_function] bedtools utility not found";

  croak "ERROR [$this_function] Cannot find $infile"
    unless (-e $infile);
  croak "ERROR [$this_function] $dest does not exist"
    unless (-d $dest);
  if (defined $log){open(LOG, ">>", $log) or croak $!;}

  $out = file($dest,$outfile);
  $cmd = "$bedtools sort -i $infile > $out";
  if (defined $log){ print LOG "LOG [$this_function] $cmd\n"; }
  my ( $success, $error_message, $full_buf, $stdout_buf, $stderr_buf ) =
    run( command => $cmd, verbose => 0 );
  if( !$success ) {
    print STDERR "ERROR [$this_function] Call to $bedtools unsuccessful\n";
    print STDERR "ERROR: this is what the command printed:\n";
    print join "", @$full_buf;
    croak $!;
  }

  if($rm_orig){
    unlink($infile) or
      carp "WARN [$this_function] Could not unlink $infile";
    if (defined $log){
      print LOG "[$this_function] removed $infile $!\n";
    }
  }

  if (defined $log){ close(LOG); }
}

sub unique_array{

    my $arrayref = shift;
    my @array = @{$arrayref};

    foreach my $item (@array)
    {
	$unique{$item} ++;
    }
    my @arrayuid = sort {$a cmp $b} keys %unique;

    return(\@arrayuid);
}

sub kmer_enrichment{

    my @seqs =  @{$_[0]};
    my $klen     = $_[1];
#    my @seq = split( //, $read_tmp );
    my $kstring ='';
#return variables
    my %km;
    foreach my $sequences (@seqs){
#      print STDERR $sequences,"\n";
      my @seq = split( //, $sequences );
      for ( my $seq_pos = 0; $seq_pos <= $#seq-$klen ; $seq_pos++ ) {
	for (my $i=$seq_pos;$i<=$seq_pos+($klen-1);$i++){
	  $kstring .= $seq[$i]; 
	}
	$km{$kstring}++;
	$kstring = "";
      }
    }
    return( \%km );
}

sub fetch_chrom_sizes{
  my $species = shift;
  my %sizes;
  my @chromsize;
  my $this_function = (caller(0))[3];

  my $test_fetchChromSizes = can_run('fetchChromSizes') or
    croak "ERROR [$this_function] fetchChromSizes utility not found";

  my $cmd = "fetchChromSizes $species";
  my( $success, $error_message, $full_buf, $stdout_buf, $stderr_buf ) = 
    run(command => $cmd, verbose => 0);
  if ($success){
    @chromsize = @{$stdout_buf};
  }
  else{
    carp "WARN [$this_function] Using UCSCs fetchChromSizes failed, trying alternative mysql fetch!\n";
    my $test_fetchChromSizes = can_run('mysql') or
      croak "ERROR [$this_function] mysql utility not found";
    $cmd = "mysql --user=genome --host=genome-mysql.cse.ucsc.edu -A -e \"select chrom, size from $species.chromInfo\"";  ### Alternative to UCSC fetchChromSizes, has mysql dependency
    my( $success, $error_message, $full_buf, $stdout_buf, $stderr_buf ) =
      run(command => $cmd, verbose => 0);
    if ($success){
      @chromsize = @{$stdout_buf};
    }
    else{
      carp "ERROR [$this_function] External command call unsuccessful\n";
      carp "ERROR [$this_function] this is what the command printed:\n";
      print join "", @$full_buf;
      confess "Fetching of chromosome sizes failed, please either download fetchChromSizes from the UCSC script collection, or install mysql!\n";
    }
  }

  foreach (@chromsize){
    chomp($_);
    foreach (split(/\n/,$_)){
      my ($chr,$size)=split (/\t/,$_);
      $sizes{$chr}=$size;
    }
  }

  return(\%sizes);
}

sub mkdircheck {
  my @dirstocreate=();
  my $this_function = (caller(0))[3];
  while(@_){
    push @dirstocreate, shift(@_);
  }
  foreach (@dirstocreate){
    my @total = split(/[\/\\]/,$_);
    if ($total[0] eq '~'){
      $total[0]=$HOME;
      carp "WARNING [$this_function] replacing \'~\' in path with \'$HOME\'";
    }
    my $dir;
    while(@total){
      $dir = dir(shift(@total)) unless (defined $dir);
      $dir = dir($dir,shift(@total));
    }
    my $check = $dir->stringify();
    return if (-d $check);
    make_path($dir,{ verbose => 0 }) or
      croak "ERROR [$this_function] Cannot create directory $check";
  }
}

sub rmdircheck {
  my @dirstorm=();
  my $this_function = (caller(0))[3];
  while(@_){
    push @dirstorm, shift(@_);
  }
  foreach (@dirstorm){
    my @total = split(/[\/\\]/,$_);
    my $dir;
    while(@total){
      $dir = dir(shift(@total)) unless (defined $dir);
      $dir = dir($dir,shift(@total));
    }
    my $check = $dir->stringify();
    return if (!-d $check);
    remove_tree($dir,{ verbose => 0 }) or
      croak "ERROR [$this_function] Cannot remove directory $check";
  }
}

1;
__END__


=head1 NAME

Bio::ViennaNGS::Util - Utility routines for Next-Generation Sequencing data
analysis

=head1 SYNOPSIS

  use Bio::ViennaNGS::Util;

  # make bigWig from BED or BAM
  $type = "bam";
  $strand = "+";
  $bwfile = bed_or_bam2bw($type,$infile,$cs_in,$strand,$destdir,$wantnorm,$size_p,$scale,$logfile);

  # make bigBed from BED
  my $bb = bed2bigBed($bed_in,$cs_in,$destdir,$logfile);

  # sort a BED file 
  sortbed($bed_in,$destdir,$bed_out,$rm_orig,$logfile)

=head1 DESCRIPTION

Bio::ViennaNGS::Util is a collection of utility subroutines for
building efficient Next-Generation Sequencing (NGS) data analysis
pipelines.

=head2 ROUTINES

=over

=item bed_or_bam2bw($type,$infile,$chromsizes,$strand,$dest,$want_norm,$size,$scale,$log)

Creates stranded, normalized BigWig coverage profiles from
strand-specific BAM or BED files (provided via C<$infile>). The
routine expects a file type 'bam' or 'bed' via the C<$type>
argument. C<$chromsizes> is the chromosome.sizes files, C<$strand> is
either "+" or "-" and C<$dest> contains the output path for
results. For normlization of bigWig profiles, additional attributes
are required: C<$want_norm> triggers normalization with values 0 or
1. C<$size> is the number of fragments/elements in the BAM or BED file
and C<$scale> gives the number to which data is normalized (ie. every
bedGraph entry is multiplied by a factor (C<$scale>/C<$size>). C<$log>
is expected to contain either the full path and file name of log file
or 'undef'. The routine returns the full file name of the newly
generated bigWig file.

While this routine can handle non-straned BAM/BED files (in which case
C<$strand> should be set to "+" and hence all coverage profiles will
be created with a positive sign, even if they map to the negative
strand), usage of strand-specific data is highly recommended. For BAM
file, this is easily achieved by calling the L<bam_split> routine (see
above) prior to this one, thus creating dedicated BAM files containing
exclusively reads mapped to the positive or negative strand,
respectively.

It is important to know that this routine B<does not extract> reads
mapped to either strand from a non-stranded BAM/BED file if the
C<$strand> argument is given. It rather adjusts the sign of B<all>
mapped reads/features in a BAM/BED file and then creates bigWig
files. See the L<split_bam> routine for extracting reads mapped to
either strand.

Stranded bigWigs can easily be visualized via
L<TrackHubs|http://genome.ucsc.edu/goldenPath/help/hgTrackHubHelp.html>
in the UCSC Genome Browser. Internally, the conversion from BAM/BED to
bigWig is accomplished via two third-party applications:
L<genomeCoverageBed|http://bedtools.readthedocs.org/en/latest/content/tools/genomecov.html>
and
L<bedGraphToBigWig|http://hgdownload.cse.ucsc.edu/admin/exe/>. Intermediate
bedGraph files are removed automatically once the bigWig files are
ready.

=item sortbed($infile,$dest,$outfile,$rm_orig,$log)

Sorts BED file C<$infile> with F<bedtools sort>. C<$dest> and
C<outfile> name path and filename of the resulting sorted BED
file. C<$rm_infile> is either 1 or 0 and indicated whether the
original C<$infile> should be deleted. C<$log> holds path and name of
log file.

=item bed2bigBed($infile,$chromsizes,$dest,$log)

Creates an indexed bigBed file from a BED file. C<$infile> is the BED
file to be transformed, C<$chromsizes> is the chromosome.sizes file
and C<$dest> contains the output path for results. C<$log> is the name
of a log file, or undef if no logging is reuqired. A '.bed', '.bed6'
or '.bed12' suffix in C<$infile> will be replaced by '.bb' in the
output. Else, the name of the output bigBed file will be the value of
C<$infile> plus '.bb' appended.

The conversion from BED to bigBed is done by a third-party utility
(bedToBigBed), which is executed by L<IPC::Cmd>.


=item unique_array($arrayref)

Takes a reference to an array and uniques entries via hash copy.
Returns a reference to an array containing unique values.

=item kmer_enrichment($seqs,$klen)

Takes a reference to a sequence array and the length of the desired
kmer. Counts occurences of kmers of given length and returns a
reference to a hash containing the kmer as key and occurences as
value.

=item fetch_chrom_sizes($species)

Takes the name of the desired species (e.g. hg19, mm9, ..) and
retrieves annotated chromosomes and their sizes from UCSC. This
methods returns a reference to a hash containing chromosomes as kays
and their corresponding size as value. Either uses the fetchChromSizes
util of the UCSC bin collection or alternatively and if mysql is
available via a mysql command.

=item mkdircheck(@dirs)

Takes the path to one or more directories, converts them to an OS
specific path and creates directories.

=item rmdircheck(@dirs)

Takes the path to one or more directories, converts them to an OS
specific path and removes directories.

=back

=head1 DEPENDENCIES

=over

=item L<Bio::Perl> >= 1.00690001

=item L<File::Basename>

=item L<File::Path>

=item L<Path::Class>

=item L<IPC::Cmd>

=item L<Math::Round>

=item L<Carp>

=back

L<Bio::ViennaNGS> uses third-party tools for computing intersections
of BED files: F<bedtools intersect> from the
L<BEDtools|http://bedtools.readthedocs.org/en/latest/content/tools/intersect.html>
suite is used to compute overlaps and F<bedtools sort> is used to sort
BED output files. Make sure that those third-party utilities are
available on your system, and that hey can be found and executed by
the Perl interpreter. We recommend installing the latest version of
L<BEDtools|https://github.com/arq5x/bedtools2> on your system.

Examples for using most of the provided methods can be found at L<ViennaNGS::Tutorial>.

=head1 AUTHORS

=over

=item Michael T. Wolfinger E<lt>michael@wolfinger.euE<gt>

=item Joerg Fallmann E<lt>fall@tbi.univie.ac.atE<gt>

=back

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2015-2017 Michael T. Wolfinger E<lt>michael@wolfinger.euE<gt>

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.10.0 or,
at your option, any later version of Perl 5 you may have available.

This software is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

=cut
