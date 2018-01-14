##############################################
# $Id: 36_ModbusTCP_CC.pm 0007 2018-01-14 11:16:00Z CD $
# 140221 0001 initial release
# 160207 0002 added FC 6 and 16, modified for FHEM 5.7
# 161231 0003 added IEEE 754 single precision (litte & big endian), added bit support for registers
# 170205 0004 fixed writing 16-bit integers
# 170527 0005 added FC 1, 2 and 15
# 170528 0006 performance improvements, updated documentation
# 180114 0007 ignore unknown format specifiers on WRITE_*_REGISTERS

package main;

use strict;
use warnings;
use Time::HiRes qw(gettimeofday time);
use Digest::MD5 qw(md5);
use bytes;
use TcpServerUtils; 

## Modbus function code
# standard
use constant READ_COILS                                  => 0x01;
use constant READ_DISCRETE_INPUTS                        => 0x02;
use constant READ_HOLDING_REGISTERS                      => 0x03;
use constant READ_INPUT_REGISTERS                        => 0x04;
use constant WRITE_SINGLE_COIL                           => 0x05;
use constant WRITE_SINGLE_REGISTER                       => 0x06;
use constant WRITE_MULTIPLE_COILS                        => 0x0F;
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

sub ModbusTCP_CC_Initialize($) {
  my ($hash) = @_;

  require "$attr{global}{modpath}/FHEM/DevIo.pm";

# Provider
  $hash->{ReadFn}  = "ModbusTCP_CC_Read";
#  $hash->{WriteFn} = "ModbusTCP_CC_Write";
#  $hash->{ReadyFn} = "ModbusTCP_CC_Ready";
#  $hash->{SetFn}   = "ModbusTCP_CC_Set";
  $hash->{NotifyFn}= "ModbusTCP_CC_Notify";
#  $hash->{AttrFn}  = "ModbusTCP_CC_Attr";

# Normal devices
  $hash->{DefFn}   = "ModbusTCP_CC_Define";
  $hash->{UndefFn} = "ModbusTCP_CC_Undef";
  $hash->{AttrList}= "do_not_notify:1,0 dummy:1,0 " .
                     "maxClients " .
                     $readingFnAttributes;
}

sub ModbusTCP_CC_Define($$) {#########################################################
  my ($hash, $def) = @_;
  my @a = split("[ \t][ \t]*", $def);

  if(@a > 3) {
    my $msg = "wrong syntax: define <name> ModbusTCP_CC [port]";
    Log3 $hash, 2, $msg;
    return $msg;
  }

  my $name = $a[0];
  my $port = @a==2?502:$a[2];

  TcpServer_Close($hash); 
  
  $hash->{STATE} = "disconnected";
  $hash->{helper}{statistics}{pktIn}=0;
  $hash->{helper}{statistics}{pktOut}=0;
  $hash->{helper}{statistics}{bytesIn}=0;
  $hash->{helper}{statistics}{bytesOut}=0;
  $hash->{statistics} =$hash->{helper}{statistics}{pktIn} ." / " . $hash->{helper}{statistics}{pktOut} ." / " . $hash->{helper}{statistics}{bytesIn} ." / " . $hash->{helper}{statistics}{bytesOut};
  $hash->{helper}{state}='?';
  
  my $ret;

  $ret = TcpServer_Open($hash, $port, "global");

  if($ret) {
    Log3 $name, 1, "$ret.";
  } else {
    readingsSingleUpdate ( $hash, "state", "opened", 1 );  
  }
  return $ret;
}

sub ModbusTCP_CC_Undef($$) {##########################################################
  my ($hash, $arg) = @_;
  return TcpServer_Close($hash); 
}

