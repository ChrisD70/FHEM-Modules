##############################################
# $Id: 36_ModbusTCPServer.pm 0007 $
# 140318 0001 initial release
# 140505 0002 use address instead of register in Parse
# 140506 0003 added 'use bytes'
# 140508 0004 added REREADCFG to ModbusTCPServer_Notify
# 140819 0005 added statistics and support for coils
# 150118 0006 removed defaultUnitId, completed documentation
# 150221 0007 added info to bad frame message
# TODO:

package main;

use strict;
use warnings;
use Time::HiRes qw(gettimeofday time);
use Digest::MD5 qw(md5);
use bytes;

sub ModbusTCPServer_Initialize($);
sub ModbusTCPServer_Define($$);
sub ModbusTCPServer_Undef($$);
sub ModbusTCPServer_Attr(@);
sub ModbusTCPServer_Set($@);
sub ModbusTCPServer_ReadAnswer($$$);
sub ModbusTCPServer_Write($$);
sub ModbusTCPServer_Read($);
sub ModbusTCPServer_Parse($$);
sub ModbusTCPServer_Ready($);
sub ModbusTCPServer_SimpleWrite(@);
sub ModbusTCPServer_DoInit($);
sub ModbusTCPServer_Poll($);
sub ModbusTCPServer_ReadDevId($);
sub ModbusTCPServer_AddWQueue($$);
sub ModbusTCPServer_AddRQueue($$);
sub ModbusTCPServer_Timeout($);
sub ModbusTCPServer_HandleWriteQueue($);
sub ModbusTCPServer_HandleReadQueue($);
sub ModbusTCPServer_Reconnect($);
sub ModbusTCPServer_UpdateStatistics($$$$$);
sub _MbLogFrame($$$);

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

