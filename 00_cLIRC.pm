##############################################
# $Id: 00_cLIRC.pm 0001 $
# 140609 0001 initial release
#
# TODO:

package main;

use strict;
use warnings;
use Time::HiRes qw(gettimeofday time);
use Digest::MD5 qw(md5);
use bytes;

sub cLIRC_Initialize($);
sub cLIRC_Define($$);
sub cLIRC_Undef($$);
sub cLIRC_Attr(@);
sub cLIRC_Set($@);
sub cLIRC_Write($$);
sub cLIRC_Read($);
sub cLIRC_Parse($$);
sub cLIRC_Ready($);
sub cLIRC_SimpleWrite(@);
sub cLIRC_DoInit($);
sub cLIRC_Reconnect($);

my $debug = 1; # set 1 for better log readability

sub cLIRC_Initialize($) {
  my ($hash) = @_;

  require "$attr{global}{modpath}/FHEM/DevIo.pm";

# Provider
  $hash->{ReadFn}  = "cLIRC_Read";
  $hash->{WriteFn} = "cLIRC_Write";
  $hash->{ReadyFn} = "cLIRC_Ready";
  $hash->{SetFn}   = "cLIRC_Set";
  $hash->{NotifyFn}= "cLIRC_Notify";
  $hash->{AttrFn}  = "cLIRC_Attr";
  $hash->{Clients} = "";

# Normal devices
  $hash->{DefFn}   = "cLIRC_Define";
  $hash->{UndefFn} = "cLIRC_Undef";
  $hash->{AttrList}= "do_not_notify:1,0 dummy:1,0 " .
                     "delay " .
                     "rep_count " .
                     "presenceLink " .
                     $readingFnAttributes;
}
sub cLIRC_Define($$) {#########################################################
  my ($hash, $def) = @_;
  my @a = split("[ \t][ \t]*", $def);

  if(@a != 3) {
    my $msg = "wrong syntax: define <name> cLIRC ip[:port]";
    Log3 $hash, 2, $msg;
    return $msg;
  }
  DevIo_CloseDev($hash);

  my $name = $a[0];
  my $dev = $a[2];
  $dev .= ":8765" if($dev !~ m/:/ && $dev ne "none" && $dev !~ m/\@/);

  $hash->{DeviceName} = $dev;
  $hash->{STATE} = "disconnected";
  $hash->{helper}{hd_unit_id}=0;
  
  my $ret;
  
  if ($init_done){
    $ret = DevIo_OpenDev($hash, 0, "cLIRC_DoInit");
  }
  return $ret;
}
sub cLIRC_Undef($$) {##########################################################
  my ($hash, $arg) = @_;
  my $name = $hash->{NAME};

  DevIo_CloseDev($hash);
  return undef;
}
sub cLIRC_Notify(@) {##########################################################
  my ($hash,$dev) = @_;
  if ($dev->{NAME} eq "global" && grep (m/^INITIALIZED$|^REREADCFG$/,@{$dev->{CHANGED}})){
    if(!defined($hash->{helper}{presence}) || (Value($hash->{helper}{presence}) eq "present")) {
      DevIo_OpenDev($hash, 0, "cLIRC_DoInit");
    } else {
      InternalTimer(gettimeofday()+60, "cLIRC_Reconnect", "reconnect:".($hash->{NAME}), 1);
    }
  }
  return;
}
sub cLIRC_Attr(@) {############################################################
  my ($cmd,$name, $aName,$aVal) = @_;
  if($aName eq "dummy"){
    if ($cmd eq "set" && $aVal != 0){
      DevIo_CloseDev($defs{$name});
      $defs{$name}->{STATE} = "ok";
      $attr{$name}{dummy} = $aVal;
    }
    else{
      if ($init_done){
        DevIo_OpenDev($defs{$name}, 1, "cLIRC_DoInit");
      }
    }
  }
  elsif($aName eq "presenceLink"){
    if ($cmd eq "set" && defined($aVal)){
      $attr{$name}{presenceLink} = $aVal;
      $defs{$name}->{helper}{presence} = $aVal;
    } else {
      delete($defs{$name}->{helper}{presence});
    }
  }
  return;
}

sub cLIRC_Set($@) {############################################################
  my ($hash, @a) = @_;

  return ("",1);
}

sub cLIRC_Write($$) {#########################################################
  my ($hash,$msg) = @_;

}

sub cLIRC_Read($) {############################################################
# called from the global loop, when the select for hash->{FD} reports data
  my ($hash) = @_;
  my $buf = DevIo_SimpleRead($hash);
  return "" if(!defined($buf));

  cLIRC_Parse($hash, $buf);
}

sub cLIRC_Parse($$) {##########################################################
  my ($hash, $rmsg) = @_;
  my $name = $hash->{NAME};

  #Log 0,$rmsg;
  
  my @lines = split /\n/, $rmsg;
  foreach my $line (@lines) {
    my ( $hex, $repeat, $button, $remote ) = split /\s+/,$line; 
    
    if (defined $button) {
      my $delay = 5;

      my $attrdelay= AttrVal($name, "delay", '.*:5');
      if($attrdelay) {
        my @adelay = split(/,/,$attrdelay);
        for (my $i=0; $i<int(@adelay); $i++) {
          my @v2 = split(/:/, $adelay[$i]);
          if(($v2[1] && $button =~ m/^$v2[0]$/) && ($v2[1] =~ m/^(\d+)$/)) {
            $delay=$v2[1];
          }
        }
      }
    
      return if (hex $repeat>0)&&(hex $repeat<=$delay);
    
      my $rep_count = 0;

      my $attrrep_count= AttrVal($name, "rep_count", '.*:0');
      if($attrrep_count) {
        my @arep_count = split(/,/,$attrrep_count);
        for (my $i=0; $i<int(@arep_count); $i++) {
          my @v2 = split(/:/, $arep_count[$i]);
          if(($v2[1] && $button =~ m/^$v2[0]$/) && ($v2[1] =~ m/^(\d+)$/)) {
            $rep_count=$v2[1];
          }
        }
      }

      return if $rep_count ? hex($repeat) % $rep_count : hex $repeat;
      Log3 $name, 4, "LIRC $name $button";
      readingsSingleUpdate($hash,"received",$button,1);
      DoTrigger($name, $button); 
    }
  }
}

sub cLIRC_Ready($) {###########################################################
  my ($hash) = @_;
  if(!defined($hash->{helper}{presence}) || (Value($hash->{helper}{presence}) eq "present")) {
    return DevIo_OpenDev($hash, 1, "cLIRC_DoInit");
  } else {
    InternalTimer(gettimeofday()+60, "cLIRC_Reconnect", "reconnect:".($hash->{NAME}), 1);
    return "";
  }
}

sub cLIRC_Reconnect($) {###########################################################
  my($in ) = shift;
  my(undef,$name) = split(':',$in);
  my $hash = $defs{$name};

  RemoveInternalTimer( "reconnect:".$name);
  cLIRC_Ready($hash);
}
  
sub cLIRC_SimpleWrite(@) {#####################################################
  my ($hash, $msg) = @_;

  return if(!$hash || AttrVal($hash->{NAME}, "dummy", undef));
}

sub cLIRC_DoInit($) {##########################################################
  my ($hash) = @_;
  my $name = $hash->{NAME};

  return undef;
}

1;

=pod
=begin html

<a name="cLIRC"></a>
<h3>cLIRC</h3>
<ul>
    Todo
</ul>

=end html
=cut
