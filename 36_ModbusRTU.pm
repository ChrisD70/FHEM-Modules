##############################################
# $Id: 36_ModbusRTU.pm 0005 $
# 140503 0001 initial release
# 140505 0002 fix dummy on startup
# 140507 0003 added 'use bytes', fixed partial data handling in read function
# 140507 0004 fixed call to parse in read function
# 140508 0005 added REREADCFG to ModbusRTU_Notify, added timer if $init_done==0
# 150118 0006 removed defaultUnitId and presenceLink, completed documentation
# TODO:

package main;

use strict;
use warnings;
use Time::HiRes qw(gettimeofday time);
use Digest::MD5 qw(md5);
use bytes;

sub ModbusRTU_Initialize($);
sub ModbusRTU_Define($$);
sub ModbusRTU_Undef($$);
sub ModbusRTU_Attr(@);
sub ModbusRTU_Set($@);
sub ModbusRTU_ReadAnswer($$$);
sub ModbusRTU_Write($$);
sub ModbusRTU_Read($);
sub ModbusRTU_Parse($$);
sub ModbusRTU_Ready($);
sub ModbusRTU_SimpleWrite(@);
sub ModbusRTU_DoInit($);
sub ModbusRTU_Poll($);
sub ModbusRTU_AddWQueue($$);
sub ModbusRTU_AddRQueue($$);
sub ModbusRTU_Timeout($);
sub ModbusRTU_HandleWriteQueue($);
sub ModbusRTU_HandleReadQueue($);
sub ModbusRTU_Reconnect($);
sub ModbusRTU_Frame($$$);
sub ModbusRTU_crc_is_ok($);
sub ModbusRTU_crc($);

my $debug = 1; # set 1 for better log readability

## Modbus function code
# standard
use constant READ_COILS                                  => 0x01;
use constant READ_DISCRETE_INPUTS                        => 0x02;
use constant READ_HOLDING_REGISTERS                      => 0x03;
use constant READ_INPUT_REGISTERS                        => 0x04;
use constant WRITE_SINGLE_COIL                           => 0x05;
use constant WRITE_SINGLE_REGISTER                       => 0x06;
use constant WRITE_MULTIPLE_REGISTERS                    => 0x10;
use constant MODBUS_ENCAPSULATED_INTERFACE               => 0x2B;
## Modbus except code
use constant EXP_ILLEGAL_FUNCTION                        => 0x01;
use constant EXP_DATA_ADDRESS                            => 0x02;
use constant EXP_DATA_VALUE                              => 0x03;
use constant EXP_SLAVE_DEVICE_FAILURE                    => 0x04;
use constant EXP_ACKNOWLEDGE                             => 0x05;
use constant EXP_SLAVE_DEVICE_BUSY                       => 0x06;
use constant EXP_MEMORY_PARITY_ERROR                     => 0x08;
use constant EXP_GATEWAY_PATH_UNAVAILABLE                => 0x0A;
use constant EXP_GATEWAY_TARGET_DEVICE_FAILED_TO_RESPOND => 0x0B;
## Module error codes
use constant MB_NO_ERR                                   => 0;
use constant MB_RESOLVE_ERR                              => 1;
use constant MB_CONNECT_ERR                              => 2;
use constant MB_SEND_ERR                                 => 3;
use constant MB_RECV_ERR                                 => 4;
use constant MB_TIMEOUT_ERR                              => 5;
use constant MB_FRAME_ERR                                => 6;
use constant MB_EXCEPT_ERR                               => 7;