sub ModbusTCPServer_Initialize($) {
  my ($hash) = @_;

  require "$attr{global}{modpath}/FHEM/DevIo.pm";

# Provider
  $hash->{ReadFn}  = "ModbusTCPServer_Read";
  $hash->{WriteFn} = "ModbusTCPServer_Write";
  $hash->{ReadyFn} = "ModbusTCPServer_Ready";
  $hash->{SetFn}   = "ModbusTCPServer_Set";
  $hash->{NotifyFn}= "ModbusTCPServer_Notify";
  $hash->{AttrFn}  = "ModbusTCPServer_Attr";
  $hash->{Clients} = ":ModbusRegister:ModbusCoil:";
  my %mc = (
    "1:ModbusRegister" => "^ModbusRegister.*",
    "2:ModbusCoil" => "^ModbusCoil.*",
  );
  $hash->{MatchList} = \%mc;

# Normal devices
  $hash->{DefFn}   = "ModbusTCPServer_Define";
  $hash->{UndefFn} = "ModbusTCPServer_Undef";
  $hash->{AttrList}= "do_not_notify:1,0 dummy:1,0 " .
                     "pollIntervall " .
                     "timeout " .
                     "presenceLink " .
                     $readingFnAttributes;
}
sub ModbusTCPServer_Define($$) {#########################################################
  my ($hash, $def) = @_;
  my @a = split("[ \t][ \t]*", $def);

  if(@a != 3) {
    my $msg = "wrong syntax: define <name> ModbusTCPServer ip[:port]";
    Log3 $hash, 2, $msg;
    return $msg;
  }
  DevIo_CloseDev($hash);

  my $name = $a[0];
  my $dev = $a[2];
  $dev .= ":502" if($dev !~ m/:/ && $dev ne "none" && $dev !~ m/\@/);

  $hash->{DeviceName} = $dev;
  $hash->{STATE} = "disconnected";
  $hash->{helper}{hd_unit_id}=0;
  $hash->{statistics} ="0 / 0 / 0 / 0";
  $hash->{helper}{statistics}{pktIn}=0;
  $hash->{helper}{statistics}{pktOut}=0;
  $hash->{helper}{statistics}{bytesIn}=0;
  $hash->{helper}{statistics}{bytesOut}=0;
  $hash->{statistics} =$hash->{helper}{statistics}{pktIn} ." / " . $hash->{helper}{statistics}{pktOut} ." / " . $hash->{helper}{statistics}{bytesIn} ." / " . $hash->{helper}{statistics}{bytesOut};
  
  my $ret;
  
  if ($init_done){
    $ret = DevIo_OpenDev($hash, 0, "ModbusTCPServer_DoInit");
  }
  return $ret;
}
sub ModbusTCPServer_Undef($$) {##########################################################
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
sub ModbusTCPServer_Notify(@) {##########################################################
  my ($hash,$dev) = @_;
  #Log 0,"ModbusTCPServer_Notify :" . $dev->{NAME};
  if ($dev->{NAME} eq "global" && grep (m/^INITIALIZED$|^REREADCFG$/,@{$dev->{CHANGED}})){
    if(!defined($hash->{helper}{presence}) || (Value($hash->{helper}{presence}) eq "present")) {
      DevIo_OpenDev($hash, 0, "ModbusTCPServer_DoInit");
    } else {
      InternalTimer(gettimeofday()+60, "ModbusTCPServer_Reconnect", "reconnect:".($hash->{NAME}), 1);
    }
  }
  return;
}
sub ModbusTCPServer_Attr(@) {############################################################
  my ($cmd,$name, $aName,$aVal) = @_;
  if($aName eq "pollIntervall") {
    if ($cmd eq "set") {
      $attr{$name}{pollIntervall} = $aVal;
      RemoveInternalTimer( "poll:".$name);
      if ($init_done){
        InternalTimer(gettimeofday()+$aVal/1000.0, "ModbusTCPServer_Poll", "poll:".$name, 0);
      }
    }
  }
  elsif($aName eq "timeout") {
    if ($cmd eq "set") {
      $attr{$name}{timeout} = $aVal;
    }
  }
  elsif($aName eq "dummy"){
    if ($cmd eq "set" && $aVal != 0){
      RemoveInternalTimer( "poll:".$name);
      RemoveInternalTimer( "timeout:".$name);
      DevIo_CloseDev($defs{$name});
      delete($defs{$name}->{WQUEUE});
      delete($defs{$name}->{RQUEUE});
      $defs{$name}->{STATE} = "ok";
      $attr{$name}{dummy} = $aVal;
    }
    else{
      delete($defs{$name}->{WQUEUE});
      delete($defs{$name}->{RQUEUE});
      if ($init_done){
        DevIo_OpenDev($defs{$name}, 1, "ModbusTCPServer_DoInit");
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

sub ModbusTCPServer_Set($@) {############################################################
  my ($hash, @a) = @_;

  return ("",1);
}

sub ModbusTCPServer_Write($$) {#########################################################
  my ($hash,$msg) = @_;

  my $id=int(rand 65535);
  my $tx_hd_pr_id      = 0;
  my $tx_hd_length     = bytes::length($msg);

  my $f_mbap = pack("nnn", $id, $tx_hd_pr_id,
                            $tx_hd_length);

  _MbLogFrame($hash,"AddWQueue",$f_mbap.$msg);
  ModbusTCPServer_AddWQueue($hash, $f_mbap.$msg);
}

sub ModbusTCPServer_Read($) {############################################################
# called from the global loop, when the select for hash->{FD} reports data
  my ($hash) = @_;
  my $buf = DevIo_SimpleRead($hash);
  return "" if(!defined($buf));

  ModbusTCPServer_UpdateStatistics($hash,1,0,bytes::length($buf),0);
  ModbusTCPServer_Parse($hash, $buf);
}

sub ModbusTCPServer_Parse($$) {##########################################################
  my ($hash, $rmsg) = @_;
  my $name = $hash->{NAME};

  _MbLogFrame($hash,"Received",$rmsg);

  if($hash->{helper}{state} eq "idle") {
    return undef;
  }
  
  # modbus TCP receive
  # decode
  my ($rx_hd_tr_id, $rx_hd_pr_id, $rx_hd_length, $rx_hd_unit_id, $rx_bd_fc, $f_body) = unpack "nnnCCa*", $rmsg;
  # check header
  if (!(($rx_hd_tr_id == $hash->{helper}{hd_tr_id}) && ($rx_hd_pr_id == 0) &&
        ($rx_hd_length == bytes::length($rmsg)-6) )) { #&& ($rx_hd_unit_id == $hash->{helper}{hd_unit_id}))) {
    Log3 $hash, 1,"ModbusTCPServer: bad frame: $rx_hd_tr_id - ".$hash->{helper}{hd_tr_id}.", $rx_hd_pr_id, $rx_hd_length - ".bytes::length($rmsg)-6;
    $hash->{STATE} = "error";
  } else {
    # check except
    if ($rx_bd_fc > 0x80) {
      # except code
      my ($exp_code) = unpack "C", $f_body;
      $hash->{LAST_ERROR}  = MB_EXCEPT_ERR;
      $hash->{LAST_EXCEPT} = $exp_code;
      Log3 $hash, 2,"ModbusTCPServer: except (code $exp_code)";
      $hash->{STATE} = "error";
    } else {
      $hash->{STATE} = "ok";
      if($hash->{helper}{state} eq "readdevid") {
        
      }
      if(($rx_bd_fc==READ_HOLDING_REGISTERS)||($rx_bd_fc==READ_INPUT_REGISTERS)) {
        my $nvals=unpack("x8C", $rmsg)/2;
        Dispatch($hash, "ModbusRegister:$rx_hd_unit_id:$rx_hd_tr_id:$rx_bd_fc:$nvals:".join(":",unpack("x9n$nvals", $rmsg)), undef); 
      }
      if($rx_bd_fc==WRITE_SINGLE_REGISTER) {
        Dispatch($hash, "ModbusRegister:$rx_hd_unit_id:".unpack("x8n", $rmsg).":$rx_bd_fc:1:".unpack("x10n", $rmsg), undef); 
      }
      if(($rx_bd_fc==READ_COILS)||($rx_bd_fc==READ_DISCRETE_INPUTS)) {
        my $nvals=unpack("x8C", $rmsg);
        Dispatch($hash, "ModbusCoil:$rx_hd_unit_id:$rx_hd_tr_id:$rx_bd_fc:$nvals:".join(":",unpack("x9C$nvals", $rmsg)), undef); 
      }
      if($rx_bd_fc==WRITE_SINGLE_COIL) {
        Dispatch($hash, "ModbusCoil:$rx_hd_unit_id:".unpack("x8n", $rmsg).":$rx_bd_fc:1:".unpack("x10n", $rmsg), undef); 
      }
      if($rx_bd_fc==WRITE_MULTIPLE_REGISTERS) {
        ;
      }
    }
  }
  RemoveInternalTimer( "timeout:".$name);
  $hash->{helper}{state}="idle";
}

sub ModbusTCPServer_Ready($) {###########################################################
  my ($hash) = @_;
  if(!defined($hash->{helper}{presence}) || (Value($hash->{helper}{presence}) eq "present")) {
    return DevIo_OpenDev($hash, 1, "ModbusTCPServer_DoInit");
  } else {
    InternalTimer(gettimeofday()+60, "ModbusTCPServer_Reconnect", "reconnect:".($hash->{NAME}), 1);
    return "";
  }
}

sub ModbusTCPServer_Reconnect($) {###########################################################
  my($in ) = shift;
  my(undef,$name) = split(':',$in);
  my $hash = $defs{$name};

  RemoveInternalTimer( "reconnect:".$name);
  ModbusTCPServer_Ready($hash);
}
  
sub ModbusTCPServer_SimpleWrite(@) {#####################################################
  my ($hash, $msg) = @_;

  return if(!$hash || AttrVal($hash->{NAME}, "dummy", undef));

  my $name = $hash->{NAME};
  my $len = length($msg);
  if($hash->{TCPDev}) {
    $hash->{helper}{hd_tr_id}=unpack("n",$msg);
    $hash->{helper}{state}="active";
    InternalTimer(gettimeofday()+AttrVal($name,"timeout",3), "ModbusTCPServer_Timeout", "timeout:".$name, 1);
    _MbLogFrame($hash,"SimpleWrite",$msg);
    ModbusTCPServer_UpdateStatistics($hash,0,1,0,bytes::length($msg));
    syswrite($hash->{TCPDev}, $msg);     
  }
}

sub ModbusTCPServer_DoInit($) {##########################################################
  my ($hash) = @_;
  my $name = $hash->{NAME};

  my $tn = gettimeofday();
  my $pollIntervall = AttrVal($name,"pollIntervall",3000)/1000.0;

  $hash->{helper}{state}="idle";
  RemoveInternalTimer( "poll:".$name);
  InternalTimer($tn+$pollIntervall, "ModbusTCPServer_Poll", "poll:".$name, 0);

  return undef;
}

sub ModbusTCPServer_Poll($) {##################################################
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
            my $tx_hd_length     = bytes::length($msg);

            my $f_mbap = pack("nnn", $chash->{helper}{address}, 0,
                                      $tx_hd_length);

            _MbLogFrame($hash,"AddRQueue",$f_mbap.$msg);
            ModbusTCPServer_AddRQueue($hash, $f_mbap.$msg);
            $chash->{helper}{nextUpdate}=time()+$chash->{helper}{updateIntervall} if(defined($chash->{helper}{updateIntervall}));
          }
        }
      }
      @chlds=devspec2array("TYPE=ModbusCoil");

      foreach(@chlds) {
        my $chash=$defs{$_};
        if(defined($chash) && defined($chash->{helper}{readCmd}) && defined($chash->{IODev}) && ($chash->{IODev} eq $hash)) {
          if((!defined($chash->{helper}{nextUpdate}))||($chash->{helper}{nextUpdate}<time())) {
            my $msg=$chash->{helper}{readCmd};
            my $tx_hd_length     = bytes::length($msg);

            my $f_mbap = pack("nnn", $chash->{helper}{address}, 0,
                                      $tx_hd_length);

            _MbLogFrame($hash,"AddRQueue",$f_mbap.$msg);
            ModbusTCPServer_AddRQueue($hash, $f_mbap.$msg);
            $chash->{helper}{nextUpdate}=time()+$chash->{helper}{updateIntervall} if(defined($chash->{helper}{updateIntervall}));
          }
        }
      }
    }
    if($tn+$pollIntervall<=gettimeofday()) {
      $tn=gettimeofday()-$pollIntervall+0.05;
    }
    InternalTimer($tn+$pollIntervall, "ModbusTCPServer_Poll", "poll:".$name, 0);
  }
}