sub ModbusTCP_CC_Notify(@) {##########################################################
  my ($hash,$dev) = @_;
  my $name = $hash->{NAME};

  if ($dev->{NAME} eq "global" && grep (m/^INITIALIZED$|^REREADCFG$/,@{$dev->{CHANGED}})){
  }
  if ($dev->{NAME} eq "global" && grep (m/comment/,@{$dev->{CHANGED}})){
    Log3 $hash,4,"ModbusTCP_CC_Notify($name) : comment changed, invalidating cache";
    delete $hash->{helper}{listsOK} if(defined($hash->{helper}{listsOK}));
  }
  return;
}

sub ModbusTCP_CC_Read($) {############################################################
# called from the global loop, when the select for hash->{FD} reports data
  my ($hash) = @_;
  my $name = $hash->{NAME};

  if( $hash->{SERVERSOCKET} ) {   # Accept and create a child
      my $chash=TcpServer_Accept( $hash, "ModbusTCP_CC" );
      $chash->{logDev}=$hash;
      return;
  }

  # Read 256 byte of data
  my $buf;
  my $ret = sysread($hash->{CD}, $buf, 256);

  # When there is an error in connection return
  if( !defined($ret ) || $ret <= 0 ) {
    CommandDelete( undef, $hash->{NAME} );
    return;
  }

  ModbusTCP_CC_UpdateStatistics($hash->{logDev},1,0,bytes::length($buf),0);
  ModbusTCP_CC_Parse($hash, $buf);
}

