# $Id: 37_StuderXT.pm 0001 $
# 150417 0001 initial release
# 150510 0002 added warning if config file can not be found
# TODO:

package main;

use strict;
use warnings;
use SetExtensions;
use Time::HiRes qw(gettimeofday time);

sub StuderXT_Parse($$);

sub
StuderXT_Initialize($)
{
  my ($hash) = @_;

  $hash->{Match}     = "^StuderXT";
  $hash->{DefFn}     = "StuderXT_Define";
  $hash->{UndefFn}   = "StuderXT_Undef";
  $hash->{SetFn}     = "StuderXT_Set"; 
  $hash->{NotifyFn}  = "StuderXT_Notify";
  #$hash->{FingerprintFn}   = "StuderXT_Fingerprint";
  $hash->{ParseFn}   = "StuderXT_Parse";
  $hash->{AttrFn}    = "StuderXT_Attr";
  $hash->{AttrList}  = "IODev ".
                       "$readingFnAttributes";
}

sub
StuderXT_Define($$)
{
  my ($hash, $def) = @_;
  my @a = split("[ \t][ \t]*", $def);

  if(@a != 4) {
    my $msg = "wrong syntax: define <name> StuderXT <addr> <config file>";
    Log3 undef, 2, $msg;
    return $msg;
  }

  if(!StuderXT_is_integer($a[2])) {
    return "$a[2] is not a valid address";
  }

  if(($a[2]<101)||($a[2]>109)) {
    return "address must be between 101 and 109";
  }

  unless (-e $a[3]) {
    Log3 $a[0], 1, "StuderXT_Define: $a[0]: config file $a[3] not found";
    unless (-e "$attr{global}{modpath}/FHEM/".$a[3]) {
      Log3 $a[0], 1, "StuderXT_Define: $a[0]: config file $attr{global}{modpath}/FHEM/$a[3] not found";
      return "config file not found";
    }
    $a[3]="$attr{global}{modpath}/FHEM/".$a[3];
  }
  
  $hash->{CONFIGFILE}=$a[3];
  my $name = $a[0];

  $hash->{helper}{addr}=$a[2];
  if(defined($hash->{helper}{addr})&&defined($modules{StuderXT}{defptr}{$hash->{helper}{addr}}{$name})) {
    Log3 $name, 5, "Removing $hash->{helper}{addr} $name";
    delete( $modules{StuderXT}{defptr}{$hash->{helper}{addr}}{$name} );
  }

  Log3 $name, 5, "Def $hash->{helper}{addr} $name";
  $modules{StuderXT}{defptr}{$hash->{helper}{addr}}{$name} = $hash;
  
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

  StuderXT_ReadConfig($hash);
  
  return undef;
}

#####################################
sub
StuderXT_ReadConfig($)
{
  my ($hash) = @_;

  delete($hash->{helper}{readings}) if defined($hash->{helper}{readings});
  
  open(my $data, '<', $hash->{CONFIGFILE});
  while (my $line = <$data>) {
    chomp $line;
    my @fields = split /[,;]/ , $line;
    if (@fields>=6) {
      if($fields[0] eq '1') {
        $hash->{helper}{readings}{$fields[1]}{name}=$fields[2];
        $hash->{helper}{readings}{$fields[1]}{unit}=$fields[3];
        $hash->{helper}{readings}{$fields[1]}{format}=$fields[4];
        $hash->{helper}{readings}{$fields[1]}{objectType}=$fields[5] eq 'RW'?2:1;
        $hash->{helper}{readings}{$fields[1]}{propertyId}=$fields[5] eq 'RW'?2:1;
        $hash->{helper}{readings}{$fields[1]}{readInterval}=$fields[6];
        $hash->{helper}{readings}{$fields[1]}{lastRead}=0;
        $hash->{helper}{readings}{$fields[1]}{nextRead}=$fields[6];
        for (my $i=7;$i<@fields;$i++) {
          my @en=split(':',$fields[$i]);
          if (@en==2) {
            $hash->{helper}{readings}{$fields[1]}{enumVals}{$en[0]}=$en[1];          
          }
        }
      }
    }
  }
}

#####################################
sub
StuderXT_tcb_ReadCycle($)
{
    my($in ) = shift;
    my(undef,$name) = split(':',$in);
    my $hash = $defs{$name};

    StuderXT_ReadCycle($hash);
}

#####################################
sub
StuderXT_ReadCycle($)
{
  my ($hash) = @_;
  my $name = $hash->{NAME};

  RemoveInternalTimer( "ReadCycle:$name");
  if(defined($hash->{helper}{readings}) && defined($hash->{IODev}->{NAME})) {
    foreach my $r ( keys %{$hash->{helper}{readings}} ) {
      if(($hash->{helper}{readings}{$r}{nextRead}<time()) && ($hash->{helper}{readings}{$r}{nextRead}!=0)) {
        IOWrite($hash,join(':',$hash->{helper}{addr},'1',$hash->{helper}{readings}{$r}{objectType},$r,$hash->{helper}{readings}{$r}{propertyId},$hash->{helper}{readings}{$r}{format},''));
      }
    }
  }
  InternalTimer( gettimeofday() + 1, 
     "StuderXT_tcb_ReadCycle",
     "ReadCycle:$name", 
     0 );
}

