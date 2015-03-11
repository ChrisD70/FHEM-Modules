# $Id: 37_ModbusRegister.pm 0014 $
# 140318 0001 initial release
# 140504 0002 added attributes registerType and disableRegisterMapping
# 140505 0003 added fc to defptr, added RAW reading
# 140506 0004 added _BE plcDataTypes, use readingsBulkUpdate, fixed RAW
# 140507 0005 fixed {helper}{nread} in ModbusRegister_Define
# 140507 0006 delete $hash->{helper}{addr} in modules list on redefine (modify)
# 150106 0007 added 3WORD and 3WORD_BE 
# 150107 0008 added QWORD and QWORD_BE 
# 150118 0009 completed documentation
# 150215 0010 fixed bug with registerType and disableRegisterMapping (thanks Dieter1)
# 150221 0011 fixed typo in attribute name updateIntervall
# 150222 0012 added alignUpdateInterval
# 150226 0013 force timestamp if alignUpdateInterval is used
# 150304 0014 fixed lastUpdate and WRITE_SINGLE_REGISTER
# TODO:

package main;

use strict;
use warnings;
use SetExtensions;

sub ModbusRegister_Parse($$);
sub ModbusRegister_SetMinMax($);

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

sub
ModbusRegister_Initialize($)
{
  my ($hash) = @_;

  $hash->{Match}     = "^ModbusRegister";
  $hash->{DefFn}     = "ModbusRegister_Define";
  $hash->{UndefFn}   = "ModbusRegister_Undef";
  $hash->{SetFn}     = "ModbusRegister_Set"; 
  $hash->{NotifyFn}  = "ModbusRegister_Notify";
  #$hash->{FingerprintFn}   = "ModbusRegister_Fingerprint";
  $hash->{ParseFn}   = "ModbusRegister_Parse";
  $hash->{AttrFn}    = "ModbusRegister_Attr";
  $hash->{AttrList}  = "IODev ".
                       "plcDataType:WORD,INT,DWORD,DWORD_BE,DINT,DINT_BE,REAL,REAL_BE,3WORD,3WORD_BE,QWORD,QWORD_BE ".
                       "conversion ".
                       "updateInterval updateIntervall alignUpdateInterval ".
                       "disableRegisterMapping:0,1 ".
                       "registerType:Holding,Input ".
                       "stateAlias ".
                       "$readingFnAttributes";
}

sub
ModbusRegister_Define($$)
{
  my ($hash, $def) = @_;
  my @a = split("[ \t][ \t]*", $def);

  if((@a != 3 )&&(@a != 4)) {
    my $msg = "wrong syntax: define <name> ModbusRegister [<unitId>] <addr>";
    Log3 undef, 2, $msg;
    return $msg;
  }

  if(!defined($a[3])) {
    $a[3]=$a[2];
    $a[2]=0;
  }
  
  return "$a[2] $a[3] is not a valid Modbus register" if(($a[2]<0)||($a[2]>255)||($a[3]<0)||($a[3]>65535));

  my $name = $a[0];

  if(defined($attr{$name}{IODev})) {
    $hash->{IODev}->{NAME}=$attr{$name}{IODev};
  } else {
    AssignIoPort($hash);
  }
  if(defined($hash->{IODev}->{NAME})) {
    Log3 $name, 3, "$name: I/O device is " . $hash->{IODev}->{NAME};
  } else {
    Log3 $name, 1, "$name: no I/O device";
  }

  $hash->{helper}{unitId}=$a[2];
  $hash->{helper}{register}=$a[3];
  $hash->{helper}{nread}=1;
  if(!defined($attr{$name}{disableRegisterMapping})) {
    $hash->{helper}{disableRegisterMapping}=0;
  }
  if ($hash->{helper}{disableRegisterMapping}==0) {
    if(($hash->{helper}{register}>30000)&&($hash->{helper}{register}<40000)) {
      $hash->{helper}{registerType}=4;
      $hash->{helper}{address}=$hash->{helper}{register}-30001;
    } else {
      $hash->{helper}{registerType}=3;
      if(($hash->{helper}{register}>40000)&&($hash->{helper}{register}<50000)) {
        $hash->{helper}{address}=$hash->{helper}{register}-40001;
      } else {
        $hash->{helper}{address}=$hash->{helper}{register};
      }
    }
  } else {
    $hash->{helper}{registerType}=AttrVal($name,"registerType",3);
    $hash->{helper}{address}=$hash->{helper}{register};
  }

  if(defined($hash->{helper}{addr})&&defined($modules{ModbusRegister}{defptr}{$hash->{helper}{addr}}{$name})) {
    Log3 $name, 5, "Removing $hash->{helper}{addr} $name";
    delete( $modules{ModbusRegister}{defptr}{$hash->{helper}{addr}}{$name} );
  }

  $hash->{helper}{addr} = "$hash->{helper}{registerType} $hash->{helper}{unitId} $hash->{helper}{address}";
  Log3 $name, 5, "Def $hash->{helper}{addr} $name";
  #Log 0, "Def $hash->{helper}{addr} $name"; # CD 0007
  $modules{ModbusRegister}{defptr}{$hash->{helper}{addr}}{$name} = $hash;

  if(defined($attr{$name}{plcDataType})) {
    if(($attr{$name}{plcDataType}=~/^DWORD/) || ($attr{$name}{plcDataType}=~/^DINT/) || ($attr{$name}{plcDataType}=~/^REAL/)) {
      $hash->{helper}{nread}=2;
    }
    # CD 0007 start
    if($attr{$name}{plcDataType}=~/^3WORD/) {
      $hash->{helper}{nread}=3;
    }
    # CD 0007 end
    # CD 0008 start
    if($attr{$name}{plcDataType}=~/^QWORD/) {
      $hash->{helper}{nread}=4;
    }
    # CD 0008 end
  }
  $hash->{helper}{readCmd}=pack("CCnn", $hash->{helper}{unitId}, $hash->{helper}{registerType}, $hash->{helper}{address}, $hash->{helper}{nread});
  $hash->{helper}{updateIntervall}=0.1 if (!defined($hash->{helper}{updateIntervall}));
  $hash->{helper}{nextUpdate}=time();
  
  ModbusRegister_SetMinMax($hash);
  return undef;
}

