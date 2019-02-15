#!/bin/env perl
# -*-mode:cperl;buffer-cleanup-p:t;buffer-read-only:t-*-
# Time-stamp: <2008-09-05 18:48:32 dky>
#------------------------------------------------------------------------------
# Perforce (p4) to mercurial (hg) incremental repository conversion
# Copyright (C) 2008  Dhruva Krishnamurthy <xshelf@yahoo.com>

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#------------------------------------------------------------------------------

#------------------------------------------------------------------------------
# File : p4hg.pl
# Desc : Incrementally import p4 changes into mercurial
# TODO :
#        o Make this mess modular
#        o Submitting to p4 from mercurial
#------------------------------------------------------------------------------
my $force_SYNC = 0;

my $p4DIR = '.hg/.p4';
my $DEV_NULL = '/dev/null';
my $debug = 0;
my $hgroot = '';
my $is_clone = 0;
my @changes = ();
my @h_changes = ();
my $p4_depot = 0;
my $corruptions = 0;
my $cmd_arg_length = 500;	# Hope this results in a small enough cmd line!

sub DBGPRN {
  if ($debug) {
    print STDERR @_;
  }
}

sub OnInterrupt {
  print STDERR "Caught a signal/interrupt, bailing out...";
  exit 0;
}

# Set signal handlers just before actual updation
use sigtrap 'handler',\&OnInterrupt,'error-signals';
use sigtrap 'handler',\&OnInterrupt,'normal-signals';

#------------------------------------------------------------------------------
#                              CHECK FOR VALID DVCS
#------------------------------------------------------------------------------

#------------------------------------------------------------------------------
#                                HG SPECIFIC
#------------------------------------------------------------------------------
# Get hg root
open(HGROOT,"hg -q root|")
  || die("Error: \"hg -q root\" failed");
$hgroot= <HGROOT>;
close(HGROOT);
chomp($hgroot);
if (-d $hgroot) {
  chdir($hgroot);
} else {
  die("Error: hgroot \"$hgroot\" does not exist\n");
}
# Check for uncomitted local changes
{
  open(HGSTAT,"hg -q --config defaults.status= status|")
    || die("Error: \"hg -q --config defaults.status= status\" failed");
  my $tainted = 0;
  while (<HGSTAT>) {
    chomp();
    if (/^[ \t]*$/) {
      next;
    }
    $tainted = 1;
    last;
  }
  close(HGSTAT);
  if (0 != $tainted) {
    print STDERR "Error: Repository has uncomitted changes, bailing out!\n";
    exit -1;
  }
}
#------------------------------------------------------------------------------


# Create some initial working folders
if (! -d $p4DIR) {
  mkdir("$p4DIR", 0755);
}
if (! -d "$p4DIR/tmp") {
  mkdir("$p4DIR/tmp", 0755);
}