sub
ModbusTCPServer_Timeout($) ##################################################
{
  my($in ) = shift;
  my(undef,$name) = split(':',$in);
  my $hash = $defs{$name};

  $hash->{STATE} = "timeout";
  $hash->{helper}{state}="idle";
  $hash->{helper}{hd_tr_id}=-1;
}

sub
ModbusTCPServer_SendFromWQueue($$) ##################################################
{
  my ($hash, $bstring) = @_;
  my $name = $hash->{NAME};

  if($bstring ne "") {
    ModbusTCPServer_SimpleWrite($hash, $bstring);
  }
  InternalTimer(gettimeofday()+0.02, "ModbusTCPServer_HandleWriteQueue", $hash, 1);
}

sub
ModbusTCPServer_AddWQueue($$) ##################################################
{
  my ($hash, $bstring) = @_;
  if(!$hash->{WQUEUE}) {
    if($hash->{helper}{state} eq "idle") {
      $hash->{WQUEUE} = [ $bstring ];
      ModbusTCPServer_SendFromWQueue($hash, $bstring);
    } else {
      $hash->{WQUEUE} = [ $bstring ];
      push(@{$hash->{WQUEUE}}, $bstring);
      InternalTimer(gettimeofday()+0.02, "ModbusTCPServer_HandleWriteQueue", $hash, 1);
    }
  } else {
    Log3 $hash, 5,"adding to WQUEUE - ".scalar(@{$hash->{WQUEUE}});
    push(@{$hash->{WQUEUE}}, $bstring);
  }
}

