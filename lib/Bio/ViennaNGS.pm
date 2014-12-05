# -*-CPerl-*-
# Last changed Time-stamp: <2014-12-05 15:44:48 mtw>

package Bio::ViennaNGS;

use 5.12.0;
use Exporter;
use version; our $VERSION = qv('0.11_02');
use strict;
use warnings;
use Bio::Perl 1.006924;
use Bio::DB::Sam 1.39;
use Data::Dumper;
use File::Basename qw(basename fileparse);
use File::Temp qw(tempfile);
use IPC::Cmd qw(can_run run);
use Path::Class;
use Carp;

our @ISA = qw(Exporter);
our @EXPORT = ();
our @EXPORT_OK = qw ( split_bam uniquify_bam bed_or_bam2bw
		    sortbed bed2bigBed computeTPM featCount_data
		    parse_multicov write_multicov totalreads );

#^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^#
#^^^^^^^^^^ Variables ^^^^^^^^^^^#
#^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^#

our @featCount = ();

#^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^#
#^^^^^^^^^^^ Subroutines ^^^^^^^^^^#
#^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^#

sub featCount_data {
  return \@featCount;
}

sub split_bam {
  my %data = ();
  my @NHval = ();
  my @processed_files = ();
  my $verbose = 0;
  my ($bamfile,$reverse,$want_uniq,$want_bed,$dest_dir,$log) = @_;
  my ($bam,$sam,$bn,$path,$ext,$header,$flag,$NH,$eff_strand,$tmp);
  my ($bam_pos,$bam_neg,$tmp_bam_pos,$tmp_bam_neg,$bamname_pos,$bamname_neg);
  my ($bed_pos,$bed_neg,$bedname_pos,$bedname_neg);
  my ($seq_id,$start,$stop,$strand,$target_names,$id,$score);
  my $this_function = (caller(0))[3];
  my %count_entries = (
		       total     => 0,
		       uniq      => 0,
		       pos       => 0,
		       neg       => 0,
		       skip      => 0,
		       cur       => 0,
		       mult      => 0,
		       se_alis   => 0,
		       pe_alis   => 0,
		       flag      => 0,
		      );
  $data{count} = \%count_entries;
  $data{flag} = ();

  croak "ERROR [$this_function] $bamfile does not exist\n"
    unless (-e $bamfile);
  croak "ERROR [$this_function] $dest_dir does not exist\n"
    unless (-d $dest_dir);

  open(LOG, ">", $log) or croak $!;

  (undef,$tmp_bam_pos) = tempfile('BAM_POS_XXXXXXX',UNLINK=>0);
  (undef,$tmp_bam_neg) = tempfile('BAM_NEG_XXXXXXX',UNLINK=>0);

  $bam = Bio::DB::Bam->open($bamfile, "r");
  $header = $bam->header;
  $target_names = $header->target_name;

  ($bn,$path,$ext) = fileparse($bamfile, qr /\..*/);
  unless ($dest_dir =~ /\/$/){$dest_dir .= "/";}
  $bamname_pos = $dest_dir.$bn.".pos".$ext;
  $bamname_neg = $dest_dir.$bn.".neg".$ext;
  $bam_pos = Bio::DB::Bam->open($tmp_bam_pos,'w')
    or croak "ERROR [$this_function] Could not open bam_pos file for writing: $!";
  $bam_neg = Bio::DB::Bam->open($tmp_bam_neg,'w')
    or croak "ERROR [$this_function] Could not open bam_neg file for writing: $!";

  if ($want_bed == 1){
     $bedname_pos = $dest_dir.$bn.".pos.bed";
     $bedname_neg = $dest_dir.$bn.".neg.bed";
     open($bed_pos, ">", $bedname_pos); open($bed_neg, ">", $bedname_neg);
  }

  $bam_pos->header_write($header);$bam_neg->header_write($header);
  if($reverse == 1) {  # switch +/- strand mapping
    $tmp = $bam_pos;$bam_pos = $bam_neg;$bam_neg = $tmp;
    $tmp = $bed_pos;$bed_pos = $bed_neg;$bed_neg = $tmp;
  }

  while (my $read= $bam->read1() ) {
    @NHval = ();
    $data{count}{total}++;
    if($verbose == 1){print STDERR $read->query->name."\t";}

    # check if NH (the SAM tag used to indicate multiple mappings) is set
    if ($read->has_tag("NH")) {
      @NHval = $read->get_tag_values("NH");
      $NH = $NHval[0];
      if ($NH == 1) {
	$data{count}{uniq}++;
	if ($verbose == 1) {print STDERR "NH:i:1\t";}
      }
      else {
	$data{count}{mult}++;
	if ($verbose == 1) {print STDERR "NH:i:".$NH."\t";}
	if ($want_uniq == 1) { # skip processing this read if it is a mutli-mapper
	  $data{count}{skip}++;
	  next;
	}
      }
      $data{count}{cur}++;
    }
    else{ carp "WARN [$this_function] Read ".$read->query->name." does not have NH attribute\n";}

  #  print Dumper ($read->query);
    $strand = $read->strand;
    $seq_id = $target_names->[$read->tid];
    $start  = $read->start;
    $stop   = $read->end;
    $id     = "x"; # $read->qname; 
    $score  = 100;

    if ( $read->get_tag_values('PAIRED') ) { # paired-end
      if($verbose == 1) {print STDERR "pe\t";}
      $data{count}{pe_alis}++;
      if ( $read->get_tag_values('FIRST_MATE') ){ # 1st mate; take its strand as granted
	if($verbose == 1) {print STDERR "FIRST_MATE\t".$strand." ";}
	if ( $strand eq "1" ){
	  $bam_pos->write1($read);
	  if ($want_bed){printf $bed_pos "%s\t%d\t%d\t%s\t%d\t",$seq_id,eval($start-1),$stop,$id,$score;}
	  if ($reverse == 0){
	    $data{count}{pos}++; $eff_strand=$strand;
	    if ($want_bed){printf $bed_pos "%s\n", "+";}
	  }
	  else {
	    $data{count}{neg}++; $eff_strand=-1*$strand;
	    if ($want_bed){printf $bed_pos "%s\n", "-";}
	  }
	}
	elsif ($strand eq "-1") {
	  $bam_neg->write1($read);
	  if ($want_bed){printf $bed_neg "%s\t%d\t%d\t%s\t%d\t",$seq_id,eval($start-1),$stop,$id,$score;}
	  if ($reverse == 0){
	    $data{count}{neg}++; $eff_strand=$strand;
	    if ($want_bed){printf $bed_neg "%s\n", "-";}
	  }
	  else {
	    $data{count}{pos}++;$eff_strand=-1*$strand;
	    if ($want_bed){printf $bed_neg "%s\n", "+";}
	  }
	}
	else {croak "Strand neither + nor - ...exiting!\n";}
      }
      else{ # 2nd mate; reverse strand since the fragment it belongs to is ALWAYS located
            # on the other strand
	if($verbose == 1) {print STDERR "SECOND_MATE\t".$strand." ";}
	if ( $strand eq "1" ) {
	  $bam_neg->write1($read);
	  if ($want_bed){printf $bed_neg "%s\t%d\t%d\t%s\t%d\t",$seq_id,eval($start-1),$stop,$id,$score;}
	  if ($reverse == 0){
	    $data{count}{neg}++;$eff_strand=$strand;
	    if ($want_bed){printf $bed_neg "%s\n", "-";}
	  }
	  else {
	    $data{count}{pos}++; $eff_strand=-1*$strand;
	    if ($want_bed){printf $bed_neg "%s\n", "+";}
	  }
	}
	elsif ( $strand eq "-1" ) {
	  $bam_pos->write1($read);
	  if ($want_bed){printf $bed_pos "%s\t%d\t%d\t%s\t%d\t",$seq_id,eval($start-1),$stop,$id,$score;}
	  if ($reverse == 0){
	    $data{count}{pos}++;$eff_strand=$strand;
	    if ($want_bed){printf $bed_pos "%s\n", "+";}
	  }
	  else {
	    $data{count}{neg}++;$eff_strand=-1*$strand;
	    if ($want_bed){printf $bed_pos "%s\n", "-";}
	  }
	}
	else {croak "Strand neither + nor - ...exiting!\n";}
      }
    }
    else { # single-end
      if($verbose == 1) {print STDERR "se\t";}
      $data{count}{se_alis}++;
      if ( $read->strand eq "1" ){
	$bam_pos->write1($read);
	if ($want_bed){printf $bed_pos "%s\t%d\t%d\t%s\t%d\t",$seq_id,eval($start-1),$stop,$id,$score;}
	if ($reverse == 0){
	  $data{count}{pos}++;$eff_strand=$strand;
	  if ($want_bed){printf $bed_pos "%s\n", "+";}
	}
	else {
	  $data{count}{neg}++;$eff_strand=-1*$strand;
	  if ($want_bed){printf $bed_pos "%s\n", "-";}
	}
      }
      elsif ($read->strand eq "-1") {
	$bam_neg->write1($read);
	if ($want_bed){printf $bed_neg "%s\t%d\t%d\t%s\t%d\t",$seq_id,eval($start-1),$stop,$id,$score;}
	if ($reverse == 0){
	  $data{count}{neg}++;$eff_strand=$strand;
	  if ($want_bed){printf $bed_neg "%s\n", "-";}
	}
	else {
	  $data{count}{pos}++;$eff_strand=-1*$strand;
	  if ($want_bed){printf $bed_neg "%s\n", "+";}
	}
      }
      else {croak "Strand neither + nor - ...exiting!\n";}
    }
    if($verbose == 1) {print STDERR "--> ".$eff_strand."\t";}

    # collect statistics of SAM flags
    $flag = $read->flag;
    unless (exists $data{flag}{$flag}){
      $data{flag}{$flag} = 0;
    }
    $data{flag}{$flag}++;
    if ($verbose == 1) {print STDERR "\n";}
  } # end while

  rename ($tmp_bam_pos, $bamname_pos);
  rename ($tmp_bam_neg, $bamname_neg);
  push (@processed_files, ($bamname_pos,$bamname_neg));
  push (@processed_files, ($data{count}{pos},$data{count}{neg}));
  if ($want_bed){
    push (@processed_files, ($bedname_pos,$bedname_neg))
  }

  # error checks
  unless ($data{count}{pe_alis} + $data{count}{se_alis} == $data{count}{cur}) {
    printf "ERROR:  paired-end + single-end alignments != total alignment count\n";
    print Dumper(\%data);
    croak $!;
  }
  unless ($data{count}{pos} + $data{count}{neg} == $data{count}{cur}) {
    printf STDERR "%20d fragments on [+] strand\n",$data{count}{pos};
    printf STDERR "%20d fragments on [-] strand\n",$data{count}{neg};
    printf STDERR "%20d sum\n",eval($data{count}{pos}+$data{count}{neg});
    printf STDERR "%20d cur_count (should be)\n",$data{count}{cur};
    printf STDERR "ERROR: pos alignments + neg alignments != total alignments\n";
    print Dumper(\%data);
    croak $!;
  }
  foreach (keys %{$data{flag}}){
    $data{count}{flag} += $data{flag}{$_};
  }
  unless ($data{count}{flag} == $data{count}{cur}){
    printf STDERR "%20d alignments considered\n",$data{count}{cur};
    printf STDERR "%20d alignments found in flag statistics\n",$data{count}{flag};
    printf STDERR "ERROR: #considered alignments != #alignments from flag stat\n";
    print Dumper(\%data);
    croak $!;
  }

  # logging output
  printf LOG "# bam_split.pl log for file \'$bamfile\'\n";
  printf LOG "#-----------------------------------------------------------------\n";
  printf LOG "%20d total alignments (unique & multi-mapper)\n",$data{count}{total};
  printf LOG "%20d unique-mappers (%6.2f%% of total)\n",
    $data{count}{uniq},eval(100*$data{count}{uniq}/$data{count}{total}) ;
  printf LOG "%20d multi-mappers  (%6.2f%% of total)\n",
    $data{count}{mult},eval(100*$data{count}{mult}/$data{count}{total});
  printf LOG "%20d multi-mappers skipped\n", $data{count}{skip};
  printf LOG "%20d alignments considered\n", $data{count}{cur};
  printf LOG "%20d paired-end\n", $data{count}{pe_alis};
  printf LOG "%20s single-end\n", $data{count}{se_alis};
  printf LOG "%20d fragments on [+] strand  (%6.2f%% of considered)\n",
    $data{count}{pos},eval(100*$data{count}{pos}/$data{count}{cur});
  printf LOG "%20d fragments on [-] strand  (%6.2f%% of considered)\n",
    $data{count}{neg},eval(100*$data{count}{neg}/$data{count}{cur});
  printf LOG "#-----------------------------------------------------------------\n";
  printf LOG "Dumper output:\n". Dumper(\%data);
  close(LOG);
  return @processed_files;
}