#####################################
sub
ModbusRegister_Undef($$)
{
  my ($hash, $arg) = @_;
  my $name = $hash->{NAME};
  my $addr = $hash->{helper}{addr};

  Log3 $name, 5, "Undef $addr $name";
  delete( $modules{ModbusRegister}{defptr}{$addr}{$name} );

  return undef;
}

#####################################
sub
ModbusRegister_Set($@)
{
  my ($hash, @a) = @_; 
  my $ret = undef;
  my $na = int(@a); 
  
  return "no set value specified" if($na==0);

  if($a[1] eq '?')
  {
#    my $list = "value:slider,$hash->{helper}{cnv}{min},$hash->{helper}{cnv}{step},$hash->{helper}{cnv}{max}"; 
    my $list = " "; 
    return SetExtensions($hash, $list, @a); 
  }

  if(($na==2) && ModbusRegister_is_float($a[1])) {
    $a[2]=$a[1];
    $a[1]="value";
    $na=3;
  }
  return "no set value specified" if($na<3);
  #Log 0,"$a[1] $a[2] $na";
  return "invalid value for set" if(($na>3)||!ModbusRegister_is_float($a[2])||($a[2]<$hash->{helper}{cnv}{min})||($a[2]>$hash->{helper}{cnv}{max}));

  return "writing to input registers not allowed" if ($hash->{helper}{registerType}==4);
  
  if($a[1] eq "value") {
    my $v=$a[2];
    my $wlen=1;
    my $msg;
    my $plcDataType=AttrVal($hash->{NAME},"plcDataType","WORD");
    
    if(defined($hash->{helper}{cnv})) {
      if($hash->{helper}{cnv}{a}==0) {
        $v=-$hash->{helper}{cnv}{b};
      } else {
        $v=$v/$hash->{helper}{cnv}{a}-$hash->{helper}{cnv}{b};
      }
      if($plcDataType eq "INT") {
        $v+= 65536 if $v<0;
      }
      if($plcDataType=~ /^DWORD/) {
        $wlen=2;
      }
      if($plcDataType=~ /^3WORD/) {
        $wlen=3;
      }
      if($plcDataType=~ /^QWORD/) {
        $wlen=4;
      }
      if($plcDataType=~ /^DINT/){
        $v+= 4294967296 if $v<0;
        $wlen=2;
      }
      if($plcDataType=~ /^REAL/){
        $v=unpack "L", pack "f", $v;
        $wlen=2;
      }
    }
    if($wlen==2) {
      if($plcDataType=~ /_BE$/) {
        $msg=pack("CCnnCnn", $hash->{helper}{unitId}, 16, $hash->{helper}{address}, 2, 4, $v>>16, $v%65536);
      } else {
        $msg=pack("CCnnCnn", $hash->{helper}{unitId}, 16, $hash->{helper}{address}, 2, 4, $v%65536, $v>>16);
      }
    # CD 0008 start
    } elsif($wlen==3) {
      if($plcDataType=~ /_BE$/) {
      $msg=pack("CCnnCnnn", $hash->{helper}{unitId}, 16, $hash->{helper}{address}, 3, 6, ($v/4294967296.0)%65536, ($v/65536.0)%65536, $v%65536);
      } else {
        $msg=pack("CCnnCnnn", $hash->{helper}{unitId}, 16, $hash->{helper}{address}, 3, 6, $v%65536, ($v/65536.0)%65536, ($v/4294967296.0)%65536);
      }
    } elsif($wlen==4) {
      if($plcDataType=~ /_BE$/) {
        $msg=pack("CCnnCnnnn", $hash->{helper}{unitId}, 16, $hash->{helper}{address}, 4, 8, $v/281474976710656.0, ($v/4294967296.0)%65536, ($v/65536.0)%65536, $v%65536);
      } else {
        $msg=pack("CCnnCnnnn", $hash->{helper}{unitId}, 16, $hash->{helper}{address}, 4, 8, $v%65536, ($v/65536.0)%65536, ($v/4294967296.0)%65536, $v/281474976710656.0);
      }
    # CD 0008 end
    } else {
      $msg=pack("CCnn", $hash->{helper}{unitId}, 6, $hash->{helper}{address}, $v);
    }
  
    IOWrite($hash,$msg);
  }
  return undef;
}
  