sub ModbusRTU_Initialize($) {
  my ($hash) = @_;

  require "$attr{global}{modpath}/FHEM/DevIo.pm";

# Provider
  $hash->{ReadFn}  = "ModbusRTU_Read";
  $hash->{WriteFn} = "ModbusRTU_Write";
  $hash->{ReadyFn} = "ModbusRTU_Ready";
  $hash->{SetFn}   = "ModbusRTU_Set";
  $hash->{NotifyFn}= "ModbusRTU_Notify";
  $hash->{AttrFn}  = "ModbusRTU_Attr";
  $hash->{Clients} = ":ModbusRegister:ModbusCoil:";
  my %mc = (
    "1:ModbusRegister" => "^ModbusRegister.*",
    "2:ModbusCoil" => "^ModbusCoil.*",
  );
  $hash->{MatchList} = \%mc;

# Normal devices
  $hash->{DefFn}   = "ModbusRTU_Define";
  $hash->{UndefFn} = "ModbusRTU_Undef";
  $hash->{AttrList}= "do_not_notify:1,0 dummy:1,0 " .
                     "pollIntervall " .
                     "timeout " .
                     "charformat " .
                     $readingFnAttributes;
}
sub ModbusRTU_Define($$) {#########################################################
  my ($hash, $def) = @_;
  my @a = split("[ \t][ \t]*", $def);

  if(@a != 3) {
    my $msg = "wrong syntax: define <name> ModbusRTU {devicename[\@baudrate] ".
                        "| devicename\@directio}";
    Log3 $hash, 2, $msg;
    return $msg;
  }
 
  DevIo_CloseDev($hash);

  my $name = $a[0];
  my $dev = $a[2];
  $dev .= "\@9600" if( $dev !~ m/\@/ );
  
  my (undef, $baudrate) = split("@", $dev);
  # calculate t35 (inter-frame delay) and t15 (inter-character time-out)
  # 1 byte = 11 bits, t35 = 39 bits, t15 = 17 bits
  # currently not used, FHEM is too slow
  if (($baudrate>19200)||($baudrate==0)) {
    $hash->{helper}{t35}=1.750;
    $hash->{helper}{t15}=0.750;
  } else {
    $hash->{helper}{t35}=39/$baudrate*1000;
    $hash->{helper}{t15}=17/$baudrate*1000;
  }

  Log3 $hash, 5, "t35: ".$hash->{helper}{t35}." ms, t15: ".$hash->{helper}{t15}." ms";
  
  $hash->{DeviceName} = $dev;
  $hash->{STATE} = "disconnected";
  $hash->{helper}{hd_unit_id}=0;
  $hash->{helper}{databits}=8;
  $hash->{helper}{parity}='even';
  $hash->{helper}{stopbits}=1;
  $hash->{dummy}=0;
  
  my $ret;
  
  if ($init_done){
    $ret = DevIo_OpenDev($hash, 0, "ModbusRTU_DoInit");
  } else {
    InternalTimer(gettimeofday()+10, "ModbusRTU_Reconnect", "reconnect:".($hash->{NAME}), 0);
  }

  return $ret;
}
sub ModbusRTU_Undef($$) {##########################################################
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
sub ModbusRTU_Notify(@) {##########################################################
  my ($hash,$dev) = @_;
  if (($dev->{NAME} eq "global" && grep (m/^INITIALIZED$|^REREADCFG$/,@{$dev->{CHANGED}}))&&($hash->{dummy}==0)){
    DevIo_OpenDev($hash, 0, "ModbusRTU_DoInit");
  }
  return;
}

sub ModbusRTU_Reconnect($) {###########################################################
  my($in ) = shift;
  my(undef,$name) = split(':',$in);
  my $hash = $defs{$name};
  #Log 0,"ModbusRTU_Reconnect";
  RemoveInternalTimer( "reconnect:".$name);

  if ($init_done==1) {
    DevIo_OpenDev($hash, 0, "ModbusRTU_DoInit") if(($hash->{STATE} eq "disconnected")&&($hash->{dummy}==0));
  } else {
    InternalTimer(gettimeofday()+10, "ModbusRTU_Reconnect", "reconnect:".($name), 1);
  }
}
  
sub ModbusRTU_Attr(@) {############################################################
  my ($cmd,$name, $aName,$aVal) = @_;
  
  my $hash=$defs{$name};
  
  if($aName eq "pollIntervall") {
    if ($cmd eq "set") {
      $attr{$name}{pollIntervall} = $aVal;
      RemoveInternalTimer( "poll:".$name);
      if ($init_done){
        InternalTimer(gettimeofday()+$aVal/1000.0, "ModbusRTU_Poll", "poll:".$name, 0);
      }
    }
  }
  elsif($aName eq "timeout") {
    if ($cmd eq "set") {
      $attr{$name}{timeout} = $aVal;
    }
  }
  elsif($aName eq "charformat") {
    if (($cmd eq "set")&&defined($aVal)) {
      if (uc($aVal) ne AttrVal($name, "charformat", "8E1")) {
        my ($db,$pa,$sb)=split('',uc($aVal));
        if (($db==7)||($db==8)) {
          $hash->{helper}{databits} = $db;
        }
        $hash->{helper}{parity} = 'even' if ($pa eq "E");
        $hash->{helper}{parity} = 'odd' if ($pa eq "O");
        $hash->{helper}{parity} = 'none' if ($pa eq "N");
        if (($sb==1)||($sb==2)) {
          $hash->{helper}{stopbits} = $sb;
        }
        
        if (defined($hash->{USBDev})) {
          my $po=$hash->{USBDev};

          $po->databits($hash->{helper}{databits});
          $po->parity($hash->{helper}{parity});
          $po->stopbits($defs{$name}->{helper}{stopbits});
          $po->write_settings;
        }
      }
      $attr{$name}{charformat} = $aVal;
    } else {
      $hash->{helper}{databits}=8;
      $hash->{helper}{parity}='even';
      $hash->{helper}{stopbits}=1;
      if (defined($hash->{USBDev})) {
        my $po=$hash->{USBDev};

        $po->databits($hash->{helper}{databits});
        $po->parity($hash->{helper}{parity});
        $po->stopbits($hash->{helper}{stopbits});
        $po->write_settings;
      }
    }
  }
  elsif($aName eq "dummy"){
    if ($cmd eq "set" && $aVal != 0){
      RemoveInternalTimer( "poll:".$name);
      RemoveInternalTimer( "timeout:".$name);
      DevIo_CloseDev($hash);
      delete($hash->{WQUEUE});
      delete($hash->{RQUEUE});
      $hash->{STATE} = "ok";
      $attr{$name}{dummy} = $aVal;
      $hash->{dummy}=1;
    }
    else{
      $hash->{dummy}=0;
      delete($hash->{WQUEUE});
      delete($hash->{RQUEUE});
      if ($init_done){
        DevIo_OpenDev($hash, 1, "ModbusRTU_DoInit");
      }
    }
  }
  return;
}

sub ModbusRTU_Set($@) {############################################################
  my ($hash, @a) = @_;

  return ("",1);
}

sub ModbusRTU_Write($$) {#########################################################
  my ($hash,$msg) = @_;

  my $id=int(rand 65535);
  my $tx_hd_pr_id      = 0;
  my $tx_hd_length     = bytes::length($msg);

  my $crc = pack 'v', ModbusRTU_crc($msg);
  
  ModbusRTU_Frame($hash,"AddWQueue",$msg.$crc);
  ModbusRTU_AddWQueue($hash, $msg.$crc);
}

sub ModbusRTU_Read($) {############################################################
# called from the global loop, when the select for hash->{FD} reports data
  my ($hash) = @_;
  my $buf = DevIo_SimpleRead($hash);
  return "" if(!defined($buf));

  my $name = $hash->{NAME};

  my $pdata = $hash->{helper}{PARTIAL};
  $pdata .= $buf;

  ModbusRTU_Frame($hash,"Read",$pdata);

  if(( bytes::length($pdata) >= 4 ) && ( ModbusRTU_crc_is_ok($pdata)))
  {
    ModbusRTU_Parse($hash, $pdata);
    $hash->{helper}{PARTIAL} = undef;
  } else {
    $hash->{helper}{PARTIAL} = $pdata;
  }

  if( bytes::length($pdata) > 256 ) {
    $hash->{helper}{PARTIAL} = undef;
  }
}

sub ModbusRTU_Parse($$) {##########################################################
  my ($hash, $rmsg) = @_;
  my $name = $hash->{NAME};

  ModbusRTU_Frame($hash,"Received",$rmsg);

  if($hash->{helper}{state} eq "idle") {
    return undef;
  }
  
  # modbus RTU receive
  # decode
  my ($rx_hd_unit_id, $rx_bd_fc, $f_body) = unpack "CCa*", $rmsg;

  # check except
  if ($rx_bd_fc > 0x80) {
    # except code
    my ($exp_code) = unpack "C", $f_body;
    $hash->{LAST_ERROR}  = MB_EXCEPT_ERR;
    $hash->{LAST_EXCEPT} = $exp_code;
    Log3 $hash, 2,"ModbusRTU: except (code $exp_code)";
    $hash->{STATE} = "error";
  } else {
    $hash->{STATE} = "ok";
    if($hash->{helper}{state} eq "readdevid") {
      
    }
    if(($rx_bd_fc==READ_HOLDING_REGISTERS)||($rx_bd_fc==READ_INPUT_REGISTERS)) {
      my $nvals=unpack("x2C", $rmsg)/2;
      Dispatch($hash, "ModbusRegister:$rx_hd_unit_id:".($hash->{helper}{hd_tr_id}).":$rx_bd_fc:$nvals:".join(":",unpack("x3n$nvals", $rmsg)), undef); 
    }
    if($rx_bd_fc==WRITE_SINGLE_REGISTER) {
      Dispatch($hash, "ModbusRegister:$rx_hd_unit_id:".unpack("x2n", $rmsg).":$rx_bd_fc:1:".unpack("x4n", $rmsg), undef); 
    }
    if($rx_bd_fc==WRITE_MULTIPLE_REGISTERS) {
      ;
    }
    if(($rx_bd_fc==1)||($rx_bd_fc==2)||($rx_bd_fc==5)) {
      Dispatch($hash, "ModbusCoil".unpack("a*", $rmsg), undef); 
    }
  }
  RemoveInternalTimer( "timeout:".$name);
  $hash->{helper}{state}="idle";
}

sub ModbusRTU_Ready($) {###########################################################
  my ($hash) = @_;
  
  if(($hash->{STATE} eq "disconnected")&&($hash->{dummy}==0)) {
    RemoveInternalTimer( "reconnect:".$hash->{NAME});
    return DevIo_OpenDev($hash, 1, "ModbusRTU_DoInit")
  }
  
  # This is relevant for windows/USB only
  my $po = $hash->{USBDev};
  my ($BlockingFlags, $InBytes, $OutBytes, $ErrorFlags);
  if($po) {
    ($BlockingFlags, $InBytes, $OutBytes, $ErrorFlags) = $po->status;
  }
  return ($InBytes && $InBytes>0);
}

sub ModbusRTU_SimpleWrite(@) {#####################################################
  my ($hash, $msg) = @_;

  return if(!$hash || AttrVal($hash->{NAME}, "dummy", undef));

  my $name = $hash->{NAME};
  my $len = length($msg);
  if(($hash->{USBDev})||($hash->{DIODev})) {
    $hash->{helper}{hd_tr_id}=unpack("x2n",$msg);
    $hash->{helper}{state}="active";
    InternalTimer(gettimeofday()+AttrVal($name,"timeout",3), "ModbusRTU_Timeout", "timeout:".$name, 1);
    ModbusRTU_Frame($hash,"SimpleWrite",$msg);
    $hash->{USBDev}->write($msg)    if($hash->{USBDev});
    syswrite($hash->{DIODev}, $msg) if($hash->{DIODev});

    # Some linux installations are broken with 0.001, T01 returns no answer
    select(undef, undef, undef, 0.01);
  }
}

sub ModbusRTU_DoInit($) {##########################################################
  my ($hash) = @_;
  my $name = $hash->{NAME};

  #Log 0,"ModbusRTU_DoInit";
  # devio.pm does not support user defined settings, try to change here
  if (defined($hash->{USBDev})) {
    my $po=$hash->{USBDev};

    $po->databits($hash->{helper}{databits});
    $po->parity($hash->{helper}{parity});
    $po->stopbits($hash->{helper}{stopbits});
    $po->write_settings;
  }
  
  my $tn = gettimeofday();
  my $pollIntervall = AttrVal($name,"pollIntervall",3000)/1000.0;

  $hash->{helper}{state}="idle";
  RemoveInternalTimer( "poll:".$name);
  InternalTimer($tn+$pollIntervall, "ModbusRTU_Poll", "poll:".$name, 0);

  return undef;
}

sub ModbusRTU_Poll($) {##################################################
  my($in ) = shift;
  my(undef,$name) = split(':',$in);
  my $hash = $defs{$name};

  if($hash->{STATE} ne "disconnected") {
    my $tn = gettimeofday();
    my $pollIntervall = AttrVal($name,"pollIntervall",3);

    if(!defined($hash->{RQUEUE})) {
      my @chlds=devspec2array("TYPE=ModbusRegister");

      foreach(@chlds) {
        my $chash=$defs{$_};
        if(defined($chash) && defined($chash->{helper}{readCmd}) && defined($chash->{IODev}) && ($chash->{IODev} eq $hash)) {
          if((!defined($chash->{helper}{nextUpdate}))||($chash->{helper}{nextUpdate}<time())) {
            my $msg=$chash->{helper}{readCmd};
            my $crc = pack 'v', ModbusRTU_crc($msg);

            ModbusRTU_Frame($hash,"AddRQueue",$msg.$crc);
            ModbusRTU_AddRQueue($hash, $msg.$crc);
            $chash->{helper}{nextUpdate}=time()+$chash->{helper}{updateIntervall} if(defined($chash->{helper}{updateIntervall}));
          }
        }
      }
    }
    if($tn+$pollIntervall<=gettimeofday()) {
      $tn=gettimeofday()-$pollIntervall+0.05;
    }
    InternalTimer($tn+$pollIntervall, "ModbusRTU_Poll", "poll:".$name, 0);
  }
}

sub
ModbusRTU_Timeout($) ##################################################
{
  my($in ) = shift;
  my(undef,$name) = split(':',$in);
  my $hash = $defs{$name};

  $hash->{STATE} = "timeout";
  $hash->{helper}{state}="idle";
  $hash->{helper}{hd_tr_id}=-1;
  $hash->{helper}{PARTIAL} = undef;
}

sub
ModbusRTU_SendFromWQueue($$) ##################################################
{
  my ($hash, $bstring) = @_;
  my $name = $hash->{NAME};

  if($bstring ne "") {
    ModbusRTU_SimpleWrite($hash, $bstring);
  }
  InternalTimer(gettimeofday()+0.02, "ModbusRTU_HandleWriteQueue", $hash, 1);
}

sub
ModbusRTU_AddWQueue($$) ##################################################
{
  my ($hash, $bstring) = @_;
  if(!$hash->{WQUEUE}) {
    if($hash->{helper}{state} eq "idle") {
      $hash->{WQUEUE} = [ $bstring ];
      ModbusRTU_SendFromWQueue($hash, $bstring);
    } else {
      $hash->{WQUEUE} = [ $bstring ];
      push(@{$hash->{WQUEUE}}, $bstring);
      InternalTimer(gettimeofday()+0.02, "ModbusRTU_HandleWriteQueue", $hash, 1);
    }
  } else {
    Log3 $hash, 5,"adding to WQUEUE - ".scalar(@{$hash->{WQUEUE}});
    push(@{$hash->{WQUEUE}}, $bstring);
  }
}

sub
ModbusRTU_HandleWriteQueue($) ##################################################
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
      Log3 $hash, 4,"WQUEUE: @{$arr}";
      my $bstring = $arr->[0];
      if($bstring eq "") {
        ModbusRTU_HandleWriteQueue($hash);
      } else {
        ModbusRTU_SendFromWQueue($hash, $bstring);
      }
    }
  } else {
    InternalTimer(gettimeofday()+0.02, "ModbusRTU_HandleWriteQueue", $hash, 1);
  }
} 

