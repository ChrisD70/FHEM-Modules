
##############################################
# $Id: 98_Text2SpeechSB.pm CD mit Patch für svox-pico von berrnd 9162 2015-08-30 05:00:32Z tobiasfaust $
# Basis: https://github.com/berrnd/fhem-mirror/blob/feature-Text2SpeechSB-add-svox-pico/fhem/FHEM/98_Text2SpeechSB.pm
# 98_Text2SpeechSB.pm
#
# written by Tobias Faust 2013-10-23
# e-mail: tobias dot faust at online dot de
#
##############################################

##############################################
# EDITOR=nano
# visudo
# ALL     ALL = NOPASSWD: /usr/bin/mplayer
##############################################

# VoiceRSS: http://www.voicerss.org/api/documentation.aspx

package main;
use strict;
use warnings;
use Blocking;
use IO::File;
use HttpUtils;
use Digest::MD5 qw(md5_hex);
use URI::Escape;
use Data::Dumper;
use lib ('./FHEM/lib', './lib');

sub Text2SpeechSB_OpenDev($);
sub Text2SpeechSB_CloseDev($);


# SetParamName -> Anzahl Paramter
my %sets = (
  "tts"    => "1",
  "volume" => "1"
);

# path to mplayer
my $mplayer 			= 'sudo /usr/bin/mplayer';
#my $mplayerOpts 		= '-nolirc -noconsolecontrols -http-header-fields "User-Agent:Mozilla/5.0 (Windows NT 6.2; WOW64) AppleWebKit/537.22 (KHTML, like Gecko) Chrome/25.0.1364.172 Safari/537.22m"';
my $mplayerOpts     = '-nolirc -noconsolecontrols';
my $mplayerNoDebug  = '-really-quiet';
my $mplayerAudioOpts 	= '-ao alsa:device=';
#my $ttsAddr 			= 'http://translate.google.com/translate_tts?tl=de&q=';
my %ttsHost         = ("Google"     => "translate.google.com",
                       "VoiceRSS"   => "api.voicerss.org"
                       );
my %ttsLang         = ("Google"     => "tl=",
                       "VoiceRSS"   => "hl="
                       );
my %ttsQuery        = ("Google"     => "q=",
                       "VoiceRSS"   => "src="
                       );
my %ttsPath         = ("Google"     => "/translate_tts?",
                       "VoiceRSS"   => "/?"
                       );
my %ttsAddon        = ("Google"     => "client=t&prev=input", 
                       "VoiceRSS"   => ""
                       );
my %ttsAPIKey       = ("Google"     => "", # kein APIKey nötig
                       "VoiceRSS"   => "key="
                       );
my %ttsUser         = ("Google"     => "", # kein Username nötig
                       "VoiceRSS"   => ""  # kein Username nötig
                       );
my %ttsSpeed        = ("Google"     => "", 
                       "VoiceRSS"   => "r="
                       );
my %ttsQuality       = ("Google"     => "", 
                       "VoiceRSS"   => "f="
                       );
my %ttsMaxChar      = ("Google"     => 100,
                       "VoiceRSS"   => 300
                       );
my %language        = ("Google"     =>  {"Deutsch"        => "de",
                                         "English-US"     => "en-us",
                                         "Schwedisch"     => "sv",
                                         "Indian-Hindi"   => "hi",
                                         "Arabic"         => "ar",
                                         "France"         => "fr",
                                         "Spain"          => "es",
                                         "Italian"        => "it",
                                         "Chinese"        => "cn"
                                         },
                       "VoiceRSS"   =>  {"Deutsch"        => "de-de",
                                         "English-US"     => "en-us",
                                         "Schwedisch"     => "sv-se",
                                         "Indian-Hindi"   => "en-in", # gibts nicht
                                         "Arabic"         => "en-us", # gibts nicht
                                         "France"         => "fr-fr",
                                         "Spain"          => "es-es",
                                         "Italian"        => "it-it",
                                         "Chinese"        => "zh-cn"
                                         }
                      );

##########################
sub Text2SpeechSB_Initialize($)
{
  my ($hash) = @_;
  $hash->{WriteFn}   = "Text2SpeechSB_Write";
  $hash->{ReadyFn}   = "Text2SpeechSB_Ready"; 
  $hash->{DefFn}     = "Text2SpeechSB_Define";
  $hash->{SetFn}     = "Text2SpeechSB_Set";
  $hash->{UndefFn}   = "Text2SpeechSB_Undefine";
  $hash->{AttrFn}    = "Text2SpeechSB_Attr";
  $hash->{AttrList}  = "disable:0,1".
                       " TTS_Delemiter".
                       " TTS_Ressource:ESpeak,SVOX-pico,". join(",", sort keys %ttsHost).
                       " TTS_APIKey".
                       " TTS_User".
                       " TTS_Quality:".
                                        "48khz_16bit_stereo,".
                                        "48khz_16bit_mono,".
                                        "48khz_8bit_stereo,".
                                        "48khz_8bit_mono".
                                        "44khz_16bit_stereo,".
                                        "44khz_16bit_mono,".
                                        "44khz_8bit_stereo,".
                                        "44khz_8bit_mono".
                                        "32khz_16bit_stereo,".
                                        "32khz_16bit_mono,".
                                        "32khz_8bit_stereo,".
                                        "32khz_8bit_mono".
                                        "24khz_16bit_stereo,".
                                        "24khz_16bit_mono,".
                                        "24khz_8bit_stereo,".
                                        "24khz_8bit_mono".
                                        "22khz_16bit_stereo,".
                                        "22khz_16bit_mono,".
                                        "22khz_8bit_stereo,".
                                        "22khz_8bit_mono".
                                        "16khz_16bit_stereo,".
                                        "16khz_16bit_mono,".
                                        "16khz_8bit_stereo,".
                                        "16khz_8bit_mono".
                                        "8khz_16bit_stereo,".
                                        "8khz_16bit_mono,".
                                        "8khz_8bit_stereo,".
                                        "8khz_8bit_mono".
                       " TTS_Speed:-10,-9,-8,-7,-6,-5,-4,-3,-2,-1,0,1,2,3,4,5,6,7,8,9,10".
                       " TTS_TimeOut".
                       " TTS_CacheFileDir".
                       " TTS_UseMP3Wrap:0,1".
                       " TTS_MplayerCall".
                       " TTS_SentenceAppendix".
                       " TTS_FileMapping".
                       " TTS_FileTemplateDir".
		                   " TTS_VolumeAdjust".
                       " TTS_Language:".join(",", sort keys %{$language{"Google"}}).
                       " ".$readingFnAttributes;
}


##########################
# Define <tts> Text2SpeechSB <alsa-device>
# Define <tts> Text2SpeechSB host[:port][:SSL] [portpassword]
##########################
sub Text2SpeechSB_Define($$)
{
  my ($hash, $def) = @_;
  my @a = split("[ \t]+", $def);

  #$a[0]: Name
  #$a[1]: Type/Alias -> Text2SpeechSB
  #$a[2]: definition
  #$a[3]: optional: portpasswd
  if(int(@a) < 3) {
    my $msg =  "wrong syntax: define <name> Text2SpeechSB <alsa-device>\n".
    			     "see at /etc/asound.conf\n".
               "or remote syntax: define <name> Text2SpeechSB host[:port][:SSL] [portpassword]";
    Log3 $hash, 2, $msg;
    return $msg;
  }

  my $dev = $a[2];
  if($dev =~ m/^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}).*/ ) {
    # Ein RemoteDevice ist angegeben
    # zb: 192.168.10.24:7272:SSL mypasswd

    if($dev =~ m/^(.*):SSL$/) {
      $dev = $1;
      $hash->{SSL} = 1;
    }
    if($dev !~ m/^.+:[0-9]+$/) { # host:port
      $dev = "$dev:7072";
    }
    $hash->{Host} = $dev;
    $hash->{portpassword} = $a[3] if(@a == 4); 

    $hash->{MODE} = "REMOTE";
  } else {
    # Ein Alsadevice ist angegeben
    # pruefen, ob Alsa-Device in /etc/asound.conf definiert ist
    $hash->{MODE} = "DIRECT";
    $hash->{ALSADEVICE} = $a[2];
  }

  BlockingKill($hash->{helper}{RUNNING_PID}) if(defined($hash->{helper}{RUNNING_PID}));
  delete($hash->{helper}{RUNNING_PID});

  $hash->{STATE} = "Initialized";

  return undef;
}