#####################################
sub
ModbusRegister_Get($@)
{
  my ($hash, $name, $cmd, @args) = @_;

  return "\"get $name\" needs at least one parameter" if(@_ < 3);

  my $list = "";

  return "Unknown argument $cmd, choose one of $list";
}

sub
ModbusRegister_Fingerprint($$)
{
  my ($name, $msg) = @_;
  return ( "", $msg );
}

sub
ModbusRegister_Parse($$)
{
  my ($hash, $msg) = @_;
  my $name = $hash->{NAME};

  my (undef,$unitid,$addr,$fc,$nvals,@vals) = split(":",$msg);

  Log3 $name, 5,"ModbusRegister_Parse: $fc $unitid $addr";

  my @list;
  my $raddr;
  if($fc==WRITE_SINGLE_REGISTER) {
    $raddr = "3 $unitid $addr";
  } else {
    $raddr = "$fc $unitid $addr";
  }
  my $rhash = $modules{ModbusRegister}{defptr}{$raddr};
  if($rhash) {
    foreach my $n (keys %{$rhash}) {
      my $lh = $rhash->{$n};
      if((defined($lh->{IODev})) && ($lh->{IODev} == $hash)) {
        $n = $lh->{NAME};
        next if($nvals!=$lh->{helper}{nread});
        next if(defined($lh->{helper}{lastUpdate}) && ($lh->{helper}{lastUpdate}==0) && ($fc!=WRITE_SINGLE_REGISTER));
        next if(!defined($lh->{helper}{lastUpdate}) && defined($lh->{helper}{alignUpdateInterval}) && ($fc!=WRITE_SINGLE_REGISTER));
        
        $lh->{ModbusRegister_lastRcv} = TimeNow();
        my $v=$vals[0];
        my $plcDataType=AttrVal($n,"plcDataType","x");
        if($plcDataType eq "INT") {
          $v-= 65536 if $v>32767;
        }
        if($plcDataType eq "DWORD"){
          $v=($vals[1]<<16)+$vals[0];
        }
        if($plcDataType eq "DWORD_BE"){
          $v=($vals[0]<<16)+$vals[1];
        }
        # CD 0007 start
        if($plcDataType eq "3WORD"){
          $v=(4294967296.0*$vals[2])+($vals[1]<<16)+$vals[0];
        }
        if($plcDataType eq "3WORD_BE"){
          $v=(4294967296.0*$vals[0])+($vals[1]<<16)+$vals[2];
        }
        # CD 0007 end
        # CD 0008 start
        if($plcDataType eq "QWORD"){
          $v=(281474976710656.0*$vals[3])+(4294967296.0*$vals[2])+($vals[1]<<16)+$vals[0];
        }
        if($plcDataType eq "QWORD_BE"){
          $v=(281474976710656.0*$vals[0])+(4294967296.0*$vals[1])+($vals[2]<<16)+$vals[3];
        }
        # CD 0008 end
        if($plcDataType eq "DINT"){
          $v=($vals[1]<<16)+$vals[0];
          $v-= 4294967296 if $v>2147483647;
        }
        if($plcDataType eq "DINT_BE"){
          $v=($vals[0]<<16)+$vals[1];
          $v-= 4294967296 if $v>2147483647;
        }
        if($plcDataType eq "REAL"){
          $v=unpack "f", pack "L", ($vals[1]<<16)+$vals[0];
        }
        if($plcDataType eq "REAL_BE"){
          $v=unpack "f", pack "L", ($vals[0]<<16)+$vals[1];
        }
        if(defined($lh->{helper}{cnv})) {
          $v=$v*$lh->{helper}{cnv}{a}+$lh->{helper}{cnv}{b};
        }
        readingsBeginUpdate($lh);
        if(defined($lh->{helper}{alignUpdateInterval}) && defined($lh->{helper}{lastUpdate}) && ($fc!=WRITE_SINGLE_REGISTER)) {
            my $fmtDateTime = FmtDateTime($lh->{helper}{lastUpdate});
            $lh->{".updateTime"} = $lh->{helper}{lastUpdate}; # in seconds since the epoch
            $lh->{".updateTimestamp"} = $fmtDateTime;
        }
        readingsBulkUpdate($lh,"state",$v);
        readingsBulkUpdate($lh,"RAW",unpack "H*",pack "n*", @vals); #sprintf("%08x",pack "n*", @vals));
        readingsBulkUpdate($lh,AttrVal($n,"stateAlias",undef),$v) if(defined(AttrVal($n,"stateAlias",undef)));  # CD 0007
        readingsEndUpdate($lh,1);
        $lh->{helper}{lastUpdate}=0 if ($fc!=WRITE_SINGLE_REGISTER);
        push(@list, $n); 
      }
    }
  } else {
   Log3 $name, 2, "ModbusRegister_Parse: invalid address $raddr";
   #return "UNDEFINED ModbusRegister_$rname ModbusRegister $raddr";
   return undef;
  }
  return @list;
}