sub
ModbusRTU_SendFromRQueue($$) ##################################################
{
  my ($hash, $bstring) = @_;
  my $name = $hash->{NAME};

  if($bstring ne "") {
    ModbusRTU_SimpleWrite($hash, $bstring);
  }
  InternalTimer(gettimeofday()+0.02, "ModbusRTU_HandleReadQueue", $hash, 1);
}

sub
ModbusRTU_AddRQueue($$) ##################################################
{
  my ($hash, $bstring) = @_;
  if(!$hash->{RQUEUE}) {
    if(($hash->{helper}{state} eq "idle")&&(!defined($hash->{WQUEUE}))) {
      $hash->{RQUEUE} = [ $bstring ];
      ModbusRTU_SendFromRQueue($hash, $bstring);
    } else {
      $hash->{RQUEUE} = [ $bstring ];
      push(@{$hash->{RQUEUE}}, $bstring);
      InternalTimer(gettimeofday()+0.02, "ModbusRTU_HandleReadQueue", $hash, 1);
    }
  } else {
    Log3 $hash, 5,"adding to RQUEUE - ".scalar(@{$hash->{RQUEUE}});
    push(@{$hash->{RQUEUE}}, $bstring);
  }
}

sub
ModbusRTU_HandleReadQueue($) ##################################################
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
        ModbusRTU_HandleReadQueue($hash);
      } else {
        ModbusRTU_SendFromRQueue($hash, $bstring);
      }
    }
  } else {
    InternalTimer(gettimeofday()+0.02, "ModbusRTU_HandleReadQueue", $hash, 1);
  }
} 