#####################################
sub Text2SpeechSB_Undefine($$)
{
 my ($hash, $arg) = @_;

 RemoveInternalTimer($hash);
 BlockingKill($hash->{helper}{RUNNING_PID}) if(defined($hash->{helper}{RUNNING_PID}));
 Text2SpeechSB_CloseDev($hash);

 return undef;
}

###################################
# Angabe des Delemiters: zb.: +af~ 
#   + -> erzwinge das Trennen, auch wenn Textbaustein < 100Zeichen
#   - -> Trenne nur wenn Textbaustein > 100Zeichen
#  af -> add first -> füge den Delemiter am Satzanfang wieder hinzu
#  al -> add last  -> füge den Delemiter am Satzende wieder hinzu
#  an -> add nothing -> Delemiter nicht wieder hinzufügen
#   ~ -> der Delemiter
###################################
sub Text2SpeechSB_Attr(@) {
  my @a = @_;
  my $do = 0;
  my $hash = $defs{$a[1]};
  my $value = $a[3];

  my $TTS_FileTemplateDir = AttrVal($hash->{NAME}, "TTS_FileTemplateDir", "templates");
  my $TTS_CacheFileDir = AttrVal($hash->{NAME}, "TTS_CacheFileDir", "cache");
  my $TTS_FileMapping  = AttrVal($hash->{NAME}, "TTS_FileMapping", ""); # zb, silence:silence.mp3 ring:myringtone.mp3;

  if($a[2] eq "TTS_Delemiter" && $a[0] ne "del") {
    return "wrong delemiter syntax: [+-]a[lfn]. \n".
           "  Example 1: +an~\n".
           "  Example 2: +al." if($value !~ m/^([+-]a[lfn]){0,1}(.){1}$/i);
    return "This Attribute is only available in direct mode" if($hash->{MODE} ne "DIRECT");

  } elsif ($a[2] eq "TTS_Ressource") {
    return "This Attribute is only available in direct mode" if($hash->{MODE} ne "DIRECT");
  
  } elsif ($a[2] eq "TTS_CacheFileDir") {
    return "This Attribute is only available in direct mode" if($hash->{MODE} ne "DIRECT");
 
  } elsif ($a[2] eq "TTS_UseMP3Wrap") {
    return "This Attribute is only available in direct mode" if($hash->{MODE} ne "DIRECT");
    return "Attribute TTS_UseMP3Wrap is required by Attribute TTS_SentenceAppendix! Please delete it first." 
      if(($a[0] eq "del") && (AttrVal($hash->{NAME}, "TTS_SentenceAppendix", undef)));

  } elsif ($a[2] eq "TTS_SentenceAppendix") { 
    return "This Attribute is only available in direct mode" if($hash->{MODE} ne "DIRECT");
    return "Attribute TTS_UseMP3Wrap is required!" unless(AttrVal($hash->{NAME}, "TTS_UseMP3Wrap", undef));
    
    my $file = $TTS_CacheFileDir ."/". $value;
    return "File <".$file."> does not exists in CacheFileDir" if(! -e $file);
  
  } elsif ($a[2] eq "TTS_FileTemplateDir") {
    # Verzeichnis beginnt mit /, dann absoluter Pfad, sonst Unterpfad von $TTS_CacheFileDir
    my $newDir;
    if($value =~ m/^\/.*/) { $newDir = $value; } else { $newDir = $TTS_CacheFileDir ."/". $value;}
    unless(-e ($newDir) or mkdir ($newDir)) {
      #Verzeichnis anlegen gescheitert
      return "Could not create directory: <$value>";
    }

  } elsif ($a[2] eq "TTS_TimeOut") {
    return "Only Numbers allowed" if ($value !~ m/[0-9]+/);

  } elsif ($a[2] eq "TTS_FileMapping") {
    #Bsp: silence:silence.mp3 pling:mypling,mp3
    #ueberpruefen, ob mp3 Template existiert
    my @FileTpl = split(" ", $TTS_FileMapping);
    my $newDir;
    for(my $j=0; $j<(@FileTpl); $j++) {
      my @FileTplPc = split(/:/, $FileTpl[$j]);
      if($TTS_FileTemplateDir =~ m/^\/.*/) { $newDir = $TTS_FileTemplateDir; } else { $newDir = $TTS_CacheFileDir ."/". $TTS_FileTemplateDir;}
      return "file does not exist: <".$newDir ."/". $FileTplPc[1] .">"
        unless (-e $newDir ."/". $FileTplPc[1]);
    }
  }

  if($a[0] eq "set" && $a[2] eq "disable") {
    $do = (!defined($a[3]) || $a[3]) ? 1 : 2;
  }
  $do = 2 if($a[0] eq "del" && (!$a[2] || $a[2] eq "disable"));
  return if(!$do);

  $hash->{STATE} = ($do == 1 ? "disabled" : "Initialized");

  return undef;
}

#####################################
sub Text2SpeechSB_Ready($)
{
my ($hash) = @_;
return Text2SpeechSB_OpenDev($hash);
} 

########################
sub Text2SpeechSB_OpenDev($) {
  my ($hash) = @_;
  my $dev = $hash->{Host};
  my $name = $hash->{NAME};

  Log3 $name, 4, "Text2SpeechSB opening $name at $dev"; 

  my $conn;
  if($hash->{SSL}) {
    eval "use IO::Socket::SSL";
    Log3 $name, 1, $@ if($@);
    $conn = IO::Socket::SSL->new(PeerAddr => "$dev") if(!$@);
  } else {
    $conn = IO::Socket::INET->new(PeerAddr => $dev);
  } 

  if(!$conn) {
    Log3($name, 3, "Text2SpeechSB: Can't connect to $dev: $!");
    $hash->{STATE} = "disconnected";
    return "";
  } else {
    $hash->{STATE} = "Initialized";
  }

  $hash->{TCPDev} = $conn;
  $hash->{FD} = $conn->fileno(); 

  Log3 $name, 4, "Text2SpeechSB device opened ($name)";

  syswrite($hash->{TCPDev}, $hash->{portpassword} . "\n")
  if($hash->{portpassword}); 

  return undef;
}

########################
sub Text2SpeechSB_CloseDev($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  my $dev = $hash->{Host};
  return if(!$dev);
  
  if($hash->{TCPDev}) {
    $hash->{TCPDev}->close(); 
    Log3 $hash, 4, "Text2SpeechSB Device closed ($name)";
  }

  delete($hash->{TCPDev});
  delete($hash->{FD});
} 

########################
sub Text2SpeechSB_Write($$) {
  my ($hash,$msg) = @_;
  my $name = $hash->{NAME};
  my $dev = $hash->{Host};

  #my $call = "set tts tts Das ist ein Test.";
  my $call = "set $name $msg"; 

  Text2SpeechSB_OpenDev($hash) if(!$hash->{TCPDev});
  #lets try again
  Text2SpeechSB_OpenDev($hash) if(!$hash->{TCPDev});

  if($hash->{TCPDev}) {
    Log3 $hash, 4, "Text2SpeechSB: Write remote message to $dev: $call";
    Log3 $hash, 3, "Text2SpeechSB: Could not write remote message ($call) at " .$hash->{Host} if(!defined(syswrite($hash->{TCPDev}, "$call\n")));
    Text2SpeechSB_CloseDev($hash);
  }

}


###########################################################################