sub
ModbusRegister_Attr(@)
{
  my ($cmd, $name, $attrName, $attrVal) = @_;
  my $hash=$defs{$name};

  if($attrName eq "plcDataType") {
    $hash->{helper}{nread}=1;
    if ($cmd eq "set") {
      $attr{$name}{plcDataType} = $attrVal;
      if(($attrVal eq "DWORD") || ($attrVal eq "DINT") || ($attrVal eq "REAL") || ($attrVal eq "DWORD_BE") || ($attrVal eq "DINT_BE") || ($attrVal eq "REAL_BE")) {
        $hash->{helper}{nread}=2;
      }
      # CD 0007 start
      if(($attrVal eq "3WORD") || ($attrVal eq "3WORD_BE")) {
        $hash->{helper}{nread}=3;
      }
      # CD 0007 end
      # CD 0008 start
      if(($attrVal eq "QWORD") || ($attrVal eq "QWORD_BE")) {
        $hash->{helper}{nread}=4;
      }
      # CD 0008 end
      ModbusRegister_SetMinMax($hash);
    }
    $hash->{helper}{readCmd}=pack("CCnn", $hash->{helper}{unitId}, $hash->{helper}{registerType}, $hash->{helper}{address}, $hash->{helper}{nread});
  }
  elsif($attrName eq "conversion") {
    if ($cmd eq "set") {
      my @a=split(":",$attrVal);
      if(@a == 2) {
        $attr{$name}{conversion} = $attrVal;
        $hash->{helper}{cnv}{a}=$a[0];
        $hash->{helper}{cnv}{b}=$a[1];
        ModbusRegister_SetMinMax($hash);
      } else {
        return "wrong syntax: conversion a:b";
      }
    } else {
      $hash->{helper}{cnv}{a}=1;
      $hash->{helper}{cnv}{b}=0;
      ModbusRegister_SetMinMax($hash);
    }
  }
  elsif(($attrName eq "updateIntervall")||($attrName eq "updateInterval")) {
    if ($cmd eq "set") {
      if($attrVal =~ m/:/) {
        my ($err, $hr, $min, $sec, $fn) = GetTimeSpec($attrVal);
        return $err if($err);
        $hash->{helper}{updateIntervall}=($hr*60+$min)*60+$sec;
      } else {
        $hash->{helper}{updateIntervall}=$attrVal;
      }
      $attr{$name}{updateInterval} = $attrVal;
    } else {
      $hash->{helper}{updateIntervall}=0.1;
      delete $attr{$name}{updateInterval} if defined($attr{$name}{updateInterval});
      delete $attr{$name}{updateIntervall} if defined($attr{$name}{updateIntervall});
    }
    ModbusRegister_CalcNextUpdate($hash);
  }
  elsif($attrName eq "alignUpdateInterval") {
    if (($cmd eq "set") && defined($attrVal)) {
        my @args=split(",",$attrVal);
        if(@args>0) {
            my ($err, $hr, $min, $sec, $fn) = GetTimeSpec($args[0]);
            return $err if($err);
            $hash->{helper}{alignUpdateInterval}=($hr*60+$min)*60+$sec;
        }
    } else {
        delete($hash->{helper}{alignUpdateInterval}) if (defined($hash->{helper}{alignUpdateInterval}));
    }
    ModbusRegister_CalcNextUpdate($hash);
  }
  elsif($attrName eq "registerType") {
    if ($cmd eq "set") {
      $attr{$name}{registerType} = $attrVal;
      if($hash->{helper}{disableRegisterMapping}==1) {
        if($attrVal eq 'Input') {
          $hash->{helper}{registerType}=4;
        } else {
          $hash->{helper}{registerType}=3;
        }
      }
    } else {
      $hash->{helper}{registerType}=3 if($hash->{helper}{disableRegisterMapping}==1);
    }
    $hash->{helper}{readCmd}=pack("CCnn", $hash->{helper}{unitId}, $hash->{helper}{registerType}, $hash->{helper}{address}, $hash->{helper}{nread});
    delete( $modules{ModbusRegister}{defptr}{$hash->{helper}{addr}}{$name} );
    $hash->{helper}{addr} = "$hash->{helper}{registerType} $hash->{helper}{unitId} $hash->{helper}{address}";
    $modules{ModbusRegister}{defptr}{$hash->{helper}{addr}}{$name} = $hash;
  }
  elsif($attrName eq "disableRegisterMapping") {
    if ($cmd eq "set") {
      $attr{$name}{disableRegisterMapping} = $attrVal;
      if($attrVal==1) {
        $hash->{helper}{disableRegisterMapping}=1;
      } else {
        $hash->{helper}{disableRegisterMapping}=0;
      }
    } else {
      $hash->{helper}{disableRegisterMapping}=0;
    }
    if ($hash->{helper}{disableRegisterMapping}==0) {
      if(($hash->{helper}{register}>30000)&&($hash->{helper}{register}<40000)) {
        $hash->{helper}{registerType}=4;
        $hash->{helper}{address}=$hash->{helper}{register}-30001;
      } else {
        $hash->{helper}{registerType}=3;
        if(($hash->{helper}{register}>40000)&&($hash->{helper}{register}<50000)) {
          $hash->{helper}{address}=$hash->{helper}{register}-40001;
        } else {
          $hash->{helper}{address}=$hash->{helper}{register};
        }
      }
    } else {
      if(AttrVal($name,"registerType",'Holding') eq 'Input') {
        $hash->{helper}{registerType}=4;
      } else {
        $hash->{helper}{registerType}=3;
      }
      $hash->{helper}{address}=$hash->{helper}{register};
    }
    $hash->{helper}{readCmd}=pack("CCnn", $hash->{helper}{unitId}, $hash->{helper}{registerType}, $hash->{helper}{address}, $hash->{helper}{nread});
    delete( $modules{ModbusRegister}{defptr}{$hash->{helper}{addr}}{$name} );
    $hash->{helper}{addr} = "$hash->{helper}{registerType} $hash->{helper}{unitId} $hash->{helper}{address}";
    $modules{ModbusRegister}{defptr}{$hash->{helper}{addr}}{$name} = $hash;
  }
  return undef;
}