sub uniquify_bam {
  my ($bamfile,$dest,$log) = @_;
  my ($bam, $bn,$path,$ext,$read,$header);
  my ($tmp_uniq,$tmp_mult,$fn_uniq,$fn_mult,$bam_uniq,$bam_mult);
  my ($count_all,$count_uniq,$count_mult) = (0)x3;
  my @processed_files = ();
  my $this_function = (caller(0))[3];

  croak "ERROR [$this_function] Cannot find $bamfile\n"
    unless (-e $bamfile);
  croak "ERROR [$this_function] $dest does not exist\n"
    unless (-d $dest);

  ($bn,$path,$ext) = fileparse($bamfile, qr /\..*/);

  (undef,$tmp_uniq) = tempfile('BAM_UNIQ_XXXXXXX',UNLINK=>0);
  (undef,$tmp_mult) = tempfile('BAM_MULT_XXXXXXX',UNLINK=>0);

  $bam     = Bio::DB::Bam->open($bamfile, "r");
  $fn_uniq = file($dest,$bn.".uniq".$ext);
  $fn_mult = file($dest,$bn.".mult".$ext);
  $header  = $bam->header; # TODO: modify header, leave traces ...

  $bam_uniq = Bio::DB::Bam->open($tmp_uniq,'w')
    or croak "ERROR [$this_function] Cannot open temp file for writing: $!";
  $bam_mult = Bio::DB::Bam->open($tmp_mult,'w')
    or croak "ERROR [$this_function] Cannot open temp file for writing: $!";
  $bam_uniq->header_write($header);
  $bam_mult->header_write($header);

  while ($read = $bam->read1() ) {
    $count_all++;
    if ($read->aux_get("NH") == 1){ # uniquely mapped reads
      $bam_uniq->write1($read);
      $count_uniq++;
    }
    else { # multiply mapped reads
      $bam_mult->write1($read);
      $count_mult++;
    }
  }

  croak "ERROR [$this_function] Read counts don't match\n"
    unless ($count_uniq + $count_mult == $count_all);

  rename ($tmp_uniq, $fn_uniq);
  rename ($tmp_mult, $fn_mult);
  push (@processed_files, ($fn_uniq,$fn_mult));

  if (defined $log){
    my $lf = file($dest,$log);
    open(LOG, ">>", $lf) or croak $!;
    printf LOG "%15d reads total\n%15d unique reads\n%15d multiple reads\n",
      $count_all,$count_uniq,$count_mult;
    close(LOG);
  }
}