sub Text2SpeechSB_Set($@)
{
  my ($hash, @a) = @_;
  my $me = $hash->{NAME};
  my $TTS_APIKey    = AttrVal($hash->{NAME}, "TTS_APIKey", undef);
  my $TTS_User      = AttrVal($hash->{NAME}, "TTS_User", undef);
  my $TTS_Ressource = AttrVal($hash->{NAME}, "TTS_Ressource", "Google");
  my $TTS_TimeOut   = AttrVal($hash->{NAME}, "TTS_TimeOut", 60);
  

  return "no set argument specified" if(int(@a) < 2);

  return "No APIKey specified"                  if (length($ttsAPIKey{$TTS_Ressource})>0 && !defined($TTS_APIKey)); 
  return "No Username for TTS Access specified" if (length($ttsUser{$TTS_Ressource})>0 && !defined($TTS_User));

  my $cmd = shift(@a); # Dummy
     $cmd = shift(@a); # DevName

  if(!defined($sets{$cmd})) {
    my $r = "Unknown argument $cmd, choose one of ".join(" ",sort keys %sets);
    return $r;
  }

  if($cmd ne "tts") {
    return "$cmd needs $sets{$cmd} parameter(s)" if(@a-$sets{$cmd} != 0);
  }

  # Abbruch falls Disabled
  return undef if(AttrVal($hash->{NAME}, "disable", "0") eq "1");

  if($cmd eq "tts") {
    readingsSingleUpdate($hash, "playing", "1", 1);
    if($hash->{MODE} eq "DIRECT") {
      Text2SpeechSB_PrepareSpeech($hash, join(" ", @a));
      $hash->{helper}{RUNNING_PID} = BlockingCall("Text2SpeechSB_DoIt", $hash, "Text2SpeechSB_Done", $TTS_TimeOut, "Text2SpeechSB_AbortFn", $hash) unless(exists($hash->{helper}{RUNNING_PID}));
    } elsif ($hash->{MODE} eq "REMOTE") {
      Text2SpeechSB_Write($hash, "tts " . join(" ", @a));
    } else {return undef;}
  } elsif($cmd eq "volume") {
    my $vol = join(" ", @a);
    return "volume level expects 0..100 percent" if($vol !~ m/^([0-9]{1,3})$/ or $vol > 100);
    
    if($hash->{MODE} eq "DIRECT") {
      $hash->{VOLUME} = $vol  if($vol <= 100);
      delete($hash->{VOLUME}) if($vol > 100);
    } elsif ($hash->{MODE} eq "REMOTE") {
      Text2SpeechSB_Write($hash, "volume $vol");
    } else {return undef;}
    readingsSingleUpdate($hash, "volume", (($vol>100)?0:$vol), 1);  
  }

  return undef;
}

#####################################
# Bereitet den gesamten String vor.
# Bei Nutzung Google wird dieser in ein Array
# zerlegt mit jeweils einer maximalen
# Stringlänge von 100Chars
#
# param1: $hash
# param2: string to speech
#
#####################################
sub Text2SpeechSB_PrepareSpeech($$) {
  my ($hash, $t) = @_;
  my $me = $hash->{NAME};

  my $TTS_Ressource = AttrVal($hash->{NAME}, "TTS_Ressource", "Google");
  my $TTS_Delemiter = AttrVal($hash->{NAME}, "TTS_Delemiter", undef); 
  my $TTS_FileTpl   = AttrVal($hash->{NAME}, "TTS_FileMapping", ""); # zb, silence:silence.mp3 ring:myringtone.mp3; im Text: mein Klingelton :ring: ist laut.
  my $TTS_FileTemplateDir = AttrVal($hash->{NAME}, "TTS_FileTemplateDir", "templates");

  my $TTS_ForceSplit = 0;
  my $TTS_AddDelemiter;

  if($TTS_Delemiter && $TTS_Delemiter =~ m/^[+-]a[lfn]/i) {
    $TTS_ForceSplit = 1 if(substr($TTS_Delemiter,0,1) eq "+");
    $TTS_ForceSplit = 0 if(substr($TTS_Delemiter,0,1) eq "-");
    
    $TTS_AddDelemiter = substr($TTS_Delemiter,1,2); # af, al oder an
    
    $TTS_Delemiter = substr($TTS_Delemiter,3);
    
  } elsif (!$TTS_Delemiter) { # Default wenn Attr nicht gesetzt
    $TTS_Delemiter = "(?<=[\\.!?])\\s*";
    $TTS_ForceSplit = 1;
    $TTS_AddDelemiter = "";
  }

  if($TTS_Ressource ne "ESpeak") {
    my @text; 

    # ersetze Sonderzeichen die Google nicht auflösen kann
    if($TTS_Ressource eq "Google") {
      $t =~ s/ä/ae/g;
      $t =~ s/ö/oe/g;
      $t =~ s/ü/ue/g;
      $t =~ s/Ä/Ae/g;
      $t =~ s/Ö/Oe/g;
      $t =~ s/Ü/Ue/g;
      $t =~ s/ß/ss/g;
    }

    @text = $hash->{helper}{Text2SpeechSB} if($hash->{helper}{Text2SpeechSB}[0]); #vorhandene Queue, neuen Sprachbaustein hinten anfuegen
    push(@text, $t);

    # hole alle Filetemplates
    my @FileTpl = split(" ", $TTS_FileTpl);
    my @FileTplPc;

    # bei Angabe direkter MP3-Files wird hier ein temporäres Template vergeben
    for(my $i=0; $i<(@text); $i++) {
      @FileTplPc = ($text[$i] =~ /:(\w+.+[mp3|ogg|wav]):/g);
      for(my $j=0; $j<(@FileTplPc); $j++) {
        my $time = time();
        $time =~ s/\.//g;
        my $tpl = "FileTpl_".$time."_#".$i; #eindeutige Templatedefinition schaffen
        Log3 $hash, 4, "$me: Angabe einer direkten MP3-Datei gefunden:  $FileTplPc[$i] => $tpl";
        push(@FileTpl, $tpl.":".$FileTplPc[$j]); #zb: FileTpl_123645875_#0:/ring.mp3
        $text[$i] =~ s/$FileTplPc[$j]/$tpl/g; # Ersetze die DateiDefinition gegen ein Template
      }
    }

    #iteriere durch die Sprachbausteine und splitte den Text bei den Filetemplates auf
    for(my $i=0; $i<(@text); $i++) {
      my $cutter = '#!#'; #eindeutigen Cutter als Delemiter bei den Filetemplates vergeben
      @FileTplPc = ($text[$i] =~ /:([^:]+):/g);
      for(my $j=0; $j<(@FileTplPc); $j++) {
        $text[$i] =~ s/:$FileTplPc[$j]:/$cutter$FileTplPc[$j]$cutter/g;
      }
      @text = Text2SpeechSB_SplitString(\@text, 0, $cutter, 1, ""); 
    }

    @text = Text2SpeechSB_SplitString(\@text, $ttsMaxChar{$TTS_Ressource}, $TTS_Delemiter, $TTS_ForceSplit, $TTS_AddDelemiter);
    @text = Text2SpeechSB_SplitString(\@text, $ttsMaxChar{$TTS_Ressource}, "(?<=[\\.!?])\\s*", 0, "");
    @text = Text2SpeechSB_SplitString(\@text, $ttsMaxChar{$TTS_Ressource}, ",", 0, "al");
    @text = Text2SpeechSB_SplitString(\@text, $ttsMaxChar{$TTS_Ressource}, ";", 0, "al");
    @text = Text2SpeechSB_SplitString(\@text, $ttsMaxChar{$TTS_Ressource}, "und", 0, "af");

    Log3 $hash, 4, "$me: Auflistung der Textbausteine nach Aufbereitung:"; 
    for(my $i=0; $i<(@text); $i++) {
      # entferne führende und abschließende Leerzeichen aus jedem Textbaustein
      $text[$i] =~ s/^\s+|\s+$//g; 
      for(my $j=0; $j<(@FileTpl); $j++) {
        # ersetze die FileTemplates mit den echten MP3-Files
        @FileTplPc = split(/:/, $FileTpl[$j]);
        $text[$i] = $TTS_FileTemplateDir ."/". $FileTplPc[1] if($text[$i] eq $FileTplPc[0]);
      }
      Log3 $hash, 4, "$me: $i => ".$text[$i]; 
    }

    @{$hash->{helper}{Text2SpeechSB}} = @text;

  } else {
    push(@{$hash->{helper}{Text2SpeechSB}}, $t);
  }
}

