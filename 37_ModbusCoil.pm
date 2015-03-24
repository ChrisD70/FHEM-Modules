# $Id: 37_ModbusCoil.pm 0008 $
# 140818 0001 initial release
# 141108 0002 added 0 (off) and 1 (on) for set
# 150118 0003 completed documentation
# 150215 0004 fixed bug with source and disableRegisterMapping (thanks Dieter1)
# 150221 0005 fixed typo in attribute name updateIntervall
# 150315 0006 added wago address conversion
# 150324 0007 added writeMode Impulse
# 150324 0008 do not trigger on set, use set_on and set_off
# TODO:

package main;

use strict;
use warnings;
use SetExtensions;

sub ModbusCoil_Parse($$);

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
ModbusCoil_Initialize($)
{
  my ($hash) = @_;

  $hash->{Match}     = "^ModbusCoil";
  $hash->{DefFn}     = "ModbusCoil_Define";
  $hash->{UndefFn}   = "ModbusCoil_Undef";
  $hash->{SetFn}     = "ModbusCoil_Set"; 
  $hash->{NotifyFn}  = "ModbusCoil_Notify";
  #$hash->{FingerprintFn}   = "ModbusCoil_Fingerprint";
  $hash->{ParseFn}   = "ModbusCoil_Parse";
  $hash->{AttrFn}    = "ModbusCoil_Attr";
  $hash->{AttrList}  = "IODev ".
                       "updateInterval updateIntervall ".
                       "disableRegisterMapping:0,1 ".
                       "source:Coil,Input ".
                       "writeMode ".
                       "$readingFnAttributes";
}

sub
ModbusCoil_Define($$)
{
  my ($hash, $def) = @_;
  my @a = split("[ \t][ \t]*", $def);

  if((@a != 3 )&&(@a != 4)) {
    my $msg = "wrong syntax: define <name> ModbusCoil [<unitId>|wago] <addr>";
    Log3 undef, 2, $msg;
    return $msg;
  }

  if(!defined($a[3])) {
    $a[3]=$a[2];
    $a[2]=0;
  }
  
  if($a[2] eq 'wago') {
    my ($type,$coil)=ModbusCoil_ParseWagoAddress($hash,$a[3]);
    return "$a[3] is not a valid Wago address" if(($type==-1)||($coil==-1));

    $hash->{helper}{registerType}=$type;
    $a[2]=0;  # UnitId
    $a[3]=$coil;
    $hash->{helper}{wago}=1;
    $hash->{helper}{disableRegisterMapping}=1;
  } else {
    return "$a[2] $a[3] is not a valid Modbus coil" if(($a[2]<0)||($a[2]>255)||($a[3]<0)||($a[3]>65535));
    delete($hash->{helper}{wago}) if defined($hash->{helper}{wago});
  }
  
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
  $hash->{helper}{nread}=8;
  if (!defined($hash->{helper}{wago})) {
    if(!defined($attr{$name}{disableRegisterMapping})) {
      $hash->{helper}{disableRegisterMapping}=0;
    }
  }
  
  ($hash->{helper}{registerType},$hash->{helper}{address})=ModbusCoil_GetAddress($hash,$hash->{helper}{register});

  if(defined($hash->{helper}{addr})&&defined($modules{ModbusCoil}{defptr}{$hash->{helper}{addr}}{$name})) {
    Log3 $name, 5, "Removing $hash->{helper}{addr} $name";
    delete( $modules{ModbusCoil}{defptr}{$hash->{helper}{addr}}{$name} );
  }

  $hash->{helper}{addr} = "$hash->{helper}{registerType} $hash->{helper}{unitId} $hash->{helper}{address}";
  Log3 $name, 5, "Def $hash->{helper}{addr} $name";
  $modules{ModbusCoil}{defptr}{$hash->{helper}{addr}}{$name} = $hash;

  $hash->{helper}{readCmd}=pack("CCnn", $hash->{helper}{unitId}, $hash->{helper}{registerType}, $hash->{helper}{address}, $hash->{helper}{nread});
  $hash->{helper}{updateIntervall}=0.1 if (!defined($hash->{helper}{updateIntervall}));
  $hash->{helper}{nextUpdate}=time();
  
  return undef;
}

