# -*-perl-*-
# Time-stamp: <2003-08-13 19:32:10 dhruva>
#------------------------------------------------------------------------------
# cvsget.pl --- Download CVS repository (like CVSGrab)
# Copyright (C) 2003 Dhruva Krishnamurthy
# Author: Dhruva Krishnamurthy
# Maintainer: seagull@fastmail.fm
# Keywords: cvs, proxy, firewall, grab
# Created: 01st August 2003
# Latest: http://schemer.fateback.com/pub/scripts/cvsget.pl
# Status: ALPHA
#         o have Tried with PERL 5.8 and GNU Wget 1.9-beta to get GNU Emacs
#           and XEmacs CVS sources

# License: GPL
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2, or (at your option)
# any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with this program; if not, you can either send email to this
# program's maintainer or write to: The Free Software Foundation,
# Inc.; 59 Temple Place, Suite 330; Boston, MA 02111-1307, USA.

# DISCLAIMER:
# I do not take any responsibility for the functioning of cvsget.pl script
# I have tested it on Windows 2000 using PERL 5.8 and GNU Wget 1.9-beta
# I request any modifications/improvements to cvsget.pl to be posted to me.

# Commentary:
# In fond rememberence of my cousin, an exceptional human being.
# PERL script to download a CVS repository through HTTP. The CVS repository
# must be viewable in the browser throught ViewCVS. Useful when behind the
# all too (in)famous fascist firewall and proxy. As I am behind one, this
# served as an inspiration. I have extensively tested this on GNU Emacs and
# XEmacs CVS repositories.

# Internals:
#    o                 CVSHASH format
#    o ---------1----------2--------3--------------4------------5---
#    o CVS ELEMENT NAME | TYPE | VERSION | UPDATION STATUS| PREV VER
#    o File or Directory path from Package root folder
#    o The 2nd field MUST be 'f' OR 'd'=> File OR Directory
#    o The 3rd field is the REVISION number. For directories '0'
#    o The 4th field MUST be 'n' => No updation required (like parity check)
#    o The 5th field stores the previous version for rollback
#    o Uses mark and sweep concept for finding modified entities
#    o Crawling is done by main thread
#    o Multi threaded for downloading only

# Usage:
#    o Copy the script to somewhere in your path
#    o $baseurl must be the base URL for download link, NOT view link
#    o perl -S cvsget.pl
#    o Set environmental variables for PROXY (HTTP_PROXY) is using proxy
#    o Edit the user modifiable variables if you want default behavior

# Dependencies:
#    o Needs IO::Handle, File::Path, LWP::UserAgent

# Todo:
#    o May be use Berkeley DB/Sleepycat to store cvsdata
#    o Support downloading from CVS BRANCHES

# ChangeLog:
#    o Changed the seperator in cvsdata from ' ' to '|'
#    o Added command line options
#    o Made it more robust
#    o Added signal handler to commit changes for modifications
#    o LWP works! but needs more testing
#    o Can restore previous version when download fails
#    o Added support to CURL downloader (Experimental)
#    o Added basic proxy options
#    o Multi threaded downloading to speed up
#    o Provided thread count limit
#    o Check downloaded file size for non-zero (mainly for LWP)
#    o Reduced runtime memory usage
#    o Fixed some SCALAR leakages...
#    o Log file generation
#------------------------------------------------------------------------------
$version="1.5.2";

#--------------------- User modifiable values - Begins ------------------------
$package="emacs";
$baseurl="http://savannah.gnu.org/cgi-bin/viewcvs/*checkout*/";
$updatedir="emacs/";
$cvsroot="D:/tmp/cvs/";
#---------------------- User modifiable values - Ends -------------------------

use Config;
use IO::Handle;
use File::Path;

if($Config{useithreads} || $Config{usethreads}){
    use threads;
    use threads::shared;
    $use_mt=1;
}else{
    $use_mt=0;
    print(STDERR "PERL $] NOT built with Thread support\n");
}

$retval=0;
$prog=$0;
$prog=~s,.*/,,;
$prog=~s/\.\w*$//;
#------------------------------------------------------------------------------
#                             Version and Usage Info
#------------------------------------------------------------------------------
$usage=
    "Usage: $prog [options...]
