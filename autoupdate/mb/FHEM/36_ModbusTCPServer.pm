##############################################
# $Id: 36_ModbusTCPServer.pm 0019 $
# 140318 0001 initial release
# 140505 0002 use address instead of register in Parse
# 140506 0003 added 'use bytes'
# 140508 0004 added REREADCFG to ModbusTCPServer_Notify
# 140819 0005 added statistics and support for coils
# 150118 0006 removed defaultUnitId, completed documentation
# 150221 0007 added info to bad frame message
# 150222 0008 fixed info for bad frame message
# 150222 0009 fixed typo in attribute name pollIntervall, added ModbusTCPServer_CalcNextUpdate
# 150225 0010 check if request is already in rqueue
# 150227 0011 added combineReads, try to recover bad frames
# 150307 0012 fixed combined reads for multiple unitids, added combineReads for coils, remove duplicate reads
# 150310 0013 delete and restart timeout timer after receiving bad packets, modified timeout log level
# 150314 0014 fixed first entry for combined reads
# 150330 0015 fixed errors in log, do not buffer writes if disconnected
# 151220 0016 use enableUpdate from ModbusRegister
# 151228 0017 use readCondition and writeCondition
# 151231 0018 added delay for readCondition
# 160305 0019 added serverType, read Wago configuration, apply offset to coils
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
sub ModbusTCPServer_AddRQueue($$$);
sub ModbusTCPServer_Timeout($);
sub ModbusTCPServer_HandleWriteQueue($);
sub ModbusTCPServer_HandleReadQueue($);
sub ModbusTCPServer_Reconnect($);
sub ModbusTCPServer_UpdateStatistics($$$$$);
sub ModbusTCPServer_LogFrame($$$$);

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
                     "pollIntervall pollInterval " .
                     "timeout " .
                     "presenceLink " .
                     "combineReads " .
                     "serverType:Wago " . # CD 0019
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
  $hash->{helper}{state}='?';   # CD 0015
  $hash->{helper}{delayNextRead}=0;
  $hash->{helper}{delayNextWrite}=0;
  
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
    my $name = $hash->{NAME};
    if (defined($attr{$name}{pollIntervall})) {
      $attr{$name}{pollInterval}=$attr{$name}{pollIntervall} if(!defined($attr{$name}{pollInterval}));
      delete $attr{$name}{pollIntervall};
    }
    $modules{$hash->{TYPE}}{AttrList} =~ s/pollIntervall.//;

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
  my $hash = $defs{$name};

  if(($aName eq "pollIntervall") || ($aName eq "pollInterval")) {
    if ($cmd eq "set") {
      $attr{$name}{pollInterval} = $aVal;
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
  elsif($aName eq "combineReads") {
    if ($cmd eq "set") {
        if(defined($aVal)) {
            my @args=split(':',$aVal);
            if(defined($args[0])) {
                if(($args[0]<0)||($args[0]>118)) {
                    return "invalid value for combineReads";
                }
                $hash->{helper}{combineReads}{cfg}{maxSpace}=$args[0];
                if(defined($args[1])) {
                    if(($args[1]<8)||($args[1]>126)) {
                        return "invalid value for combineReads";
                    }
                    $hash->{helper}{combineReads}{cfg}{maxSize}=$args[1];
                } else {
                    $hash->{helper}{combineReads}{cfg}{maxSize}=120;
                }
            } else {
                return "invalid value for combineReads";
            }
        }
    } else {
        delete($hash->{helper}{combineReads}) if(defined($hash->{helper}{combineReads}));
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
  # CD 0019 start
  elsif($aName eq "serverType") {
    delete($hash->{helper}{Wago}) if(defined($hash->{helper}{Wago}));
    delete($hash->{server}) if(defined($hash->{server}));
    if ($cmd eq "set") {
      if ($aVal eq "Wago") {
        RemoveInternalTimer( "poll:".$name);
        $hash->{helper}{Wago}{x}=1;
        if($hash->{STATE} ne "disconnected") {
          # read controller informations
          my $tx=pack("nnnCCnn", 8208, 0, 6, 0, 3, 8208, 5);
          ModbusTCPServer_LogFrame($hash,"AddRQueue",$tx,4);
          ModbusTCPServer_AddRQueue($hash, $tx,0);
          # read I/O informations
          $tx=pack("nnnCCnn", 4130, 0, 6, 0, 3, 4130, 4);
          ModbusTCPServer_LogFrame($hash,"AddRQueue",$tx,4);
          ModbusTCPServer_AddRQueue($hash, $tx,0);
        }
      }
    } else {
      RemoveInternalTimer( "poll:".$name);
      if($hash->{STATE} ne "disconnected") {
        InternalTimer(gettimeofday()+AttrVal($name,"pollInterval",0.5), "ModbusTCPServer_Poll", "poll:".$name, 0);
      }
    }
  # CD 0019 end
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
  $tx_hd_length-=4 if((substr $msg,-4,4) eq "QQQQ");  # CD 0019

  my $f_mbap = pack("nnn", $id, $tx_hd_pr_id,
                            $tx_hd_length);

  ModbusTCPServer_LogFrame($hash,"AddWQueue",$f_mbap.$msg,5);
  ModbusTCPServer_AddWQueue($hash, $f_mbap.$msg) if(ReadingsVal($hash->{NAME},"state","?") eq 'opened');
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

  my $lastFrame="unknown";
  $lastFrame=$hash->{helper}{lastFrame} if (defined($hash->{helper}{lastFrame}));
  
  ModbusTCPServer_LogFrame($hash,"ModbusTCPServer_Parse: received",$rmsg,5);

  if($hash->{helper}{state} eq "idle") {
    return undef;
  }
  
  # modbus TCP receive
  # decode
  my ($rx_hd_tr_id, $rx_hd_pr_id, $rx_hd_length, $rx_hd_unit_id, $rx_bd_fc, $f_body) = unpack "nnnCCa*", $rmsg;
  # check header
  if (!(($rx_hd_tr_id == $hash->{helper}{hd_tr_id}) && ($rx_hd_pr_id == 0) &&
        ($rx_hd_length == bytes::length($rmsg)-6) && ($hash->{helper}{fc} == $rx_bd_fc) )) { #&& ($rx_hd_unit_id == $hash->{helper}{hd_unit_id}))) {
        
    if(($rx_hd_tr_id == $hash->{helper}{last_hd_tr_id}) && ($rx_bd_fc == $hash->{helper}{last_fc}) && ($rx_hd_length <= bytes::length($rmsg)-6) ) {
        ModbusTCPServer_LogFrame($hash,"ModbusTCPServer_Parse: got frame for previous request: ",$rmsg,3);
        my @btmp = unpack('C*',$rmsg);
        my $n=$rx_hd_length+6;
        my $act_hd_tr_id=$hash->{helper}{hd_tr_id};
        my $act_fc=$hash->{helper}{fc};
        $hash->{helper}{hd_tr_id}=$hash->{helper}{last_hd_tr_id};
        $hash->{helper}{fc}=$hash->{helper}{last_fc};
        ModbusTCPServer_Parse($hash,pack("C$n",@btmp));
        RemoveInternalTimer( "timeout:".$name); # CD 0013
        InternalTimer(gettimeofday()+AttrVal($name,"timeout",3), "ModbusTCPServer_Timeout", "timeout:".$name, 1) if(!defined($hash->{helper}{badFrame}));
        $hash->{helper}{hd_tr_id}=$act_hd_tr_id;
        $hash->{helper}{fc}=$act_fc;
        $hash->{helper}{badFrame}=1;
        $hash->{helper}{state}="active";
        if($#btmp>$n) {
            ModbusTCPServer_LogFrame($hash,"ModbusTCPServer_Parse: trying to parse additional data: ",pack("C*",@btmp[$n..$#btmp]),3);  # CD 0013
            ModbusTCPServer_Parse($hash,pack("C*",@btmp[$n..$#btmp]));
        }
    } else {
        Log3 $hash, 1,"ModbusTCPServer_Parse: bad frame, sent: $lastFrame";
        ModbusTCPServer_LogFrame($hash,"ModbusTCPServer_Parse: bad frame, received: ",$rmsg,1);
        $hash->{STATE} = "error";
        if(!defined($hash->{helper}{badFrame})) {
            $hash->{helper}{badFrame}=1;
        } else {
            delete($hash->{helper}{badFrame});
        }
    }
  } else {
    # check except
    if ($rx_bd_fc > 0x80) {
      # except code
      my ($exp_code) = unpack "C", $f_body;
      $hash->{LAST_ERROR}  = MB_EXCEPT_ERR;
      $hash->{LAST_EXCEPT} = $exp_code;
      Log3 $hash, 2,"ModbusTCPServer_Parse: except (code $exp_code)";
      $hash->{STATE} = "error";
    } else {
      $hash->{STATE} = "ok";
      if($hash->{helper}{state} eq "readdevid") {
        
      }
      if(($rx_bd_fc==READ_HOLDING_REGISTERS)||($rx_bd_fc==READ_INPUT_REGISTERS)) {
        my $nvals=unpack("x8C", $rmsg)/2;
        if((defined($hash->{helper}{combineReads})) && (defined($hash->{helper}{combineReads}{data}{$rx_hd_tr_id}))) {
            my $off;
            for my $r (@{$hash->{helper}{combineReads}{registers}})
            {
                if(($r->[0]==$hash->{helper}{combineReads}{data}{$rx_hd_tr_id}->[0]) && ($r->[1]==$hash->{helper}{combineReads}{data}{$rx_hd_tr_id}->[1])) {
                    if(($r->[2]>=$hash->{helper}{combineReads}{data}{$rx_hd_tr_id}->[2]) && (($r->[2]+$r->[3])<=($hash->{helper}{combineReads}{data}{$rx_hd_tr_id}->[2]+$nvals))) {
                        $off=9+($r->[2]-$hash->{helper}{combineReads}{data}{$rx_hd_tr_id}->[2])*2;
                        Dispatch($hash, "ModbusRegister:$rx_hd_unit_id:$r->[2]:$r->[1]:$r->[3]:".join(":",unpack("x".$off."n".($r->[3]), $rmsg)), undef); 
                        #Log 0, "ModbusRegister:$rx_hd_unit_id:$r->[2]:$r->[1]:$r->[3]:".join(":",unpack("x".$off."n".($r->[3]), $rmsg));
                    }
                }
            }
            delete($hash->{helper}{combineReads}{data}{$rx_hd_tr_id});
        } else {
          # CD 0019 start
          if(defined($hash->{helper}{Wago}) && !defined($hash->{helper}{Wago}{initDone})) {
            my ($cnt,@v)=unpack "Cn*",$f_body;
            if(($rx_hd_tr_id==4130) && ($cnt==8)) {
              $hash->{helper}{Wago}{AO}=$v[0]/16;
              $hash->{helper}{Wago}{AI}=$v[1]/16;
              $hash->{helper}{Wago}{DO}=$v[2];
              $hash->{helper}{Wago}{DI}=$v[3];
              $hash->{helper}{Wago}{DOOffset}=$v[0];
              $hash->{helper}{Wago}{DIOffset}=$v[1];
              $hash->{helper}{Wago}{initDone}=1;
              RemoveInternalTimer( "poll:".$name);
              InternalTimer(gettimeofday()+AttrVal($name,"pollInterval",0.5), "ModbusTCPServer_Poll", "poll:".$name, 0);
            }
            if(($rx_hd_tr_id==8208) && ($cnt==10)) {
              $hash->{helper}{Wago}{INFO_REVISION}=$v[0];
              $hash->{helper}{Wago}{INFO_SERIES}=$v[1];
              $hash->{helper}{Wago}{INFO_ITEM}=$v[2];
              $hash->{helper}{Wago}{INFO_MAJOR}=$v[3];
              $hash->{helper}{Wago}{INFO_MINOR}=$v[4];
              $hash->{server}="Wago ".$v[1]."-".$v[2] if($v[1]+$v[2]>0);
            }
          } else {
          # CD 0019 end
            Dispatch($hash, "ModbusRegister:$rx_hd_unit_id:$rx_hd_tr_id:$rx_bd_fc:$nvals:".join(":",unpack("x9n$nvals", $rmsg)), undef); 
          }
        }
      }
      if($rx_bd_fc==WRITE_SINGLE_REGISTER) {
        Dispatch($hash, "ModbusRegister:$rx_hd_unit_id:".unpack("x8n", $rmsg).":$rx_bd_fc:1:".unpack("x10n", $rmsg), undef); 
      }
      if(($rx_bd_fc==READ_COILS)||($rx_bd_fc==READ_DISCRETE_INPUTS)) {
        my $nvals=unpack("x8C", $rmsg);
        if((defined($hash->{helper}{combineReads})) && (defined($hash->{helper}{combineReads}{data}{$rx_hd_tr_id}))) {
            $nvals*=8;
            my $off;
            my @coilvals=split('',unpack('x9b*',$rmsg));
#            Log 0,unpack('x9b*',$rmsg);
            for my $r (@{$hash->{helper}{combineReads}{coils}})
            {
                if(($r->[0]==$hash->{helper}{combineReads}{data}{$rx_hd_tr_id}->[0]) && ($r->[1]==$hash->{helper}{combineReads}{data}{$rx_hd_tr_id}->[1])) {
                    if(($r->[2]>=$hash->{helper}{combineReads}{data}{$rx_hd_tr_id}->[2]) && (($r->[2]+$r->[3])<=($hash->{helper}{combineReads}{data}{$rx_hd_tr_id}->[2]+$nvals))) {
                        $off=$r->[2]-$hash->{helper}{combineReads}{data}{$rx_hd_tr_id}->[2];
#                        Log 0,"ModbusCoil:$rx_hd_unit_id:$r->[2]:$r->[1]:$r->[3]:".$coilvals[$off];
                        Dispatch($hash, "ModbusCoil:$rx_hd_unit_id:$r->[4]:$r->[1]:$r->[3]:".$coilvals[$off], undef); # CD 0019 $r->[4] statt $r->[2]
                    }
                }
            }
            delete($hash->{helper}{combineReads}{data}{$rx_hd_tr_id});
        } else {
            Dispatch($hash, "ModbusCoil:$rx_hd_unit_id:$rx_hd_tr_id:$rx_bd_fc:$nvals:".join(":",unpack("x9C$nvals", $rmsg)), undef); 
        }
      }
      if($rx_bd_fc==WRITE_SINGLE_COIL) {
        # CD 0019 start
        if(defined($hash->{helper}{wagowritereturnaddress})) {
          Dispatch($hash, "ModbusCoil:$rx_hd_unit_id:".$hash->{helper}{wagowritereturnaddress}.":$rx_bd_fc:1:".unpack("x10n", $rmsg), undef); 
          delete $hash->{helper}{wagowritereturnaddress};
        } else {
        # CD 0019 end
          Dispatch($hash, "ModbusCoil:$rx_hd_unit_id:".unpack("x8n", $rmsg).":$rx_bd_fc:1:".unpack("x10n", $rmsg), undef); 
        }
      }
      if($rx_bd_fc==WRITE_MULTIPLE_REGISTERS) {
        ;
      }
    }
    delete($hash->{helper}{badFrame}) if(defined($hash->{helper}{badFrame}));
  }
  if(!defined($hash->{helper}{badFrame})) {
    RemoveInternalTimer( "timeout:".$name);
    $hash->{helper}{state}="idle";
  }
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
    $hash->{helper}{last_hd_tr_id}=$hash->{helper}{hd_tr_id} if(defined($hash->{helper}{hd_tr_id}) && ($hash->{helper}{hd_tr_id}!=-1));
    $hash->{helper}{last_fc}=$hash->{helper}{fc} if(defined($hash->{helper}{fc}) && ($hash->{helper}{fc}!=-1));
    my ($tx_hd_tr_id, $tx_hd_pr_id, $tx_hd_length, $tx_hd_unit_id, $tx_bd_fc, $f_body) = unpack "nnnCCa*", $msg;
    # CD 0019 start
    if(((substr $msg,-4,4) eq "QQQQ")&&($tx_bd_fc==5)) {
      $msg=substr $msg,0,$len-4;
      my ($wadr,$wv)=unpack "nn",$f_body;
      if(defined($hash->{helper}{Wago}{DOOffset}) && ($hash->{helper}{Wago}{DOOffset}>0) && ($hash->{helper}{Wago}{DOOffset}<$wadr)) {
        $msg=pack("nnnCCnn", $tx_hd_tr_id, $tx_hd_pr_id, $tx_hd_length,$tx_hd_unit_id, $tx_bd_fc, $wadr-$hash->{helper}{Wago}{DOOffset}, $wv);
      }
      $hash->{helper}{wagowritereturnaddress}=$wadr;
    }
    # CD 0019 end
    $hash->{helper}{hd_tr_id}=$tx_hd_tr_id;
    $hash->{helper}{fc}=$tx_bd_fc;
    $hash->{helper}{state}="active";
    RemoveInternalTimer( "timeout:".$name); # CD 0013
    InternalTimer(gettimeofday()+AttrVal($name,"timeout",3), "ModbusTCPServer_Timeout", "timeout:".$name, 1);
    ModbusTCPServer_LogFrame($hash,"SimpleWrite",$msg,5);
    ModbusTCPServer_UpdateStatistics($hash,0,1,0,bytes::length($msg));
    $hash->{helper}{lastSimpleWrite}=$msg;
    syswrite($hash->{TCPDev}, $msg);     
  }
}

sub ModbusTCPServer_DoInit($) {##########################################################
  my ($hash) = @_;
  my $name = $hash->{NAME};

  my $tn = gettimeofday();
  my $pollInterval = AttrVal($name,"pollInterval",0.5);
  
  delete($hash->{WQUEUE}) if(defined($hash->{WQUEUE}));     # CD 0015
  $hash->{helper}{state}="idle";

  RemoveInternalTimer( "poll:".$name);

  # CD 0019 start
  if (defined($hash->{helper}{Wago})) {
    delete($hash->{helper}{Wago}{initDone}) if defined($hash->{helper}{Wago}{initDone});
    # read controller informations
    my $tx=pack("nnnCCnn", 8208, 0, 6, 0, 3, 8208, 5);
    ModbusTCPServer_LogFrame($hash,"AddRQueue",$tx,4);
    ModbusTCPServer_AddRQueue($hash, $tx,0);
    # read I/O informations
    $tx=pack("nnnCCnn", 4130, 0, 6, 0, 3, 4130, 4);
    ModbusTCPServer_LogFrame($hash,"AddRQueue",$tx,4);
    ModbusTCPServer_AddRQueue($hash, $tx,0);
  } else {
  # CD 0019 end
    InternalTimer($tn+$pollInterval, "ModbusTCPServer_Poll", "poll:".$name, 0);
  }
  
  return undef;
}

sub ModbusTCPServer_CalcNextUpdate(@) {##########################################################
    my ($hash)=@_;
    my $name = $hash->{NAME};

    $hash->{helper}{lastUpdate}=$hash->{helper}{nextUpdate} if(defined($hash->{helper}{nextUpdate}));
    $hash->{lastUpdate}=$hash->{nextUpdate};
    if(defined($hash->{helper}{updateIntervall})) {
        if(defined($hash->{helper}{alignUpdateInterval})) {
            my $t=int(time());
            my @lt = localtime($t);
            
            $t -= ($lt[2]*3600+$lt[1]*60+$lt[0]);
            my $nextUpdate=$t+$hash->{helper}{alignUpdateInterval};
            while($nextUpdate<time()) {
                $nextUpdate+=$hash->{helper}{updateIntervall};
            }
            $hash->{helper}{nextUpdate}=$nextUpdate;
        } else {
            $hash->{helper}{nextUpdate}=time()+$hash->{helper}{updateIntervall};
        }
    } else {
        $hash->{helper}{nextUpdate}=time()+0.01;
    }
    $hash->{nextUpdate}=localtime($hash->{helper}{nextUpdate});
}

sub ModbusTCPServer_Poll($) {##################################################
  my($in ) = shift;
  my(undef,$name) = split(':',$in);
  my $hash = $defs{$name};
  
  my @registers;
  my @coils;

  if($hash->{STATE} ne "disconnected") {
    my $tn = gettimeofday();
    if (defined($attr{$name}{pollIntervall})) {
      $attr{$name}{pollInterval}=$attr{$name}{pollIntervall} if(!defined($attr{$name}{pollInterval}));
      delete $attr{$name}{pollIntervall};
    }
    my $pollInterval = AttrVal($name,"pollInterval",0.5);

    if(!defined($hash->{RQUEUE})) {
      my @chlds=devspec2array("TYPE=ModbusRegister");
      my $lastcondmsg="0";

      foreach(@chlds) {
        my $cn=$_;
        my $chash=$defs{$_};
        if(defined($chash) && defined($chash->{helper}{readCmd}) && defined($chash->{IODev}) && ($chash->{IODev} eq $hash)) {
          if((!defined($chash->{helper}{nextUpdate}))||($chash->{helper}{nextUpdate}<=time())) {
            my $msg=$chash->{helper}{readCmd};
            my $tx_hd_length     = bytes::length($msg);

            my $f_mbap = pack("nnn", $chash->{helper}{address}, 0,
                                      $tx_hd_length);

            # CD 0016 start
            my $nocombineReads=0;
            my $cond=AttrVal($cn,"readCondition",undef);
            
            if (defined($cond)) {
              my @c=split(':',$cond);
              if ($#c>=3) {
                my $cv=ReadingsVal($c[0],$c[1],undef);
                if (defined($cv) && ($c[3]==1)) {
                  my $conh=$defs{$c[0]};
                  if (defined($conh)) {
                    # check type, only if same IODev
                    my $condmsg='skip';
                    if(($conh->{TYPE} eq 'ModbusRegister') && (defined($conh->{IODev}) && ($chash->{IODev} eq $conh->{IODev}))) {
                      $condmsg=pack("CCnn", $conh->{helper}{unitId}, 6, $conh->{helper}{address}, $c[2]);
                    }
                    if(($conh->{TYPE} eq 'ModbusCoil') && (defined($conh->{IODev}) && ($chash->{IODev} eq $conh->{IODev}))) {
                      my $v=0;
                      $v=255 if(($c[2] eq "on") || ($c[2] eq "1"));
                      $condmsg=pack("CCnCC", $conh->{helper}{unitId}, 5, $conh->{helper}{address}, $v,0);
                    }
                    if($condmsg ne 'skip') {
                      my $condf_mbap = pack("nnn", int(rand 65535), 0,bytes::length($condmsg));
#                      Log3 $hash, 0, unpack("H*",$lastcondmsg)." - ".unpack("H*",$condmsg);
                      if ($lastcondmsg ne $condmsg) {
                        ModbusTCPServer_LogFrame($hash,"AddRQueue",$condf_mbap.$condmsg,5);
                        ModbusTCPServer_AddRQueue($hash, $condf_mbap.$condmsg,1);
                        if (defined($c[4])) {
                          ModbusTCPServer_AddRQueue($hash, "delay:".$c[4],1);
                        }
                        $lastcondmsg=$condmsg;
                      }
                      $nocombineReads=1;
                    }
                  }
                }            
              }
            }
                                      
            if(!defined($hash->{helper}{combineReads}) || ($nocombineReads==1)) {
                ModbusTCPServer_LogFrame($hash,"AddRQueue",$f_mbap.$msg,5);
                ModbusTCPServer_AddRQueue($hash, $f_mbap.$msg, $nocombineReads);
            } else {
                push(@registers,[$chash->{helper}{unitId}, $chash->{helper}{registerType}, $chash->{helper}{address}, $chash->{helper}{nread}]);
            }
            ModbusTCPServer_CalcNextUpdate($chash);
          }
        }
      }

      if(defined($hash->{helper}{combineReads})) {
          my @sorted=sort {
            if($a->[0] == $b->[0]) {
                if($a->[1] == $b->[1]) {
                    return $a->[2] <=> $b->[2]
                } else {
                    return $a->[1] <=> $b->[1]
                }
            } else {
                return $a->[0] <=> $b->[0]
            }} @registers;
          #use Data::Dump 'dump';
          #Log 0,dump @sorted;            
          my $ui=-1;
          my $rt=-1;
          my $st=-1;
          my $n=-1;
          $hash->{helper}{seq}=65000 if(!defined($hash->{helper}{seq}));
          delete($hash->{helper}{combineReads}{registers}) if defined($hash->{helper}{combineReads}{registers});
          my $rlast;
          for my $r (@sorted)
          {
            if(!defined($rlast) || (defined($rlast) && (($rlast->[0]!=$r->[0]) || ($rlast->[1]!=$r->[1]) || ($rlast->[2]!=$r->[2]) || ($rlast->[3]!=$r->[3])))) {
                push(@{$hash->{helper}{combineReads}{registers}},$r);
            }
            $rlast=$r;
            if($ui != $r->[0]) {
                if($ui != -1) {
                    ModbusTCPServer_AddCombinedReads($hash, $ui, $rt, $st, $n);
                }
                $ui=$r->[0]; $rt=$r->[1]; $st=$r->[2]; $n=$r->[3];
            } else {
                if($rt != $r->[1]) {
                    if($rt != -1) {
                        ModbusTCPServer_AddCombinedReads($hash, $ui, $rt, $st, $n);
                    }
                    $rt=$r->[1]; $st=$r->[2]; $n=$r->[3];
                } else {
                    if($st+$n<$r->[2]+$r->[3]) {
                        if(($r->[2]+$r->[3]-$st<=$hash->{helper}{combineReads}{cfg}{maxSize}) &&
                            ($r->[2]-($st+$n)<=$hash->{helper}{combineReads}{cfg}{maxSpace})) {
                            $n=$r->[2]+$r->[3]-$st;
                        } else {
                            ModbusTCPServer_AddCombinedReads($hash, $ui, $rt, $st, $n);
                            $st=$r->[2]; $n=$r->[3];
                        }
                    }
                }
            }
            $hash->{helper}{seq}=65000 if($hash->{helper}{seq}>65500);
          }
          if($rt != -1) {
            ModbusTCPServer_AddCombinedReads($hash, $ui, $rt, $st, $n);
          }
      }
      
      @chlds=devspec2array("TYPE=ModbusCoil");

      foreach(@chlds) {
        my $cn=$_;
        my $chash=$defs{$_};
        if(defined($chash) && defined($chash->{helper}{readCmd}) && defined($chash->{IODev}) && ($chash->{IODev} eq $hash)) {
          if((!defined($chash->{helper}{nextUpdate}))||($chash->{helper}{nextUpdate}<=time())) {
            my $msg=$chash->{helper}{readCmd};
            # CD 0019 start
            if(defined($chash->{helper}{wagoT})) {
              if(($chash->{helper}{wagoT} eq "I") && (defined($hash->{helper}{Wago}{DIOffset})) && ($hash->{helper}{Wago}{DIOffset}<$chash->{helper}{address})) {
                $msg=pack("CCnn", $chash->{helper}{unitId}, $chash->{helper}{registerType}, $chash->{helper}{address}-$hash->{helper}{Wago}{DIOffset}, $chash->{helper}{nread});
              }
              if(($chash->{helper}{wagoT} eq "Q") && (defined($hash->{helper}{Wago}{DOOffset})) && ($hash->{helper}{Wago}{DOOffset}<$chash->{helper}{address})) {
                $msg=pack("CCnn", $chash->{helper}{unitId}, $chash->{helper}{registerType}, $chash->{helper}{address}-$hash->{helper}{Wago}{DOOffset}, $chash->{helper}{nread});
              }
            }
            # CD 0019 end
            my $tx_hd_length     = bytes::length($msg);

            my $f_mbap = pack("nnn", $chash->{helper}{address}, 0,
                                      $tx_hd_length);

            # CD 0017 start
            my $nocombineReads=0;
            my $cond=AttrVal($cn,"readCondition",undef);
            if (defined($cond)) {
              my @c=split(':',$cond);
              if ($#c>=3) {
                my $cv=ReadingsVal($c[0],$c[1],undef);
                if (defined($cv) && ($c[3]==1)) {
                  my $conh=$defs{$c[0]};
                  if (defined($conh)) {
                    # check type, only if same IODev
                    my $condmsg='skip';
                    if(($conh->{TYPE} eq 'ModbusRegister') && (defined($conh->{IODev}) && ($chash->{IODev} eq $conh->{IODev}))) {
                      $condmsg=pack("CCnn", $conh->{helper}{unitId}, 6, $conh->{helper}{address}, $c[2]);
                    }
                    if(($conh->{TYPE} eq 'ModbusCoil') && (defined($conh->{IODev}) && ($chash->{IODev} eq $conh->{IODev}))) {
                      my $v=0;
                      $v=255 if(($c[2] eq "on") || ($c[2] eq "1"));
                      $condmsg=pack("CCnCC", $conh->{helper}{unitId}, 5, $conh->{helper}{address}, $v,0);
                      # CD 0019 start
                      if(defined($conh->{helper}{wagoT})) {
                        if(($conh->{helper}{wagoT} eq "Q") && (defined($hash->{helper}{Wago}{DOOffset})) && ($hash->{helper}{Wago}{DOOffset}<$conh->{helper}{address})) {
                          $condmsg=pack("CCnCC", $conh->{helper}{unitId}, 5, $conh->{helper}{address}-$hash->{helper}{Wago}{DOOffset}, $v, 0);
                        }
                      }
                      # CD 0019 end
                    }
                    if($condmsg ne 'skip') {
                      my $condf_mbap = pack("nnn", int(rand 65535), 0,bytes::length($condmsg));
                      if ($lastcondmsg ne $condmsg) {
                        ModbusTCPServer_LogFrame($hash,"AddRQueue",$condf_mbap.$condmsg,5);
                        ModbusTCPServer_AddRQueue($hash, $condf_mbap.$condmsg,1);
                        if (defined($c[4])) {
                          ModbusTCPServer_AddRQueue($hash, "delay:".$c[4],1);
                        }
                        $lastcondmsg=$condmsg;
                      }
                      $nocombineReads=1;
                    }
                  }
                }            
              }
            }
                                      
            if(!defined($hash->{helper}{combineReads}) || ($nocombineReads==1)) {
                ModbusTCPServer_LogFrame($hash,"AddRQueue",$f_mbap.$msg,5);
                ModbusTCPServer_AddRQueue($hash, $f_mbap.$msg, $nocombineReads);
            } else {
              # CD 0019 start
              if(defined($chash->{helper}{wagoT})) {
                if(($chash->{helper}{wagoT} eq "I") && (defined($hash->{helper}{Wago}{DIOffset})) && ($hash->{helper}{Wago}{DIOffset}<$chash->{helper}{address})) {
                  push(@coils,[$chash->{helper}{unitId}, $chash->{helper}{registerType}, $chash->{helper}{address}-$hash->{helper}{Wago}{DIOffset}, 1, $chash->{helper}{address}]);
                }
                elsif(($chash->{helper}{wagoT} eq "Q") && (defined($hash->{helper}{Wago}{DOOffset})) && ($hash->{helper}{Wago}{DOOffset}<$chash->{helper}{address})) {
                  push(@coils,[$chash->{helper}{unitId}, $chash->{helper}{registerType}, $chash->{helper}{address}-$hash->{helper}{Wago}{DOOffset}, 1, $chash->{helper}{address}]);
                } else {
                  push(@coils,[$chash->{helper}{unitId}, $chash->{helper}{registerType}, $chash->{helper}{address}, 1, $chash->{helper}{address}]);
                }
              } else {
              # CD 0019 end
                push(@coils,[$chash->{helper}{unitId}, $chash->{helper}{registerType}, $chash->{helper}{address}, 1, $chash->{helper}{address}]);
              }
            }
            ModbusTCPServer_CalcNextUpdate($chash);
          }
        }
      }
      if(defined($hash->{helper}{combineReads})) {
          my @sorted=sort {
            if($a->[0] == $b->[0]) {
                if($a->[1] == $b->[1]) {
                    return $a->[2] <=> $b->[2]
                } else {
                    return $a->[1] <=> $b->[1]
                }
            } else {
                return $a->[0] <=> $b->[0]
            }} @coils;
          #Log 0,dump @sorted;            
          my $ui=-1;
          my $rt=-1;
          my $st=-1;
          my $n=-1;
          $hash->{helper}{seqCoils}=64000 if(!defined($hash->{helper}{seqCoils}));
          delete($hash->{helper}{combineReads}{coils}) if defined($hash->{helper}{combineReads}{coils});
          my $rlast;
          for my $r (@sorted)
          {
            if(!defined($rlast) || (defined($rlast) && (($rlast->[0]!=$r->[0]) || ($rlast->[1]!=$r->[1]) || ($rlast->[2]!=$r->[2]) || ($rlast->[3]!=$r->[3]) || ($rlast->[4]!=$r->[4])))) { # CD 0019 added $r->[4]
                push(@{$hash->{helper}{combineReads}{coils}},$r) ;
            }
            $rlast=$r;
            if($ui != $r->[0]) {
                if($ui != -1) {
                    ModbusTCPServer_AddCombinedCoilReads($hash, $ui, $rt, $st, $n);
                }
                $ui=$r->[0]; $rt=$r->[1]; $st=($r->[2])-($r->[2]%8); $n=8; #$r->[3]+($r->[2]%8);
            } else {
                if($rt != $r->[1]) {
                    if($rt != -1) {
                        ModbusTCPServer_AddCombinedCoilReads($hash, $ui, $rt, $st, $n);
                    }
                    $rt=$r->[1]; $st=($r->[2])-($r->[2]%8); $n=8;
                } else {
                    if($st+$n<$r->[2]+$r->[3]) {
                        if(($r->[2]+$r->[3]-$st<=$hash->{helper}{combineReads}{cfg}{maxSize}) &&
                            ($r->[2]-($st+$n)<=$hash->{helper}{combineReads}{cfg}{maxSpace})) {
                            $n=$r->[2]+$r->[3]-$st;
                            $n+=(8-($n%8)) if($n%8>0);
                        } else {
                            ModbusTCPServer_AddCombinedCoilReads($hash, $ui, $rt, $st, $n);
                            $st=($r->[2])-($r->[2]%8); $n=8;
                        }
                    }
                }
            }
            $hash->{helper}{seqCoils}=64000 if($hash->{helper}{seqCoils}>64500);
          }
          if($rt != -1) {
            ModbusTCPServer_AddCombinedCoilReads($hash, $ui, $rt, $st, $n);
          }
      }
    }
    if($tn+$pollInterval<=gettimeofday()) {
      $tn=gettimeofday()-$pollInterval+0.05;
    }
    InternalTimer($tn+$pollInterval, "ModbusTCPServer_Poll", "poll:".$name, 0);
  }
}

sub
ModbusTCPServer_AddCombinedCoilReads($$$$$) ##################################################
{
    my ($hash, $ui, $rt, $st, $n) = @_;

    my $tx=pack("nnnCCnn", $hash->{helper}{seqCoils}, 0, 6, $ui, $rt, $st, $n);
    $hash->{helper}{combineReads}{data}{$hash->{helper}{seqCoils}}=[$ui, $rt, $st, $n];
    $hash->{helper}{seqCoils}++;
    ModbusTCPServer_LogFrame($hash,"AddRQueue",$tx,4);
    ModbusTCPServer_AddRQueue($hash, $tx,0);
}

sub
ModbusTCPServer_AddCombinedReads($$$$$) ##################################################
{
    my ($hash, $ui, $rt, $st, $n) = @_;

    my $tx=pack("nnnCCnn", $hash->{helper}{seq}, 0, 6, $ui, $rt, $st, $n);
    $hash->{helper}{combineReads}{data}{$hash->{helper}{seq}}=[$ui, $rt, $st, $n];
    $hash->{helper}{seq}++;
    ModbusTCPServer_LogFrame($hash,"AddRQueue",$tx,4);
    ModbusTCPServer_AddRQueue($hash, $tx,0);
}

sub
ModbusTCPServer_Timeout($) ##################################################
{
  my($in ) = shift;
  my(undef,$name) = split(':',$in);
  my $hash = $defs{$name};

  Log3 $hash, 3,"ModbusTCPServer_Timeout, request: ".($hash->{helper}{lastFrame});

  $hash->{STATE} = "timeout";
  $hash->{helper}{state}="idle";
  $hash->{helper}{last_hd_tr_id}=$hash->{helper}{hd_tr_id};
  $hash->{helper}{last_fc}=$hash->{helper}{fc};
  $hash->{helper}{hd_tr_id}=-1;
  $hash->{helper}{fc}=-1;
  delete $hash->{helper}{wagowritereturnaddress} if(defined($hash->{helper}{wagowritereturnaddress}));  # CD 0019
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

  my @cmd=split(':',$bstring);
  if($#cmd==1) {
    if($cmd[0] eq 'delay') {
      $hash->{helper}{delayNextRead}=time()+$cmd[1]/1000.0;
    }
  } else {
    if($bstring ne "") {
      ModbusTCPServer_SimpleWrite($hash, $bstring);
    }
  }
  InternalTimer(gettimeofday()+0.02, "ModbusTCPServer_HandleReadQueue", $hash, 1);
}

sub
ModbusTCPServer_AddRQueue($$$) ##################################################
{
  my ($hash, $bstring, $ignoreDups) = @_;
  
  if(!$hash->{RQUEUE}) {
    if(($hash->{helper}{state} eq "idle")&&(!defined($hash->{WQUEUE})) && ($hash->{helper}{delayNextRead}<time())) {
      $hash->{RQUEUE} = [ $bstring ];
      ModbusTCPServer_SendFromRQueue($hash, $bstring);
    } else {
      $hash->{RQUEUE} = [ $bstring ];
      push(@{$hash->{RQUEUE}}, $bstring);
      InternalTimer(gettimeofday()+0.02, "ModbusTCPServer_HandleReadQueue", $hash, 1);
    }
  } else {
    my $add=1;
    for my $el (@{$hash->{RQUEUE}}) {
        if($el eq $bstring) {
            $add=0;
        }
    }
    if (($add==1) or ($ignoreDups)) {
        Log3 $hash, 5,"adding to RQUEUE - ".scalar(@{$hash->{RQUEUE}});
        push(@{$hash->{RQUEUE}}, $bstring);
    }
  }
}

sub
ModbusTCPServer_HandleReadQueue($) ##################################################
{
  my $hash = shift;
  if(($hash->{helper}{state} eq "idle")&&(!defined($hash->{WQUEUE})) && ($hash->{helper}{delayNextRead}<time())) {
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

sub ModbusTCPServer_LogFrame($$$$) {
  my ($hash,$c,$data,$verbose)=@_;

  my @dump = map {sprintf "%02X", $_ } unpack("C*", $data);
  $dump[0] = "[".$dump[0];
  $dump[5] = $dump[5]."]";

  $hash->{helper}{lastFrame}=$c." ".join(" ",@dump) if($c eq 'SimpleWrite');

  Log3 $hash, $verbose,$c." ".join(" ",@dump);
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
    <li><a name="">pollInterval</a><br>
        Intervall in seconds for the reading cycle. Default: 0.5</li><br>
    <li><a name="">combineReads</a><br>
        Combine register reads if possible. The attribute accepts two values separated by a colon. The first value
        defines how many consecutive unused registers will be included (1-118), the second defines the maximum
        number of register per read (8-126).</li><br>
    <li><a name="">timeout</a><br>
        Timeout in seconds waiting for data from the server. Default: 3</li><br>
    <li><a name="">presenceLink</a><br>
        Name of a <a href="#PRESENCE">PRESENCE</a> instance. Used to detect if the server is accessible.</li><br>
    
  </ul>
</ul>

=end html
=cut