sub ModbusRTU_Frame($$$) {
  my ($hash,$c,$data)=@_;

  my @dump = map {sprintf "%02X", $_ } unpack("C*", $data);
  #$dump[0] = "[".$dump[0];
  #$dump[5] = $dump[5]."]";
  
  Log3 $hash, 5,$c." ".join(" ",@dump)
}

# functions taken from:
# Perl module: Client ModBus / TCP class 1
#     Version: 1.4.2
#     Website: http://source.perl.free.fr (in french)
#        Date: 23/03/2013
#     License: GPL v3 (http://www.gnu.org/licenses/quick-guide-gplv3.en.html)
# Description: Client ModBus / TCP command line
#              Support functions 3 and 16 (class 0)
#              1,2,4,5,6 (Class 1)
#     Charset: us-ascii, unix end of line

# Compute modbus CRC16 (for RTU mode).
#   _crc(modbus_frame)
#   return the CRC
sub ModbusRTU_crc($) {
  my ($frame) =@_;
  my $crc = 0xFFFF;
  my ($chr, $lsb);
  for my $i (0..bytes::length($frame)-1) {
    $chr = ord(bytes::substr($frame, $i, 1));
    $crc ^= $chr;
    for (1..8) {
      $lsb = $crc & 1;
      $crc >>= 1;
      $crc ^= 0xA001 if $lsb;
      }
    }
  return $crc;
}