#####################################
# param1: array : Text 2 Speech   
# param2: string: MaxChar
# param3: string: Delemiter
# param4: int   : 1 -> es wird am Delemiter gesplittet
#                 0 -> es wird nur gesplittet, wenn Stringlänge länger als MaxChar
# param5: string: Add Delemiter to String? [al|af|<empty>] (AddLast/AddFirst)
#
# Splittet die Texte aus $hash->{helper}->{Text2SpeechSB} anhand des
# Delemiters, wenn die Stringlänge MaxChars übersteigt.
# Ist "AddDelemiter" angegeben, so wird der Delemiter an den 
# String wieder angefügt
#####################################
sub Text2SpeechSB_SplitString(@$$$$){
  my @text          = @{$_[0]};
  my $MaxChar       = $_[1];
  my $Delemiter     = $_[2];
  my $ForceSplit    = $_[3];
  my $AddDelemiter  = $_[4];
  my @newText;

  for(my $i=0; $i<(@text); $i++) {
    if((length($text[$i]) <= $MaxChar) && (!$ForceSplit)) { #Google kann nur 100zeichen
      push(@newText, $text[$i]);
      next;
    }

    my @b = split(/$Delemiter/, $text[$i]); 
    for(my $j=0; $j<(@b); $j++) {
      $b[$j] = $b[$j] . $Delemiter if($AddDelemiter eq "al"); # Am Satzende wieder hinzufügen.
      $b[$j+1] = $Delemiter . $b[$j+1] if(($AddDelemiter eq "af") && ($b[$j+1])); # Am Satzanfang des nächsten Satzes wieder hinzufügen.
      push(@newText, $b[$j]);
    }
  }
  return @newText;
}

#####################################
# param1: hash  : Hash
# param2: string: Typ (mplayer oder mp3wrap oder ....)
# param3: string: Datei
# 
# Erstellt den Commandstring für den Systemaufruf
#####################################
sub Text2SpeechSB_BuildMplayerCmdString($$) {
  my ($hash, $file) = @_;
  my $cmd;

  my $TTS_MplayerCall = AttrVal($hash->{NAME}, "TTS_MplayerCall", $mplayer);
  my $TTS_VolumeAdjust = AttrVal($hash->{NAME}, "TTS_VolumeAdjust", 110);
  my $verbose = AttrVal($hash->{NAME}, "verbose", 3);

  if($hash->{VOLUME}) { # per: set <name> volume <..>
    $mplayerOpts .= " -softvol -softvol-max ". $TTS_VolumeAdjust ." -volume " . $hash->{VOLUME}; 
  }

  my $AlsaDevice = $hash->{ALSADEVICE};
  if($AlsaDevice eq "none") {
    $AlsaDevice = "";
    $mplayerAudioOpts = "";
  }

  my $NoDebug = $mplayerNoDebug;
  $NoDebug = "" if($verbose >= 5);

  $cmd = $TTS_MplayerCall . " " . $mplayerAudioOpts . $AlsaDevice . " " .$NoDebug. " " . $mplayerOpts . " " . $file; 

  my $mp3Duration =  Text2SpeechSB_CalcMP3Duration($hash, $file);
  BlockingInformParent("Text2SpeechSB_readingsSingleUpdateByName", [$hash->{NAME}, "duration", "$mp3Duration"], 0);
  BlockingInformParent("Text2SpeechSB_readingsSingleUpdateByName", [$hash->{NAME}, "endTime", "00:00:00"], 0);
  return $cmd;
}

sub Text2SpeechSB_readingsSingleUpdateByName($$$) {
  my ($devName, $readingName, $readingVal) = @_;
  my $hash = $defs{$devName};
  #Log3 $hash, 4, "Text2SpeechSB_readingsSingleUpdateByName: Dev:$devName Reading:$readingName Val:$readingVal";
  readingsSingleUpdate($defs{$devName}, $readingName, $readingVal, 1);
}

sub Text2SpeechSB_DoTriggerByName($$) {
  my ($name, $val) = @_;
  my $hash = $defs{$name};
  if(defined($hash->{helper}{SB_PLAYER})) {
    Log3 $hash, 4, "Text2SpeechSB_DoTriggerByName: Dev:$name Data:$val";
    my $sb=$hash->{helper}{SB_PLAYER};
    DoTrigger($name, "$sb $val");
  }
}

#####################################
# param1: string: MP3 Datei inkl. Pfad
# 
# Ermittelt die Abspieldauer einer MP3 und gibt die Zeit in Sekunden zurück.
# Die Abspielzeit wird auf eine ganze Zahl gerundet
#####################################
sub Text2SpeechSB_CalcMP3Duration($$) {
  my $time;
  my ($hash, $file) = @_;
  eval {
    use MP3::Info;    
    my $tag = get_mp3info($file);
    if ($tag && defined($tag->{SECS})) {
	  $time = int($tag->{SECS}+0.5);
      Log3 $hash, 4, "Text2SpeechSB_CalcMP3Duration: $file hat eine Länge von $time Sekunden.";
    }
  };
  
  if ($@) {
	Log3 $hash, 2, "Text2SpeechSB_CalcMP3Duration: Bei der MP3-Längenermittlung ist ein Fehler aufgetreten: $@";
    return undef;
  }
  return $time;
}


#####################################
# param1: hash  : Hash
# param2: string: Dateiname
# param2: string: Text
# 
# Holt den Text aus dem Google Translator als MP3Datei
#####################################
sub Text2SpeechSB_Download($$$) {
  my ($hash, $file, $text) = @_;

  my $TTS_Ressource = AttrVal($hash->{NAME}, "TTS_Ressource", "Google");
  my $TTS_User      = AttrVal($hash->{NAME}, "TTS_User", "");
  my $TTS_APIKey    = AttrVal($hash->{NAME}, "TTS_APIKey", "");
  my $TTS_Language  = AttrVal($hash->{NAME}, "TTS_Language", "Deutsch");
  my $TTS_Quality   = AttrVal($hash->{NAME}, "TTS_Quality", "");
  my $TTS_Speed     = AttrVal($hash->{NAME}, "TTS_Speed", "");


  my $HttpResponse;
  my $HttpResponseErr;
  my $fh;

  my $url  = "http://" . $ttsHost{$TTS_Ressource} . $ttsPath{$TTS_Ressource};
     $url .= $ttsLang{$TTS_Ressource};
     $url .= $language{$TTS_Ressource}{$TTS_Language};
     $url .= "&" . $ttsAddon{$TTS_Ressource}              if(length($ttsAddon{$TTS_Ressource})>0);
     $url .= "&" . $ttsUser{$TTS_Ressource} . $TTS_User     if(length($ttsUser{$TTS_Ressource})>0);
     $url .= "&" . $ttsAPIKey{$TTS_Ressource} . $TTS_APIKey if(length($ttsAPIKey{$TTS_Ressource})>0);
     $url .= "&" . $ttsQuality{$TTS_Ressource} . $TTS_Quality if(length($ttsQuality{$TTS_Ressource})>0);
     $url .= "&" . $ttsSpeed{$TTS_Ressource} . $TTS_Speed if(length($ttsSpeed{$TTS_Ressource})>0);
     $url .= "&" . $ttsQuery{$TTS_Ressource} . uri_escape($text);
  
  Log3 $hash->{NAME}, 4, "Text2SpeechSB: Verwende ".$TTS_Ressource." OnlineResource zum Download";
  Log3 $hash->{NAME}, 4, "Text2SpeechSB: Hole URL: ". $url;
  #$HttpResponse = GetHttpFile($ttsHost, $ttsPath . $ttsLang . $language{$TTS_Ressource}{$TTS_Language} . "&" . $ttsQuery . uri_escape($text));
  my $param = {
                    url         => $url,
                    timeout     => 5,
                    hash        => $hash,                                                                                  # Muss gesetzt werden, damit die Callback funktion wieder $hash hat
                    method      => "GET"                                                                                  # Lesen von Inhalten
                    #httpversion => "1.1",
                    #header      => "User-Agent:Mozilla/5.0 (Windows NT 6.2; WOW64) AppleWebKit/537.22 (KHTML, like Gecko) Chrome/25.0.1364.172 Safari/537.22m"              # Den Header gemäss abzufragender Daten ändern
                    #header     => "agent: Mozilla/1.22\r\nUser-Agent: Mozilla/1.22"
                };
  ($HttpResponseErr, $HttpResponse) = HttpUtils_BlockingGet($param);
  
  if(length($HttpResponseErr) > 0) {
    Log3 $hash->{NAME}, 3, "Text2SpeechSB: Fehler beim abrufen der Daten von " .$TTS_Ressource. " Translator";
    Log3 $hash->{NAME}, 3, "Text2SpeechSB: " . $HttpResponseErr; 
  }

  $fh = new IO::File ">$file";
  $fh->binmode;
  if(!defined($fh)) {
    Log3 $hash->{NAME}, 2, "Text2SpeechSB: mp3 Datei <$file> konnte nicht angelegt werden.";
    return undef;
  }

  $fh->print($HttpResponse);
  Log3 $hash->{NAME}, 4, "Text2SpeechSB: Schreibe mp3 in die Datei $file mit ".length($HttpResponse)." Bytes";  
  close($fh);
}

