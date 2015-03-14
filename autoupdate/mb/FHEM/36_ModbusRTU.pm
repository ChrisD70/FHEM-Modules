##############################################
# $Id: 36_ModbusRTU.pm 0008 $
# 140503 0001 initial release
# 140505 0002 fix dummy on startup
# 140507 0003 added 'use bytes', fixed partial data handling in read function
# 140507 0004 fixed call to parse in read function
# 140508 0005 added REREADCFG to ModbusRTU_Notify, added timer if $init_done==0
# 150118 0006 removed defaultUnitId and presenceLink, completed documentation
# 150215 0007 added support for hostname:port (by Dieter1)
# 150314 0008 fixed typo in attribute name pollIntervall
#             added ModbusRTU_CalcNextUpdate
#             added timeout message
#             check if request is already in rqueue
#             added combineReads
#             added support for coils
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
sub ModbusRTU_LogFrame($$$$);
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
                     "pollIntervall pollInterval " .
                     "timeout " .
                     "charformat " .
                     "combineReads " .
                     $readingFnAttributes;
}
sub ModbusRTU_Define($$) {#########################################################
  my ($hash, $def) = @_;
  my @a = split("[ \t][ \t]*", $def);

  if(@a != 3) {
    my $msg = "wrong syntax: define <name> ModbusRTU {devicename[\@baudrate] ".
                        "| devicename\@directio | hostname:port}";
    Log3 $hash, 2, $msg;
    return $msg;
  }
 
  DevIo_CloseDev($hash);

  my $name = $a[0];
  my $dev = $a[2];
  $dev .= "\@9600" if( ($dev !~ m/\@/) && ($dev !~ m/:/));
  
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
    my $name = $hash->{NAME};
    if (defined($attr{$name}{pollIntervall})) {
      $attr{$name}{pollInterval}=$attr{$name}{pollIntervall} if(!defined($attr{$name}{pollInterval}));
      delete $attr{$name}{pollIntervall};
    }
    $modules{$hash->{TYPE}}{AttrList} =~ s/pollIntervall.//;
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
  
  if(($aName eq "pollIntervall") || ($aName eq "pollInterval")) {
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
  my $trId= pack 'n', unpack('x2n',$msg);
  
  ModbusRTU_LogFrame($hash,"AddWQueue",$msg.$crc,5);
  ModbusRTU_AddWQueue($hash, $trId.$msg.$crc);
}

sub ModbusRTU_Read($) {############################################################
# called from the global loop, when the select for hash->{FD} reports data
  my ($hash) = @_;
  my $buf = DevIo_SimpleRead($hash);
  return "" if(!defined($buf));

  my $name = $hash->{NAME};

  my $pdata = $hash->{helper}{PARTIAL};
  $pdata .= $buf;

  ModbusRTU_LogFrame($hash,"ModbusRTU_Read",$pdata,4);

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

  ModbusRTU_LogFrame($hash,"ModbusRTU_Parse",$rmsg,4);

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
        my $rx_hd_tr_id=$hash->{helper}{hd_tr_id};
        if((defined($hash->{helper}{combineReads})) && (defined($hash->{helper}{combineReads}{data}{$rx_hd_tr_id}))) {
            my $off;
            for my $r (@{$hash->{helper}{combineReads}{registers}})
            {
                if(($r->[0]==$hash->{helper}{combineReads}{data}{$rx_hd_tr_id}->[0]) && ($r->[1]==$hash->{helper}{combineReads}{data}{$rx_hd_tr_id}->[1])) {
                    if(($r->[2]>=$hash->{helper}{combineReads}{data}{$rx_hd_tr_id}->[2]) && (($r->[2]+$r->[3])<=($hash->{helper}{combineReads}{data}{$rx_hd_tr_id}->[2]+$nvals))) {
                        $off=3+($r->[2]-$hash->{helper}{combineReads}{data}{$rx_hd_tr_id}->[2])*2;
                        Dispatch($hash, "ModbusRegister:$rx_hd_unit_id:$r->[2]:$r->[1]:$r->[3]:".join(":",unpack("x".$off."n".($r->[3]), $rmsg)), undef); 
                    }
                }
            }
            delete($hash->{helper}{combineReads}{data}{$rx_hd_tr_id});
        } else {
            Dispatch($hash, "ModbusRegister:$rx_hd_unit_id:$rx_hd_tr_id:$rx_bd_fc:$nvals:".join(":",unpack("x3n$nvals", $rmsg)), undef); 
        }
    }
    if($rx_bd_fc==WRITE_SINGLE_REGISTER) {
      Dispatch($hash, "ModbusRegister:$rx_hd_unit_id:".unpack("x2n", $rmsg).":$rx_bd_fc:1:".unpack("x4n", $rmsg), undef); 
    }
    if($rx_bd_fc==WRITE_MULTIPLE_REGISTERS) {
      ;
    }
    if(($rx_bd_fc==READ_COILS)||($rx_bd_fc==READ_DISCRETE_INPUTS)) {
        my $nvals=unpack("x2C", $rmsg);
        my $rx_hd_tr_id=$hash->{helper}{hd_tr_id};
        if((defined($hash->{helper}{combineReads})) && (defined($hash->{helper}{combineReads}{data}{$rx_hd_tr_id}))) {
            $nvals*=8;
            my $off;
            my @coilvals=split('',unpack('x3b*',$rmsg));
            for my $r (@{$hash->{helper}{combineReads}{coils}})
            {
                if(($r->[0]==$hash->{helper}{combineReads}{data}{$rx_hd_tr_id}->[0]) && ($r->[1]==$hash->{helper}{combineReads}{data}{$rx_hd_tr_id}->[1])) {
                    if(($r->[2]>=$hash->{helper}{combineReads}{data}{$rx_hd_tr_id}->[2]) && (($r->[2]+$r->[3])<=($hash->{helper}{combineReads}{data}{$rx_hd_tr_id}->[2]+$nvals))) {
                        $off=$r->[2]-$hash->{helper}{combineReads}{data}{$rx_hd_tr_id}->[2];
                        Dispatch($hash, "ModbusCoil:$rx_hd_unit_id:$r->[2]:$r->[1]:$r->[3]:".$coilvals[$off], undef); 
                    }
                }
            }
            delete($hash->{helper}{combineReads}{data}{$rx_hd_tr_id});
        } else {
            Dispatch($hash, "ModbusCoil:$rx_hd_unit_id:$rx_hd_tr_id:$rx_bd_fc:$nvals:".join(":",unpack("x3C$nvals", $rmsg)), undef); 
        }
    }
    if($rx_bd_fc==WRITE_SINGLE_COIL) {
        Dispatch($hash, "ModbusCoil:$rx_hd_unit_id:".unpack("x2n", $rmsg).":$rx_bd_fc:1:".unpack("x4n", $rmsg), undef); 
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
  if(($hash->{USBDev})||($hash->{DIODev})||($hash->{TCPDev})) {
    $hash->{helper}{hd_tr_id}=unpack("n",$msg);
    $msg=pack('n*',unpack('x2n*',$msg));
    $hash->{helper}{state}="active";
    RemoveInternalTimer( "timeout:".$name); # CD 0008
    InternalTimer(gettimeofday()+AttrVal($name,"timeout",3), "ModbusRTU_Timeout", "timeout:".$name, 1);
    ModbusRTU_LogFrame($hash,"ModbusRTU_SimpleWrite",$msg,5);
    $hash->{USBDev}->write($msg)    if($hash->{USBDev});
    syswrite($hash->{DIODev}, $msg) if($hash->{DIODev});
    syswrite($hash->{TCPDev}, $msg) if($hash->{TCPDev});    # CD 0007
    $hash->{helper}{lastSimpleWrite}=$msg;

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

sub ModbusRTU_CalcNextUpdate(@) {##########################################################
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

sub ModbusRTU_Poll($) {##################################################
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

      foreach(@chlds) {
        my $chash=$defs{$_};
        if(defined($chash) && defined($chash->{helper}{readCmd}) && defined($chash->{IODev}) && ($chash->{IODev} eq $hash)) {
          if((!defined($chash->{helper}{nextUpdate}))||($chash->{helper}{nextUpdate}<=time())) {
            my $msg=$chash->{helper}{readCmd};
            my $crc = pack 'v', ModbusRTU_crc($msg);
            my $trId= pack 'n', $chash->{helper}{address};
            
            if(!defined($hash->{helper}{combineReads})) {
                ModbusRTU_LogFrame($hash,"AddRQueue",$msg.$crc,5);
                ModbusRTU_AddRQueue($hash, $trId.$msg.$crc);
            } else {
                push(@registers,[$chash->{helper}{unitId}, $chash->{helper}{registerType}, $chash->{helper}{address}, $chash->{helper}{nread}]);
            }
            ModbusRTU_CalcNextUpdate($chash);
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
                    ModbusRTU_AddCombinedReads($hash, $ui, $rt, $st, $n);
                }
                $ui=$r->[0]; $rt=$r->[1]; $st=$r->[2]; $n=$r->[3];
            } else {
                if($rt != $r->[1]) {
                    if($rt != -1) {
                        ModbusRTU_AddCombinedReads($hash, $ui, $rt, $st, $n);
                    }
                    $rt=$r->[1]; $st=$r->[2]; $n=$r->[3];
                } else {
                    if($st+$n<$r->[2]+$r->[3]) {
                        if(($r->[2]+$r->[3]-$st<=$hash->{helper}{combineReads}{cfg}{maxSize}) &&
                            ($r->[2]-($st+$n)<=$hash->{helper}{combineReads}{cfg}{maxSpace})) {
                            $n=$r->[2]+$r->[3]-$st;
                        } else {
                            ModbusRTU_AddCombinedReads($hash, $ui, $rt, $st, $n);
                            $st=$r->[2]; $n=$r->[3];
                        }
                    }
                }
            }
            $hash->{helper}{seq}=65000 if($hash->{helper}{seq}>65500);
          }
          if($rt != -1) {
            ModbusRTU_AddCombinedReads($hash, $ui, $rt, $st, $n);
          }
      }

      @chlds=devspec2array("TYPE=ModbusCoil");

      foreach(@chlds) {
        my $chash=$defs{$_};
        if(defined($chash) && defined($chash->{helper}{readCmd}) && defined($chash->{IODev}) && ($chash->{IODev} eq $hash)) {
          if((!defined($chash->{helper}{nextUpdate}))||($chash->{helper}{nextUpdate}<=time())) {
            my $msg=$chash->{helper}{readCmd};
            my $crc = pack 'v', ModbusRTU_crc($msg);
            my $trId= pack 'n', $chash->{helper}{address};
            
            if(!defined($hash->{helper}{combineReads})) {
                ModbusRTU_LogFrame($hash,"AddRQueue",$msg.$crc,5);
                ModbusRTU_AddRQueue($hash, $trId.$msg.$crc);
            } else {
                push(@coils,[$chash->{helper}{unitId}, $chash->{helper}{registerType}, $chash->{helper}{address}, 1]);
            }
            ModbusRTU_CalcNextUpdate($chash);
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
            if(!defined($rlast) || (defined($rlast) && (($rlast->[0]!=$r->[0]) || ($rlast->[1]!=$r->[1]) || ($rlast->[2]!=$r->[2]) || ($rlast->[3]!=$r->[3])))) {
                push(@{$hash->{helper}{combineReads}{coils}},$r) ;
            }
            $rlast=$r;
            if($ui != $r->[0]) {
                if($ui != -1) {
                    ModbusRTU_AddCombinedCoilReads($hash, $ui, $rt, $st, $n);
                }
                $ui=$r->[0]; $rt=$r->[1]; $st=($r->[2])-($r->[2]%8); $n=8; #$r->[3]+($r->[2]%8);
            } else {
                if($rt != $r->[1]) {
                    if($rt != -1) {
                        ModbusRTU_AddCombinedCoilReads($hash, $ui, $rt, $st, $n);
                    }
                    $rt=$r->[1]; $st=($r->[2])-($r->[2]%8); $n=8;
                } else {
                    if($st+$n<$r->[2]+$r->[3]) {
                        if(($r->[2]+$r->[3]-$st<=$hash->{helper}{combineReads}{cfg}{maxSize}) &&
                            ($r->[2]-($st+$n)<=$hash->{helper}{combineReads}{cfg}{maxSpace})) {
                            $n=$r->[2]+$r->[3]-$st;
                            $n+=(8-($n%8)) if($n%8>0);
                        } else {
                            ModbusRTU_AddCombinedCoilReads($hash, $ui, $rt, $st, $n);
                            $st=($r->[2])-($r->[2]%8); $n=8;
                        }
                    }
                }
            }
            $hash->{helper}{seqCoils}=64000 if($hash->{helper}{seqCoils}>64500);
          }
          if($rt != -1) {
            ModbusRTU_AddCombinedCoilReads($hash, $ui, $rt, $st, $n);
          }
      }
    }
    if($tn+$pollInterval<=gettimeofday()) {
      $tn=gettimeofday()-$pollInterval+0.05;
    }
    InternalTimer($tn+$pollInterval, "ModbusRTU_Poll", "poll:".$name, 0);
  }
}

sub
ModbusRTU_AddCombinedCoilReads($$$$$) ##################################################
{
    my ($hash, $ui, $rt, $st, $n) = @_;

    my $tx=pack("CCnn", $ui, $rt, $st, $n);
    my $crc = pack 'v', ModbusRTU_crc($tx);
    my $trId= pack 'n', $hash->{helper}{seqCoils};
    $hash->{helper}{combineReads}{data}{$hash->{helper}{seqCoils}}=[$ui, $rt, $st, $n];
    $hash->{helper}{seqCoils}++;
    ModbusRTU_LogFrame($hash,"AddRQueue",$tx.$crc,4);
    ModbusRTU_AddRQueue($hash, $trId.$tx.$crc);
}

sub
ModbusRTU_AddCombinedReads($$$$$) ##################################################
{
    my ($hash, $ui, $rt, $st, $n) = @_;

    my $tx=pack("CCnn", $ui, $rt, $st, $n);
    my $crc = pack 'v', ModbusRTU_crc($tx);
    my $trId= pack 'n', $hash->{helper}{seq};
    $hash->{helper}{combineReads}{data}{$hash->{helper}{seq}}=[$ui, $rt, $st, $n];
    $hash->{helper}{seq}++;
    ModbusRTU_LogFrame($hash,"AddRQueue",$tx.$crc,4);
    ModbusRTU_AddRQueue($hash, $trId.$tx.$crc);
}

sub
ModbusRTU_Timeout($) ##################################################
{
  my($in ) = shift;
  my(undef,$name) = split(':',$in);
  my $hash = $defs{$name};

  Log3 $hash, 3,"ModbusRTU_Timeout";

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
      Log3 $hash, 4,"WQUEUE: ".scalar(@{$arr});
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

sub ModbusRTU_LogFrame($$$$) {
  my ($hash,$c,$data,$verbose)=@_;

  my @dump = map {sprintf "%02X", $_ } unpack("C*", $data);

  $hash->{helper}{lastFrame}=$c." ".join(" ",@dump) if($c eq 'SimpleWrite');

  Log3 $hash, $verbose,$c." ".join(" ",@dump);
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
    <code>define &lt;name&gt; ModbusRTU &lt;device&gt;</code> <br>
    <br>
      You can specify a baudrate if the device name contains the @
      character, e.g.: /dev/ttyS0@9600<br>The port is opened with 8 data bits, 1 stop bit and even parity.<br>
      If the slaves use different settings they can be specified with the <a href="#ModbusRTUattrcharformat">charformat</a> attribute.<br>
      All slaves connected to a master must use the same character format.<br>

      Note: this module requires the Device::SerialPort or Win32::SerialPort module if the devices is connected via USB or a serial port. 
    <br><br>
      For network-connected devices (serial to ethernet gateways)<br>
      &lt;device&gt; specifies the host:port of the device, e.g.
      192.168.0.246:10001
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
    <li><a name="">pollInterval</a><br>
        Interval in seconds for the reading cycle. Default: 0.1</li><br>
    <li><a name="">combineReads</a><br>
        Combine reads if possible. The attribute accepts two values separated by a colon. The first value
        defines how many consecutive unused registers/coils will be included (1-118), the second defines the maximum
        number of registers/coils per read (8-126).</li><br>
    <li><a name="">timeout</a><br>
        Timeout in seconds waiting for data from the server. Default: 3</li><br>
    <li><a name="ModbusRTUattrcharformat">charformat</a><br>
        Character format to be used for communication with the slaves. Default: 8E1.</li><br>
    
  </ul>
</ul>

=end html
=cut