sub bed_or_bam2bw {
  my ($type,$infile,$chromsizes,$strand,$dest,$want_norm,$size,$scale,$log) = @_;
  my ($fn_bg_tmp,$fn_bg,$fn_bw);
  my ($bn,$path,$ext,$cmd);
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

  ($bn,$path,$ext) = fileparse($infile, qr /\..*/);
  $fn_bg_tmp  = file($dest,$bn.".tmp.bg");
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
    croak "ERROR [$this_function bedtools utility not found";

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

sub computeTPM {
  my ($featCount_sample,$rl) = @_;
  my ($TPM,$T,$totalTPM) = (0)x3;
  my ($i,$features,$meanTPM);

  $features = keys %$featCount_sample; # of of features in hash

  # iterate through $featCount_sample twice:
  # 1. for computing T (denominator in TPM formula)
  foreach $i (keys %$featCount_sample){
    $T += ($$featCount_sample{$i}{count} * $rl)/($$featCount_sample{$i}{len});
  }
  # 2. for computng actual TPM values
  foreach $i (keys %$featCount_sample){
    $TPM = 1000000 * $$featCount_sample{$i}{count} * $rl/($$featCount_sample{$i}{len} * $T);
    $$featCount_sample{$i}{TPM} = $TPM;
    $totalTPM += $TPM;
  }
  $meanTPM = $totalTPM/$features;
  # print "totalTPM=$totalTPM | meanTPM=$meanTPM\n";
  return $meanTPM;
}

sub parse_multicov {
  my ($file) = @_;
  my @mcData = ();
  my ($mcSamples,$i);

  croak "ERROR: multicov file $file not available\n" unless (-e $file);
  open (MULTICOV_IN, "< $file") or croak $!;

  while (<MULTICOV_IN>){
    chomp;
    @mcData = split(/\t/); # 0:chr|1:start|2:end|3:name|4:score|5:strand
    $mcSamples = (scalar @mcData)-6; # multicov extends BED6
    #print "$_\n";
    for ($i=0;$i<$mcSamples;$i++){
      $featCount[$i]{$mcData[3]} = {
				    chr    => $mcData[0],
				    start  => $mcData[1],
				    end    => $mcData[2],
				    name   => $mcData[3],
				    score  => $mcData[4],
				    strand => $mcData[5],
				    len    => eval($mcData[2]-$mcData[1]),
				    count  => $mcData[eval(6+$i)],
				   }
    }
    #print Dumper(@mcData);
  }
  close(MULTICOV_IN);
  return $mcSamples;
}

sub write_multicov {
  my ($item,$dest_dir,$base_name) = @_;
  my ($outfile,$mcSamples,$nrFeatures,$feat,$i);
  my $this_function = (caller(0))[3];

  croak "ERROR [$this_function]: $dest_dir does not exist\n"
    unless (-d $dest_dir);
  $outfile = $dest_dir.$base_name.".".$item.".multicov.csv";
  open (MULTICOV_OUT, "> $outfile") or croak $!;

  $mcSamples = scalar @featCount; # of samples in %{$featCount}
  $nrFeatures = scalar keys %{$featCount[1]}; # of keys in %{$featCount}[1]
  #print "=====> write_multicov: writing multicov file $outfile with $nrFeatures lines and $mcSamples conditions\n";

  # check whether each column in %$featCount has the same number of entries
  for($i=0;$i<$mcSamples;$i++){
    my $fc = scalar keys %{$featCount[$i]}; # of keys in %{$featCount}
    #print "condition $i => $fc keys\n";
    unless($nrFeatures == $fc){
      croak "ERROR [$this_function]: unequal element count in \%\$featCount\nExpected $nrFeatures have $fc in condition $i\n";
    }
  }

  foreach $feat (keys  %{$featCount[1]}){
    my @mcLine = ();
    # process standard BED6 fields first
    push @mcLine, (${$featCount[1]}{$feat}->{chr},
		   ${$featCount[1]}{$feat}->{start},
		   ${$featCount[1]}{$feat}->{end},
		   ${$featCount[1]}{$feat}->{name},
		   ${$featCount[1]}{$feat}->{score},
		   ${$featCount[1]}{$feat}->{strand});
    # process multicov values for all samples

    for($i=0;$i<$mcSamples;$i++){
     # print "------------>  ";  print "processing $i th condition ";  print "<-----------\n";
      unless (defined ${$featCount[$i]}{$feat}){
	croak "Could not find item $feat in mcSample $i\n";
      }
      push @mcLine, ${$featCount[$i]}{$feat}->{$item};

    }
    #print Dumper(\@mcLine);
    print MULTICOV_OUT join("\t",@mcLine)."\n";
  }
  close(MULTICOV_OUT);
}

sub totalreads {
  return 1;
}

1;
__END__


=head1 NAME

Bio::ViennaNGS - Perl extension for Next-Generation Sequencing
analysis

=head1 SYNOPSIS

  use Bio::ViennaNGS;

  # split a single-end  or paired-end BAM file by strands
  @result = split_bam($bam_in,$rev,$want_uniq,$want_bed,$destdir,$logfile);

  # extract unique and multi mappers from a BAM file
  @result = uniquify_bam($bam_in,$outdir,$logfile);

  # make bigWig from BED or BAM
  $type = "bam";
  $strand = "+";
  $bwfile = bed_or_bam2bw($type,$infile,$cs_in,$strand,$destdir,$wantnorm,$size_p,$scale,$logfile);

  # make bigBed from BED
  my $bb = bed2bigBed($bed_in,$cs_in,$destdir,$logfile);

  # sort a BED file 
  sortbed($bed_in,$destdir,$bed_out,$rm_orig,$logfile)

  # compute transcript abundance in TPM
  $meanTPM = computeTPM($sample,$readlength);

  # parse a bedtools multicov compatible file
  $conds = parse_multicov($infile);

  # write bedtools multicov compatible file
  write_multicov("TPM",$destdir,$basename);

=head1 DESCRIPTION

Bio::ViennaNGS is a collection of utilities and subroutines for
building efficient Next-Generation Sequencing (NGS) data analysis
pipelines.

=head2 ROUTINES

=over

=item split_bam($bam,$reverse,$want_uniq,$want_bed,$dest_dir,$log)

Splits BAM file $bam according to [+] and [-] strand. C<$reverse>,
C<$want_uniq> and C<$want_bed> are switches with values of 0 or 1,
triggering forced reversion of strand mapping (due to RNA-seq protocol
constraints), filtering of unique mappers (identified via NH:i:1 SAM
argument), and forced output of a BED file corresponding to
strand-specific mapping, respectively. C<$log> holds name and path of
the log file.

Strand-splitting is done in a way that in paired-end alignments, FIRST
and SECOND mates (reads) are treated as _one_ fragment, ie FIRST_MATE
reads determine the strand, while SECOND_MATE reads are assigned the
opposite strand I<per definitionem>. This also holds if the reads are
not mapped in proper pairs and even if there is no mapping partner at
all.

Sometimes the library preparation protocol causes inversion of the
read assignment (with respect to the underlying annotation). In those
cases, the natural mapping of the reads can be obtained by the
C<$reverse> flag.

This routine returns an array whose fist two elements are the file
names of the newly generate BAM files with reads mapped to the
positive, and negative strand, respectively. Elements three and four
are the number of fragments mapped to the positive and negative
strand. If the C<$want_bed> option was given elements fiveand six are
the file names of the output BED files for positive and negative
strand, respectively.

NOTE: Filtering of unique mappers is only safe for single-end
experiments; In paired-end experiments, read and mate are treated
separately, thus allowing for scenarios where eg. one read is a
multi-mapper, whereas its associate mate is a unique mapper, resulting
in an ambiguous alignment of the entire fragment.

=item uniquify_bam($bam,$dest,$log)

Extract I<unique> and I<multi> mapping reads from BAM file
C<$bam>. New BAM files for unique and multi mappers are created in the
output folder C<$dest>, which are named B<basename.uniq.bam> and
B<basename.mult.bam>, respectively. If defined, a logfile named
C<$log> is created in the output folder.

This routine returns an array holding file names of the newly created
BAm files for unique and multi mappers, respectively.

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

Sorts BED file C<$infile> with F<bedtools sortt>. C<$dest> and
C<outfile> name path and filename of the resulting sorted BED
file. C<$rm_infile> is either 1 or 0 and indicated whether the
original C<$infile> should be deleted. C<$log> holds path and name of
log file.

=item bed2bigBed($infile,$chromsizes,$dest,$log)

Creates an indexed bigBed file from a BED file. C<$infile> is the BED
file to be transformed, C<$chromsizes> is the chromosome.sizes file
and C<$dest> contains the output path for results. C<$log> is the name
of a log file, or undef if no logging is reuqired. A '.bed', '.bed6'
or '.bed12' suffix in C<$infile> will be replace by '.bb' in the
output. Else, the name of the output bigBed file will be the value of
C<$infile> plus '.bb' appended.

The conversion from BED to bigBed is done by a third-party utility
(bedToBigBed), which is executed by IPC::Cmd.

=item computeTPM($featCount_sample,$rl)

Computes expression in Transcript per Million (TPM) [Wagner
et.al. Theory Biosci. (2012)]. C<$featCount_sample> is a reference to
a Hash of Hashes data straucture where keys are feature names and
values hold a hash that must at least contain length and raw read
counts. Practically, C<$featCount_sample> is represented by _one_
element of C<@featCount>, which is populated from a multicov file by
C<parse_multicov()>. C<$rl> is the read length of the sequencing run.

Returns the mean TPM of the processed sample, which is invariant among
samples. (TPM models relative molar concentration and thus fulfills
the invariant average criterion.)

=item parse_multicov($file)

Parse a bedtools multicov (multiBamCov) file, i.e. an extended BED6
file, into an Array of Hash of Hashes data structure
(C<@featCount>). C<$file> is the input file. Returns the number of
samples present in the multicov file, ie. the numner of columns
extending the canonical BED6 columns in the input multicov file.

=item write_multicov($item,$dest_dir,$base_name)

Write C<@featCount> data to a bedtools multicov (multiBamCov)-type
file. C<$item> specifies the type of information from C<@featCount>
HoH entries, e.g. TPM or RPKM. These values must have been computed
and inserted into C<@featCount> beforehand by
e.g. C<computeTPM()>. C<$dest_dir> gives the absolute path and
C<$base_name> the basename (will be extended by C<$item>.csv) of the
output file.

=back

=head1 DEPENDENCIES

=over 7

=item  L<Bio::Perl> >= 1.006924

=item  L<BIO::DB::Sam> >= 1.39

=item  L<File::Basename>

=item  L<File::Temp>

=item  L<Path::Class>

=item  L<IPC::Cmd>

=item  L<Carp>

=back

L<Bio::ViennaNGS> uses third-party tools for computing intersections
of BED files: F<bedtools intersect> from the
L<BEDtools|http://bedtools.readthedocs.org/en/latest/content/tools/intersect.html>
suite is used to compute overlaps and F<bedtools sort> is used to sort
BED output files. Make sure that those third-party utilities are
available on your system, and that hey can be found and executed by
the Perl interpreter. We recommend installing the latest version of
L<BEDtools|https://github.com/arq5x/bedtools2> on your system.

=head1 SEE ALSO

=over 4

=item L<Bio::ViennaNGS::AnnoC>

=item L<Bio::ViennaNGS::UCSC>

=item L<Bio::ViennaNGS::SpliceJunc>

=item L<Bio::ViennaNGS::Fasta>

=back

=head1 AUTHORS

=over

=item Michael T. Wolfinger E<lt>michael@wolfinger.euE<gt>

=item Jörg Fallmann E<lt>fall@tbi.univie.ac.atE<gt>

=item Florian Eggenhofer E<lt>florian.eggenhofer@tbi.univie.ac.atE<gt>


=back

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2014 Michael T. Wolfinger E<lt>michael@wolfinger.euE<gt>

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.12.4 or,
at your option, any later version of Perl 5 you may have available.

This software is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

=cut