#####################################
sub Text2SpeechSB_DoIt($) {
  my ($hash) = @_;

  my $TTS_CacheFileDir = AttrVal($hash->{NAME}, "TTS_CacheFileDir", "cache");
  my $TTS_Ressource = AttrVal($hash->{NAME}, "TTS_Ressource", "Google");
  my $TTS_Language = AttrVal($hash->{NAME}, "TTS_Language", "Deutsch");
  my $TTS_SentenceAppendix = AttrVal($hash->{NAME}, "TTS_SentenceAppendix", undef); #muss eine mp3-Datei sein, ohne Pfadangabe
  my $TTS_FileTemplateDir = AttrVal($hash->{NAME}, "TTS_FileTemplateDir", "templates");

  my $myFileTemplateDir;
  if($TTS_FileTemplateDir =~ m/^\/.*/) { $myFileTemplateDir = $TTS_FileTemplateDir; } else { $myFileTemplateDir = $TTS_CacheFileDir ."/". $TTS_FileTemplateDir;}

  my $verbose = AttrVal($hash->{NAME}, "verbose", 3);
  my $cmd;

  Log3 $hash->{NAME}, 4, "Verwende TTS Spracheinstellung: ".$TTS_Language;

  if($TTS_Ressource =~ m/(Google|VoiceRSS)/) {

    my $filename;
    my $file;

    unless(-e $TTS_CacheFileDir or mkdir $TTS_CacheFileDir) {
      #Verzeichnis anlegen gescheitert
      Log3 $hash->{NAME}, 2, "Text2SpeechSB: Angegebenes Verzeichnis $TTS_CacheFileDir konnte erstmalig nicht angelegt werden.";
      return undef;
    }

    
    if(AttrVal($hash->{NAME}, "TTS_UseMP3Wrap", 0)) {
      # benutze das Tool MP3Wrap um bereits einzelne vorhandene Sprachdateien
      # zusammenzuführen. Ziel: sauberer Sprachfluss
      my @Mp3WrapFiles;
      my @Mp3WrapText;
      
      $TTS_SentenceAppendix = $myFileTemplateDir ."/". $TTS_SentenceAppendix if($TTS_SentenceAppendix);
      undef($TTS_SentenceAppendix) if($TTS_SentenceAppendix && (! -e $TTS_SentenceAppendix));

      #Abspielliste erstellen
      foreach my $t (@{$hash->{helper}{Text2SpeechSB}}) {
        if(-e $TTS_CacheFileDir."/".$t) { $filename = $t;} else {$filename = md5_hex($language{$TTS_Ressource}{$TTS_Language} ."|". $t) . ".mp3";} # falls eine bestimmte mp3-Datei gespielt werden soll
        $file = $TTS_CacheFileDir."/".$filename;
        if(-e $file) {
          push(@Mp3WrapFiles, $file);
          push(@Mp3WrapText, $t);
          #Text2SpeechSB_WriteStats($hash, 0, $file, $t);
        } else {last;}
      }

      push(@Mp3WrapFiles, $TTS_SentenceAppendix) if($TTS_SentenceAppendix);

      if(scalar(@Mp3WrapFiles) >= 2) {
        Log3 $hash->{NAME}, 4, "Text2SpeechSB: Bearbeite per MP3Wrap jetzt den Text: ". join(" ", @Mp3WrapText);

        my $Mp3WrapPrefix = md5_hex(join("|", @Mp3WrapFiles));
        my $Mp3WrapFile = $TTS_CacheFileDir ."/". $Mp3WrapPrefix . "_MP3WRAP.mp3"; 

        if(! -e $Mp3WrapFile) {
          $cmd = "mp3wrap " .$TTS_CacheFileDir. "/" .$Mp3WrapPrefix. ".mp3 " .join(" ", @Mp3WrapFiles);
          $cmd .= " >/dev/null" if($verbose < 5);;

          Log3 $hash->{NAME}, 4, "Text2SpeechSB: " .$cmd;
          system($cmd);
        }
        if(-e $Mp3WrapFile) {
          if($hash->{ALSADEVICE} eq "SB_PLAYER") {  # CD
            BlockingInformParent("Text2SpeechSB_DoTriggerByName", [$hash->{NAME}, "ttsadd ".$Mp3WrapPrefix."_MP3WRAP.mp3"], 0);
          } else {
          $cmd = Text2SpeechSB_BuildMplayerCmdString($hash, $Mp3WrapFile);
          Log3 $hash->{NAME}, 4, "Text2SpeechSB:" .$cmd;
          system($cmd);
          }
          #Text2SpeechSB_WriteStats($hash, 1, $Mp3WrapFile, join(" ", @Mp3WrapText));
        } else {
          Log3 $hash->{NAME}, 2, "Text2SpeechSB: Mp3Wrap Datei konnte nicht angelegt werden.";
        }
        
        return $hash->{NAME} ."|". 
               ($TTS_SentenceAppendix ? scalar(@Mp3WrapFiles)-1: scalar(@Mp3WrapFiles)) ."|". 
               $Mp3WrapFile;
      }
    }

    Log3 $hash->{NAME}, 4, "Text2SpeechSB: Bearbeite jetzt den Text: ". $hash->{helper}{Text2SpeechSB}[0];

    if(-e $hash->{helper}{Text2SpeechSB}[0]) {
      # falls eine bestimmte mp3-Datei mit absolutem Pfad gespielt werden soll
      $filename = $hash->{helper}{Text2SpeechSB}[0];
      $file = $filename;
      Log3 $hash->{NAME}, 4, "Text2SpeechSB: $filename als direkte MP3 Datei erkannt!";
    } elsif(-e $TTS_CacheFileDir."/".$hash->{helper}{Text2SpeechSB}[0]) { 
      # falls eine bestimmte mp3-Datei mit relativem Pfad gespielt werden soll
      $filename = $hash->{helper}{Text2SpeechSB}[0];
      $file = $TTS_CacheFileDir."/".$filename;
      Log3 $hash->{NAME}, 4, "Text2SpeechSB: $filename als direkte MP3 Datei erkannt!";
    } else {
      $filename = md5_hex($language{$TTS_Ressource}{$TTS_Language} ."|". $hash->{helper}{Text2SpeechSB}[0]) . ".mp3";
      $file = $TTS_CacheFileDir."/".$filename;
      Log3 $hash->{NAME}, 4, "Text2SpeechSB: Textbaustein ist keine direkte MP3 Datei, ermittle MD5 CacheNamen: $filename";
    } 
    
    if(! -e $file) { # Datei existiert noch nicht im Cache
      Text2SpeechSB_Download($hash, $file, $hash->{helper}{Text2SpeechSB}[0]);
    } else {
      Log3 $hash->{NAME}, 4, "Text2SpeechSB: $file gefunden, kein Download";
    }

    if(-e $file) { # Datei existiert jetzt
      if($hash->{ALSADEVICE} eq "SB_PLAYER") {  # CD
        BlockingInformParent("Text2SpeechSB_DoTriggerByName", [$hash->{NAME}, "ttsadd $filename"], 0);
      } else {
        $cmd = Text2SpeechSB_BuildMplayerCmdString($hash, $file);
        Log3 $hash->{NAME}, 4, "Text2SpeechSB:" .$cmd;
        system($cmd);
      }
    }

    return $hash->{NAME}. "|". 
           "1" ."|".
           $file;

  } elsif ($TTS_Ressource eq "ESpeak") {
    $cmd = "sudo espeak -vde+f3 -k5 -s150 \"" . $hash->{helper}{Text2SpeechSB}[0] . "\""; 
    Log3 $hash, 4, "Text2SpeechSB:" .$cmd;
    system($cmd);
  } elsif ($TTS_Ressource eq "SVOX-pico") {
  	my $Mp3FilePath = $TTS_CacheFileDir . "/" . md5_hex($hash->{helper}{Text2SpeechSB}[0]) . ".mp3";
  	if(! -e $Mp3FilePath) {
  	  #Generate .wav file and convert to .mp3
  	  my $WavFilePath = $TTS_CacheFileDir . "/" . md5_hex($hash->{helper}{Text2SpeechSB}[0]) . ".wav";
  	  my $TTS_Language = AttrVal($hash->{NAME}, "TTS_Language", "de-DE");
  	  
  	  $cmd = "pico2wave --lang=" . $TTS_Language . " --wave=\"" . $WavFilePath . "\" \"" . $hash->{helper}{Text2SpeechSB}[0] . "\""; 
        Log3 $hash, 4, "Text2SpeechSB:" .$cmd;
        system($cmd);
  	  
  	  $cmd = "lame \"" . $WavFilePath . "\" \"" . $Mp3FilePath . "\""; 
        Log3 $hash, 4, "Text2SpeechSB:" .$cmd;
        system($cmd);
  	  
  	  unlink $WavFilePath;
  	}
  	
  	#Play .mp3 file
  	if(-e $Mp3FilePath) {
      if($hash->{ALSADEVICE} eq "SB_PLAYER") {  # CD
        BlockingInformParent("Text2SpeechSB_DoTriggerByName", [$hash->{NAME}, "ttsadd $Mp3FilePath"], 0);
      } else {
        $cmd = Text2SpeechSB_BuildMplayerCmdString($hash, $Mp3FilePath);
        Log3 $hash->{NAME}, 4, "Text2SpeechSB:" .$cmd;
        system($cmd);
      }
  	}
  }

  return $hash->{NAME}. "|". 
         "1" ."|".
         "";
}