Options:
  --package=Package_Name                 Name of the package
  --baseurl=Base_Checkout_URL            The base url for download
  --dir=Remote_Folder_Under_Package      Sub folder under package for update
  --cvsroot=Output_Folder                Root CVS folder on local host
  --lwp                                  PERL LWP for download, EXPERIMENTAL
  --curl                                 CURL for download, EXPERIMENTAL
  --proxy-user=user[:passwd]             User details for proxy authentication
  --min-threads=Num                      Minimum threads [5]
  --max-threads=Num                      Maximum threads [50]
  --files-thread=Num                     Files per thread [10]
  --disable-threads                      Disable multi threaded download
  --quite                                Disable progress information
  --help                                 Display this help message
  --version                              Display version information

       o Uses GNU Wget as default downloader
       o Set GNU Wget extra options in .wgetrc file
       o Set --lwp=1 only if you want to test. Highly EXPERIMENTAL!
       o Multi threaded downloading be default
       o Files per thread means the threshold number which can spawn a thread

Example:
$prog --baseurl=http://savannah.gnu.org/cgi-bin/viewcvs/*checkout*/
          --package=emacs --dir=emacs --cvsroot=D:/cvs/";

$verinfo=
    "$prog
Version: $version
Updates: http://schemer.fateback.com/pub/scripts/cvsget.pl
Maintainer: Dhruva Krishnamurthy <seagull\@fastmail.fm>";
#------------------------------------------------------------------------------

if($use_mt){
    share($use_mt);
    share($retval);
    share(%statushash);

    share($minthreads);
    share($maxthreads);
    share($threadcount);
    share($filesperthread);
}

#------------------------------------------------------------------------------
# Init
#  To be executed immediately after GetOpt
#------------------------------------------------------------------------------
sub Init
{
    if($use_mt){
        $threadcount=1;
        $minthreads=5;
        $maxthreads=50;
        $filesperthread=10;
    }

    if(-f $indexfile){
        unlink($indexfile);
    }
    return(0);
}

#------------------------------------------------------------------------------
# WrongOption
#------------------------------------------------------------------------------
sub WrongOption
{
    my $opt=$_[0];
    print(STDERR "Error: Unrecognised option \"$opt\"\n");
    return(0);
}

#------------------------------------------------------------------------------
# GetOpt
#------------------------------------------------------------------------------
sub GetOpt
{
    $use_lwp=0;
    $use_curl=0;
    $use_wget=0;
    $verbosity=1;

    foreach(@_){
        if(/(--help|-h|\/\?)/i){
            print("$usage\n");
            exit(0);
        }elsif(/--version/i){
            print("\n$verinfo\n");
            exit(0);
        }elsif(/--disable-threads/i){
            $use_mt=0;
            next;
        }elsif(/--quite/i){
            $verbosity=0;
            next;
        }elsif(/--lwp/i){
            $use_lwp=1;
            @downopt=("Using LWP");
            $downloader="LWP";
            next;
        }elsif(/--curl/i){
            $use_curl=1;
            $downloader="curl";
            next;
        }

        my @arr=split(/=/,$_);
        if($#arr ne 1){
            WrongOption($_);
            return(1);
        }

        my ($key,$val)=@arr;
        if($key=~/--package/i){
            $package=$val;
        }elsif($key=~/--baseurl/i){
            $baseurl=$val."/";
        }elsif($key=~/--dir/i){
            $updatedir=$val."/";
        }elsif($key=~/--min-threads/i){
            if($val=~/[0-9]+/){
                $minthreads=$val;
            }
        }elsif($key=~/--max-threads/i){
            if($val=~/[0-9]+/){
                $maxthreads=$val;
            }
        }elsif($key=~/--files-thread/i){
            if($val=~/[0-9]+/){
                $filesperthread=$val;
            }
        }elsif($key=~/--cvsroot/i){
            $cvsroot=$val."/";
        }elsif($key=~/--proxy-user/i){
            @pup=split(/:/,$val);
            if(!$#pup){
                WrongOption($_);
                return(1);
            }
            $use_proxy=1;
        }else{
            WrongOption($_);
            return(1);
        }
    }

    # Set Wget as default
    if(!$use_lwp && !$use_curl && !$use_curl){
        $use_wget=1;
        $downloader="wget";
    }

    # Setting download options based on download tool used
    if($use_lwp){
        use LWP::UserAgent;
        $useragent=LWP::UserAgent->new(env_proxy=>1,
                                       keep_alive=>1,
                                       timeout=>180,
                                      );
    }elsif($use_wget){
        @downopt=("--quiet",
                  "--tries=1",
                  "--timeout=180");
        if($use_proxy){
            push(@downopt,"--proxy-user=$pup[0]");
            if($#pup==1){
                push(@downopt,"--proxy-passwd=$pup[1]");
            }
        }
    }elsif($use_curl){
        @downopt=("-s");
        if($use_proxy){
            if($#pup==1){
                push(@downopt,"-U $pup[0]:$pup[1]");
            }else{
                push(@downopt,"-U $pup[0]");
            }
            push(@downopt,"-x $ENV{'HTTP_PROXY'}");
        }
    }

    $package=~tr/\///d;
    $baseurl=~s/\/+$//g;

    $startdir="$updatedir/";
    $packageurl="$baseurl/$package/";
    $packageroot="$cvsroot/$package/";

    $startdir=~s/\/+/\//g;
    $packageroot=~s/\/+/\//g;

    $cvsdata=$packageroot."cvsdata";
    $cvsgetlog=$packageroot.$prog.".log";
    $indexfile=$packageroot."index.html";

    &Init;

    return(0);
}