#####################################
sub
ModbusCoil_ParseWagoAddress($$)
{
  my ($hash, $arg) = @_;

  my $coil=-1;
  my $type=-1;
  if($arg=~/^([M|Q|I]+)X(\d+)\.(\d+)$/) {
    if($3<16) {
      if($1 eq 'I') {
        if(($2>31) && ($2<128)) {
          $coil=32256+$2*16+$3;
        } elsif(($2>255) && ($2<512)) {
          $coil=4096+$2*16+$3;
        } else {
          $coil=$2*16+$3;
        }
        $type=2;
      }
      if($1 eq 'Q') {
        if(($2>31) && ($2<128)) {
          $coil=36352+$2*16+$3;
        } elsif(($2>255) && ($2<512)) {
          $coil=$2*16+$3;
        } else {
          $coil=512+$2*16+$3;
        }
        $type=1;
      }
      if($1 eq 'M') {
        if($2<1280) {
          $coil=12288+$2*16+$3;
          $type=1;
        }
      }
    }
  }
  return ($type, $coil);
}

#####################################
sub
ModbusCoil_Undef($$)
{
  my ($hash, $arg) = @_;
  my $name = $hash->{NAME};
  my $addr = $hash->{helper}{addr};

  Log3 $name, 5, "Undef $addr $name";
  delete( $modules{ModbusCoil}{defptr}{$addr}{$name} );
  delete( $modules{ModbusCoil}{defptr}{$hash->{helper}{writeMode}{addr}}{$name} ) if(defined($hash->{helper}{writeMode}));

  return undef;
}

#####################################
sub
ModbusCoil_Set($@)
{
  my ($hash, @a) = @_; 
  my $ret = undef;
  my $na = int(@a); 
  my $name = $hash->{NAME};
  
  return "no set value specified" if($na==0);

  if($a[1] eq '?')
  {
    my $list = "off on 0 1"; 
    return SetExtensions($hash, $list, @a); 
  }

  return "no set value specified" if($na<2);
  return "writing to inputs not allowed" if (($hash->{helper}{registerType}==2)&&(!defined($hash->{helper}{writeMode})));

  if (($a[1] eq "on") || ($a[1] eq "off") || ($a[1] eq "1") || ($a[1] eq "0")) {
    my $v=0;
    $v=255 if (($a[1] eq "on")||($a[1] eq "1"));

    my $msg;
    
    if(!defined($hash->{helper}{writeMode})) {
      $msg=pack("CCnCC", $hash->{helper}{unitId}, 5, $hash->{helper}{address}, $v),0;
    } else {
      if($hash->{helper}{writeMode}{type} eq 'IM') {
        if((($v==0)&&(ReadingsVal($name,"state","off") ne "off")) || (($v==255)&&(ReadingsVal($name,"state","on") ne "on"))) {
          RemoveInternalTimer( "ModbusCoil_ResetImpulse:$name");
          InternalTimer( gettimeofday() + 0.5, 
           "ModbusCoil_tcb_ResetImpulse",
           "ModbusCoil_ResetImpulse:$name", 
           0 );
          $msg=pack("CCnCC", $hash->{helper}{unitId}, 5, $hash->{helper}{writeMode}{address}, 255),0;
        }
      }
    }
    if(defined($msg)) {
      IOWrite($hash,$msg);
      if($v==0) {
        readingsSingleUpdate( $hash, "state", "set_off", 1 );
      } else {
        readingsSingleUpdate( $hash, "state", "set_on", 1 );
      }
    }
  } else {
    my $list = "off on "; 
    return SetExtensions($hash, $list, @a); 
  }
  return ("",1);  # do not trigger
}