sub
ModbusTCPServer_HandleWriteQueue($) ##################################################
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
        ModbusTCPServer_HandleWriteQueue($hash);
      } else {
        ModbusTCPServer_SendFromWQueue($hash, $bstring);
      }
    }
  } else {
    InternalTimer(gettimeofday()+0.02, "ModbusTCPServer_HandleWriteQueue", $hash, 1);
  }
} 

sub
ModbusTCPServer_SendFromRQueue($$) ##################################################
{
  my ($hash, $bstring) = @_;
  my $name = $hash->{NAME};

  if($bstring ne "") {
    ModbusTCPServer_SimpleWrite($hash, $bstring);
  }
  InternalTimer(gettimeofday()+0.02, "ModbusTCPServer_HandleReadQueue", $hash, 1);
}

sub
ModbusTCPServer_AddRQueue($$) ##################################################
{
  my ($hash, $bstring) = @_;
  if(!$hash->{RQUEUE}) {
    if(($hash->{helper}{state} eq "idle")&&(!defined($hash->{WQUEUE}))) {
      $hash->{RQUEUE} = [ $bstring ];
      ModbusTCPServer_SendFromRQueue($hash, $bstring);
    } else {
      $hash->{RQUEUE} = [ $bstring ];
      push(@{$hash->{RQUEUE}}, $bstring);
      InternalTimer(gettimeofday()+0.02, "ModbusTCPServer_HandleReadQueue", $hash, 1);
    }
  } else {
    Log3 $hash, 5,"adding to RQUEUE - ".scalar(@{$hash->{RQUEUE}});
    push(@{$hash->{RQUEUE}}, $bstring);
  }
}