####################################################
# Rückgabe der Blockingfunktion
# param1: HashName
# param2: Anzahl der abgearbeiteten Textbausteine
# param3: Dateiname der abgespielt wurde
####################################################
sub Text2SpeechSB_Done($) {
  my ($string) = @_;
  return unless(defined($string));

  my @a = split("\\|",$string);
  my $hash = $defs{shift(@a)};
  my $tts_done = shift(@a);
  my $filename = shift(@a);
  
  my $TTS_TimeOut   = AttrVal($hash->{NAME}, "TTS_TimeOut", 60);

  if($filename) {
    my @text;
    for(my $i=0; $i<$tts_done; $i++) { 
      push(@text, $hash->{helper}{Text2SpeechSB}[$i]);
    }         
    Text2SpeechSB_WriteStats($hash, 1, $filename, join(" ", @text));
  }

  delete($hash->{helper}{RUNNING_PID});
  splice(@{$hash->{helper}{Text2SpeechSB}}, 0, $tts_done);

  # erneutes aufrufen da ev. weiterer Text in der Warteschlange steht
  if(@{$hash->{helper}{Text2SpeechSB}} > 0) {
    $hash->{helper}{RUNNING_PID} = BlockingCall("Text2SpeechSB_DoIt", $hash, "Text2SpeechSB_Done", $TTS_TimeOut, "Text2SpeechSB_AbortFn", $hash);
  } else {
    readingsSingleUpdate($hash, "playing", "0", 1);
    if(defined($hash->{helper}{SB_PLAYER})) {
      my $sb=$hash->{helper}{SB_PLAYER};
      delete($hash->{helper}{SB_PLAYER});
      DoTrigger($hash->{NAME}, "$sb ttsdone");
    }
  }
}

#####################################
sub Text2SpeechSB_AbortFn($)     { 
  my ($hash) = @_;

  delete($hash->{helper}{RUNNING_PID});
  Log3 $hash->{NAME}, 2, "Text2SpeechSB: BlockingCall for ".$hash->{NAME}." was aborted";
}

#####################################
# Hiermit werden Statistken per DbLogModul gesammelt
# Wichitg zur Entscheidung welche Dateien aus dem Cache lange 
# nicht benutzt und somit gelöscht werden koennen.
#
# param1: hash
# param2: int:    0=indirekt (über mp3wrap); 1=direkt abgespielt
# param3: string: Datei
# param4: string: Text der als mp3 abgespielt wird
#####################################
sub Text2SpeechSB_WriteStats($$$$){
  my($hash, $typ, $file, $text) = @_;
  my $DbLogDev;

  #suche ein DbLogDevice
  return undef unless($modules{"DbLog"} && $modules{"DbLog"}{"LOADED"});
  foreach my $key (keys(%defs)) {
    if($defs{$key}{TYPE} eq "DbLog") {
      $DbLogDev = $key;
      last;
    } 
  }
  return undef if($defs{$DbLogDev}{STATE} !~ m/(active|connected)/); # muss active sein!

  # den letzten Value von "Usage" ermitteln um dann die Staistik um 1 zu erhoehen.
  my @LastValue = DbLog_Get($defs{$DbLogDev}, "", "current", "array", "-", "-", $hash->{NAME} ."|". $file.":Usage");
  my $NewValue = 1;
  $NewValue = $LastValue[0]{value} + 1 if($LastValue[0]);

  #           DbLogHash,        DbLogTable, TIMESTAMP, DEVICE,                    TYPE,          EVENT, READING, VALUE,     UNIT
  DbLog_Push($defs{$DbLogDev}, "Current", TimeNow(), $hash->{NAME} ."|". $file, $hash->{TYPE}, $text, "Usage", $NewValue, "");
}

1;

=pod
=begin html

<a name="Text2SpeechSB"></a>
<h3>Text2SpeechSB</h3> 
<ul>
  <br>
  <a name="Text2SpeechSBdefine"></a>
  <b>Define</b>
  <ul>
    <b>Local : </b><code>define &lt;name&gt; Text2SpeechSB &lt;alsadevice&gt;</code><br>
    <b>Remote: </b><code>define &lt;name&gt; Text2SpeechSB &lt;host&gt;[:&lt;portnr&gt;][:SSL] [portpassword]</code> 
    <p>
    This module converts any text into speech with serveral possible providers. The Device can be defined as locally 
    or remote device.
    </p>
       
    <li>
      <b>Local Device</b><br>
      <ul>
        The output will be send to any connected audiodevice. For example external speakers connected per jack 
        or with bluetooth speakers - connected per bluetooth dongle. Its important to install mplayer.<br>
        <code>apt-get install mplayer</code><br>
        The given alsadevice has to be configured in <code>/etc/asound.conf</code>
        <p>
          <b>Special AlsaDevice: </b><i>none</i><br>
          The internal mplayer command will be without any audio directive if the given alsadevice is <i>none</i>.
          In this case mplayer is using the standard audiodevice.
        </p>
        <p>
          <b>Example:</b><br>
          <code>define MyTTS Text2SpeechSB hw=0.0</code><br>
          <code>define MyTTS Text2SpeechSB none</code>
        </p>
      </ul>
    </li>

    <li>
      <b>Remote Device</b><br>
      <ul>
        This module can configured as remote-device for client-server Environments. The Client has to be configured 
        as local device.<br>
        Notice: the Name of the locally instance has to be the same!
        <ul>
          <li>Host: setting up IP-adress</li>
          <li>PortNr: setting up TelnetPort of FHEM; default: 7072</li>
          <li>SSL: setting up if connect over SSL; default: no SSL</li>
          <li>PortPassword: setting up the configured target telnet passwort</li>
        </ul>
        <p>
          <b>Example:</b><br>
          <code>define MyTTS Text2SpeechSB 192.168.178.10:7072 fhempasswd</code>
          <code>define MyTTS Text2SpeechSB 192.168.178.10</code>
        </p>
      </ul>
    </li>

  </ul>
</ul>

<a name="Text2SpeechSBset"></a>
<b>Set</b> 
<ul>
  <li><b>tts</b>:<br>
    Giving a text to translate into audio. You play set mp3-files directly. In this case you have to enclosure them with a single colon before and after the declaration.
    The files must save under the directory of given <i>TTS_FileTemplateDir</i>.
    Please note: The text doesn´t have any colons itself.
  </li>
  <li><b>volume</b>:<br>
    Setting up the volume audio response.<br>
    Notice: Only available in locally instances!
  </li>
</ul><br> 

<a name="Text2SpeechSBget"></a>
<b>Get</b> 
<ul>N/A</ul><br> 