#####################################
sub
ModbusCoil_tcb_ResetImpulse( $ ) {
    my($in ) = shift;
    my(undef,$name) = split(':',$in);
    my $hash = $defs{$name};
    my $msg;

    $msg=pack("CCnCC", $hash->{helper}{unitId}, 5, $hash->{helper}{writeMode}{address}, 0),0;
    IOWrite($hash,$msg);
}
  
#####################################
sub
ModbusCoil_Get($@)
{
  my ($hash, $name, $cmd, @args) = @_;

  return "\"get $name\" needs at least one parameter" if(@_ < 3);

  my $list = "";

  return "Unknown argument $cmd, choose one of $list";
}

sub
ModbusCoil_Fingerprint($$)
{
  my ($name, $msg) = @_;
  return ( "", $msg );
}

sub
ModbusCoil_Parse($$)
{
  my ($hash, $msg) = @_;
  my $name = $hash->{NAME};

  my (undef,$unitid,$addr,$fc,$nvals,@vals) = split(":",$msg);
  #Log3 $name, 5,"ModbusCoil_Parse: $fc $unitid $addr $nvals $vals[0]";

  my @list;
  my $raddr;
  if($fc==WRITE_SINGLE_COIL) {
    $raddr = "1 $unitid $addr";
    $vals[0]=1 if ($vals[0]==65280);
  } else {
    $raddr = "$fc $unitid $addr";
  }
  my $rhash = $modules{ModbusCoil}{defptr}{$raddr};
  if($rhash) {
    foreach my $n (keys %{$rhash}) {
      my $lh = $rhash->{$n};
      if((defined($lh->{IODev})) && ($lh->{IODev} == $hash)) {
        $n = $lh->{NAME};
        next if($nvals!=ceil($lh->{helper}{nread}/8));
        if(($fc==WRITE_SINGLE_COIL)&&defined($lh->{helper}{writeMode})) {
          # Rückmeldung ignorieren
        } else {
          $lh->{ModbusCoil_lastRcv} = TimeNow();
          my $v="off";
          $v="on" if(($vals[0]&1)==1);
          readingsBeginUpdate($lh);
          readingsBulkUpdate($lh,"state",$v);
          readingsEndUpdate($lh,1);
        }
        push(@list, $n); 
      }
    }
  } else {
   Log3 $name, 2, "ModbusCoil_Parse: invalid address $raddr";
   #return "UNDEFINED ModbusCoil_$rname ModbusCoil $raddr";
   return undef;
  }
  return @list;
}