# Parse some basic command line options
if ($#ARGV >= 0) {
  if ($ARGV[0]=~m/clone/i) {
    $is_clone = 1;
  }
  if ($ARGV[$#ARGV]=~m/debug/i) {
    $debug = 1;
  }
  if ($ARGV[$#ARGV]=~m/sync/i) {
    $force_SYNC = 1;
  }
}

# Get the p4 client depot root
open(P4CLIENT,"p4 client -o 2>$DEV_NULL|")
  || die("Error: Failed in p4 client -o\n");
while (<P4CLIENT>) {
  chomp();
  if (/^View:[ \t]*$/) {
    $p4_depot = 1;
    next;
  }

  if (0 == $p4_depot) {
    next;
  }

  s/^[ \t]+//;
  {
    s/\.\.\.//;
    my @buff = split(" ",$_);
    $p4_depot = $buff[0];
    $p4_depot=~s/\/$//;
    last;
  }
}
close(P4CLIENT);

# Get all available changes for the client
open(P4CHANGES,"p4 changes ... 2>${DEV_NULL} |")
  || die("Error: p4 changes\n");
while (<P4CHANGES>) {
  chomp();
  if (0 == length($_)) {
    next;
  }

  if (/^Change/) {
    my @buff = split(' ',$_);
    push(@changes,$buff[1]);
    $h_changes{$buff[1]} = 1;
  }
}
close(P4CHANGES);

# Read all imported changes and generate a hash of new changes to be imported
if (open(P4IMPORTED,"<$p4DIR/.p4imported")) {
  my $last_change = 0;
  while (<P4IMPORTED>) {
    chomp();
    $last_change = $_;
    if (exists($h_changes{$_})) {
      delete $h_changes{$_};
    }
  }
  close(P4IMPORTED);
  if (0 != $last_change) {
    system("p4 sync -k \@${last_change} 2>$DEV_NULL 1>$DEV_NULL");
    $last_change = 0;
  } else {
    $is_clone = 1;		# On empty file, treate as clone
  }
} else {
  $is_clone = 1;		# If file missing, treat as clone
}

#------------------------------------------------------------------------------
#                  THE GREAT OUTER LOOP PROCESSING P4 CHANGES
#------------------------------------------------------------------------------
my $first = 0;			# Switch to the desired branch the first time
open(P4IMPORTED,">>$p4DIR/.p4imported")
  || die("Error: Unable to opeb $p4DIR/.p4imported for append\n");
foreach (reverse @changes) {	# Reverse import!
  my $cID = $_;

  if (!exists($h_changes{$cID})) {
    next;
  }

  my $syncfiles = 0;
  my $addedfiles = 0;
  my $editedfiles = 0;
  my $deletedfiles = 0;

  my %h_syncfiles = ();
  my %h_addedfiles = ();
  my %h_editedfiles = ();
  my %h_deletedfiles = ();

  if (0 == $first) {
    system("hg -q branch p4");
    $first = 1;
  }

  if (0 == $is_clone) {
    print "Importing p4 changeset ${cID}\n";
  } else {
    print "Cloning p4 changeset ${cID}\n";
  }

  # Store the massaged diff as patch file for future import
  open(DIFFOUT,">$p4DIR/tmp/${cID}.diff")
    || die("Error: Unable to open $p4DIR/tmp/${cID}.diff\n");
  open(DIFFMSG,">$p4DIR/tmp/${cID}.msg")
    || die("Error: Unable to open $p4DIR/tmp/${cID}.msg\n");
  open(DIFF,"p4 describe -du ${cID} 2>${DEV_NULL}|")
    || die("Error: In p4 describe -du ${cID}\n");

  # Massage the p4 describe output into a useful patch file
  my $has_diffs = 0;
  my $block_aff = 0;
  my $block_chg = 0;
  my $block_diff = 0;
  my @diffheader = ();
  my %h_commitmsg = ();
  my $filepath = 0;
  my $hunkfound = -1;

  while (<DIFF>) {
    # Skip empty/blank lines in non diff block
    if (0 == $block_diff && /^[ \t]*\n$/) {
      next;
    }

    # Change description block
    if (0 == $block_diff && 0 == $block_aff && /^Change/) {
      $block_diff = 0;
      $block_aff = 0;
      $block_chg = 1;

      chomp();
      s/[ \t]+/ /g;
      my @buff = split(" ",$_);
      $buff[5]=~s/\//\-/g;	# Massage the date for hg

      $h_commitmsg{'user'} = $buff[3];
      $h_commitmsg{'date'} = join(" ",@buff[5..6]);

      print DIFFMSG "p4 changeset: $buff[1]\n";

      next;
    }

    if (/^Affected files[ \t]+\.\.\.[ \t]*\n$/) {
      $block_diff = 0;
      $block_chg = 0;
      $block_aff = 1;

      next;
    }

    # On seeing the differences block, wake up to act
    if (/^Differences[ \t]+\.\.\.[ \t]*\n$/) {
      $block_chg = 0;
      $block_aff = 0;
      $block_diff = 1;

      next;
    }

    # Get the changes done on files here, add/edit/integrate/delete
    if (0 != $block_aff) {
      chomp();

      # Add and delete are best handled through sync
      my @buff = split(" ",$_);
      my $fileondepot=$buff[1];
      $buff[-1]=~tr/[A-Z]/[a-z]/;

      # Stuff that requires a sync due to lack of diff in describe
      # Treat 'branch' and 'integrate' as add
      if ($buff[-1]=~m/branch/ || $buff[-1]=~m/integrate/ ||
	  $buff[-1]=~m/add/ || $buff[-1]=~m/delete/) {

	$buff[1]=~s/${p4_depot}//;
	$buff[1]=~s/^\/*//;
	$buff[1]=~s/\#.+//g;

	if ($buff[-1]=~m/branch/ || $buff[-1]=~m/add/) { # New file addition
	  $addedfiles++;
	  $h_addedfiles{$buff[1]} = "$fileondepot";
	  DBGPRN "DEBUG: Added file $buff[1]\n";
	} elsif ($buff[-1]=~m/delete/) { # File deletion
	  $deletedfiles++;
	  $h_deletedfiles{$buff[1]} = "$fileondepot";
	  DBGPRN "DEBUG: Deleted file $buff[1]\n";
	} elsif ($buff[-1]=~m/integrate/) {
	  # Pull integrated files through 'p4 sync' as diffs may be with
	  # parent at different level/branch!
	  $syncfiles++;
	  $h_syncfiles{$buff[1]} = "$fileondepot";
	  DBGPRN "DEBUG: Integrate/sync file $buff[1]\n";
	}
      } else {			# edit
	if ($force_SYNC) {
	  $syncfiles++;
	  $h_syncfiles{$buff[1]} = "$fileondepot";
	  print "DEBUG: Forcing sync for edited file $buff[1]\n";
	} else {
	  $editedfiles++;
	  $h_editedfiles{$buff[1]} = "$fileondepot";
	  DBGPRN "DEBUG: Edited file $buff[1]\n";
	}
      }

      next;
    }

    # Massage the o/p to patch format
    if (0 != $block_diff && /^====/) {
      # Handle all files that lack diff but marked as edited (ex: binary)
      # Pull such files through 'p4 sync'
      if (0 == $hunkfound) {
	if (exists($h_editedfiles{$filepath})) { # If binary file?
	  $h_syncfiles{$filepath} = $h_editedfiles{$filepath};
	  $syncfiles++;
	  delete $h_editedfiles{$filepath};
	  $editedfiles--;
	  DBGPRN "DEBUG: Binary [$filepath], moving from edit to sync hash\n";
	}
      }

      $hunkfound = 0;
      @diffheader = ();
      chomp();

      s/[ \t]+/ /g;		# Reduce multiple space/tabs to single space
      my @buff = split(" ",$_);
      $buff[1]=~s/${p4_depot}//; # Get relative to depot root
      $buff[1]=~s/^\/*//g;	 # Strip leading '/'
      $buff[1]=~s/\#.+$//;	 # Strip the revision part
      $filepath = $buff[1];	 # The current file being processed in diff

      # Some sanity checks, edited file cannot be in added/deleted hash
      if (exists($h_addedfiles{$filepath})) {
	$corruptions++;
	DBGPRN "Error: $buff[1] is in edited and added hash!\n";
      }
      if (exists($h_deletedfiles{$filepath})) {
	$corruptions++;
	DBGPRN "Error: $buff[1] is in edited and deleted hash!\n";
      }

      push(@diffheader, "diff $filepath\n");
      push(@diffheader, "--- a/$filepath\n");
      push(@diffheader, "+++ b/$filepath\n");

      next;
    }

    if (0 != $block_chg) {
      print DIFFMSG $_;
    }

    if (0 != $block_diff) {
      if (0 == $hunkfound && /^\@\@/) {	# On start of first hunk
	$hunkfound = 1;
	print DIFFOUT @diffheader;
      }
      if ($hunkfound > 0) {	# Start writing to patch file only on hunk
	print DIFFOUT $_;
      }
    }
  }

  close(DIFF);
  close(DIFFMSG);
  close(DIFFOUT);

  #----------------------------------------------------------------------------
  #                              SOME SANITY CHECKS
  #----------------------------------------------------------------------------
  if ($corruptions > 0) {
    print STDERR "Error: $corruptions corruptions in P4 changelist ${cID}\n";
    exit -1;
  }

  #----------------------------------------------------------------------------
  #              HG import first: if it fails, fall back on p4 sync
  #----------------------------------------------------------------------------

  # import the patch of modified files with out commit
  if ($editedfiles > 0 && -f "$p4DIR/tmp/${cID}.diff") {
    DBGPRN "DEBUG: hg import $p4DIR/tmp/${cID}.diff\n";
    if (0 != system("hg -q import -f --no-commit $p4DIR/tmp/${cID}.diff")) {
      warn("Error: Failed in importing $p4DIR/tmp/${cID}.diff\n");
      if (0 != system("hg -q update -C")) {
	die("Error: Failed in hg -q update -C\n");
      }
      foreach (keys %h_editedfiles) {
	$h_syncfiles{$_} = $h_editedfiles{$_};
	$syncfiles++;
	delete $h_editedfiles{$_};
	$editedfiles--;
      }
      if ($editedfiles > 0) {
	die("Error: Corruption in editedfiles count...\n");
      }
      %h_editedfiles = ();
    }
  }

  #----------------------------------------------------------------------------

  #----------------------------------------------------------------------------
  #                         P4 COMMANDS THAT MODIFY FILE SYSTEM
  #----------------------------------------------------------------------------

  # Bring newly added files first so that addremove can detect a move
  # Much faster than getting individual files on first pull
  if (0 != $is_clone &&
      ($addedfiles > 0 || $syncfiles > 0) &&
      0 == $editedfiles && 0 == $deletedfiles) {
    if (0 != system("p4 sync -f \@${cID} 2>$DEV_NULL 1>$DEV_NULL")) {
      die("Error: Failed in \"p4 sync -f \@${cID}\"\n");
    }
    $is_clone = 0;
  } else {			# Handle files that are brought through sync
    my @syncget = ();
    if ($addedfiles > 0) {
      push(@syncget,values %h_addedfiles);
    }
    if ($syncfiles > 0) {
      push(@syncget,values %h_syncfiles);
    }

    while ($#syncget >= 0) {
      my @chunks = splice(@syncget, 0, $cmd_arg_length);
      DBGPRN "DEBUG: p4 sync [@chunks]\n";
      if (0 != system("p4 sync -f @chunks 2>$DEV_NULL 1>$DEV_NULL")) {
	die("Error: Failed in \"p4 sync -f @chunks\" with $#syncget to go\n");
      }
    }

    # Delete the files marked for deletion from disk
    if ($deletedfiles > 0) {
      foreach (keys %h_deletedfiles) {
	unlink "$_";
      }
    }
  }

  # Make files updated from p4 writable
  foreach (keys %h_addedfiles) {
    my $perm = (stat $_)[2] & 07777;
    chmod($perm | 0600, $_);
  }
  foreach (keys %h_syncfiles) {
    my $perm = (stat $_)[2] & 07777;
    chmod($perm | 0600, $_);
  }

  #----------------------------------------------------------------------------

  #----------------------------------------------------------------------------
  #                                ALL Hg STUFF
  #----------------------------------------------------------------------------

  # process add/delete files before calling sync
  my @addremove = ();
  if ($deletedfiles > 0) {
    $op = 'rm';
    push(@addremove, keys %h_deletedfiles);
  }
  if ($addedfiles > 0) {
    $op = 'add';
    push(@addremove, keys %h_addedfiles);
  }
  if ($addedfiles > 0 && $deletedfiles > 0) {
    $op = 'addremove -s 99.0';
  }
  while ($#addremove >= 0) {
    my @chunks = splice(@addremove, 0, $cmd_arg_length);
    DBGPRN "DEBUG: hg $op [@chunks]\n";
    if (0 != system("hg -q $op @chunks 2>$DEV_NULL")) {
      die("Error: Failed in \"hg -q $op $#chunks\" with $#addremove to go\n");
    }
  }

  # Commit the changes into hg
  my $cmd = "hg -q ci -u ".$h_commitmsg{'user'};
  $cmd = $cmd." -d \"".$h_commitmsg{'date'}."\"";
  if (-f "$p4DIR/tmp/${cID}.msg") {
    $cmd = $cmd." -l $p4DIR/tmp/${cID}.msg";
  }
  $cmd = $cmd." 2>$DEV_NULL";
  if (0 != system($cmd)) {
    die("Error: Failed in \"$cmd\"\n");
  }

  # DEBUG, break on first import without update
  # last;

  # Update the internal book keeping
  print P4IMPORTED "${cID}\n";
  $last_change = ${cID};
  #----------------------------------------------------------------------------

  #----------------------------------------------------------------------------
  #                         ALL CLEANUP
  #----------------------------------------------------------------------------

  if (-f "$p4DIR/tmp/${cID}.diff") {
    unlink "$p4DIR/tmp/${cID}.diff";
  }
  if (-f "$p4DIR/tmp/${cID}.msg") {
    unlink "$p4DIR/tmp/${cID}.msg";
  }

  if ($force_SYNC) {
    last;
  }
}				# Looping over changes

# Make P4 believe the current state is in sync with last imported changelist
if (0 != $last_change) {
  system("p4 sync -k \@${last_change} 2>$DEV_NULL 1>$DEV_NULL");
}