#------------------------------------------------------------------------------
# GetRemoteFile
#  Creates directories on local repository if required
#------------------------------------------------------------------------------
sub GetRemoteFile
{
    if(@_!=2){
        return(1);
    }

    my $backed=0;
    my ($url,$tar)=@_;

    # Backup the file if something goes wrong
    if(-f $tar){
        $backed=1;
        rename($tar,"$tar.prev");
    }

    if($use_lwp){
        my $req=HTTP::Request->new(GET=>$url);
        my $response=$useragent->request($req,$tar);
        if($response->is_success){
            $retval=0;
        }
    }elsif($use_wget){
        push(@downopt,"--output-document=$tar");
        push(@downopt,"$url");
        $retval=system("$downloader",@downopt);
    }elsif($use_curl){
        push(@downopt,"-o $tar");
        push(@downopt,"$url");
        $retval=system("$downloader",@downopt);
    }

    # Some paranoid checks to ensure download
    if(!$retval && -z $tar){
        $retval=1;
    }

    if($retval){
        print(CVSGETLOG "Error updating \"$tar\" from \"$url\"\n");
        unlink($tar);
    }

    # Reset downloader options
    if($use_curl || $use_wget){
        pop(@downopt);
        pop(@downopt);
    }

    # Restore previous version on error
    if($backed){
        if($retval){
            rename("$tar.prev",$tar);
        }else{
            unlink("$tar.prev");
        }
    }

    return($retval);
}

#------------------------------------------------------------------------------
# GetLocalRepositoryData
#  Extracts information of local CVS reporitory from previous update
#------------------------------------------------------------------------------
sub GetLocalRepositoryData
{
    $newrepository=0;

    if(! -f $cvsdata){
        $newrepository=1;
        return(0);
    }
    open(CVSDATA,"<$cvsdata")
        || die("Cannot open $cvsdata for read");

    # Incomplete updation during previous call
    my $corrupt=0;

    while(<CVSDATA>){
        chomp();
        my @harr=split(/\|/,$_);
        my $elem=$harr[0];
        shift(@harr);

        if(!$corrupt && $harr[2] ne 'n'){
            $corrupt=1;
        }

        if($elem=~/^($startdir)/i){
            $harr[2]='r';
        }

        # Store previous version info for rollback
        push(@harr,$harr[1]);
        $cvshash{$elem}=\@harr;
    }
    close(CVSDATA);

    return(0);
}

#------------------------------------------------------------------------------
# UnWebify
#  UnWebify the names [hacked code]
#------------------------------------------------------------------------------
sub UnWebify
{
    if(@_==0){
        return(1);
    }
    my $ref=\$_[0];
    $$ref=~tr/+/ /;
    $$ref=~s/%([a-fA-F0-9][a-fA-F0-9])/pack("C",hex($1))/eg;
    return(0);
}

