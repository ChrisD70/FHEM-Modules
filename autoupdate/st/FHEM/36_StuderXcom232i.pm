##############################################
# $Id: 36_StuderXcom232i.pm 0001 $
# 150415 0001 initial release
# 150417 0002 ignore StuderXcom232i_Write calls until init_done
# 150426 0003 added set XXX test
# 150507 0004 removed set XXX test, activated dispatch
# TODO:

package main;

use strict;
use warnings;
use Time::HiRes qw(gettimeofday time);
use Digest::MD5 qw(md5);
use bytes;

sub StuderXcom232i_Initialize($);
sub StuderXcom232i_Define($$);
sub StuderXcom232i_Undef($$);
sub StuderXcom232i_Attr(@);
sub StuderXcom232i_Set($@);
sub StuderXcom232i_ReadAnswer($$$);
sub StuderXcom232i_Write($$);
sub StuderXcom232i_Read($);
sub StuderXcom232i_Parse($$);
sub StuderXcom232i_Ready($);
sub StuderXcom232i_SimpleWrite(@);
sub StuderXcom232i_DoInit($);
sub StuderXcom232i_Poll($);
sub StuderXcom232i_AddWQueue($$);
sub StuderXcom232i_AddRQueue($$);
sub StuderXcom232i_Timeout($);
sub StuderXcom232i_HandleWriteQueue($);
sub StuderXcom232i_HandleReadQueue($);
sub StuderXcom232i_Reconnect($);
sub StuderXcom232i_LogFrame($$$$);
sub StuderXcom232i_checksum_is_ok($);
sub StuderXcom232i_checksum($);

use constant READ_PROPERTY    => 1;
use constant WRITE_PROPERTY   => 2;

sub StuderXcom232i_Initialize($) {
  my ($hash) = @_;

  require "$attr{global}{modpath}/FHEM/DevIo.pm";

# Provider
  $hash->{ReadFn}  = "StuderXcom232i_Read";
  $hash->{WriteFn} = "StuderXcom232i_Write";
  $hash->{ReadyFn} = "StuderXcom232i_Ready";
  $hash->{SetFn}   = "StuderXcom232i_Set";
  $hash->{NotifyFn}= "StuderXcom232i_Notify";
  $hash->{AttrFn}  = "StuderXcom232i_Attr";
  $hash->{Clients} = ":StuderXT:";
  my %mc = (
    "1:StuderXT" => "^StuderXT.*"
  );
  $hash->{MatchList} = \%mc;

# Normal devices
  $hash->{DefFn}   = "StuderXcom232i_Define";
  $hash->{UndefFn} = "StuderXcom232i_Undef";
  $hash->{AttrList}= "do_not_notify:1,0 dummy:1,0 " .
                     "timeout " .
                     $readingFnAttributes;
}
sub StuderXcom232i_Define($$) {#########################################################
  my ($hash, $def) = @_;
  my @a = split("[ \t][ \t]*", $def);

  if(@a != 3) {
    my $msg = "wrong syntax: define <name> StuderXcom232i {devicename[\@baudrate] ".
                        "| devicename\@directio | hostname:port}";
    Log3 $hash, 2, $msg;
    return $msg;
  }
 
  DevIo_CloseDev($hash);

  my $name = $a[0];
  my $dev = $a[2];
  $dev .= "\@38400" if( ($dev !~ m/\@/) && ($dev !~ m/:/));
  
  $hash->{DeviceName} = $dev;
  $hash->{STATE} = "disconnected";
  $hash->{helper}{databits}=8;
  $hash->{helper}{parity}='even';
  $hash->{helper}{stopbits}=1;
  $hash->{dummy}=0;
  
  my $ret;
  
  if ($init_done){
    $ret = DevIo_OpenDev($hash, 0, "StuderXcom232i_DoInit");
  } else {
    InternalTimer(gettimeofday()+10, "StuderXcom232i_Reconnect", "reconnect:".($hash->{NAME}), 0);
  }

  return $ret;
}
sub StuderXcom232i_Undef($$) {##########################################################
  my ($hash, $arg) = @_;
  my $name = $hash->{NAME};

  foreach my $d (sort keys %defs) {
    if(defined($defs{$d}) &&
       defined($defs{$d}{IODev}) &&
       $defs{$d}{IODev} == $hash){
        Log3 $hash, 2, "deleting port for $d";
        delete $defs{$d}{IODev};
      }
  }
  DevIo_CloseDev($hash);
  return undef;
}
sub StuderXcom232i_Notify(@) {##########################################################
  my ($hash,$dev) = @_;
  if (($dev->{NAME} eq "global" && grep (m/^INITIALIZED$|^REREADCFG$/,@{$dev->{CHANGED}}))&&($hash->{dummy}==0)){
    DevIo_OpenDev($hash, 0, "StuderXcom232i_DoInit");
  }
  return;
}