<a name="Text2SpeechSBattr"></a>
<b>Attributes</b>
<ul>
  <li>TTS_Delemiter<br>
    optional: By using the google engine, its not possible to convert more than 100 characters in a single audio brick.
    With a delemiter the audio brick will be split at this character. A delemiter must be a single character.!<br>
    By default, ech audio brick will be split at sentence end. Is a single sentence longer than 100 characters, 
    the sentence will be split additionally at comma, semicolon and the word <i>and</i>.<br>
    Notice: Only available in locally instances with Google engine!
  </li> 

  <li>TTS_Ressource<br>
    optional: Selection of the Translator Engine<br>
    Notice: Only available in locally instances!
    <ul>
      <li>Google<br>
        Using the Google Engine. It´s nessessary to have internet access. This engine is the recommend engine
        because the quality is fantastic. This engine is using by default.
      </li>
      <li>VoiceRSS<br>
        Using the VoiceRSS Engine. Its a free engine till 350 requests per day. If you need more, you have to pay. 
        It´s nessessary to have internet access. This engine is the 2nd recommend engine
        because the quality is also fantastic. To use this engine you need an APIKey (see TTS_APIKey)
      </li>
      <li>ESpeak<br>
        Using the ESpeak Engine. Installation of the espeak sourcen is required.<br>
        <code>apt-get install espeak</code>
      </li>
	  <li>SVOX-pico<br>
        Using SVOX-Pico TTS-Engine (from the AOSP).<br>
		Installation of the engine and <code>lame</code> is required, see <a target="_blank" href="http://blogs.uni-due.de/zim/2014/03/21/sprich-freund-und-tritt-ein-sprachausgabe-fur-den-raspberry-pi-mit-espeak-und-svox-pico/">here</a> or in short:<br>
        <code>sudo apt-get install libpopt-dev lame</code><br>
        <code>cd /tmp</code><br>
        <code>wget http://www.dr-bischoff.de/raspi/pico2wave.deb</code><br>
        <code>sudo dpkg --install pico2wave.deb</code>
      </li>
    </ul>
  </li>

  <li>TTS_APIKey<br>
    An APIKey its needed if you want to use VoiceRSS. You have to register at the following page:<br>
    http://www.voicerss.org/registration.aspx <br>
    After this, you will get your personal APIKey.
  </li>

  <li>TTS_User<br>
    Actual without any usage. Needed in case if a TTS Engine need an username and an apikey for each request.
  </li>

  <li>TTS_CacheFileDir<br>
    optional: The downloaded Goole audio bricks are saved in this folder for reusing. 
    No automatically implemented deleting are available.<br>
    Default: <i>cache/</i><br>
    Notice: Only available in locally instances!
  </li>

  <li>TTS_UseMP3Wrap<br>
    optional: To become a liquid audio response its recommend to use the tool mp3wrap.
    Each downloaded audio bricks are concatinated to a single audio file to play with mplayer.<br>
    Installtion of the mp3wrap source is required.<br>
    <code>apt-get install mp3wrap</code><br>
    Notice: Only available in locally instances!
  </li>

  <li>TTS_MplayerCall<br>
    optional: Setting up the Mplayer system call. The following example is default.<br>
    Example: <code>sudo /usr/bin/mplayer</code>
  </li>

  <li>TTS_SentenceAppendix<br>
    Optional: Definition of one mp3-file to append each time of audio response.<br>
    Using of Mp3Wrap is required. The audio bricks has to be downloaded before into CacheFileDir.
    Example: <code>silence.mp3</code>
  </li>

  <li>TTS_FileMapping<br>
    Definition of mp3files with a custom templatedefinition. Separated by space.
    All templatedefinitions can used in audiobricks by <i>tts</i>. 
    The definition must begin and end with e colon. 
    The mp3files must saved in the given directory by <i>TTS_FIleTemplateDir</i>.<br>
    <code>attr myTTS TTS_FileMapping ring:ringtone.mp3 beep:MyBeep.mp3</code><br>
    <code>set MyTTS tts Attention: This is my ringtone :ring: Its loud?</code>
  </li>

  <li>TTS_FileTemplateDir<br>
    Directory to save all mp3-files are defined in <i>TTS_FileMapping</i> und <i>TTS_SentenceAppendix</i><br>
    Optional, Default: <code>cache/templates</code>
  </li>

  <li><a href="#readingFnAttributes">readingFnAttributes</a></li><br>

  <li><a href="#disable">disable</a><br>
    If this attribute is activated, the soundoutput will be disabled.<br>
    Possible values: 0 => not disabled , 1 => disabled<br>
    Default Value is 0 (not disabled)<br><br> 
  </li>

  <li><a href="#verbose">verbose</a><br>
    <b>4:</b> each step will be logged<br>
    <b>5:</b> Additionally the individual debug informations from mplayer and mp3wrap will be logged
  </li>

</ul><br>

<a name="Text2SpeechSBExamples"></a>
<b>Beispiele</b> 
<ul>
  <code>define MyTTS Text2SpeechSB hw=0.0</code><br>
  <code>set MyTTS tts Die Alarmanlage ist bereit.</code><br>
  <code>set MyTTS tts :beep.mp3:</code><br>
  <code>set MyTTS tts :mytemplates/alarm.mp3:Die Alarmanlage ist bereit.:ring.mp3:</code><br>
</ul>

=end html
=begin html_DE

<a name="Text2SpeechSB"></a>
<h3>Text2SpeechSB</h3> 
<ul>
  <br>
  <a name="Text2SpeechSBdefine"></a>
  <b>Define</b>
  <ul>
    <b>Local : </b><code>define &lt;name&gt; Text2SpeechSB &lt;alsadevice&gt;</code><br>
    <b>Remote: </b><code>define &lt;name&gt; Text2SpeechSB &lt;host&gt;[:&lt;portnr&gt;][:SSL] [portpassword]</code> 
    <p>
    Das Modul wandelt Text mittels verschiedener Provider/Ressourcen in Sprache um. Dabei kann das Device als 
    Remote oder Lokales Device konfiguriert werden.
    </p>
       
    <li>
      <b>Local Device</b><br>
      <ul>
        Die Ausgabe erfolgt auf angeschlossenen Audiodevices, zb. Lautsprecher direkt am Ger&auml;t oder per 
        Bluetooth-Lautsprecher per Mplayer. Dazu ist Mplayer zu installieren.<br>
        <code>apt-get install mplayer</code><br>
        Das angegebene Alsadevice ist in der <code>/etc/asound.conf</code> zu konfigurieren.
        <p>
          <b>Special AlsaDevice: </b><i>none</i><br>
          Ist als Alsa-Device <i>none</i> angegeben, so wird mplayer ohne eine Audiodevice Angabe aufgerufen. 
          Dementsprechend verwendet mplayer das Standard Audio Ausgabedevice.
        </p>
        <p>
          <b>Beispiel:</b><br>
          <code>define MyTTS Text2SpeechSB hw=0.0</code><br>
          <code>define MyTTS Text2SpeechSB none</code>
        </p>
      </ul>
    </li>

    <li>
      <b>Remote Device</b><br>
      <ul>
        Das Modul ist Client-Server f&auml;as bedeutet, das auf der Haupt-FHEM Installation eine Text2SpeechSB-Instanz 
        als Remote definiert wird. Auf dem Client wird Text2SpeechSB als Local definiert. Die Sprachausgabe erfolgt auf 
        der lokalen Instanz.<br>
        Zu beachten ist, das die Text2SpeechSB Instanz (Definition als local Device) auf dem Zieldevice identisch benannt ist.
        <ul>
          <li>Host: Angabe der IP-Adresse</li>
          <li>PortNr: Angabe des TelnetPorts von FHEM; default: 7072</li>
          <li>SSL: Angabe ob der der Zugriff per SSL erfolgen soll oder nicht; default: kein SSL</li>
          <li>PortPassword: Angabe des in der Ziel-FHEM-Installtion angegebene Telnet Portpasswort</li>
        </ul>
        <p>
          <b>Beispiel:</b><br>
          <code>define MyTTS Text2SpeechSB 192.168.178.10:7072 fhempasswd</code>
          <code>define MyTTS Text2SpeechSB 192.168.178.10</code>
        </p>
      </ul>
    </li>

  </ul>
</ul>