sub
ModbusTCPServer_HandleReadQueue($) ##################################################
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
        ModbusTCPServer_HandleReadQueue($hash);
      } else {
        ModbusTCPServer_SendFromRQueue($hash, $bstring);
      }
    }
  } else {
    InternalTimer(gettimeofday()+0.02, "ModbusTCPServer_HandleReadQueue", $hash, 1);
  }
} 

sub _MbLogFrame($$$) {
  my ($hash,$c,$data)=@_;

  my @dump = map {sprintf "%02X", $_ } unpack("C*", $data);
  $dump[0] = "[".$dump[0];
  $dump[5] = $dump[5]."]";
  
  Log3 $hash, 5,$c." ".join(" ",@dump)
}

sub ModbusTCPServer_UpdateStatistics($$$$$) {############################################################
  my ($hash,$pi,$po,$bi,$bo)=@_;

  $hash->{helper}{statistics}{pktIn}=0 if (!defined($hash->{helper}{statistics}{pktIn}));
  $hash->{helper}{statistics}{pktOut}=0 if (!defined($hash->{helper}{statistics}{pktOut}));
  $hash->{helper}{statistics}{bytesIn}=0 if (!defined($hash->{helper}{statistics}{bytesIn}));
  $hash->{helper}{statistics}{bytesOut}=0 if (!defined($hash->{helper}{statistics}{bytesOut}));
  
  $hash->{helper}{statistics}{pktIn}+=$pi;
  $hash->{helper}{statistics}{pktOut}+=$po;
  $hash->{helper}{statistics}{bytesIn}+=$bi;
  $hash->{helper}{statistics}{bytesOut}+=$bo;
  $hash->{statistics} =$hash->{helper}{statistics}{pktIn} ." / " . $hash->{helper}{statistics}{pktOut} ." / " . $hash->{helper}{statistics}{bytesIn} ." / " . $hash->{helper}{statistics}{bytesOut};
}
1;

=pod
=begin html

<a name="ModbusTCPServer"></a>
<h3>ModbusTCPServer</h3>
<ul>
  This module allows you to connect to a Modbus TCP/IP server.<br><br>
  This module provides an IODevice for:
  <ul>
    <li><a href="#ModbusRegister">ModbusRegister</a> a module for accessing holding and input registers</li>
    <li><a href="#ModbusCoil">ModbusCoil</a> a module for accessing coils and discrete inputs</li>
  </ul>
  <br><br>
  <a name="ModbusTCPServerdefine"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; ModbusTCPServer &lt;ip-address[:port]&gt;</code> <br>
    <br>
    If no port is specified 502 will be used.<br/>

  </ul>
  <br>
  <a name="ModbusTCPServerset"></a>
  <b>Set</b> <ul>N/A</ul><br>
  <a name="ModbusTCPServerget"></a>
  <b>Get</b> <ul>N/A</ul><br>
  <a name="ModbusTCPServerattr"></a>
  <b>Attributes</b>
  <ul>
    <li><a href="#attrdummy">dummy</a></li><br>
    <li><a href="#readingFnAttributes">readingFnAttributes</a></li><br>
    <li><a name="">pollIntervall</a><br>
        Intervall in seconds for the reading cycle. Default: 0.1</li><br>
    <li><a name="">timeout</a><br>
        Timeout in seconds waiting for data from the server. Default: 3</li><br>
    <li><a name="">presenceLink</a><br>
        Name of a <a href="#PRESENCE">PRESENCE</a> instance. Used to detect if the server is accessible.</li><br>
    
  </ul>
</ul>

=end html
=cut