sub
ModbusCoil_Attr(@)
{
  my ($cmd, $name, $attrName, $attrVal) = @_;
  my $hash=$defs{$name};

  if(($attrName eq "updateIntervall") || ($attrName eq "updateInterval")) {
    if ($cmd eq "set") {
      $attr{$name}{updateInterval} = $attrVal;
      $hash->{helper}{updateIntervall}=$attrVal;
    } else {
      $hash->{helper}{updateIntervall}=0.1;
      delete $attr{$name}{updateInterval} if defined($attr{$name}{updateInterval});
      delete $attr{$name}{updateIntervall} if defined($attr{$name}{updateIntervall});
    }
    $hash->{helper}{nextUpdate}=time()+$hash->{helper}{updateIntervall};
  }
  elsif($attrName eq "source") {
    if (!defined($hash->{helper}{wago})) {
      if ($cmd eq "set") {
        #$attr{$name}{source} = $attrVal;
        if(($hash->{helper}{disableRegisterMapping}==1)) {
          if($attrVal eq 'Input') {
            $hash->{helper}{registerType}=2;
          } else {
            $hash->{helper}{registerType}=1;
          }
        }
      } else {
        $hash->{helper}{registerType}=1 if($hash->{helper}{disableRegisterMapping}==1);
      }
      $hash->{helper}{readCmd}=pack("CCnn", $hash->{helper}{unitId}, $hash->{helper}{registerType}, $hash->{helper}{address}, $hash->{helper}{nread});
      delete( $modules{ModbusCoil}{defptr}{$hash->{helper}{addr}}{$name} );
      $hash->{helper}{addr} = "$hash->{helper}{registerType} $hash->{helper}{unitId} $hash->{helper}{address}";
      $modules{ModbusCoil}{defptr}{$hash->{helper}{addr}}{$name} = $hash;
    }
  }
  elsif($attrName eq "disableRegisterMapping") {
    if (!defined($hash->{helper}{wago})) {
      if ($cmd eq "set") {
        #$attr{$name}{disableRegisterMapping} = $attrVal;
        if($attrVal==1) {
          $hash->{helper}{disableRegisterMapping}=1;
        } else {
          $hash->{helper}{disableRegisterMapping}=0;
        }
      } else {
        $hash->{helper}{disableRegisterMapping}=0;
      }
      ($hash->{helper}{registerType},$hash->{helper}{address})=ModbusCoil_GetAddress($hash,$hash->{helper}{register});
      if((defined($hash->{helper}{writeMode})) && (!defined($hash->{helper}{wago}))) {
        my ($type,$coil)=ModbusCoil_GetAddress($hash,$hash->{helper}{writeMode}{register});
        
        $hash->{helper}{writeMode}{registerType}=$type;
        $hash->{helper}{writeMode}{address}=$coil;
        
        delete($modules{ModbusCoil}{defptr}{$hash->{helper}{writeMode}{addr}}{$name} ) if defined($hash->{helper}{writeMode}{addr});
        $hash->{helper}{writeMode}{addr} = "$hash->{helper}{writeMode}{registerType} $hash->{helper}{unitId} $hash->{helper}{writeMode}{address}";
        $modules{ModbusCoil}{defptr}{$hash->{helper}{writeMode}{addr}}{$name} = $hash;
      }
      $hash->{helper}{readCmd}=pack("CCnn", $hash->{helper}{unitId}, $hash->{helper}{registerType}, $hash->{helper}{address}, $hash->{helper}{nread});
      delete( $modules{ModbusCoil}{defptr}{$hash->{helper}{addr}}{$name} );
      $hash->{helper}{addr} = "$hash->{helper}{registerType} $hash->{helper}{unitId} $hash->{helper}{address}";
      $modules{ModbusCoil}{defptr}{$hash->{helper}{addr}}{$name} = $hash;
    }
  }
  elsif($attrName eq "writeMode") {
    if ($cmd eq "set") {
      my @args=split(":",$attrVal);
      if($args[0] eq 'Impulse') {
        my ($type,$coil);
        if (defined($hash->{helper}{wago})) {
          ($type,$coil)=ModbusCoil_ParseWagoAddress($hash,$args[1]);
          return "$args[1] is not a valid Wago address" if(($type==-1)||($coil==-1));
        } else {
          ($type,$coil)=ModbusCoil_GetAddress($hash,$args[1]);
          $type=1;
        }
        return "writing to input $args[1] is not allowed" if($type==2);

        $hash->{helper}{writeMode}{register}=$args[1];
        $hash->{helper}{writeMode}{registerType}=$type;
        $hash->{helper}{writeMode}{address}=$coil;
        
        delete($modules{ModbusCoil}{defptr}{$hash->{helper}{writeMode}{addr}}{$name} ) if defined($hash->{helper}{writeMode}{addr});
        $hash->{helper}{writeMode}{addr} = "$hash->{helper}{writeMode}{registerType} $hash->{helper}{unitId} $hash->{helper}{writeMode}{address}";
        $modules{ModbusCoil}{defptr}{$hash->{helper}{writeMode}{addr}}{$name} = $hash;
        $hash->{helper}{writeMode}{type}='IM';
      }
      else {
        return "unknown writeMode $args[0]";
      }
    } else {
      delete($hash->{helper}{writeMode}) if defined($hash->{helper}{writeMode});
      delete($modules{ModbusCoil}{defptr}{$hash->{helper}{writeMode}{addr}}{$name} ) if defined($hash->{helper}{writeMode});
    }
  }
  return undef;
}