<a name="Text2SpeechSBset"></a>
<b>Set</b> 
<ul>
  <li><b>tts</b>:<br>
    Setzen eines Textes zur Sprachausgabe. Um mp3-Dateien direkt auszugeben, müssen diese mit f&uuml;hrenden 
    und schließenden Doppelpunkten angegebenen sein. Die MP3-Dateien müssen unterhalb des Verzeichnisses <i>TTS_FileTemplateDir</i> gespeichert sein.<br>
    Der Text selbst darf deshalb selbst keine Doppelpunte beinhalten. Siehe Beispiele.
  </li>
  <li><b>volume</b>:<br>
    Setzen der Ausgabe Lautst&auml;rke.<br>
    Achtung: Nur bei einem lokal definierter Text2SpeechSB Instanz m&ouml;glich!
  </li>
</ul><br> 

<a name="Text2SpeechSBget"></a>
<b>Get</b> 
<ul>N/A</ul><br> 

<a name="Text2SpeechSBattr"></a>
<b>Attribute</b>
<ul>
  <li>TTS_Delemiter<br>
    Optional: Wird ein Delemiter angegeben, so wird der Sprachbaustein an dieser Stelle geteilt. 
    Als Delemiter ist nur ein einzelnes Zeichen zul&auml;ssig.
    Hintergrund ist die Tatsache, das die Google Sprachengine nur 100Zeichen zul&auml;sst.<br>
    Im Standard wird nach jedem Satzende geteilt. Ist ein einzelner Satz l&auml;nger als 100 Zeichen,
    so wird zus&auml;tzlich nach Kommata, Semikolon und dem Verbindungswort <i>und</i> geteilt.<br>
    Achtung: Nur bei einem lokal definierter Text2SpeechSB Instanz m&ouml;glich und nur Nutzung der Google Sprachengine relevant!
  </li> 

  <li>TTS_Ressource<br>
    Optional: Auswahl der Sprachengine<br>
    Achtung: Nur bei einem lokal definierter Text2SpeechSB Instanz m&ouml;glich!
    <ul>
      <li>Google<br>
        Nutzung der Google Sprachengine. Ein Internetzugriff ist notwendig! Aufgrund der Qualit&auml;t ist der 
        Einsatz diese Engine zu empfehlen und der Standard.
      </li>
      <li>VoiceRSS<br>
        Nutzung der VoiceRSS Sprachengine. Die Nutzung ist frei bis zu 350 Anfragen pro Tag. 
        Wenn mehr benötigt werden ist ein Bezahlmodell wählbar. Ein Internetzugriff ist notwendig! 
        Aufgrund der Qualit&auml;t ist der Einsatz diese Engine ebenfalls zu empfehlen.
        Wenn diese Engine benutzt wird, ist ein APIKey notwendig (siehe TTXS_APIKey)
      </li>
      <li>ESpeak<br>
        Nutzung der ESpeak Offline Sprachengine. Die Qualit&auml; ist schlechter als die Google Engine.
        ESpeak ist vor der Nutzung zu installieren.<br>
        <code>apt-get install espeak</code>
      </li>
	  <li>SVOX-pico<br>
        Nutzung der SVOX-Pico TTS-Engine (aus dem AOSP).<br>
		Die Sprachengine sowie <code>lame</code> müssen installiert sein, siehe <a target="_blank" href="http://blogs.uni-due.de/zim/2014/03/21/sprich-freund-und-tritt-ein-sprachausgabe-fur-den-raspberry-pi-mit-espeak-und-svox-pico/">hier</a> oder in aller K&uuml;rze:<br>
        <code>sudo apt-get install libpopt-dev lame</code><br>
        <code>cd /tmp</code><br>
        <code>wget http://www.dr-bischoff.de/raspi/pico2wave.deb</code><br>
        <code>sudo dpkg --install pico2wave.deb</code>
		</code>
      </li>
    </ul>
  </li>
  
  <li>TTS_APIKey<br>
    Wenn VoiceRSS genutzt wird, ist ein APIKey notwendig. Um diesen zu erhalten ist eine vorherige
    Registrierung notwendig. Anschließend erhält man den APIKey <br>
    http://www.voicerss.org/registration.aspx <br>
  </li>

  <li>TTS_User<br>
    Bisher ohne Benutzung. Falls eine Sprachengine zusätzlich zum APIKey einen Usernamen im Request verlangt.
  </li>

  <li>TTS_CacheFileDir<br>
    Optional: Die per Google geladenen Sprachbausteine werden in diesem Verzeichnis zur Wiedeverwendung abgelegt.
    Es findet zurZEit keine automatisierte L&ouml;schung statt.<br>
    Default: <i>cache/</i><br>
    Achtung: Nur bei einem lokal definierter Text2SpeechSB Instanz m&ouml;glich!
  </li>

  <li>TTS_UseMP3Wrap<br>
    Optional: F&uuml;r eine fl&uuml;ssige Sprachausgabe ist es zu empfehlen, die einzelnen vorher per Google 
    geladenen Sprachbausteine zu einem einzelnen Sprachbaustein zusammenfassen zu lassen bevor dieses per 
    Mplayer ausgegeben werden. Dazu muss Mp3Wrap installiert werden.<br>
    <code>apt-get install mp3wrap</code><br>
    Achtung: Nur bei einem lokal definierter Text2SpeechSB Instanz m&ouml;glich!
  </li>

  <li>TTS_MplayerCall<br>
    Optional: Angabe der Systemaufrufes zu Mplayer. Das folgende Beispiel ist der Standardaufruf.<br>
    Beispiel: <code>sudo /usr/bin/mplayer</code>
  </li>

  <li>TTS_SentenceAppendix<br>
    Optional: Angabe einer mp3-Datei die mit jeder Sprachausgabe am Ende ausgegeben wird.<br>
    Voraussetzung ist die Nutzung von MP3Wrap. Die Sprachbausteine müssen bereits als mp3 im 
    CacheFileDir vorliegen.
    Beispiel: <code>silence.mp3</code>
  </li>

  <li>TTS_FileMapping<br>
    Angabe von m&ouml;glichen MP3-Dateien mit deren Templatedefinition. Getrennt duch Leerzeichen.
    Die Templatedefinitionen können in den per <i>tts</i> &uuml;bergebenen Sprachbausteinen verwendet werden
    und m&uuml;ssen mit einem beginnenden und endenden Doppelpunkt angegeben werden.
    Die Dateien müssen im Verzeichnis <i>TTS_FileTemplateDir</i> gespeichert sein.<br>
    <code>attr myTTS TTS_FileMapping ring:ringtone.mp3 beep:MyBeep.mp3</code><br>
    <code>set MyTTS tts Achtung: hier kommt mein Klingelton :ring: War der laut?</code>
  </li>

  <li>TTS_FileTemplateDir<br>
    Verzeichnis, in dem die per <i>TTS_FileMapping</i> und <i>TTS_SentenceAppendix</i> definierten
    MP3-Dateien gespeichert sind.<br>
    Optional, Default: <code>cache/templates</code>
  </li>

  <li>TTS_VolumeAdjust<br>
    Anhebung der Grundlautstärke zur Anpassung an die angeschlossenen Lautsprecher. <br>
    Default: 110<br>
    <code>attr myTTS TTS_VolumeAdjust 400</code><br>
  </li>

  <li><a href="#readingFnAttributes">readingFnAttributes</a></li><br>

  <li><a href="#disable">disable</a><br>
    If this attribute is activated, the soundoutput will be disabled.<br>
    Possible values: 0 => not disabled , 1 => disabled<br>
    Default Value is 0 (not disabled)<br><br> 
  </li>

  <li><a href="#verbose">verbose</a><br>
    <b>4:</b> Alle Zwischenschritte der Verarbeitung werden ausgegeben<br>
    <b>5:</b> Zus&auml;tzlich werden auch die Meldungen von Mplayer und Mp3Wrap ausgegeben
  </li>

</ul><br> 

<a name="Text2SpeechSBExamples"></a>
<b>Beispiele</b> 
<ul>
  <code>define MyTTS Text2SpeechSB hw=0.0</code><br>
  <code>set MyTTS tts Die Alarmanlage ist bereit.</code><br>
  <code>set MyTTS tts :beep.mp3:</code><br>
  <code>set MyTTS tts :mytemplates/alarm.mp3:Die Alarmanlage ist bereit.:ring.mp3:</code><br>
</ul>


=end html_DE
=cut 