sub StuderXcom232i_Reconnect($) {###########################################################
  my($in ) = shift;
  my(undef,$name) = split(':',$in);
  my $hash = $defs{$name};
  #Log 0,"StuderXcom232i_Reconnect";
  RemoveInternalTimer( "reconnect:".$name);

  if ($init_done==1) {
    DevIo_OpenDev($hash, 0, "StuderXcom232i_DoInit") if(($hash->{STATE} eq "disconnected")&&($hash->{dummy}==0));
  } else {
    InternalTimer(gettimeofday()+10, "StuderXcom232i_Reconnect", "reconnect:".($name), 1);
  }
}
  
sub StuderXcom232i_Attr(@) {############################################################
  my ($cmd,$name, $aName,$aVal) = @_;
  
  my $hash=$defs{$name};
  
  if($aName eq "dummy"){
    if ($cmd eq "set" && $aVal != 0){
      RemoveInternalTimer( "poll:".$name);
      RemoveInternalTimer( "timeout:".$name);
      DevIo_CloseDev($hash);
      delete($hash->{WQUEUE});
      delete($hash->{RQUEUE});
      $hash->{STATE} = "ok";
      $hash->{dummy}=1;
    }
    else{
      $hash->{dummy}=0;
      delete($hash->{WQUEUE});
      delete($hash->{RQUEUE});
      if ($init_done){
        DevIo_OpenDev($hash, 1, "StuderXcom232i_DoInit");
      }
    }
  }
  return;
}

sub StuderXcom232i_Set($@) {############################################################
  my ($hash, @a) = @_;
  my $name = $hash->{NAME};

  if( @a < 2 ) {
    return( "at least one parameter is needed" ) ;
  }

  $name = shift( @a );
  my $cmd = shift( @a );

  if( $cmd eq "?" ) {
    # this one should give us a drop down list
    my $res = "Unknown argument ?, choose one of " . 
              "read ";

    return( $res );
  } elsif( $cmd eq "read" ) {
    StuderXcom232i_Write($hash,"101:".READ_PROPERTY.":1:".$a[0].":1:FLOAT:");
  }

  return( undef );
}

sub StuderXcom232i_Write($$) {#########################################################
  my ($hash,$msg) = @_;

  return unless ($init_done);
  
  my ($dst_addr,$service_id,$object_type,$object_id,$property_id,$format,$property_data)=split(":",$msg);

  # build frame data
  my $frame_data=pack "CCvVv",0x00,$service_id,$object_type,$object_id,$property_id;
  if ($service_id == WRITE_PROPERTY) {
    if (defined($format) && defined($property_data)) {
      $frame_data.=pack "C",$property_data if($format eq 'BOOL');
      $frame_data.=pack "<f",$property_data if($format eq 'FLOAT');
      $frame_data.=pack "v",$property_data if($format eq 'ENUM');
      $frame_data.=pack "V",$property_data if($format eq 'INT32');
    }
  }
  
  # build header
  my $header=pack 'CVVv',0x00,1,$dst_addr,bytes::length($frame_data);

  # add checksums
  $frame_data.=pack 'v',StuderXcom232i_checksum($frame_data);
  $header=(pack 'C',0xaa) . $header . pack 'v',StuderXcom232i_checksum($header);

  if ($service_id == WRITE_PROPERTY) {
    StuderXcom232i_LogFrame($hash,"AddWQueue",$header.$frame_data,5);
    StuderXcom232i_AddWQueue($hash, $header.$frame_data);
  }
  if ($service_id == READ_PROPERTY) {
    StuderXcom232i_LogFrame($hash,"AddRQueue",$header.$frame_data,5);
    StuderXcom232i_AddRQueue($hash, $header.$frame_data);
  }
}