sub ModbusRegister_CalcNextUpdate(@) {##########################################################
    my ($hash)=@_;
    my $name = $hash->{NAME};

    delete($hash->{helper}{lastUpdate}) if(defined($hash->{helper}{lastUpdate}));
    if(defined($hash->{helper}{alignUpdateInterval})) {
        my $t=int(time());
        my @lt = localtime($t);
        
        $t -= ($lt[2]*3600+$lt[1]*60+$lt[0]);
        my $nextUpdate=$t+$hash->{helper}{alignUpdateInterval};
        while($nextUpdate<time()) {
            $nextUpdate+=$hash->{helper}{updateIntervall};
        }
        $hash->{nextUpdate}=localtime($nextUpdate);
        $hash->{helper}{nextUpdate}=$nextUpdate;
    } else {
        $hash->{helper}{nextUpdate}=time()+$hash->{helper}{updateIntervall};
    }
}

sub ModbusRegister_Notify(@) {##########################################################
  my ($hash,$dev) = @_;
  if ($dev->{NAME} eq "global" && grep (m/^INITIALIZED$|^REREADCFG$/,@{$dev->{CHANGED}})){
    my $name = $hash->{NAME};

    if (defined($attr{$name}{updateIntervall})) {
      $attr{$name}{updateInterval}=$attr{$name}{updateIntervall} if(!defined($attr{$name}{updateInterval}));
      delete $attr{$name}{updateIntervall};
    }
    $modules{$hash->{TYPE}}{AttrList} =~ s/updateIntervall.//;
  }
  return;
}