#####################################
sub
StuderXT_Undef($$)
{
  my ($hash, $arg) = @_;
  my $name = $hash->{NAME};
  my $addr = $hash->{helper}{addr};

  Log3 $name, 5, "Undef $addr $name";
  delete( $modules{StuderXT}{defptr}{$addr}{$name} );

  return undef;
}

#####################################
sub
StuderXT_Set($@)
{
  my ($hash, @a) = @_; 
  my $ret = undef;
  my $na = int(@a); 
  my $name = $hash->{NAME};
  
  return "no set value specified" if($na==0);

  if($a[1] eq '?')
  {
    my $list = "doReadCycle"; 
    return $list; 
  }
  if($a[1] eq 'doReadCycle') {
    StuderXT_ReadCycle($hash);
  }
}

#####################################
sub
StuderXT_Get($@)
{
  my ($hash, $name, $cmd, @args) = @_;

  return "\"get $name\" needs at least one parameter" if(@_ < 3);

  my $list = "";

  return "Unknown argument $cmd, choose one of $list";
}

sub
StuderXT_Fingerprint($$)
{
  my ($name, $msg) = @_;
  return ( "", $msg );
}

sub
StuderXT_Parse($$)
{
  my ($hash, $msg) = @_;
  my $name = $hash->{NAME};

  #Dispatch($hash, "StuderXT:$src_addr:$service_id:$object_type:$object_id:$property_id".join(":",unpack("C*", $value)), undef);

  my (undef,$src_addr,$service_id,$object_type,$object_id,$property_id,@vals) = split(":",$msg);

  my @list;

  my $rhash = $modules{StuderXT}{defptr}{$src_addr};
  if($rhash) {
    foreach my $n (keys %{$rhash}) {
      my $lh = $rhash->{$n};
      if((defined($lh->{IODev})) && ($lh->{IODev} == $hash)) {
        $n = $lh->{NAME};
        $lh->{StuderXT_lastRcv} = TimeNow();
        if(defined($lh->{helper}{readings}{$object_id})) {
          my $v=0;
          $v=unpack "f", pack "C4", @vals if($lh->{helper}{readings}{$object_id}{format} eq 'FLOAT');
          $v=$vals[0] if($lh->{helper}{readings}{$object_id}{format} eq 'BOOL');
          $v=unpack "v", pack "C2", @vals if($lh->{helper}{readings}{$object_id}{format} eq 'ENUM');
          $v=unpack "V", pack "C4", @vals if($lh->{helper}{readings}{$object_id}{format} eq 'INT32');
          readingsBeginUpdate($lh);
          readingsBulkUpdate($lh,$lh->{helper}{readings}{$object_id}{name},$v);
          readingsEndUpdate($lh,1);
          $lh->{helper}{readings}{$object_id}{lastRead}=time();
          if($lh->{helper}{readings}{$object_id}{readInterval}>0) {
            $lh->{helper}{readings}{$object_id}{nextRead}=time()+$lh->{helper}{readings}{$object_id}{readInterval};
          } else {
            $lh->{helper}{readings}{$object_id}{nextRead}=0;
          }
        }
        push(@list, $n); 
      }
    }
  } else {
   Log3 $name, 2, "StuderXT_Parse: invalid address $src_addr";
   #return "UNDEFINED StuderXT_$rname StuderXT $src_addr";
   return undef;
  }
  return @list;
}

sub
StuderXT_Attr(@)
{
  my ($cmd, $name, $attrName, $attrVal) = @_;
  my $hash=$defs{$name};

  return undef;
}

sub StuderXT_Notify(@) {##########################################################
  my ($hash,$dev) = @_;
  my $name = $hash->{NAME}; # own name / hash
  my $devName = $dev->{NAME}; # Device that created the events

  if ($devName eq "global" && grep (m/^INITIALIZED$|^REREADCFG$/,@{$dev->{CHANGED}})){
  }

  # event from IODev
  if (defined($hash->{IODev}) && defined($hash->{IODev}->{NAME}) && ($devName eq $hash->{IODev}->{NAME})) {
  }
  return;
}

sub StuderXT_is_integer {
   defined $_[0] && $_[0] =~ /^[+-]?\d+$/;
}

sub StuderXT_is_float {
   defined $_[0] && $_[0] =~ /^[+-]?\d+(\.\d+)?$/;
}

1;

=pod
=begin html

<a name="StuderXT"></a>
<h3>StuderXT</h3>
<ul>
</ul>

=end html
=cut