# Check the CRC of modbus RTU frame.
#   _crc_is_ok(modbus_frame_with_crc)
#   return true if CRC is ok
sub ModbusRTU_crc_is_ok($) {
  my ($frame) = @_;
  my $crc = unpack('v', bytes::substr($frame, -2));
  return ($crc == ModbusRTU_crc(bytes::substr($frame,0,-2)));
}

1;

=pod
=begin html

<a name="ModbusRTU"></a>
<h3>ModbusRTU</h3>
<ul>
  This module implements a Modbus master for communicating with Modbus slaves over serial line.<br><br>
  This module provides an IODevice for:
  <ul>
    <li><a href="#ModbusRegister">ModbusRegister</a> a module for accessing holding and input registers</li>
    <li><a href="#ModbusCoil">ModbusCoil</a> a module for accessing coils and discrete inputs</li>
  </ul>
  <br><br>
  <a name="ModbusRTUdefine"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; ModbusRTU &lt;serial port&gt;</code> <br>
    <br>
      You can specify a baudrate if the device name contains the @
      character, e.g.: /dev/ttyS0@9600<br>The port is opened with 8 data bits, 1 stop bit and even parity.<br>
      If the slaves use different settings they can be specified with the <a href="#ModbusRTUattrcharformat">charformat</a> attribute.<br>
      All slaves connected to a master must use the same character format.<br>

      Note: this module requires the Device::SerialPort or Win32::SerialPort module if the devices is connected via USB or a serial port. 
  </ul>
  <br>
  <a name="ModbusRTUset"></a>
  <b>Set</b> <ul>N/A</ul><br>
  <a name="ModbusRTUget"></a>
  <b>Get</b> <ul>N/A</ul><br>
  <a name="ModbusRTUattr"></a>
  <b>Attributes</b>
  <ul>
    <li><a href="#attrdummy">dummy</a></li><br>
    <li><a href="#readingFnAttributes">readingFnAttributes</a></li><br>
    <li><a name="">pollIntervall</a><br>
        Intervall in seconds for the reading cycle. Default: 0.1</li><br>
    <li><a name="">timeout</a><br>
        Timeout in seconds waiting for data from the server. Default: 3</li><br>
    <li><a name="ModbusRTUattrcharformat">charformat</a><br>
        Character format to be used for communication with the slaves. Default: 8E1.</li><br>
    
  </ul>
</ul>

=end html
=cut