sub StuderXcom232i_Read($) {############################################################
# called from the global loop, when the select for hash->{FD} reports data
  my ($hash) = @_;
  my $buf = DevIo_SimpleRead($hash);
  return "" if(!defined($buf));

  my $name = $hash->{NAME};

  my $pdata = $hash->{helper}{PARTIAL};
  $pdata .= $buf;

  StuderXcom232i_LogFrame($hash,"StuderXcom232i_Read",$pdata,4);
  RemoveInternalTimer( "timeout:".$name);

  # check received data
  if(ord(bytes::substr($pdata, 0, 1)) == 0xaa) {
    # header complete ?
    if(bytes::length($pdata) >= 14) {
      # header checksum ok ?
      if(StuderXcom232i_checksum_is_ok(substr $pdata,1,13)) {
        # unpack header
        my (undef,$frame_flags,$src_addr,$dest_addr,$data_length,$checksum,$frame_data)=unpack "CCVVvva*",$pdata;
        # frame complete ?
        if(bytes::length($frame_data) >= $data_length+2) {
          # frame_data checksum ok ?
          if(StuderXcom232i_checksum_is_ok($frame_data)) {
            # unpack frame_data
            my ($flags,$service_id,$object_type,$object_id,$property_id,$value)=unpack "CCvVva*",(substr $frame_data,0,$data_length);
            Dispatch($hash, "StuderXT:$src_addr:$service_id:$object_type:$object_id:$property_id:".join(":",unpack("C*", $value)), undef);
            readingsSingleUpdate( $hash, "received", (unpack "H*",$pdata) , 1 );
            $hash->{helper}{state}="idle";
          } else {
            Log3 $hash, 1,"StuderXcom232i_Read: bad frame_data checksum";
            $hash->{helper}{PARTIAL} = undef;
            $hash->{helper}{state}="idle";
          }
        } else {
          $hash->{helper}{PARTIAL} = $pdata;
          InternalTimer(gettimeofday()+AttrVal($name,"timeout",5), "StuderXcom232i_Timeout", "timeout:".$name, 1);
        }
      } else {
        Log3 $hash, 1,"StuderXcom232i_Read: bad header checksum";
        $hash->{helper}{PARTIAL} = undef;
        $hash->{helper}{state}="idle";
      }
    } else {
      $hash->{helper}{PARTIAL} = $pdata;
      InternalTimer(gettimeofday()+AttrVal($name,"timeout",5), "StuderXcom232i_Timeout", "timeout:".$name, 1);
    }
  } else {
    Log3 $hash, 1,"StuderXcom232i_Read: bad start_byte";
    $hash->{helper}{PARTIAL} = undef;
    $hash->{helper}{state}="idle";
  }
}

sub StuderXcom232i_Parse($$) {##########################################################
  my ($hash, $rmsg) = @_;
  my $name = $hash->{NAME};

  StuderXcom232i_LogFrame($hash,"StuderXcom232i_Parse",$rmsg,4);

  if($hash->{helper}{state} eq "idle") {
    return undef;
  }

  # Dispatch($hash, "ModbusCoil:$rx_hd_unit_id:".unpack("x2n", $rmsg).":$rx_bd_fc:1:".unpack("x4n", $rmsg), undef); 

  RemoveInternalTimer( "timeout:".$name);
  $hash->{helper}{state}="idle";
}

sub StuderXcom232i_Ready($) {###########################################################
  my ($hash) = @_;
  
  if(($hash->{STATE} eq "disconnected")&&($hash->{dummy}==0)) {
    RemoveInternalTimer( "reconnect:".$hash->{NAME});
    return DevIo_OpenDev($hash, 1, "StuderXcom232i_DoInit")
  }
  
  # This is relevant for windows/USB only
  my $po = $hash->{USBDev};
  my ($BlockingFlags, $InBytes, $OutBytes, $ErrorFlags);
  if($po) {
    ($BlockingFlags, $InBytes, $OutBytes, $ErrorFlags) = $po->status;
  }
  return ($InBytes && $InBytes>0);
}