#------------------------------------------------------------------------------
# GetRemoteRepositoryData
#  Main parser method, extracts information of remote CVS repository, If the
#  ViewCVS changes, need to modify the parsing
#------------------------------------------------------------------------------
sub GetRemoteRepositoryData
{
    if(@_==0){
        return(1);
    }

    my $cdir=$_[0];
    if(&GetRemoteFile("$packageurl$cdir",$indexfile)){
        return(1);
    }
    open(INDEX,"<$indexfile")
        || die("Unable to open $indexfile file for read");

    &UnWebify($cdir);
    # Do not create directory if it exists
    my $flag='y';
    if(-d "$packageroot$cdir"){
        $flag='n';
    }

    if(exists($cvshash{$cdir})){
        my @harr=$cvshash{$cdir};
        $harr[0][2]=$flag;
        $harr[0][3]=0;
    }else{
        $cvshash{$cdir}=['d',0,$flag,0];
    }

    my @ldirlist=();
    my @downlist=($cdir);
    while(<INDEX>){
        chomp();
        tr/"//d;
        if(/href=[a-z\/]+:/xi){
            next;
        }

        if(/href/xi){
            my @arr=split(/ /,$_);
            foreach(@arr){
                # Ignore .cvsignore, Attic
                if(/(\.cvsignore|attic\/)/xi){
                    next;
                }
                # For folders
                if(/href=.+\/>/xi){
                    tr/>//d;
                    my @type=split(/=/,$_);
                    my $dir="$cdir$type[1]";
                    push(@ldirlist,$dir);
                }elsif(/href=.+\?rev=[0-9\.]+/i){
                    my @data=split(/\?/,$_);
                    if($#data!=1){
                        next;
                    }
                    my @type=split(/=/,$data[0]);
                    my @rev=split(/=/,$data[1]);
                    my $file="$cdir$type[1]";
                    &UnWebify($file);
                    my $ver=$rev[1];
                    $ver=~s/&.+//g;
                    if(exists($cvshash{$file})){
                        my @harr=$cvshash{$file};
                        if(! -f "$packageroot$file" || $harr[0][1] ne $ver){
                            $harr[0][1]=$ver;
                            $harr[0][2]='y';
                            push(@downlist,$file);
                        }else{
                            $harr[0][2]='n';
                        }
                    }else{
                        $cvshash{$file}=['f',$ver,'y',$ver];
                        push(@downlist,$file);
                    }
                }
            }
        }
    }
    close(INDEX);
    unlink($indexfile);

    # Start multi-threaded downloading
    if($use_mt){
        my $numthreads=int($#downlist/$filesperthread);
        if(!$numthreads){
            $numthreads=1;
        }elsif($#downlist%$filesperthread){
            $numthreads++;
        }
        foreach(1..$numthreads){
            if($threadcount<$maxthreads){
                &ThreadedDownloader(@downlist);
            }
        }
    }

    # Recurse through folders
    foreach(@ldirlist){
        if(&GetRemoteRepositoryData($_)){
            return(1);
        }
    }

    return(0);
}

#------------------------------------------------------------------------------
# DoDeletions
#  Entities that are not crawled from Start directory are to be deleted
#  Call this before Commit (Not inside Commit)
#------------------------------------------------------------------------------
sub DoDeletions
{
    if(@_==0){
        return(1);
    }
    my (@dlist)=@_;
    foreach(sort @dlist){
        my @harr=$cvshash{$_};
        my $type=$harr[0][0];
        my $flag=\$harr[0][2];
        if(!$$flag || $$flag ne 'r'){
            next;
        }
        print("Removing $packageroot$_\n");
        if($type eq 'd'){
            rmtree("$packageroot$_");
        }elsif($type eq 'f'){
            unlink("$packageroot$_");
        }
        $$flag='d';
    }
    return(0);
}

#------------------------------------------------------------------------------
# UpdateLocalRepository
#  Synchronizes the local repository with remote CVS repository.
#  Handles multi threaded call. Can spawn threads depending on min threads.
#------------------------------------------------------------------------------
sub UpdateLocalRepository
{
    if(@_==0){
        return(1);
    }

    my (@dlist)=@_;
    if($use_mt){
        my $counter=0;
    }

    foreach(sort @dlist){
        if($use_mt && (exists($statushash{$_}) &&
                       ($statushash{$_} eq 'p' || $statushash{$_} eq 'n'))){
            next;
        }

        # Mark this as being processed to avoid race
        if($use_mt){
            $statushash{$_}='p';
        }

        my @harr=$cvshash{$_};
        my $type=$harr[0][0];
        my $flag=\$harr[0][2];

        if($$flag ne 'y'){
            if($use_mt){
                $statushash{$_}=$$flag;
            }
            next;
        }

        # If directory, create it before threading
        if($type eq 'd'){
            eval{mkpath("$packageroot$_")};
            if(!$@){
                $$flag='n';
            }
            if($use_mt){
                $statushash{$_}='n';
            }
        }

        if($use_mt){
            $counter++;
        }
        # If things are going slow...
        # Main thread should not spawn threads here!
        if($use_mt && $threadcount<$minthreads && $counter==$filesperthread){
            $counter=0;
            &ThreadedDownloader(@dlist);
        }

        # Conditions processed by threads
        if($type eq 'f'){
            if($verbosity){
                print("Updating $packageroot$_\n");
            }

            my $url=$packageurl.$_;
            my $tar=$packageroot.$_;
            if(!&GetRemoteFile($url,$tar)){
                $$flag='n';
                if($use_mt){
                    $statushash{$_}='n';
                }
            }
        }
    }

    # Update thread counter and detach
    if($use_mt && $threadcount){
        $threadcount--;
    }

    return(0);
}

#------------------------------------------------------------------------------
# ThreadSync
#  Prevent zombie threads
#------------------------------------------------------------------------------
sub ThreadSync
{
    if($use_mt){
        foreach(threads->list()){
            $_->join;
        }
    }
}

#------------------------------------------------------------------------------
# ThreadedDownloader
#------------------------------------------------------------------------------
sub ThreadedDownloader
{
    if(@_==0){
        return(1);
    }
    if($threadcount<$maxthreads){
        $threadcount++;
        my $thr=threads->create("UpdateLocalRepository",@_);
        if(threads->tid()!=0){
            $thr->yield();
        }
    }else{
        return(&UpdateLocalRepository(@_));
    }
    return(0);
}

#------------------------------------------------------------------------------
# CommitChanges
#  Record the changes in the 'cvsdata' file
#------------------------------------------------------------------------------
sub CommitChanges
{
    open(CVSDATA,">$cvsdata")
        || die("Cannot open $cvsdata for write");

    my $corrupt=0;
    foreach(sort keys %cvshash){
        my @harr=$cvshash{$_};
        my $stat=\$harr[0][2];
        if($use_mt && exists($statushash{$_})){
            $$stat=$statushash{$_};
        }
        if($$stat ne 'd'){
            if($$stat ne 'n'){
                # Restore previous version info
                $harr[0][1]=$harr[0][3];
                $corrupt=1;
            }
            print(CVSDATA "$_|$harr[0][0]|$harr[0][1]|$$stat\n");
        }
    }
    close(CVSDATA);

    if($corrupt){
        print(CVSGETLOG "Corrupted! Incomplete synchronization...\n");
        print(STDERR "Error: Incomplete synchronization\n");
        print(STDERR "       Consider repeating: \"$prog @ARGV\"\n");
    }else{
        print(CVSGETLOG "Successful synchronization...\n");
    }

    return($corrupt);
}

#------------------------------------------------------------------------------
# OnInterrupt
#------------------------------------------------------------------------------
sub OnInterrupt
{
    print(STDERR "\n\n$prog interrupted! Commiting changes....\n");
    print(CVSGETLOG "$prog interrupted by user...\n");
    if(-f $indexfile){
        unlink($indexfile);
    }
    &ThreadSync;
    &CommitChanges;
    exit(1);
}

#------------------------------ Execution starts ------------------------------
# Set signal handlers just before actual updation
use sigtrap 'handler',\&OnInterrupt,'error-signals';
use sigtrap 'handler',\&OnInterrupt,'normal-signals';

# Parse user command line options
if(&GetOpt(@ARGV)){
    print("$usage\n");
    exit(1);
}

# Create the Package directory if it does not exist
if(! -d "$packageroot"){
    eval{mkpath("$packageroot")};
    if($@){
        print(STDERR "Error: Unable to create $packageroot\n");
        print(STDERR "Create it and restart \"$prog @ARGV\"\n");
        exit(1);
    }
}

# Generate log file
open(CVSGETLOG,">>$cvsgetlog")
    || die("Cannot open \"$cvsgetlog\" for write");
$currtime=gmtime(time);
print(CVSGETLOG "Executing Command: \"$prog @ARGV\" on $currtime\n");

# Gets the current CVS repository's data
&GetLocalRepositoryData;

# Crawl the CVS repository with multi threading [No exits beyond]
print("Getting [$package] package: $startdir\n");
if(!&GetRemoteRepositoryData($startdir)){
    &ThreadSync;
    my @updatelist=();
    foreach(grep{/^($startdir)/} keys %cvshash){
        push(@updatelist,$_);
    }
    &UpdateLocalRepository(@updatelist);
    &DoDeletions(@updatelist);
}

# Cleanup all zombie threads
&ThreadSync;

# Record the modifications & exit
$retval=&CommitChanges;

# Close the error log file
close(CVSGETLOG);
if($verbosity){
    print("Completed Synchronization, refer \"$cvsgetlog\" for details\n");
}

exit($retval);