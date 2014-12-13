# $Id: 37_ModbusRegister.pm 0006 $
# 140318 0001 initial release
# 140504 0002 added attributes registerType and disableRegisterMapping
# 140505 0003 added fc to defptr, added RAW reading
# 140506 0004 added _BE plcDataTypes, use readingsBulkUpdate, fixed RAW
# 140507 0005 fixed {helper}{nread} in ModbusRegister_Define
# 140507 0006 delete $hash->{helper}{addr} in modules list on redefine (modify)
#
# TODO:

package main;

use strict;
use warnings;
use SetExtensions;

sub ModbusRegister_Parse($$);
sub _ModbusRegister_SetMinMax($);

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
  #$hash->{FingerprintFn}   = "ModbusRegister_Fingerprint";
  $hash->{ParseFn}   = "ModbusRegister_Parse";
  $hash->{AttrFn}    = "ModbusRegister_Attr";
  $hash->{AttrList}  = "IODev ".
                       "plcDataType:WORD,INT,DWORD,DWORD_BE,DINT,DINT_BE,REAL,REAL_BE ".
                       "conversion ".
                       "updateIntervall ".
                       "disableRegisterMapping:0,1 ".
                       "registerType:Holding,Input ".
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
  Log 0, "Def $hash->{helper}{addr} $name";
  $modules{ModbusRegister}{defptr}{$hash->{helper}{addr}}{$name} = $hash;

  if(defined($attr{$name}{plcDataType})) {
    if(($attr{$name}{plcDataType}=~/^DWORD/) || ($attr{$name}{plcDataType}=~/^DINT/) || ($attr{$name}{plcDataType}=~/^REAL/)) {
      $hash->{helper}{nread}=2;
    }
  }
  $hash->{helper}{readCmd}=pack("CCnn", $hash->{helper}{unitId}, $hash->{helper}{registerType}, $hash->{helper}{address}, $hash->{helper}{nread});
  $hash->{helper}{updateIntervall}=0.1 if (!defined($hash->{helper}{updateIntervall}));
  $hash->{helper}{nextUpdate}=time();
  
  _ModbusRegister_SetMinMax($hash);
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

  if(($na==2)&&_is_float($a[1])) {
    $a[2]=$a[1];
    $a[1]="value";
    $na=3;
  }
  return "no set value specified" if($na<3);
  #Log 0,"$a[1] $a[2] $na";
  return "invalid value for set" if(($na>3)||!_is_float($a[2])||($a[2]<$hash->{helper}{cnv}{min})||($a[2]>$hash->{helper}{cnv}{max}));

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
        readingsBulkUpdate($lh,"state",$v);
        readingsBulkUpdate($lh,"RAW",unpack "H*",pack "n*", @vals); #sprintf("%08x",pack "n*", @vals));
        readingsEndUpdate($lh,1);
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
      _ModbusRegister_SetMinMax($hash);
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
        _ModbusRegister_SetMinMax($hash);
      } else {
        return "wrong syntax: conversion a:b";
      }
    } else {
      $hash->{helper}{cnv}{a}=1;
      $hash->{helper}{cnv}{b}=0;
      _ModbusRegister_SetMinMax($hash);
    }
  }
  elsif($attrName eq "updateIntervall") {
    if ($cmd eq "set") {
      $attr{$name}{updateIntervall} = $attrVal;
      $hash->{helper}{updateIntervall}=$attrVal;
    } else {
      $hash->{helper}{updateIntervall}=0.1;
    }
    $hash->{helper}{nextUpdate}=time()+$hash->{helper}{updateIntervall};
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
      $hash->{helper}{registerType}=AttrVal($name,"registerType",3);
      $hash->{helper}{address}=$hash->{helper}{register};
    }
    $hash->{helper}{readCmd}=pack("CCnn", $hash->{helper}{unitId}, $hash->{helper}{registerType}, $hash->{helper}{address}, $hash->{helper}{nread});
    delete( $modules{ModbusRegister}{defptr}{$hash->{helper}{addr}}{$name} );
    $hash->{helper}{addr} = "$hash->{helper}{registerType} $hash->{helper}{unitId} $hash->{helper}{address}";
    $modules{ModbusRegister}{defptr}{$hash->{helper}{addr}}{$name} = $hash;
  }
  return undef;
}

sub
_ModbusRegister_SetMinMax($)
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

sub _is_integer {
   defined $_[0] && $_[0] =~ /^[+-]?\d+$/;
}

sub _is_float {
   defined $_[0] && $_[0] =~ /^[+-]?\d+(\.\d+)?$/;
}

1;

=pod
=begin html

<a name="ModbusRegister"></a>
<h3>ModbusRegister</h3>
<ul>
  Todo
</ul>

=end html
=cut
