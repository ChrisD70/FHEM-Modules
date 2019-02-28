package Plugins::Voltage::Plugin;

use strict;
use base qw(Slim::Plugin::Base);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Misc;
use Slim::Utils::Strings;
use vars qw($VERSION);

my $prefs = preferences('server'); 

# A logger we will use to write plugin-specific messages. 
my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.Voltage',
	'defaultLevel' => 'ERROR',
	'description'  => getDisplayName(),
});

my $CRLF = "\015\012";   # "\r\n" is not portable	

sub getDisplayName { return 'PLUGIN_VOLTAGE_HEADER'; }

sub initPlugin {
	my $class = shift;

	$VERSION = $class->_pluginDataFor('version');

	$log->info("Initialising " . Slim::Utils::Strings::string('PLUGIN_VOLTAGE_HEADER') . " version $VERSION");

	Slim::Control::Request::addDispatch(['voltage', '?'],[1, 1, 0, \&Plugins::Voltage::Plugin::QueryVoltage]); 
  
	$class->SUPER::initPlugin;
}

sub QueryVoltage {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['voltage']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get the parameters
	my $client = $request->client();

	$request->addResult('_voltage', Slim::Networking::Slimproto::voltage($client) || 0);
	$request->setStatusDone();
} 

1;

__END__