##########################################################
sub ModbusCoil_GetAddress(@)
{
  my ($hash, $arg) = @_;
  my $name = $hash->{NAME};

  my $address=-1;
  my $type=-1;

  if ($hash->{helper}{disableRegisterMapping}==0) {
    if(($arg>10000)&&($arg<20000)) {
      $type=1;
      $address=$arg-10001;
    } else {
      $type=1;
      if(($arg>0)&&($arg<10000)) {
        $address=$arg-1;
      } else {
        $address=$arg;
      }
    }
  } else {
    if(AttrVal($name,"source",'') eq 'Input') {
      $type=2;
    } else {
      $type=1;
    }
    $address=$arg;
  }
  return($type,$address);
}

sub ModbusCoil_Notify(@) {##########################################################
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

sub ModbusCoil_is_integer {
   defined $_[0] && $_[0] =~ /^[+-]?\d+$/;
}

sub ModbusCoil_is_float {
   defined $_[0] && $_[0] =~ /^[+-]?\d+(\.\d+)?$/;
}

1;

=pod
=begin html

<a name="ModbusCoil"></a>
<h3>ModbusCoil</h3>
<ul>
  This module implements a coil or discrete input as defined in the Modbus specification.<br>
  <br><br>
  <a name="ModbusCoildefine"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; ModbusCoil &lt;unitId or slave address&gt; &lt;element number&gt;</code><br>
    <br>
    The unitId allows addressing slaves on a serial line sub-network connected to a ModbusTCP gateway.<br/>
    Most ModbusTCP servers that do not act as a gateway ignore this setting, in that case 0, 1 or 255 should be used.<br/>
    <br/>
    On a serial Modbus network the slave address (1-254) of the device must be indicated.<br/><br/>
    The module supports 2 addressing modes for the element, the attribute <a href="#ModbusCoildisableRegisterMapping">disableRegisterMapping</a> defines
    how the element number is interpreted.<br/>
  </ul>
  <br>
  <a name="ModbusCoilset"></a>
  <b>Set </b>
  <ul>
    <code>set &lt;name&gt; &lt;value&gt;</code>
    <br><br>
    where <code>value</code> is one of:<br>
    <ul><code>
       on<br>
       off<br>
       0<br>
       1<br>
    </code></ul><br>
    The <a href="#setExtensions"> set extensions</a> are also supported.<br>
    <br>
  </ul><br>
  <a name="ModbusCoilget"></a>
  <b>Get</b> <ul>N/A</ul><br>
  <a name="ModbusCoilattr"></a>
  <b>Attributes</b>
  <ul>
    <li><a href="#readingFnAttributes">readingFnAttributes</a></li><br>
    <li><a name="">updateInterval</a><br>
        Interval in seconds for reading the coil. If the value is smaller than the pollInterval attribute of the IODev,
        the setting from the IODev takes precedence over this attribute. Default: 0.1</li><br>
    <li><a name="">IODev</a><br>
        IODev: Sets the ModbusTCP or ModbusRTU device which should be used for sending and receiving data for this coil.</li><br>
    <li><a name="ModbusCoildisableRegisterMapping">disableRegisterMapping</a><br>
        The Modbus specification defines 2 bit-addressable data blocks with elements numbered from 1 to n. Some vendors use in their
        documentation a numbering scheme starting from 0. If this attribute is not defined or set to 0 the numbering starts at 1 and
        the used data block depends on the coil number. Numbers 1-9999 are read and written to the coil block, numbers 10001-19999 are
        read from the discrete input block (read-only). If the attribute is set to 1 the numbering starts at 0. By default data is then read
        from the coil block, this can be changed with the attribute <a href="#ModbusCoilsource">source</a></li><br>
    <li><a name="ModbusCoilsource">source</a><br>
        This attribute can be used to define from which block (coils or discrete input) data is read. If the attribute
        <a href="#ModbusCoildisableRegisterMapping">disableRegisterMapping</a> is set to 0 or not defined, this attribute is ignored.</li><br>
  </ul>
</ul>

=end html
=cut