sub ModbusTCP_CC_Parse($$) {##########################################################
  my ($hash, $rmsg) = @_;
  my $name = $hash->{NAME};

  ModbusTCP_CC_LogFrame($hash->{logDev},"ModbusTCP_CC_Parse: received",$rmsg,5);

  my ($rx_hd_tr_id, $rx_hd_pr_id, $rx_hd_length, $rx_hd_unit_id, $rx_bd_fc, $f_body) = unpack "nnnCCa*", $rmsg;

  my $msg;
  # check header
  if ($rx_hd_length == bytes::length($rmsg)-6)
  {
    my @regs;
    my @coils;
  
    if((!defined($hash->{logDev}->{helper}{listsOK}))||($init_done==0)) {
      Log3 $hash->{logDev},4,"ModbusTCP_CC_Parse($name) : caching devspec2array";
      @regs=devspec2array("comment=.*MBR:.*");
      @coils=devspec2array("comment=.*MBC:.*");
      $hash->{logDev}->{helper}{regs}=join(',',@regs);
      $hash->{logDev}->{helper}{coils}=join(',',@coils);
      $hash->{logDev}->{helper}{listsOK}=1;
    } else {
      @regs=split ',',$hash->{logDev}->{helper}{regs};
      @coils=split ',',$hash->{logDev}->{helper}{coils};
    }
  
    if (($rx_bd_fc==READ_HOLDING_REGISTERS)||($rx_bd_fc==READ_INPUT_REGISTERS)) {
      my ($start,$num)=unpack "nn",$f_body;
      if (@regs>0) {
        my @v;
        my $found=0;
        my $skipnext=0;
        for (my $r=$start;$r<$start+$num;$r++) {
          if ($skipnext>0) {
            $skipnext--;
#            Log 0,"skipping $r";
            next;
          }
          $v[$r-$start]=0;
          foreach(@regs) {
            my $n=$_;
            my $c=AttrVal($n,"comment","");
            $c =~ m/MBR:(\S+)/;
            my @mb=split(':',$1);
            foreach(@mb) {
              my @mbd=split(',',$_);
              if (@mbd>2) {
                if (($mbd[0] eq $rx_hd_unit_id)||($mbd[0] eq '*')) {
                  if ($mbd[1] eq $r+1) {
                    if ((($mbd[2] eq 'H')&&($rx_bd_fc==READ_HOLDING_REGISTERS))||(($mbd[2] eq 'I')&&($rx_bd_fc==READ_INPUT_REGISTERS))||($mbd[2] eq '*')) {
                      my $rv;
                      my $rvx=0;
                      my $ext=0;
                      if(defined($mbd[3]) && ($mbd[3] ne "")) {
                        $rv=ReadingsVal($n,$mbd[3],0);
                      } else {
                        $rv=ReadingsVal($n,"state",0);
                      }
                      if (defined($mbd[4])) {
                        if($mbd[4] =~ /^B(\d+)$/) {
                          if(($1>=0) && ($1<16)) {
                            if(defined($mbd[6])) {
                              $rvx=1 if($rv eq $mbd[6]);
                            } else {
                              $rvx=1 if($rv eq 'on');
                            }
                            if ($rvx) {
                              $v[$r-$start]=$v[$r-$start] | (1<<$1);
                            } else {
                              $v[$r-$start]=$v[$r-$start] & ~(1<<$1);
                            }
                            $ext=1;
                            $found=1;
                          } else {
                            $ext=1;
                            Log3 $hash, 2, "invalid bit $1 in $n";
                          }
                        }
                        elsif($mbd[4] eq 'F') {
                          $rvx=unpack "L", pack "f", $rv;
                          # genug Platz ?
                          if($r<$start+$num-1) {
                            $v[$r-$start]=$rvx%65536;
                            $v[$r-$start+1]=$rvx>>16;
                            $skipnext=1;
                            $ext=1;
                            $found=1;
                          }
                        }
                        elsif($mbd[4] eq 'FB') {
                          $rvx=unpack "L", pack "f", $rv;
                          # genug Platz ?
                          if($r<$start+$num-1) {
                            $v[$r-$start]=$rvx>>16;
                            $v[$r-$start+1]=$rvx%65536;
                            $skipnext=1;
                            $ext=1;
                            $found=1;
                          }
                        }
                      }
                      if($ext==0) {
                        if(defined($mbd[3]) && ($mbd[3] ne "")) {
                          $v[$r-$start]=ReadingsVal($n,$mbd[3],0)+0;
                        } else {
                          $v[$r-$start]=ReadingsVal($n,"state",0)+0;
                        }
                        $found=1;
                        $v[$r-$start]*=$mbd[5] if(defined($mbd[5]));
                        $v[$r-$start]+=$mbd[6] if(defined($mbd[6]));
                        if (defined($mbd[4])) {
                          # Zweikomplement für negative Zahlen bilden
                          $v[$r-$start]+=65536 if(($v[$r-$start]<0) && ($mbd[4] eq 'T'));
                        }
                        $v[$r-$start]=0 if (($v[$r-$start]>65535)||($v[$r-$start]<0));
                      }
                    }
                  }
                }
              }
            }
          }
        }
        if ($found) {
          $msg = pack("nnnCCCn*", $rx_hd_tr_id, $rx_hd_pr_id, 3+@v*2, $rx_hd_unit_id, $rx_bd_fc, @v*2, @v);
        } else {
          $msg = pack("nnnCCC", $rx_hd_tr_id, $rx_hd_pr_id, 3, $rx_hd_unit_id, $rx_bd_fc+128, EXP_DATA_ADDRESS);
        }
      } else {
        $msg = pack("nnnCCC", $rx_hd_tr_id, $rx_hd_pr_id, 3, $rx_hd_unit_id, $rx_bd_fc+128, EXP_DATA_ADDRESS);
      }
    } elsif ($rx_bd_fc==WRITE_SINGLE_REGISTER) {
      my ($adr,$val)=unpack "nn",$f_body;
      my $oval=$val;
      if (@regs>0) {
        my @v;
        my $found=0;
        foreach(@regs) {
          my $n=$_;
          my $c=AttrVal($n,"comment","");
          $c =~ m/MBR:(\S+)/;
          my @mb=split(':',$1);
          foreach(@mb) {
            my @mbd=split(',',$_);
            if (@mbd>2) {
              if (($mbd[0] eq $rx_hd_unit_id)||($mbd[0] eq '*')) {
                if ($mbd[1] eq $adr+1) {
                  if (($mbd[2] eq 'H')||($mbd[2] eq '*')) {
                    my $ext=0;
                    my $sval=0;
                    my $set=0;
                    if (defined($mbd[4])) {
                      if($mbd[4] =~ /^B(\d+)$/) {
                        if(($1>=0) && ($1<16)) {
                          if(($val & (1<<$1))>0) {
                            $sval=defined($mbd[6])?$mbd[6]:'on';
                          } else {
                            $sval=defined($mbd[5])?$mbd[5]:'off';
                          }
                          $ext=1;
                          $set=1;
                          $found=1;
                        } else {
                          $ext=1;
                          Log3 $hash, 2, "invalid bit $1 in $n";
                        }
                      }
                      elsif($mbd[4] eq 'F') {
                        # ignorieren
                        $ext=1;
                      }
                      elsif($mbd[4] eq 'FB') {
                        # ignorieren
                        $ext=1;
                      } else {
                        $sval=$val;
                      }
                    } else {
                        $sval=$val;
                    }
                    if($ext==0) {
                      $sval-=65536 if(defined($mbd[4]) && ($val>32767) && ($mbd[4] eq 'T'));
                      $sval/=$mbd[5] if(defined($mbd[5]) && ($mbd[5]!=0));
                      $sval-=$mbd[6] if(defined($mbd[6]));
                      $set=1;
                      $found=1;
                    }

                    if($set==1) {
                      if(defined($mbd[3]) && ($mbd[3] ne "")) {
                        my $s=getAllSets($n);
                        if ($s=~$mbd[3]) {
                          fhem "set $n $mbd[3] $sval";
                        } else {
                          fhem "setreading $n $mbd[3] $sval";
                        }
                      } else {
                        fhem "set $n $sval";
                      }
                    }
                  }
                }
              }
            }
          }
        }
        if ($found) {
          $msg = pack("nnnCCnn", $rx_hd_tr_id, $rx_hd_pr_id, 6, $rx_hd_unit_id, $rx_bd_fc, $adr,$oval);
        } else {
          $msg = pack("nnnCCC", $rx_hd_tr_id, $rx_hd_pr_id, 3, $rx_hd_unit_id, $rx_bd_fc+128, EXP_DATA_ADDRESS);
        }
      } else {
        $msg = pack("nnnCCC", $rx_hd_tr_id, $rx_hd_pr_id, 3, $rx_hd_unit_id, $rx_bd_fc+128, EXP_DATA_ADDRESS);
      }
    } elsif ($rx_bd_fc==WRITE_MULTIPLE_REGISTERS) {
      my ($start,$num,$bytes,@data)=unpack "nnCn*",$f_body;
      if (($num>0) && ($num<128) && ($num*2==$bytes)) {
        if (@regs>0) {
          my @v;
          my $found=0;
          for (my $r=$start;$r<$start+$num;$r++) {
            my $val=$data[$r-$start];
            foreach(@regs) {
              my $n=$_;
              my $c=AttrVal($n,"comment","");
              $c =~ m/MBR:(\S+)/;
              my @mb=split(':',$1);
              foreach(@mb) {
                my @mbd=split(',',$_);
                if (@mbd>2) {
                  if (($mbd[0] eq $rx_hd_unit_id)||($mbd[0] eq '*')) {
                    if ($mbd[1] eq $r+1) {
                      if (($mbd[2] eq 'H')||($mbd[2] eq '*')) {
                        my $ext=0;
                        my $sval=0;
                        my $set=0;
                        if (defined($mbd[4])) {
                          if($mbd[4] =~ /^B(\d+)$/) {
                            if(($1>=0) && ($1<16)) {
                              if(($val & (1<<$1))>0) {
                                $sval=defined($mbd[6])?$mbd[6]:'on';
                              } else {
                                $sval=defined($mbd[5])?$mbd[5]:'off';
                              }
                              $ext=1;
                              $set=1;
                              $found=1;
                            } else {
                              $ext=1;
                              Log3 $hash, 2, "invalid bit $1 in $n";
                            }
                          }
                          elsif($mbd[4] eq 'F') {
                            # genug Daten ?
                            if($r<$start+$num-1) {
                              $sval=unpack "f", pack "L", ($data[$r-$start+1]<<16)+$val;
                              $set=1;
                              $found=1;
                            }
                            $ext=1;
                          }
                          elsif($mbd[4] eq 'FB') {
                            # genug Daten ?
                            if($r<$start+$num-1) {
                              $sval=unpack "f", pack "L", ($val<<16)+$data[$r-$start+1];
                              $set=1;
                              $found=1;
                            }
                            $ext=1;
                          } else {
                            $sval=$val;
                          }
                        } else {
                            $sval=$val;
                        }
                        if($ext==0) {
                          $sval-=65536 if(defined($mbd[4]) && ($val>32767) && ($mbd[4] eq 'T'));
                          $sval/=$mbd[5] if(defined($mbd[5]) && ($mbd[5]!=0));
                          $sval-=$mbd[6] if(defined($mbd[6]));
                          $set=1;
                          $found=1;
                        }

                        if($set==1) {
                          if(defined($mbd[3]) && ($mbd[3] ne "")) {
                            my $s=getAllSets($n);
                            if ($s=~$mbd[3]) {
                              fhem "set $n $mbd[3] $sval";
                            } else {
                              fhem "setreading $n $mbd[3] $sval";
                            }
                          } else {
                            fhem "set $n $sval";
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
          if ($found) {
            $msg = pack("nnnCCnn", $rx_hd_tr_id, $rx_hd_pr_id, 6, $rx_hd_unit_id, $rx_bd_fc, $start, $num);
          } else {
            $msg = pack("nnnCCC", $rx_hd_tr_id, $rx_hd_pr_id, 3, $rx_hd_unit_id, $rx_bd_fc+128, EXP_DATA_ADDRESS);
          }
        } else {
          $msg = pack("nnnCCC", $rx_hd_tr_id, $rx_hd_pr_id, 3, $rx_hd_unit_id, $rx_bd_fc+128, EXP_DATA_ADDRESS);
        }
      } else {
        $msg = pack("nnnCCC", $rx_hd_tr_id, $rx_hd_pr_id, 3, $rx_hd_unit_id, $rx_bd_fc+128, EXP_DATA_VALUE);
      }
    } elsif (($rx_bd_fc==READ_COILS)||($rx_bd_fc==READ_DISCRETE_INPUTS)) {
      my ($start,$num)=unpack "nn",$f_body;
      if (@coils>0) {
        my @v;
        my $found=0;
        my $vindex=-1;
        my $vpos=0;
        
        for (my $r=$start;$r<$start+$num;$r++) {
          if($vindex!=int(($r-$start)/8)) {
            $vindex=int(($r-$start)/8);
            $v[$vindex]=0;

          }
          $vpos=($r-$start)%8;

          foreach(@coils) {
            my $n=$_;
            my $c=AttrVal($n,"comment","");
            $c =~ m/MBC:(\S+)/;
            my @mb=split(':',$1);
            foreach(@mb) {
              my @mbd=split(',',$_);
              if (@mbd>2) {
                if (($mbd[0] eq $rx_hd_unit_id)||($mbd[0] eq '*')) {
                  if ($mbd[1] eq $r+1) {
                    if ((($mbd[2] eq 'C')&&($rx_bd_fc==READ_COILS))||(($mbd[2] eq 'I')&&($rx_bd_fc==READ_DISCRETE_INPUTS))||($mbd[2] eq '*')) {
                      my $rv;
                      my $rvx=0;
                      my $ext=0;
                      if(defined($mbd[3]) && ($mbd[3] ne "")) {
                        $rv=ReadingsVal($n,$mbd[3],0);
                      } else {
                        $rv=ReadingsVal($n,"state",0);
                      }
                      if(defined($mbd[5])) {
                        $rvx=1 if($rv eq $mbd[5]);
                      } else {
                        $rvx=1 if($rv eq 'on');
                      }
                      if ($rvx) {
                        $v[$vindex]=$v[$vindex] | (1<<$vpos);
                      } else {
                        $v[$vindex]=$v[$vindex] & ~(1<<$vpos);
                      }
                      $found=1;
                    }
                  }
                }
              }
            }
          }
        }
        if ($found) {
          $msg = pack("nnnCCCC*", $rx_hd_tr_id, $rx_hd_pr_id, 3+@v*1, $rx_hd_unit_id, $rx_bd_fc, @v*1, @v);
        } else {
          $msg = pack("nnnCCC", $rx_hd_tr_id, $rx_hd_pr_id, 3, $rx_hd_unit_id, $rx_bd_fc+128, EXP_DATA_ADDRESS);
        }
      } else {
        $msg = pack("nnnCCC", $rx_hd_tr_id, $rx_hd_pr_id, 3, $rx_hd_unit_id, $rx_bd_fc+128, EXP_DATA_ADDRESS);
      }
    } elsif ($rx_bd_fc==WRITE_SINGLE_COIL) {
      my ($adr,$val)=unpack "nn",$f_body;
      if(($val==0)||($val==0xff00)) {
        if (@coils>0) {
          my @v;
          my $found=0;
          foreach(@coils) {
            my $n=$_;
            my $c=AttrVal($n,"comment","");
            $c =~ m/MBC:(\S+)/;
            my @mb=split(':',$1);
            foreach(@mb) {
              my @mbd=split(',',$_);
              if (@mbd>2) {
                if (($mbd[0] eq $rx_hd_unit_id)||($mbd[0] eq '*')) {
                  if ($mbd[1] eq $adr+1) {
                    if (($mbd[2] eq 'C')||($mbd[2] eq '*')) {
                      my $sval=0;
                      if($val==0) {
                        $sval=defined($mbd[4])?$mbd[4]:'off';
                      } else {
                        $sval=defined($mbd[5])?$mbd[5]:'on';
                      }
                      if(defined($mbd[3]) && ($mbd[3] ne "")) {
                        my $s=getAllSets($n);
                        if ($s=~$mbd[3]) {
                          fhem "set $n $mbd[3] $sval";
                        } else {
                          fhem "setreading $n $mbd[3] $sval";
                        }
                      } else {
                        fhem "set $n $sval";
                      }
                      $found=1;
                    }
                  }
                }
              }
            }
          }
          if ($found) {
            $msg = pack("nnnCCnn", $rx_hd_tr_id, $rx_hd_pr_id, 6, $rx_hd_unit_id, $rx_bd_fc, $adr,$val);
          } else {
            $msg = pack("nnnCCC", $rx_hd_tr_id, $rx_hd_pr_id, 3, $rx_hd_unit_id, $rx_bd_fc+128, EXP_DATA_ADDRESS);
          }
        } else {
          $msg = pack("nnnCCC", $rx_hd_tr_id, $rx_hd_pr_id, 3, $rx_hd_unit_id, $rx_bd_fc+128, EXP_DATA_ADDRESS);
        }
      } else {
        $msg = pack("nnnCCC", $rx_hd_tr_id, $rx_hd_pr_id, 3, $rx_hd_unit_id, $rx_bd_fc+128, EXP_DATA_VALUE);
      }
    } elsif ($rx_bd_fc==WRITE_MULTIPLE_COILS) {
      my ($start,$num,$bytes,@data)=unpack "nnCC*",$f_body;
      if (($num>0) && ($num<=2048) && (ceil($num/8)==$bytes)) {
        if (@coils>0) {
          my @v;
          my $found=0;
          for (my $r=$start;$r<$start+$num;$r++) {
            my $vindex=int(($r-$start)/8);
            my $vpos=($r-$start)%8;
            my $val=(($data[$vindex])>>$vpos) & 1;
            foreach(@coils) {
              my $n=$_;
              my $c=AttrVal($n,"comment","");
              $c =~ m/MBC:(\S+)/;
              my @mb=split(':',$1);
              foreach(@mb) {
                my @mbd=split(',',$_);
                if (@mbd>2) {
                  if (($mbd[0] eq $rx_hd_unit_id)||($mbd[0] eq '*')) {
                    if ($mbd[1] eq $r+1) {
                      if (($mbd[2] eq 'C')||($mbd[2] eq '*')) {
                        my $sval=0;
                        if($val==0) {
                          $sval=defined($mbd[4])?$mbd[4]:'off';
                        } else {
                          $sval=defined($mbd[5])?$mbd[5]:'on';
                        }
                        if(defined($mbd[3]) && ($mbd[3] ne "")) {
                          my $s=getAllSets($n);
                          if ($s=~$mbd[3]) {
                            fhem "set $n $mbd[3] $sval";
                          } else {
                            fhem "setreading $n $mbd[3] $sval";
                          }
                        } else {
                          fhem "set $n $sval";
                        }
                        $found=1;
                      }
                    }
                  }
                }
              }
            }
          }
          if ($found) {
            $msg = pack("nnnCCnn", $rx_hd_tr_id, $rx_hd_pr_id, 6, $rx_hd_unit_id, $rx_bd_fc, $start, $num);
          } else {
            $msg = pack("nnnCCC", $rx_hd_tr_id, $rx_hd_pr_id, 3, $rx_hd_unit_id, $rx_bd_fc+128, EXP_DATA_ADDRESS);
          }
        } else {
          $msg = pack("nnnCCC", $rx_hd_tr_id, $rx_hd_pr_id, 3, $rx_hd_unit_id, $rx_bd_fc+128, EXP_DATA_ADDRESS);
        }
      } else {
        $msg = pack("nnnCCC", $rx_hd_tr_id, $rx_hd_pr_id, 3, $rx_hd_unit_id, $rx_bd_fc+128, EXP_DATA_VALUE);
      }
    } else {
      $msg = pack("nnnCCC", $rx_hd_tr_id, $rx_hd_pr_id, 3, $rx_hd_unit_id, $rx_bd_fc+128, EXP_ILLEGAL_FUNCTION);
    }
    ModbusTCP_CC_LogFrame($hash->{logDev},"ModbusTCP_CC_Parse: sending",$msg,5);
    ModbusTCP_CC_UpdateStatistics($hash->{logDev},0,1,0,bytes::length($msg));
    syswrite($hash->{CD}, $msg );  
  }
}

sub ModbusTCP_CC_LogFrame($$$$) {
  my ($hash,$c,$data,$verbose)=@_;

  my @dump = map {sprintf "%02X", $_ } unpack("C*", $data);
  $dump[0] = "[".$dump[0];
  $dump[5] = $dump[5]."]";

  $hash->{helper}{lastFrame}=$c." ".join(" ",@dump) if($c eq 'SimpleWrite');

  Log3 $hash, $verbose,$c." ".join(" ",@dump);
}

sub ModbusTCP_CC_UpdateStatistics($$$$$) {############################################################
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
=item device 
=item summary    access FHEM from a SCADA system using ModbusTCP
=item summary_DE Anbindung von FHEM an ein PLS über ModbusTCP 
=begin html

<a name="ModbusTCP_CC"></a>
<h3>ModbusTCP_CC</h3>
<ul>
  This module implements a connector for ModbusTCP clients ('masters'). It can be used to access FHEM from a SCADA system.<br>
  Currently FC 1, 2, 3, 4, 6, 15 and 16 are supported.
  <br><br>
  <a name="ModbusTCP_CCdefine"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; ModbusTCP_CC &lt;[port]&gt;</code> <br>
    <br>
    If no port is specified 502 will be used. Port 502 requires root/administrator rights.<br/>
  </ul>
  <br>
  <a name="ModbusTCP_CCset"></a>
  <b>Set</b> <ul>N/A</ul><br>
  <a name="ModbusTCP_CCget"></a>
  <b>Get</b> <ul>N/A</ul><br>
  <a name="ModbusTCP_CCattr"></a>
  <b>Attributes</b>
  <ul>
    <li><a href="#attrdummy">dummy</a></li><br>
  </ul>
  <b>Usage</b><br>
  The Modbus coil/register number is configured through the comment field of the devices.<br><br>
  Format for registers: MBR:&lt;unitId&gt;,&lt;register&gt;,&lt;register type&gt;[,&lt;reading&gt;
  [,&lt;format&gt;[,&lt;multiplier&gt;[,&lt;offset&gt;]]]]<br> with
  <ul>
  <li>&lt;unitId&gt; - the unit id (0 - 255), * for any id</li>
  <li>&lt;register&gt; - the register number (1 - 65536) (not address !)</li>
  <li>&lt;register type&gt; - I for input register, H for holding register or * for any type</li>
  <li>&lt;reading&gt; - optional, name of the reading, if none is specified, state is used</li>
  <li>&lt;format&gt; - optional, T for two's complement, F for IEEE754 single precision, little endian, FB for IEEE754 single precision, big endian</li>
  <li>&lt;multiplier&gt; - optional, multiplier applied to the reading on reads, used as divisor on writes</li>
  <li>&lt;offset&gt; - optional, offset added to the reading on reads, subtracted on writes</li>
  </ul>
  <br>Example for a Homematic room thermostat (HM-CC-TC) called th:<br><br>
  <code>attr th comment MBR:1,1,I,measured-temp,N,10:1,2,I,humidity:1,21,H,desired-temp,N,10</code><br><br>
  The reading <code>measured-temp</code> is mapped to input register 1 on unit 1, <code>humidity</code>
  is mapped on input register 2 on unit 1 and <code>desired-temp</code> is mapped on holding register
  21 on unit 1. <code>measured-temp</code> and <code>desired-temp</code> are multiplied by 10 and negative
  values are represented in two's complement.
  <br><br>
  Format for coils: MBC:&lt;unitId&gt;,&lt;coil&gt;,&lt;type&gt;[,&lt;reading&gt;
  [,&lt;off&gt;[,&lt;on&gt;]]]<br> with
  <ul>
  <li>&lt;unitId&gt; - the unit id (0 - 255), * for any id</li>
  <li>&lt;coil&gt; - the coil number (1 - 65536) (not address !)</li>
  <li>&lt;type&gt; - I for input (read only), C for coil (read/write) or * for any type</li>
  <li>&lt;reading&gt; - optional, name of the reading, if none is specified, state is used</li>
  <li>&lt;off&gt; - optional, alternative value for the off-state</li>
  <li>&lt;on&gt; - optional, alternative value for the on-state</li>
  </ul>
  <br>Example for a Homematic switch (HM-ES-PMSw1-Pl) called sw:<br><br>
  <code>attr sw comment MBC:1,12,C</code><br><br>
  The switch state is mapped to coil 12 on unit 1.
  <br><br>
  Format for mapping coils to registers: MBR:&lt;unitId&gt;,&lt;coil&gt;,&lt;type&gt;[,&lt;reading&gt;
  [,B&lt;bit&gt;[,&lt;off&gt;[,&lt;on&gt;]]]<br> with
  <ul>
  <li>&lt;unitId&gt; - the unit id (0 - 255), * for any id</li>
  <li>&lt;coil&gt; - the coil number (1 - 65536) (not address !)</li>
  <li>&lt;type&gt; - I for input (read only), C for coil (read/write) or * for any type</li>
  <li>&lt;reading&gt; - optional, name of the reading, if none is specified, state is used</li>
  <li>B&lt;bit&gt; - optional, map value to specified bit (range 0-15)</li>
  <li>&lt;off&gt; - optional, alternative value for the off-state</li>
  <li>&lt;on&gt; - optional, alternative value for the on-state</li>
  </ul>
  <br>Example for a Homematic switch (HM-ES-PMSw1-Pl) called sw:<br><br>
  <code>attr sw comment MBR:1,6,H,,B4</code><br><br>
  The switch state is mapped to bit 4 of register 6 on unit 1.
</ul>

=end html
=cut