sub
ModbusRegister_SetMinMax($)
{
  my ($hash)=@_;
  
  $hash->{helper}{cnv}{a}=1 if(!defined($hash->{helper}{cnv}{a}));
  $hash->{helper}{cnv}{b}=0 if(!defined($hash->{helper}{cnv}{b}));
  $hash->{helper}{nread}=1 if(!defined($hash->{helper}{nread}));
  $hash->{helper}{cnv}{step}=100 if(!defined($hash->{helper}{cnv}{step}));
  
  my $vmin=0.0;
  my $vmax=65535.0;
  
  my $plcDataType=AttrVal($hash->{NAME},"plcDataType","WORD");
  if($plcDataType eq "WORD") {
    $vmin=0;
    $vmax=65535;
  }
  if($plcDataType eq "INT") {
    $vmin=-32768;
    $vmax=32767;
  }
  if($plcDataType=~ /^DWORD/) {
    $vmin=0;
    $vmax=0xffffffff;
  }
  # CD 0007 start
  if($plcDataType=~ /^3WORD/) {
    $vmin=0;
    $vmax=2**48-1;
  }
  # CD 0007 end
  # CD 0008 start
  if($plcDataType=~ /^QWORD/) {
    $vmin=0;
    $vmax=2**64-1;
  }
  # CD 0008 end
  if($plcDataType=~ /^DINT/) {
    $vmin=-2**31;
    $vmax=2**31-1;
  }
  if($plcDataType=~ /^REAL/) {
    $vmin=-3.403*10**38;
    $vmax=3.403*10**38;
  }
  $vmin=$vmin*$hash->{helper}{cnv}{a}+$hash->{helper}{cnv}{b};
  $vmax=$vmax*$hash->{helper}{cnv}{a}+$hash->{helper}{cnv}{b};
  
  $hash->{helper}{cnv}{min}=$vmin;
  $hash->{helper}{cnv}{max}=$vmax;
  if($vmax-$vmin == 0) {
    $hash->{helper}{cnv}{step}=1;
  } else {
    $hash->{helper}{cnv}{step}=10**(int(log($vmax-$vmin)/log(10))-2);
    $hash->{helper}{cnv}{step}=1 if($hash->{helper}{cnv}{step}==0);
  }
}

sub ModbusRegister_is_integer { # CD 0007 renamed
   defined $_[0] && $_[0] =~ /^[+-]?\d+$/;
}

sub ModbusRegister_is_float {   # CD 0007 renamed
   defined $_[0] && $_[0] =~ /^[+-]?\d+(\.\d+)?$/;
}

1;

=pod
=begin html