sub StuderXcom232i_SimpleWrite(@) {#####################################################
  my ($hash, $msg) = @_;

  return if(!$hash || AttrVal($hash->{NAME}, "dummy", undef));

  my $name = $hash->{NAME};
  if(($hash->{USBDev})||($hash->{DIODev})||($hash->{TCPDev})) {
    $hash->{helper}{state}="active";
    RemoveInternalTimer( "timeout:".$name);
    InternalTimer(gettimeofday()+AttrVal($name,"timeout",5), "StuderXcom232i_Timeout", "timeout:".$name, 1);
    StuderXcom232i_LogFrame($hash,"StuderXcom232i_SimpleWrite",$msg,5);
    $hash->{USBDev}->write($msg)    if($hash->{USBDev});
    syswrite($hash->{DIODev}, $msg) if($hash->{DIODev});
    syswrite($hash->{TCPDev}, $msg) if($hash->{TCPDev});
    $hash->{helper}{lastSimpleWrite}=unpack 'h*',$msg;

    # Some linux installations are broken with 0.001, T01 returns no answer
    select(undef, undef, undef, 0.01);
  }
}

sub StuderXcom232i_DoInit($) {##########################################################
  my ($hash) = @_;
  my $name = $hash->{NAME};

  #Log 0,"StuderXcom232i_DoInit";
  # devio.pm does not support user defined settings, try to change here
  if (defined($hash->{USBDev})) {
    my $po=$hash->{USBDev};

    $po->databits($hash->{helper}{databits});
    $po->parity($hash->{helper}{parity});
    $po->stopbits($hash->{helper}{stopbits});
    $po->write_settings;
  }
  
  $hash->{helper}{state}="idle";

  return undef;
}

sub
StuderXcom232i_Timeout($) ##################################################
{
  my($in ) = shift;
  my(undef,$name) = split(':',$in);
  my $hash = $defs{$name};

  Log3 $hash, 3,"StuderXcom232i_Timeout";

  $hash->{STATE} = "timeout";
  $hash->{helper}{state}="idle";
  $hash->{helper}{PARTIAL} = undef;
}

sub
StuderXcom232i_SendFromWQueue($$) ##################################################
{
  my ($hash, $bstring) = @_;
  my $name = $hash->{NAME};

  if($bstring ne "") {
    StuderXcom232i_SimpleWrite($hash, $bstring);
  }
  InternalTimer(gettimeofday()+0.02, "StuderXcom232i_HandleWriteQueue", $hash, 1);
}

sub
StuderXcom232i_AddWQueue($$) ##################################################
{
  my ($hash, $bstring) = @_;
  if(!$hash->{WQUEUE}) {
    if($hash->{helper}{state} eq "idle") {
      $hash->{WQUEUE} = [ $bstring ];
      StuderXcom232i_SendFromWQueue($hash, $bstring);
    } else {
      $hash->{WQUEUE} = [ $bstring ];
      push(@{$hash->{WQUEUE}}, $bstring);
      InternalTimer(gettimeofday()+0.02, "StuderXcom232i_HandleWriteQueue", $hash, 1);
    }
  } else {
    Log3 $hash, 5,"adding to WQUEUE - ".scalar(@{$hash->{WQUEUE}});
    push(@{$hash->{WQUEUE}}, $bstring);
  }
}

sub
StuderXcom232i_HandleWriteQueue($) ##################################################
{
  my $hash = shift;
  if($hash->{helper}{state} eq "idle") {
    my $arr = $hash->{WQUEUE};
    if(defined($arr) && @{$arr} > 0) {
      shift(@{$arr});
      if(@{$arr} == 0) {
        delete($hash->{WQUEUE});
        return;
      }
      Log3 $hash, 4,"WQUEUE: ".scalar(@{$arr});
      my $bstring = $arr->[0];
      if($bstring eq "") {
        StuderXcom232i_HandleWriteQueue($hash);
      } else {
        StuderXcom232i_SendFromWQueue($hash, $bstring);
      }
    }
  } else {
    InternalTimer(gettimeofday()+0.02, "StuderXcom232i_HandleWriteQueue", $hash, 1);
  }
} 