<a name="ModbusRegister"></a>
<h3>ModbusRegister</h3>
<ul>
  This module implements a set of registers as defined in the Modbus specification.<br>
  <br><br>
  <a name="ModbusRegisterdefine"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; ModbusRegister &lt;unitId or slave address&gt; &lt;element number&gt;</code><br>
    <br>
    The unitId allows addressing slaves on a serial line sub-network connected to a ModbusTCP gateway.<br/>
    Most ModbusTCP servers that do not act as a gateway ignore this setting, in that case 0, 1 or 255 should be used.<br/>
    <br/>
    On a serial Modbus network the slave address (1-254) of the device must be indicated.<br/><br/>
    The module supports 2 addressing modes for the element, the attribute <a href="#ModbusRegisterdisableRegisterMapping">disableRegisterMapping</a> defines
    how the element number is interpreted.<br/>
  </ul>
  <br>
  <a name="ModbusRegisterset"></a>
  <b>Set </b>
  <ul>
    <code>set &lt;name&gt; &lt;value&gt;</code>
    <br><br>
        where <code>value</code> depends on the data type<br>
    <br>
  </ul>
  <a name="ModbusRegisterget"></a>
  <b>Get</b> <ul>N/A</ul><br>
  <a name="ModbusRegisterattr"></a>
  <b>Attributes</b>
  <ul>
    <li><a href="#readingFnAttributes">readingFnAttributes</a></li><br>
    <li><a name="">updateInterval</a><br>
        Interval in seconds for reading the register. If the value is smaller than the pollInterval attribute of the IODev,
        the setting from the IODev takes precedence over this attribute. Default: 0.1</li><br>
    <li><a name="">IODev</a><br>
        IODev: Sets the ModbusTCP or ModbusRTU device which should be used for sending and receiving data for this register.</li><br>
    <li><a name="ModbusRegisterdisableRegisterMapping">disableRegisterMapping</a><br>
        The Modbus specification defines 2 word-addressable data blocks with elements numbered from 1 to n. Some vendors use in their
        documentation a numbering scheme starting from 0. If this attribute is not defined or set to 0 the numbering starts at 1 and
        the used data block depends on the register number. Numbers 40001-49999 are read and written to the holding register block,
        numbers 30001-39999 are read from the input register block (read-only). If the attribute is set to 1 the numbering starts at 0.
        By default data is then read from the holding register block, this can be changed with the attribute <a href="#ModbusRegisterregisterType">registerType</a></li><br>
    <li><a name="ModbusRegisterregisterType">registerType</a><br>
        This attribute can be used to define from which block (holding or input) data is read. If the attribute
        <a href="#ModbusRegisterdisableRegisterMapping">disableRegisterMapping</a> is set to 0 or not defined, this attribute is ignored.</li><br>
    <li><a name="">conversion</a><br>
        The read data can be scaled with this attribute. The scaling factors are defined in the form <code>a:b</code> with<br>
        <code>returned value = a * raw data + b</code><br><br>
        Example:<ul>For an energy meter returning the current in 0.1A steps<br><code>attr &lt;name&gt; conversion 0.1:0</code><br>scales the value to A.</ul></li><br>
    <li><a name="">plcDataType</a><br>
        A modbus register is 16 bit wide an contains an unsigned value ranging from 0 to 65535. With this attribute the data type
        and size can be modified.<br>Possible values:<br>
        <ul>
            <li>WORD, 1 register, 16 bit unsigned, default</li>
            <li>INT, 1 register, 16 bit signed</li>
            <li>DWORD, 2 registers, 32 bit unsigned, little endian</li>
            <li>DWORD_BE, 2 registers, 32 bit unsigned, big endian</li>
            <li>DINT, 2 registers, 32 bit signed, little endian</li>
            <li>DINT_BE, 2 registers, 32 bit signed, big endian</li>
            <li>3WORD, 3 registers, 48 bit unsigned, little endian</li>
            <li>3WORD_BE, 3 registers, 48 bit unsigned, big endian</li>
            <li>QWORD, 4 registers, 64 bit unsigned, little endian</li>
            <li>QWORD_BE, 4 registers, 64 bit unsigned, big endian</li>
            <li>REAL, 2 registers, IEEE 754 single precision floating point number, little endian</li>
            <li>REAL_BE, 2 registers, IEEE 754 single precision floating point number, big endian</li>
        </ul></li><br>
    <li><a name="">stateAlias</a><br>
        The read data is written by default to the state reading. If this attribute is defined the data is also written to a reading with
        the name of the attribute value. This can be used to create a reading that is easier to use in a notify or in conjunction with an
        other module that requires a certain reading.
    </li><br>
  </ul>
</ul>
=end html
=cut