sub
StuderXcom232i_SendFromRQueue($$) ##################################################
{
  my ($hash, $bstring) = @_;
  my $name = $hash->{NAME};

  if($bstring ne "") {
    StuderXcom232i_SimpleWrite($hash, $bstring);
  }
  InternalTimer(gettimeofday()+0.02, "StuderXcom232i_HandleReadQueue", $hash, 1);
}

sub
StuderXcom232i_AddRQueue($$) ##################################################
{
  my ($hash, $bstring) = @_;
  if(!$hash->{RQUEUE}) {
    if(($hash->{helper}{state} eq "idle")&&(!defined($hash->{WQUEUE}))) {
      $hash->{RQUEUE} = [ $bstring ];
      StuderXcom232i_SendFromRQueue($hash, $bstring);
    } else {
      $hash->{RQUEUE} = [ $bstring ];
      push(@{$hash->{RQUEUE}}, $bstring);
      InternalTimer(gettimeofday()+0.02, "StuderXcom232i_HandleReadQueue", $hash, 1);
    }
  } else {
    my $add=1;
    for my $el (@{$hash->{RQUEUE}}) {
        if($el eq $bstring) {
            $add=0;
        }
    }
    if ($add==1) {
        Log3 $hash, 5,"adding to RQUEUE - ".scalar(@{$hash->{RQUEUE}});
        push(@{$hash->{RQUEUE}}, $bstring);
    }
  }
}

sub
StuderXcom232i_HandleReadQueue($) ##################################################
{
  my $hash = shift;
  if(($hash->{helper}{state} eq "idle")&&(!defined($hash->{WQUEUE}))) {
    my $arr = $hash->{RQUEUE};
    if(defined($arr) && @{$arr} > 0) {
      shift(@{$arr});
      if(@{$arr} == 0) {
        delete($hash->{RQUEUE});
        return;
      }
      Log3 $hash, 4,"RQUEUE: ".scalar(@{$arr});
      my $bstring = $arr->[0];
      if($bstring eq "") {
        StuderXcom232i_HandleReadQueue($hash);
      } else {
        StuderXcom232i_SendFromRQueue($hash, $bstring);
      }
    }
  } else {
    InternalTimer(gettimeofday()+0.02, "StuderXcom232i_HandleReadQueue", $hash, 1);
  }
} 

sub StuderXcom232i_LogFrame($$$$) {
  my ($hash,$c,$data,$verbose)=@_;

  my @dump = map {sprintf "%02X", $_ } unpack("C*", $data);

  $hash->{helper}{lastFrame}=$c." ".join(" ",@dump) if($c eq 'SimpleWrite');

  Log3 $hash, $verbose,"StuderXcom232i_LogFrame: ".$c." ".join(" ",@dump);
}

# SCOM checksum
# A = 0xFF
# B = 0
# For I FROM 0 TO number_of_bytes -1 DO
#   A := (A + DATA[I]) mod 0x100;
#   B := (B + A) mod 0x100;
# END
# checksum[0] := A
# checksum[1] := B

sub StuderXcom232i_checksum($) {
  my ($frame) =@_;
  my $a = 0xFF;
  my $b = 0;
  my $chr;

  for my $i (0..bytes::length($frame)-1) {
    $chr = ord(bytes::substr($frame, $i, 1));
    $a = ($a + $chr) % 0x100;
    $b = ($b + $a) % 0x100;
  }
  return $a + ($b << 8);
}

# Check the checksum of an SCOM frame.
#   return true if checksum is ok
sub StuderXcom232i_checksum_is_ok($) {
  my ($frame) = @_;
  my $crc = unpack('v', bytes::substr($frame, -2));
  return ($crc == StuderXcom232i_checksum(bytes::substr($frame,0,-2)));
}

1;

=pod
=begin html

<a name="StuderXcom232i"></a>
<h3>StuderXcom232i</h3>
<ul>
Todo
</ul>

=end html
=cut
